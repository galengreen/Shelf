import Foundation
import os
import UIKit

nonisolated private let log = Logger(subsystem: "nz.galengreen.shelf", category: "api")

nonisolated enum APIError: LocalizedError, Sendable {
    case unauthorized
    case http(Int)
    case offline
    case invalidURL
    case invalidResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your session has expired. Please sign in again."
        case .http(let code): "The server responded with an error (\(code))."
        case .offline: "You're offline."
        case .invalidURL: "That server address doesn't look right."
        case .invalidResponse: "The server sent an unexpected response."
        case .decoding(let detail): "Couldn't read the server's response. \(detail)"
        }
    }

    var isConnectivity: Bool {
        if case .offline = self { return true }
        return false
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

/// All traffic to the Audiobookshelf server goes through this actor.
///
/// - Access tokens are refreshed proactively (before expiry) and at most once at a time, so
///   concurrent requests never race to rotate the refresh token (a common source of random logouts).
/// - Cacheable GETs use ETags: unchanged responses come back as an empty 304 and are served from disk,
///   which keeps library refreshes to a few hundred bytes. The same cache serves stale data when offline.
actor APIClient {
    private(set) var credentials: Credentials
    private let session: URLSession
    private let cache = ResponseCache()
    private var refreshTask: Task<TokenPair, Error>?

    private struct TokenPair: Sendable {
        let access: String
        let refresh: String
    }
    private let onCredentialsChange: @Sendable (Credentials?) -> Void

    var baseURL: URL { credentials.serverURL }

    init(credentials: Credentials, onCredentialsChange: @escaping @Sendable (Credentials?) -> Void) {
        self.credentials = credentials
        self.onCredentialsChange = onCredentialsChange
        self.session = APIClient.makeSession()
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil // ETag caching is handled explicitly by ResponseCache
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": DeviceInfo.userAgent]
        return URLSession(configuration: config)
    }

    // MARK: - Unauthenticated

    /// Candidate URLs for what the user typed. Without a scheme, local addresses try plain HTTP
    /// first (most home servers), anything else tries HTTPS first.
    static func candidates(for input: String) throws -> [URL] {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host() != nil else { throw APIError.invalidURL }
            return [url]
        }
        guard let https = URL(string: "https://" + text), let host = https.host()?.lowercased(),
              let http = URL(string: "http://" + text) else { throw APIError.invalidURL }
        let isLocal = host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
        return isLocal ? [http, https] : [https, http]
    }

    /// Finds the first candidate address that answers as an Audiobookshelf server.
    static func resolve(_ input: String) async throws -> (url: URL, status: ServerStatus) {
        var lastError: Error = APIError.invalidURL
        for url in try candidates(for: input) {
            do {
                return (url, try await status(of: url))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func status(of server: URL) async throws -> ServerStatus {
        var request = URLRequest(url: server.appending(path: "status"))
        request.timeoutInterval = 8
        let (data, response) = try await performRaw(request, session: .shared)
        try check(response)
        return try decode(ServerStatus.self, from: data)
    }

    static func login(server: URL, username: String, password: String) async throws -> Credentials {
        var request = URLRequest(url: server.appending(path: "login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONEncoder().encode(["username": username, "password": password])
        let (data, response) = try await performRaw(request, session: .shared)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw APIError.unauthorized }
        try check(response)
        let login = try decode(LoginResponse.self, from: data)
        guard let token = login.user.accessToken ?? login.user.token else { throw APIError.invalidResponse }
        return Credentials(
            serverURL: server,
            userId: login.user.id,
            username: login.user.username,
            accessToken: token,
            refreshToken: login.user.refreshToken,
            defaultLibraryId: login.userDefaultLibraryId
        )
    }

    /// API keys (Settings → API Keys on the server) never expire unless the admin sets an expiry.
    static func login(server: URL, apiKey: String) async throws -> Credentials {
        var request = URLRequest(url: server.appending(path: "api/me"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRaw(request, session: .shared)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw APIError.unauthorized }
        try check(response)
        let user = try decode(User.self, from: data)
        return Credentials(serverURL: server, userId: user.id, username: user.username, accessToken: apiKey, refreshToken: nil)
    }

    // MARK: - Tokens

    /// Returns a token that is valid for at least `margin` seconds.
    func validToken(margin: TimeInterval = 120) async throws -> String {
        if let refreshTask { return try await refreshTask.value.access }
        guard tokenExpiresSoon(within: margin) else { return credentials.accessToken }
        return try await refresh()
    }

    /// True if the token expires within `margin` seconds. The margin is capped at a quarter of the
    /// token's lifetime, so servers configured with short-lived tokens don't refresh on every call.
    func tokenExpiresSoon(within margin: TimeInterval) -> Bool {
        guard credentials.refreshToken != nil, let expiry = JWT.expiry(of: credentials.accessToken) else { return false }
        let lifetime = JWT.lifetime(of: credentials.accessToken) ?? .infinity
        return expiry.timeIntervalSinceNow < min(margin, lifetime / 4)
    }

    /// True if the token can expire at all (JWT with a refresh token, not a legacy token or API key).
    var tokenIsRefreshable: Bool { credentials.refreshToken != nil }

    @discardableResult
    func refresh() async throws -> String {
        if let refreshTask { return try await refreshTask.value.access }
        guard let refreshToken = credentials.refreshToken else { throw APIError.unauthorized }
        let server = credentials.serverURL
        let session = self.session
        let task = Task<TokenPair, Error> {
            var request = URLRequest(url: server.appending(path: "auth/refresh"))
            request.httpMethod = "POST"
            request.setValue(refreshToken, forHTTPHeaderField: "x-refresh-token")
            let (data, response) = try await APIClient.performRaw(request, session: session)
            if let code = (response as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 {
                throw APIError.unauthorized
            }
            try APIClient.check(response)
            let result = try APIClient.decode(LoginResponse.self, from: data)
            guard let access = result.user.accessToken else { throw APIError.invalidResponse }
            return TokenPair(access: access, refresh: result.user.refreshToken ?? refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let tokens = try await task.value
            log.notice("Access token refreshed")
            credentials.accessToken = tokens.access
            credentials.refreshToken = tokens.refresh
            onCredentialsChange(credentials)
            return tokens.access
        } catch APIError.unauthorized {
            onCredentialsChange(nil)
            throw APIError.unauthorized
        }
    }

    // MARK: - Requests

    func get<T: Decodable & Sendable>(_ path: String, query: [String: String] = [:], cached: Bool = false, as type: T.Type = T.self) async throws -> T {
        let data = try await getData(path, query: query, cached: cached)
        return try APIClient.decode(T.self, from: data)
    }

    func getData(_ path: String, query: [String: String] = [:], cached: Bool) async throws -> Data {
        let url = try makeURL(path, query: query)
        let key = cache.key(for: url)
        var request = URLRequest(url: url)
        let stored = cached ? await cache.entry(for: key) : nil
        if let etag = stored?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        do {
            let (data, response) = try await authorised(request)
            let http = response as? HTTPURLResponse
            if http?.statusCode == 304, let stored { return stored.data }
            try APIClient.check(response)
            if cached { await cache.store(data, etag: http?.value(forHTTPHeaderField: "ETag"), for: key) }
            return data
        } catch let error as APIError where error.isConnectivity {
            if let stored { return stored.data }
            throw error
        }
    }

    /// Returns cached data for a GET without touching the network, for instant cold starts.
    func cachedData(_ path: String, query: [String: String] = [:]) async -> Data? {
        guard let url = try? makeURL(path, query: query) else { return nil }
        return await cache.entry(for: cache.key(for: url))?.data
    }

    @discardableResult
    func send(_ method: String, _ path: String, json body: (any Encodable & Sendable)? = nil) async throws -> Data {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await authorised(request)
        try APIClient.check(response)
        return data
    }

    func post<T: Decodable & Sendable>(_ path: String, json body: (any Encodable & Sendable)?, as type: T.Type) async throws -> T {
        try APIClient.decode(T.self, from: try await send("POST", path, json: body))
    }

    /// URL suitable for AVPlayer/background downloads, which can't attach headers.
    func mediaURL(for contentUrl: String) async throws -> URL {
        let token = try await validToken(margin: 600)
        return try makeURL(contentUrl, query: ["token": token])
    }

    func coverRequest(itemId: String, width: Int, version: Int) async throws -> URLRequest {
        let url = try makeURL("api/items/\(itemId)/cover", query: ["width": String(width), "format": "webp", "ts": String(version)])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    func authorImageRequest(authorId: String, width: Int, version: Int) async throws -> URLRequest {
        let url = try makeURL("api/authors/\(authorId)/image", query: ["width": String(width), "format": "webp", "ts": String(version)])
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    func clearCache() async { await cache.removeAll() }
    func cacheSize() async -> Int64 { await cache.size() }

    // MARK: - Plumbing

    private func authorised(_ base: URLRequest) async throws -> (Data, URLResponse) {
        var request = base
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await APIClient.performRaw(request, session: session)
        guard (response as? HTTPURLResponse)?.statusCode == 401, credentials.refreshToken != nil else {
            if (response as? HTTPURLResponse)?.statusCode == 401 { throw APIError.unauthorized }
            return (data, response)
        }
        // Token was rejected early (clock skew, server restart): refresh once and retry.
        request.setValue("Bearer \(try await refresh())", forHTTPHeaderField: "Authorization")
        let retried = try await APIClient.performRaw(request, session: session)
        if (retried.1 as? HTTPURLResponse)?.statusCode == 401 { throw APIError.unauthorized }
        return retried
    }

    private func makeURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // contentUrl values may already carry a query string.
        guard var components = URLComponents(url: credentials.serverURL.appending(path: trimmed.components(separatedBy: "?")[0]), resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL }
        var items = URLComponents(string: "/" + trimmed)?.queryItems ?? []
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    static func performRaw(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .timedOut, .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
                throw APIError.offline
            default:
                throw error
            }
        }
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            throw APIError.http(http.statusCode)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error).prefix(200).description)
        }
    }
}

// MARK: - JWT

nonisolated enum JWT {
    static func expiry(of token: String) -> Date? {
        guard let exp = claims(of: token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func lifetime(of token: String) -> TimeInterval? {
        guard let claims = claims(of: token), let exp = claims["exp"] as? Double, let iat = claims["iat"] as? Double else { return nil }
        return exp - iat
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - Device info

nonisolated enum DeviceInfo {
    static let clientName = "Shelf"
    static let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let userAgent = "Shelf/\(clientVersion) (iOS)"

    /// Stable per-install id so the server shows one device rather than one per session.
    static let deviceId: String = {
        let key = "deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    struct Payload: Encodable, Sendable {
        let deviceId: String
        let clientName: String
        let clientVersion: String
        let manufacturer: String
        let model: String
    }

    static var payload: Payload {
        Payload(deviceId: deviceId, clientName: clientName, clientVersion: clientVersion, manufacturer: "Apple", model: model)
    }
}

// MARK: - Response cache

/// A tiny on-disk store of `(ETag, body)` per URL.
actor ResponseCache {
    struct Entry: Sendable {
        let etag: String?
        let data: Data
    }

    private let directory: URL = {
        let dir = URL.cachesDirectory.appending(path: "api", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated func key(for url: URL) -> String {
        // Strip auth tokens so a refreshed token doesn't miss the cache.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems?.filter { $0.name != "token" }
        components?.queryItems = items
        let raw = components?.url?.absoluteString ?? url.absoluteString
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .prefix(200).description
    }

    func entry(for key: String) -> Entry? {
        let file = directory.appending(path: key)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let etag = try? String(contentsOf: file.appendingPathExtension("etag"), encoding: .utf8)
        return Entry(etag: etag, data: data)
    }

    func store(_ data: Data, etag: String?, for key: String) {
        let file = directory.appending(path: key)
        try? data.write(to: file, options: .atomic)
        let etagFile = file.appendingPathExtension("etag")
        if let etag { try? etag.write(to: etagFile, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: etagFile) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func size() -> Int64 {
        FileManager.default.directorySize(directory)
    }
}

extension FileManager {
    nonisolated func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
