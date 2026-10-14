import Foundation
import Observation

/// Bookmarks are stored on the server (so they sync with the web app and other clients).
/// Changes apply locally straight away and are queued if the server can't be reached, so
/// bookmarking on a plane works and uploads later.
@Observable
final class BookmarkStore {
    nonisolated enum Change: Codable, Sendable {
        case create(Bookmark)
        case rename(Bookmark)
        case delete(Bookmark)
    }

    /// Server bookmarks with any queued changes applied, keyed by library item id.
    private(set) var byItem: [String: [Bookmark]] = [:]

    @ObservationIgnored private var server: [Bookmark] = []
    @ObservationIgnored private var pending: [Change]
    @ObservationIgnored private var isFlushing = false
    private let file = URL.applicationSupportDirectory.appending(path: "bookmark-changes.json")

    init() {
        pending = DiskWriter.read([Change].self, from: file) ?? []
    }

    func bookmarks(for itemId: String) -> [Bookmark] { byItem[itemId] ?? [] }

    func apply(server bookmarks: [Bookmark]) {
        server = bookmarks
        rebuild()
    }

    func add(itemId: String, time: Double, title: String, api: APIClient?) async {
        // The server keys bookmarks by whole seconds in practice; avoid near-duplicates.
        let time = time.rounded()
        enqueue(.create(Bookmark(libraryItemId: itemId, time: time, title: title, createdAt: Date.now.timeIntervalSince1970 * 1000)))
        await flush(api: api)
    }

    func rename(_ bookmark: Bookmark, to title: String, api: APIClient?) async {
        var renamed = bookmark
        renamed.title = title
        enqueue(.rename(renamed))
        await flush(api: api)
    }

    func delete(_ bookmark: Bookmark, api: APIClient?) async {
        enqueue(.delete(bookmark))
        await flush(api: api)
    }

    /// Sends queued changes in order. Changes that the server rejects outright (e.g. the book was
    /// deleted) are dropped; network failures leave the queue for the next attempt.
    func flush(api: APIClient?) async {
        guard let api, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while let change = pending.first {
            do {
                switch change {
                case .create(let b):
                    server.append(try await api.post("api/me/item/\(b.libraryItemId)/bookmark", json: Body(time: b.time, title: b.title), as: Bookmark.self))
                case .rename(let b):
                    try await api.send("PATCH", "api/me/item/\(b.libraryItemId)/bookmark", json: Body(time: b.time, title: b.title))
                    if let index = server.firstIndex(where: { $0.id == b.id }) { server[index].title = b.title }
                case .delete(let b):
                    try await api.send("DELETE", "api/me/item/\(b.libraryItemId)/bookmark/\(Self.timeString(b.time))")
                    server.removeAll { $0.id == b.id }
                }
            } catch let error as APIError where error.isConnectivity || error.isUnauthorized {
                return
            } catch {
                // 404 and friends: nothing more we can do with this change.
            }
            pending.removeFirst()
            persist()
        }
        rebuild()
    }

    func reset() {
        server = []
        pending = []
        persist()
        rebuild()
    }

    // MARK: - Private

    private nonisolated struct Body: Encodable, Sendable { let time: Double; let title: String }

    private func enqueue(_ change: Change) {
        pending.append(change)
        persist()
        rebuild()
    }

    private func rebuild() {
        var all = server
        for change in pending {
            switch change {
            case .create(let b):
                all.removeAll { $0.id == b.id }
                all.append(b)
            case .rename(let b):
                if let index = all.firstIndex(where: { $0.id == b.id }) { all[index].title = b.title }
            case .delete(let b):
                all.removeAll { $0.id == b.id }
            }
        }
        byItem = Dictionary(grouping: all, by: \.libraryItemId).mapValues { $0.sorted { $0.time < $1.time } }
    }

    private func persist() {
        DiskWriter.write(pending, to: file)
    }

    /// Matches how the server parses the time path component (`Number(...)`).
    private static func timeString(_ time: Double) -> String {
        time == time.rounded() ? String(Int(time)) : String(time)
    }
}
