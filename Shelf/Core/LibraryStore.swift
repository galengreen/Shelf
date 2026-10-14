import Foundation
import Observation

/// Library catalogue. Everything is served from disk first (instant launch, works offline) and
/// refreshed with conditional requests, so an unchanged library costs a handful of 304s.
@Observable
final class LibraryStore {
    private(set) var libraries: [Library] = []
    private(set) var items: [LibraryItem] = []
    private(set) var shelves: [HomeShelf] = []
    private(set) var authors: [Author] = []
    private(set) var series: [Series] = []
    private(set) var collections: [BookCollection]?
    private(set) var playlists: [Playlist]?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastRefresh: Date?

    /// Expanded items (chapters, tracks, description), keyed by id.
    private(set) var details: [String: LibraryItem] = [:]

    @ObservationIgnored private var itemsById: [String: LibraryItem] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private let pageSize = 250
    private let detailsFile = URL.applicationSupportDirectory.appending(path: "details.json")

    var selectedLibrary: Library? {
        libraries.first { $0.id == settings.selectedLibraryId } ?? libraries.first
    }

    var isPodcastLibrary: Bool { selectedLibrary?.isPodcastLibrary == true }

    @ObservationIgnored private let settings: Settings

    init(settings: Settings) {
        self.settings = settings
        details = DiskWriter.read([String: LibraryItem].self, from: detailsFile) ?? [:]
    }

    func item(_ id: String) -> LibraryItem? {
        details[id] ?? itemsById[id]
    }

    // MARK: - Loading

    /// Populates everything from the on-disk response cache without any network traffic.
    func loadCached(api: APIClient) async {
        if let data = await api.cachedData("api/libraries"),
           let response = try? JSONDecoder().decode(LibrariesResponse.self, from: data) {
            libraries = Self.playable(response.libraries)
        }
        guard let library = selectedLibrary else { return }
        var cachedItems: [LibraryItem] = []
        var page = 0
        while let data = await api.cachedData(itemsPath(library.id), query: itemsQuery(page: page)),
              let decoded = try? JSONDecoder().decode(ItemsPage.self, from: data) {
            cachedItems += decoded.results
            if decoded.results.count < pageSize { break }
            page += 1
        }
        if !cachedItems.isEmpty { setItems(cachedItems) }
        if let data = await api.cachedData(shelvesPath(library.id), query: shelvesQuery),
           let decoded = try? JSONDecoder().decode([Lossy<HomeShelf>].self, from: data) {
            shelves = decoded.compactMap(\.value)
        }
        if let data = await api.cachedData(authorsPath(library.id)),
           let decoded = try? JSONDecoder().decode(AuthorsPage.self, from: data) {
            authors = Self.sortedAuthors(decoded.all)
        }
        if let data = await api.cachedData(seriesPath(library.id), query: seriesQuery),
           let decoded = try? JSONDecoder().decode(Page<Series>.self, from: data) {
            series = decoded.results
        }
    }

    /// Coalesces concurrent refresh requests into one.
    func refresh(api: APIClient) async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh(api: api) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh(api: APIClient) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let response = try await api.get("api/libraries", cached: true, as: LibrariesResponse.self)
            libraries = Self.playable(response.libraries)
            guard let library = selectedLibrary else { return }
            if settings.selectedLibraryId == nil { settings.selectedLibraryId = library.id }

            async let shelvesTask = api.get(shelvesPath(library.id), query: shelvesQuery, cached: true, as: [Lossy<HomeShelf>].self)
            async let authorsTask = library.isBookLibrary
                ? api.get(authorsPath(library.id), cached: true, as: AuthorsPage.self) : nil
            async let seriesTask = library.isBookLibrary
                ? api.get(seriesPath(library.id), query: seriesQuery, cached: true, as: Page<Series>.self) : nil

