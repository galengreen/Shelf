import Foundation

/// Listening done without a server playback session (offline, or before the server answered),
/// kept on disk and uploaded through `/api/session/local-all` so it shows up in the server's
/// listening stats. Re-uploading a session id updates it, so uploads are safe to retry.
final class LocalSessionStore {
    private var sessions: [String: LocalSession]
    private var isUploading = false
    private let file = URL.applicationSupportDirectory.appending(path: "local-sessions.json")

    init() {
        sessions = DiskWriter.read([String: LocalSession].self, from: file) ?? [:]
    }

    var hasPending: Bool { !sessions.isEmpty }

    /// Adds listening time to the session for this playthrough, starting one if needed.
    /// Returns the session id to pass back next time.
    @discardableResult
    func record(sessionId: String?, item: LibraryItem, episode: PodcastEpisode?, duration: Double,
                startTime: Double, currentTime: Double, listened: Double) -> String {
        let now = Date.now
        let nowMs = now.timeIntervalSince1970 * 1000
        let today = Self.dayFormatter.string(from: now)
        // A new day starts a new session, so per-day stats stay right.
        if let sessionId, var existing = sessions[sessionId], existing.date == today {
            existing.currentTime = currentTime
            existing.timeListening += listened
            existing.updatedAt = nowMs
            sessions[sessionId] = existing
            persist()
            return sessionId
        }
        let session = LocalSession(
            id: UUID().uuidString.lowercased(),
            libraryItemId: item.id,
            episodeId: episode?.id,
            mediaType: item.isPodcast ? "podcast" : "book",
            displayTitle: episode?.displayTitle ?? item.title,
            displayAuthor: episode != nil ? item.title : item.authorName,
            duration: duration,
            startTime: startTime,
            currentTime: currentTime,
            timeListening: listened,
            startedAt: nowMs,
            updatedAt: nowMs,
            date: today,
            dayOfWeek: Self.weekdayFormatter.string(from: now)
        )
        sessions[session.id] = session
        persist()
        return session.id
    }

    func upload(using api: APIClient) async {
        guard !isUploading else { return }
        // Sessions with no real listening aren't worth a server row.
        let batch = Array(sessions.values.filter { $0.timeListening >= 1 })
        sessions = sessions.filter { $0.value.timeListening >= 1 }
        guard !batch.isEmpty else { return persist() }
        isUploading = true
        defer { isUploading = false }

        nonisolated struct Body: Encodable, Sendable { let sessions: [LocalSession]; let deviceInfo: DeviceInfo.Payload }
        nonisolated struct Response: Decodable, Sendable {
            nonisolated struct Result: Decodable, Sendable { let id: String; let success: Bool; let error: String? }
            let results: [Result]
        }
        guard let response = try? await api.post("api/session/local-all", json: Body(sessions: batch, deviceInfo: DeviceInfo.payload), as: Response.self) else { return }
        let uploaded = Dictionary(batch.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        // Drop sessions the server took (or permanently rejected, e.g. a deleted book), but keep
        // any that kept growing while the upload was in flight.
        for result in response.results where sessions[result.id]?.updatedAt == uploaded[result.id] {
            sessions[result.id] = nil
        }
        persist()
    }

    func reset() {
        sessions = [:]
        persist()
    }

    private func persist() {
        DiskWriter.write(sessions, to: file)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f
    }()
}
