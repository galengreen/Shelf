import Foundation
import Observation

/// Progress is keyed by library item id for books and "itemId/episodeId" for podcast episodes.
nonisolated enum ProgressKey {
    static func make(_ itemId: String, _ episodeId: String?) -> String {
        episodeId.map { "\(itemId)/\($0)" } ?? itemId
    }

    static func split(_ key: String) -> (itemId: String, episodeId: String?) {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
}

/// Merged view of listening progress: what the server knows plus anything recorded on this
/// device that hasn't been uploaded yet. The newer of the two always wins, so listening offline
/// (or on a flaky connection) never rewinds you to a stale server position.
@Observable
final class ProgressStore {
    nonisolated struct Local: Codable, Sendable {
        var currentTime: Double
        var duration: Double
        var isFinished: Bool
        var updatedAt: Date
        var needsUpload: Bool
    }

    struct Snapshot: Equatable {
        var currentTime: Double
        var duration: Double
        var isFinished: Bool
        var updatedAt: Date

        var fraction: Double {
            if isFinished { return 1 }
            guard duration > 0 else { return 0 }
            return (currentTime / duration).clamped(to: 0...1)
        }

        var remaining: Double { max(0, duration - currentTime) }
        var isStarted: Bool { isFinished || currentTime > 1 }
    }

    private(set) var server: [String: MediaProgress] = [:]
    private(set) var local: [String: Local] = [:]

    private let file = URL.applicationSupportDirectory.appending(path: "progress.json")

    init() {
        local = DiskWriter.read([String: Local].self, from: file) ?? [:]
    }

    func snapshot(for key: String) -> Snapshot? {
        let remote = server[key].map {
            Snapshot(
                currentTime: $0.currentTime ?? 0,
                duration: $0.duration ?? 0,
                isFinished: $0.isFinished ?? false,
                updatedAt: Date(timeIntervalSince1970: ($0.lastUpdate ?? 0) / 1000)
            )
        }
        let mine = local[key].map {
            Snapshot(currentTime: $0.currentTime, duration: $0.duration, isFinished: $0.isFinished, updatedAt: $0.updatedAt)
        }
        switch (remote, mine) {
        case let (r?, m?): return m.updatedAt > r.updatedAt ? m : r
        case let (r?, nil): return r
        case let (nil, m?): return m
        default: return nil
        }
    }

    /// Where playback should start. Finished books start over.
    func resumePosition(for key: String) -> Double {
        guard let snap = snapshot(for: key), !snap.isFinished else { return 0 }
        return snap.currentTime
    }

    /// Books (not episodes) you're part-way through, most recent first.
    var inProgressIds: [String] {
        let ids = Set(server.keys).union(local.keys).filter { !$0.contains("/") }
        return ids
            .compactMap { id in snapshot(for: id).map { (id, $0) } }
            .filter { $0.1.isStarted && !$0.1.isFinished && !isHidden($0.0) }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .map(\.0)
    }

    func isHidden(_ key: String) -> Bool { server[key]?.hideFromContinueListening == true }

    func lastUpdated(_ key: String) -> Date? { snapshot(for: key)?.updatedAt }

    // MARK: - Recording

    /// Record a position locally. `uploaded` is true when the caller already synced it to the server.
    func record(key: String, currentTime: Double, duration: Double, isFinished: Bool = false, uploaded: Bool) {
        local[key] = Local(currentTime: currentTime, duration: duration, isFinished: isFinished, updatedAt: .now, needsUpload: !uploaded)
        persist()
    }

    func markUploaded(_ key: String) {
        guard local[key]?.needsUpload == true else { return }
        local[key]?.needsUpload = false
        persist()
    }

    var hasPendingUploads: Bool { local.values.contains { $0.needsUpload } }

    // MARK: - Server

    func apply(serverProgress: [MediaProgress]) {
        var map: [String: MediaProgress] = [:]
        for progress in serverProgress {
            if let id = progress.libraryItemId { map[ProgressKey.make(id, progress.episodeId)] = progress }
        }
        server = map
        pruneLocal()
    }

    /// A single update pushed by the server (another device synced).
    func apply(remote progress: MediaProgress) {
        guard let id = progress.libraryItemId else { return }
        let key = ProgressKey.make(id, progress.episodeId)
        if let existing = server[key], (existing.lastUpdate ?? 0) > (progress.lastUpdate ?? 0) { return }
        server[key] = progress
        pruneLocal()
    }

    /// Drop local entries the server has caught up with, so the file stays small.
    private func pruneLocal() {
        var changed = false
        for (key, entry) in local where !entry.needsUpload {
            if let remote = server[key], (remote.lastUpdate ?? 0) / 1000 >= entry.updatedAt.timeIntervalSince1970 - 1 {
                local[key] = nil
                changed = true
            }
        }
        if changed { persist() }
    }

    /// Uploads positions recorded while offline. Safe to call often.
    func flushPending(using api: APIClient) async {
        let pending = local.filter(\.value.needsUpload)
        guard !pending.isEmpty else { return }
        let updates = pending.map { key, entry in
            let (itemId, episodeId) = ProgressKey.split(key)
            return ProgressUpdate(
                libraryItemId: itemId,
                episodeId: episodeId,
                duration: entry.duration,
                currentTime: entry.currentTime,
                progress: entry.duration > 0 ? min(1, entry.currentTime / entry.duration) : 0,
                isFinished: entry.isFinished ? true : nil
            )
        }
        do {
            try await api.send("PATCH", "api/me/progress/batch/update", json: updates)
            for (key, entry) in pending where local[key]?.updatedAt == entry.updatedAt {
                local[key]?.needsUpload = false
            }
            persist()
        } catch {
            // Stays queued; retried on the next reconnect or foreground.
        }
    }

    func setFinished(_ finished: Bool, key: String, duration: Double, api: APIClient?) async {
        record(key: key, currentTime: finished ? duration : 0, duration: duration, isFinished: finished, uploaded: false)
        guard let api else { return }
        nonisolated struct Body: Encodable, Sendable { let isFinished: Bool; let currentTime: Double; let progress: Double }
        let (itemId, episodeId) = ProgressKey.split(key)
        let path = "api/me/progress/\(itemId)" + (episodeId.map { "/\($0)" } ?? "")
        do {
            try await api.send("PATCH", path, json: Body(isFinished: finished, currentTime: finished ? duration : 0, progress: finished ? 1 : 0))
            markUploaded(key)
        } catch {}
    }

    /// Hides a book from Continue Listening on every device (it reappears if you play it again).
    func hideFromContinueListening(_ key: String, api: APIClient?) async {
        guard let api else { return }
        if server[key]?.id == nil {
            // The server only knows about progress it has received.
            await flushPending(using: api)
            if let user = try? await api.get("api/me", as: User.self) { apply(serverProgress: user.mediaProgress ?? []) }
        }
        guard let progressId = server[key]?.id else { return }
        server[key]?.hideFromContinueListening = true
        do {
            try await api.send("GET", "api/me/progress/\(progressId)/remove-from-continue-listening")
        } catch {
            server[key]?.hideFromContinueListening = false
        }
    }

    func reset() {
        server = [:]
        local = [:]
        persist()
    }

    private func persist() {
        DiskWriter.write(local, to: file)
    }
}