            var all: [LibraryItem] = []
            var page = 0
            while true {
                let result = try await api.get(itemsPath(library.id), query: itemsQuery(page: page), cached: true, as: ItemsPage.self)
                all += result.results
                if result.results.count < pageSize || all.count >= (result.total ?? .max) { break }
                page += 1
            }
            setItems(all)
            shelves = (try? await shelvesTask)?.compactMap(\.value) ?? shelves
            if let fetched = try? await authorsTask { authors = Self.sortedAuthors(fetched.all) }
            if let fetched = try? await seriesTask { series = fetched.results }
            if collections != nil { await loadCollections(api: api) }
            if playlists != nil { await loadPlaylists(api: api) }
            lastRefresh = .now
            lastError = nil
        } catch APIError.offline {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectLibrary(_ library: Library, api: APIClient) async {
        guard library.id != settings.selectedLibraryId else { return }
        settings.selectedLibraryId = library.id
        items = []
        shelves = []
        authors = []
        series = []
        collections = nil
        playlists = nil
        await loadCached(api: api)
        await refresh(api: api)
    }

    /// Full item with chapters and tracks (or episodes). Returns the cached copy when offline.
    @discardableResult
    func loadDetails(_ id: String, api: APIClient?) async -> LibraryItem? {
        guard let api else { return details[id] }
        if let item = try? await api.get("api/items/\(id)", query: ["expanded": "1"], cached: true, as: LibraryItem.self) {
            details[id] = item
            return item
        }
        return details[id]
    }

    func cacheDetails(_ item: LibraryItem) {
        if item.media.chapters != nil || item.media.tracks != nil || item.media.episodes != nil { details[item.id] = item }
    }

    /// Fetches full details for the given books in a single request and keeps them on disk, so
    /// chapters for everything you're listening to are available offline without opening each book.
    func prefetchDetails(_ ids: [String], api: APIClient) async {
        let missing = ids.filter { id in details[id]?.media.tracks == nil }
        if !missing.isEmpty {
            nonisolated struct Body: Encodable, Sendable { let libraryItemIds: [String] }
            nonisolated struct Response: Decodable, Sendable { let libraryItems: [Lossy<LibraryItem>] }
            guard let response = try? await api.post("api/items/batch/get", json: Body(libraryItemIds: missing), as: Response.self) else { return }
            for item in response.libraryItems.compactMap(\.value) { details[item.id] = item }
        }
        let keep = Set(ids)
        DiskWriter.write(details.filter { keep.contains($0.key) }, to: detailsFile)
    }

    func loadAuthor(_ id: String, api: APIClient?) async -> Author? {
        guard let api else { return nil }
        return try? await api.get("api/authors/\(id)", query: ["include": "items,series"], cached: true, as: Author.self)
    }

    func loadCollections(api: APIClient?) async {
        guard let api, let library = selectedLibrary else { return }
        if let page = try? await api.get("api/libraries/\(library.id)/collections", query: ["limit": "200", "minified": "1"], cached: true, as: Page<BookCollection>.self) {
            collections = page.results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else if collections == nil {
            collections = []
        }
    }

    func loadPlaylists(api: APIClient?) async {
        guard let api, let library = selectedLibrary else { return }
        if let page = try? await api.get("api/libraries/\(library.id)/playlists", query: ["limit": "200"], cached: true, as: Page<Playlist>.self) {
            playlists = page.results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } else if playlists == nil {
            playlists = []
        }
    }

    func search(_ query: String, api: APIClient?) async throws -> SearchResults {
        guard let api, let library = selectedLibrary else { throw APIError.offline }
        return try await api.get("api/libraries/\(library.id)/search", query: ["q": query, "limit": "12"], as: SearchResults.self)
    }

    // MARK: - Playlists

    func addToPlaylist(_ playlist: Playlist, itemId: String, episodeId: String? = nil, api: APIClient?) async throws {
        guard let api else { throw APIError.offline }
        nonisolated struct Body: Encodable, Sendable { let libraryItemId: String; let episodeId: String? }
        try await api.send("POST", "api/playlists/\(playlist.id)/item", json: Body(libraryItemId: itemId, episodeId: episodeId))
        await loadPlaylists(api: api)
    }

    func removeFromPlaylist(_ playlist: Playlist, itemId: String, episodeId: String? = nil, api: APIClient?) async throws {
        guard let api else { throw APIError.offline }
        let path = "api/playlists/\(playlist.id)/item/\(itemId)" + (episodeId.map { "/\($0)" } ?? "")
        try await api.send("DELETE", path)
        await loadPlaylists(api: api)
    }

    func createPlaylist(named name: String, itemId: String?, episodeId: String? = nil, api: APIClient?) async throws {
        guard let api, let library = selectedLibrary else { throw APIError.offline }
        nonisolated struct Entry: Encodable, Sendable { let libraryItemId: String; let episodeId: String? }
        nonisolated struct Body: Encodable, Sendable { let libraryId: String; let name: String; let items: [Entry] }
        let entries = itemId.map { [Entry(libraryItemId: $0, episodeId: episodeId)] } ?? []
        try await api.send("POST", "api/playlists", json: Body(libraryId: library.id, name: name, items: entries))
        await loadPlaylists(api: api)
    }

    func deletePlaylist(_ playlist: Playlist, api: APIClient?) async throws {
        guard let api else { throw APIError.offline }
        try await api.send("DELETE", "api/playlists/\(playlist.id)")
        playlists?.removeAll { $0.id == playlist.id }
    }

    // MARK: - Derived browse data (computed locally, so no extra requests and it works offline)

    func values(for facet: Facet) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items {
            for value in facet.values(of: item) { counts[value, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func items(matching facet: Facet, value: String) -> [LibraryItem] {
        items.filter { facet.values(of: $0).contains(value) }
    }

    /// The series a book belongs to (with its books in reading order), if known.
    func series(containing itemId: String) -> Series? {
        series.first { $0.books?.contains { $0.id == itemId } == true }
    }

    /// The first unfinished book after `itemId` in its series.
    func nextInSeries(after itemId: String, isFinished: (String) -> Bool) -> LibraryItem? {
        guard let books = series(containing: itemId)?.books,
              let index = books.firstIndex(where: { $0.id == itemId }) else { return nil }
        return books[(index + 1)...].first { !isFinished($0.id) }.map { self.item($0.id) ?? $0 }
    }

    /// Removes a book from the server's continue-listening shelf locally (after hiding it).
    func hideFromShelves(_ itemId: String) {
        for index in shelves.indices where shelves[index].id == "continue-listening" {
            shelves[index].items.removeAll { $0.id == itemId }
        }
    }

    func reset() {
        libraries = []
        items = []
        shelves = []
        authors = []
        series = []
        collections = nil
        playlists = nil
        details = [:]
        itemsById = [:]
        DiskWriter.remove(detailsFile)
    }

    // MARK: - Helpers

    private static func playable(_ libraries: [Library]) -> [Library] {
        libraries.filter { $0.isBookLibrary || $0.isPodcastLibrary }.sorted { ($0.displayOrder ?? 0) < ($1.displayOrder ?? 0) }
    }

    private static func sortedAuthors(_ authors: [Author]) -> [Author] {
        authors.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func itemsPath(_ libraryId: String) -> String { "api/libraries/\(libraryId)/items" }
    private func shelvesPath(_ libraryId: String) -> String { "api/libraries/\(libraryId)/personalized" }
    private func authorsPath(_ libraryId: String) -> String { "api/libraries/\(libraryId)/authors" }
    private func seriesPath(_ libraryId: String) -> String { "api/libraries/\(libraryId)/series" }
    private var shelvesQuery: [String: String] { ["limit": "12"] }
    private var seriesQuery: [String: String] { ["limit": "1000", "page": "0", "sort": "name"] }

    /// Oldest-first so newly added books only change the last page; earlier pages keep their ETags.
    private func itemsQuery(page: Int) -> [String: String] {
        ["minified": "1", "sort": "addedAt", "desc": "0", "limit": String(pageSize), "page": String(page)]
    }

    private func setItems(_ new: [LibraryItem]) {
        // Pages can shift if the library changes mid-fetch; never hand duplicate ids to a List.
        var seen = Set<String>()
        items = new.filter { seen.insert($0.id).inserted }
        itemsById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// A browsable attribute of books, derived from the minified library listing.
enum Facet: String, Hashable, CaseIterable, Identifiable {
    case narrator, genre, tag, language

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrator: "Narrators"
        case .genre: "Genres"
        case .tag: "Tags"
        case .language: "Languages"
        }
    }

    var systemImage: String {
        switch self {
        case .narrator: "person.wave.2"
        case .genre: "theatermasks"
        case .tag: "tag"
        case .language: "globe"
        }
    }

    func values(of item: LibraryItem) -> [String] {
        switch self {
        case .narrator: item.narratorList
        case .genre: item.media.metadata.genres ?? []
        case .tag: item.media.tags ?? []
        case .language: item.media.metadata.language.nonEmpty.map { [$0] } ?? []
        }
    }
}
