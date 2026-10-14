import SwiftUI

struct AuthorsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let authors = filtered
        List(authors) { author in
            NavigationLink(value: author) {
                HStack(spacing: 14) {
                    AuthorImage(author: author, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.name).font(.body.weight(.medium))
                        if let count = author.numBooks {
                            Text(count == 1 ? "1 book" : "\(count) books")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 62 }
        }
        .listStyle(.plain)
        .navigationTitle("Authors")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search authors")
        .toolbar { LibraryMenu() }
        .overlay {
            if authors.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if model.library.isRefreshing {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Authors", systemImage: "person.2")
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private var filtered: [Author] {
        guard !query.isEmpty else { return model.library.authors }
        return model.library.authors.filter { $0.name.localizedStandardContains(query) }
    }
}

struct AuthorDetailView: View {
    let author: Author

    @Environment(AppModel.self) private var model
    @State private var loaded: Author?
    @State private var showFullBio = false

    var body: some View {
        let current = loaded ?? author
        List {
            Section {
                VStack(spacing: 14) {
                    AuthorImage(author: current, size: 120)
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                    Text(current.name)
                        .font(.bookTitle(.title))
                        .multilineTextAlignment(.center)
                    if let bio = current.description, !bio.isEmpty {
                        VStack(spacing: 6) {
                            Text(bio.strippingHTML)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(showFullBio ? nil : 4)
                            Button(showFullBio ? "Less" : "More") {
                                withAnimation(.smooth) { showFullBio.toggle() }
                            }
                            .font(.callout.weight(.semibold))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let series = current.series, !series.isEmpty {
                ForEach(series) { group in
                    Section(group.name) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) { BookRow(item: item) }
                                .contextMenu { BookActions(item: item) }
                        }
                    }
                }
            }

            let standalone = standaloneBooks(current)
            if !standalone.isEmpty {
                Section(current.series?.isEmpty == false ? "Other Books" : "Books") {
                    ForEach(standalone) { item in
                        NavigationLink(value: item) { BookRow(item: item) }
                            .contextMenu { BookActions(item: item) }
                    }
                }
            }

            if loaded == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: author.id) {
            loaded = await model.library.loadAuthor(author.id, api: model.api) ?? fallback
        }
    }

    private func standaloneBooks(_ author: Author) -> [LibraryItem] {
        let inSeries = Set((author.series ?? []).flatMap { $0.items.map(\.id) })
        return (author.libraryItems ?? []).filter { !inSeries.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Offline: build the author page from the cached library.
    private var fallback: Author {
        let books = model.library.items.filter { item in
            item.media.metadata.authors?.contains { $0.id == author.id } == true
                || item.authorName?.localizedStandardContains(author.name) == true
        }
        return Author(id: author.id, name: author.name, description: author.description, imagePath: author.imagePath,
                      numBooks: books.count, updatedAt: author.updatedAt, libraryItems: books, series: nil)
    }
}
