import SwiftUI

/// Searches the whole library on the server: books, series, authors, narrators, genres and tags.
/// Falls back to the cached library when offline.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var isSearching = false
    @State private var failed = false

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions
            } else {
                resultSections
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: model.library.isPodcastLibrary ? "Podcasts and episodes" : "Books, authors, series, narrators")
        .overlay {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && results.isEmpty {
                if isSearching {
                    ProgressView()
                } else {
                    ContentUnavailableView.search(text: trimmed)
                }
            }
        }
        .task(id: query) { await search() }
    }

    // MARK: - Content

    @ViewBuilder private var suggestions: some View {
        if !model.library.isPodcastLibrary {
            Section("Browse") {
                NavigationLink(value: BrowseList.series) { Label("Series", systemImage: "books.vertical") }
                NavigationLink(value: BrowseList.collections) { Label("Collections", systemImage: "square.stack") }
                NavigationLink(value: BrowseList.playlists) { Label("Playlists", systemImage: "music.note.list") }
                ForEach(Facet.allCases) { facet in
                    NavigationLink(value: BrowseList.facet(facet)) { Label(facet.title, systemImage: facet.systemImage) }
                }
            }
            let genres = model.library.values(for: .genre).sorted { $0.count > $1.count }.prefix(8)
            if !genres.isEmpty {
                Section("Popular Genres") {
                    ForEach(Array(genres), id: \.name) { genre in
                        NavigationLink(value: FacetValue(facet: .genre, value: genre.name)) {
                            LabeledContent(genre.name, value: "\(genre.count)")
                        }
                    }
                }
            }
        } else {
            Section("Browse") {
                NavigationLink(value: BrowseList.playlists) { Label("Playlists", systemImage: "music.note.list") }
            }
        }
    }

    @ViewBuilder private var resultSections: some View {
        if failed {
            Label("Showing results from your saved library.", systemImage: "wifi.slash")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        let books = results.books + results.podcasts
        if !books.isEmpty {
            Section(model.library.isPodcastLibrary ? "Podcasts" : "Books") {
                ForEach(books) { item in
                    let item = model.library.item(item.id) ?? item
                    NavigationLink(value: item) { BookRow(item: item) }
                        .contextMenu { BookActions(item: item) }
                }
            }
        }
        if !results.episodes.isEmpty {
            Section("Episodes") {
                ForEach(results.episodes, id: \.recentEpisode!.id) { item in
                    EpisodeRow(item: item, episode: item.recentEpisode!, showsPodcast: true)
                }
            }
        }
        if !results.series.isEmpty {
            Section("Series") {
                ForEach(results.series, id: \.series.id) { match in
                    let series = match.withBooks
                    NavigationLink(value: model.library.series.first { $0.id == series.id } ?? series) {
                        HStack(spacing: 12) {
                            StackedCovers(items: match.books ?? [], size: 44)
                            Text(series.name)
                        }
                    }
                }
            }
        }
        if !results.authors.isEmpty {
            Section("Authors") {
                ForEach(results.authors) { author in
                    NavigationLink(value: author) {
                        HStack(spacing: 12) {
                            AuthorImage(author: author, size: 40)
                            Text(author.name)
                        }
                    }
                }
            }
        }
        facetSection("Narrators", .narrator, results.narrators)
        facetSection("Genres", .genre, results.genres)
        facetSection("Tags", .tag, results.tags)
    }

    @ViewBuilder private func facetSection(_ title: String, _ facet: Facet, _ values: [SearchResults.NameCount]) -> some View {
        if !values.isEmpty {
            Section(title) {
                ForEach(values, id: \.name) { value in
                    NavigationLink(value: FacetValue(facet: facet, value: value.name)) {
                        LabeledContent {
                            Text("\(value.count)")
                        } label: {
                            Label(value.name, systemImage: facet.systemImage)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Searching

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = SearchResults()
            return
        }
        // Instant local results while the server answers (and the only results offline).
        results = localResults(for: trimmed)
        guard model.network.isOnline else { failed = true; return }
        isSearching = true
        defer { isSearching = false }
        // Debounce: typing cancels this task before the request goes out.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let server = try await model.library.search(trimmed, api: model.api)
            guard !Task.isCancelled else { return }
            results = server
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    private func localResults(for query: String) -> SearchResults {
        let terms = query.split(separator: " ").map(String.init)
        func matches(_ text: String) -> Bool { terms.allSatisfy { text.localizedStandardContains($0) } }
        var local = SearchResults()
        let items = model.library.items.filter { item in
            matches([item.title, item.authorName, item.narratorName, item.media.metadata.seriesName, item.media.metadata.subtitle]
                .compactMap { $0 }.joined(separator: " "))
        }
        if model.library.isPodcastLibrary { local.podcasts = Array(items.prefix(12)) } else { local.books = Array(items.prefix(12)) }
        local.authors = Array(model.library.authors.filter { matches($0.name) }.prefix(6))
        local.series = model.library.series.filter { matches($0.name) }.prefix(6).map {
            SearchResults.SeriesMatch(series: $0, books: $0.books)
        }
        return local
    }
}

private extension SearchResults.SeriesMatch {
    var withBooks: Series {
        var series = self.series
        if series.books == nil { series.books = books }
        return series
    }
}
