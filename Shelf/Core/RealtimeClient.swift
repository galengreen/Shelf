import Foundation
import os

nonisolated private let log = Logger(subsystem: "nz.galengreen.shelf", category: "realtime")

/// Minimal Socket.IO (Engine.IO v4, WebSocket transport) client for the server's live events:
/// progress synced from other devices, bookmark changes, and library updates.
///
/// Only connected while the app is in the foreground, so it costs nothing in the background.
/// A WebSocket idles at a ping every 25 seconds, far cheaper than polling for the same freshness.
final class RealtimeClient {
    /// Event name and its JSON payload.
    var onEvent: ((String, Data) -> Void)?
    /// Called after (re)authenticating, so the app can catch up on anything missed while disconnected.
    var onConnected: (() -> Void)?

    private(set) var isConnected = false

    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var wantsConnection = false
    private var api: APIClient?
    private var attempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastMessageAt = Date.now
    private var generation = 0

    func connect(api: APIClient) {
        self.api = api
        wantsConnection = true
        guard task == nil else { return }
        open()
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        close()
    }

    // MARK: - Connection

    private func open() {
        guard let api else { return }
        generation += 1
        let current = generation
        Task {
            guard let url = Self.socketURL(for: await api.baseURL) else { return }
            guard current == generation, wantsConnection else { return }
            var request = URLRequest(url: url)
            request.setValue(DeviceInfo.userAgent, forHTTPHeaderField: "User-Agent")
            let task = session.webSocketTask(with: request)
            self.task = task
            lastMessageAt = .now
            task.resume()
            startWatchdog(generation: current)
            await receive(on: task, generation: current)
        }
    }

    private func close() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isConnected = false
        generation += 1
    }

    private func receive(on task: URLSessionWebSocketTask, generation current: Int) async {
        while current == generation {
            do {
                let message = try await task.receive()
                guard current == generation else { return }
                lastMessageAt = .now
                switch message {
                case .string(let text): await handle(text, on: task)
                case .data(let data): await handle(String(decoding: data, as: UTF8.self), on: task)
                @unknown default: break
                }
            } catch {
                guard current == generation else { return }
                log.notice("Socket closed: \(error.localizedDescription, privacy: .public)")
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ packet: String, on task: URLSessionWebSocketTask) async {
        guard let type = packet.first else { return }
        let body = packet.dropFirst()
        switch type {
        case "0": // Engine.IO open: connect to the default namespace.
            send("40", on: task)
        case "2": // Ping: must answer or the server drops us.
            send("3", on: task)
        case "1": // Engine.IO close.
            scheduleReconnect()
        case "4":
            await handleSocketIO(body, on: task)
        default:
            break
        }
    }

    private func handleSocketIO(_ packet: Substring, on task: URLSessionWebSocketTask) async {
        guard let type = packet.first else { return }
        switch type {
        case "0": // Namespace connected: authenticate with a fresh token.
            guard let api, let token = try? await api.validToken() else { return }
            send("42" + Self.encodeEvent("auth", token), on: task)
        case "2": // Event: ["name", payload]
            guard let data = packet.dropFirst().data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let name = array.first as? String else { return }
            let payload = array.count > 1 ? (try? JSONSerialization.data(withJSONObject: array[1], options: .fragmentsAllowed)) ?? Data() : Data()
            switch name {
            case "init":
                isConnected = true
                attempt = 0
                log.notice("Socket authenticated")
                onConnected?()
            case "auth_failed":
                // Usually an expired token; refresh once and reconnect.
                log.notice("Socket auth failed")
                if let api, await api.tokenIsRefreshable { _ = try? await api.refresh() }
                scheduleReconnect()
            default:
                onEvent?(name, payload)
            }
        case "1", "4": // Namespace disconnect / connect error.
            scheduleReconnect()
        default:
            break
        }
    }

    /// The server pings every 25 seconds; if nothing arrives for a minute the connection died
    /// silently (e.g. a network change), so start again rather than wait for TCP to notice.
    private func startWatchdog(generation current: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(10))
                guard let self, !Task.isCancelled, current == self.generation else { return }
                if Date.now.timeIntervalSince(self.lastMessageAt) > 60 {
                    log.notice("Socket went quiet; reconnecting")
                    self.scheduleReconnect()
                    return
                }
            }
        }
    }

    private func send(_ text: String, on task: URLSessionWebSocketTask) {
        task.send(.string(text)) { _ in }
    }

    private func scheduleReconnect() {
        close()
        guard wantsConnection, reconnectTask == nil else { return }
        attempt += 1
        // 2, 4, 8 … up to 60 seconds, so an unreachable server isn't hammered.
        let delay = min(60, pow(2, Double(min(attempt, 6))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.wantsConnection { self.open() }
        }
    }

    // MARK: - Helpers

    /// `http(s)://host/base` → `ws(s)://host/base/socket.io/?EIO=4&transport=websocket`
    private static func socketURL(for server: URL) -> URL? {
        guard var components = URLComponents(url: server.appending(path: "socket.io/"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        return components.url
    }

    private static func encodeEvent(_ name: String, _ argument: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [name, argument])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
