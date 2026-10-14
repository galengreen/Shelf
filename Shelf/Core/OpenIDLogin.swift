import AuthenticationServices
import CryptoKit
import Foundation

/// Single sign-on through the server's OpenID Connect provider (Authentik, Authelia, Keycloak …),
/// using Audiobookshelf's mobile flow:
///
/// 1. Ask the server to start a login with our PKCE challenge. It answers with a redirect to the
///    provider and a session cookie, which we keep in a private cookie store.
/// 2. Show the provider's login page in the system browser sheet. When done, the server redirects
///    to `audiobookshelf://oauth?code=…&state=…` (allowed by default on every server).
/// 3. Exchange the code (with the PKCE verifier and the same cookie) for tokens.
nonisolated enum OpenIDLogin {
    static let callbackScheme = "audiobookshelf"
    static let redirectURI = "audiobookshelf://oauth"

    enum Failure: LocalizedError {
        case notOffered, cancelled, stateMismatch, rejected(String)

        var errorDescription: String? {
            switch self {
            case .notOffered: "This server doesn't have single sign-on set up."
            case .cancelled: nil
            case .stateMismatch: "The sign-in response didn't match. Please try again."
            case .rejected(let message): message
            }
        }
    }

    /// Prepares step 1 and returns the provider URL to open, plus what's needed to finish.
    static func begin(server: URL) async throws -> Pending {
        let verifier = randomString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = randomString()
        guard var components = URLComponents(url: server.appending(path: "auth/openid"), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: DeviceInfo.clientName),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: state),
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
              let providerURL = URL(string: location, relativeTo: server)?.absoluteURL else {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if http.statusCode == 400 && message.localizedCaseInsensitiveContains("redirect") {
                throw Failure.rejected("The server doesn't allow the app's sign-in address. In Audiobookshelf, add \(redirectURI) to the OpenID mobile redirect URIs.")
            }
            throw message.isEmpty ? Failure.notOffered : Failure.rejected(message)
        }
        return Pending(server: server, providerURL: providerURL, verifier: verifier, state: state, session: session)
    }

    struct Pending: Sendable {
        let server: URL
        let providerURL: URL
        let verifier: String
        let state: String
        let session: URLSession

        /// Step 3: exchange the code from the callback URL for tokens.
        func finish(callback: URL) async throws -> Credentials {
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state else { throw Failure.stateMismatch }
            guard let code = items.first(where: { $0.name == "code" })?.value else {
                throw Failure.rejected(items.first { $0.name == "error" }?.value ?? "Sign-in was cancelled.")
            }
            guard var components = URLComponents(url: server.appending(path: "auth/openid/callback"), resolvingAgainstBaseURL: false) else {
                throw APIError.invalidURL
            }
            components.queryItems = [
                .init(name: "state", value: state),
                .init(name: "code", value: code),
                .init(name: "code_verifier", value: verifier),
            ]
            guard let url = components.url else { throw APIError.invalidURL }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.rejected(message.isEmpty ? "The server didn't accept the sign-in." : "The server didn't accept the sign-in (\(message)).")
            }
            let login = try APIClient.decode(LoginResponse.self, from: data)
            guard let token = login.user.accessToken ?? login.user.token else { throw APIError.invalidResponse }
            return Credentials(serverURL: server, userId: login.user.id, username: login.user.username,
                               accessToken: token, refreshToken: login.user.refreshToken, defaultLibraryId: login.userDefaultLibraryId)
        }
    }

    /// Keeps the server's redirect so we can read the provider URL (and its cookie) ourselves.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        // The completion-handler form: the async form crashes the Swift 6.4 beta compiler.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    nonisolated var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
