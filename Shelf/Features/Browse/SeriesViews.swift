import SwiftUI

extension LibraryItem {
    /// This book's position in a series, from the minified "Series #2" form or the expanded refs.
    func sequence(in series: String) -> String? {
        if let ref = media.metadata.series?.first(where: { $0.name == series }), let sequence = ref.sequence.nonEmpty {
            return sequence
        }
        guard let joined = media.metadata.seriesName else { return nil }
        for part in joined.components(separatedBy: ", ") where part.hasPrefix(series + " #") {
            return String(part.dropFirst(series.count + 2)).nonEmpty
        }
        return nil
    }
}

struct SeriesListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let series = filtered
        List(series) { entry in
            NavigationLink(value: entry) { SeriesRow(series: entry) }
        }
        .listStyle(.plain)
        .navigationTitle("Series")
        .searchable(text: $query, prompt: "Search series")
        .overlay {
            if series.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if model.library.isRefreshing {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Series", systemImage: "books.vertical",
                                           description: Text("Books that belong to a series on your server appear here."))
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private var filtered: [Series] {
        guard !query.isEmpty else { return model.library.series }
        return model.library.series.filter { $0.name.localizedStandardContains(query) }
    }
}

private struct SeriesRow: View {
    let series: Series
    @Environment(AppModel.self) private var model

    var body: some View {
        let books = series.books ?? []
        let finished = books.filter { model.progress.snapshot(for: $0.id)?.isFinished == true }.count
        HStack(spacing: 14) {
            StackedCovers(items: books, size: 58)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(series.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(summary(count: books.count, finished: finished))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if finished > 0, !books.isEmpty {
                    ProgressBar(fraction: Double(finished) / Double(books.count), height: 3)
                        .frame(maxWidth: 140)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func summary(count: Int, finished: Int) -> String {
        let books = count == 1 ? "1 book" : "\(count) books"
        if finished == count, count > 0 { return "\(books) · Finished" }
        return finished > 0 ? "\(books) · \(finished) finished" : books
    }
}

struct SeriesDetailView: View {
    let seriesId: String
    let seed: Series?
    var fallbackName: String?

    @Environment(AppModel.self) private var model

    var body: some View {
        let series = model.library.series.first { $0.id == seriesId } ?? seed
        let name = series?.name ?? fallbackName ?? "Series"
        let books = (series?.books ?? []).map { model.library.item($0.id) ?? $0 }
        List {
            Section {
                header(name: name, books: books)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        HStack(alignment: .center, spacing: 10) {
                            if let sequence = book.sequence(in: name) {
                                Text(sequence)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 22)
                            }
                            BookRow(item: book)
                        }
                    }
                    .contextMenu { BookActions(item: book) }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .background(alignment: .top) {
            if let first = books.first { PaletteBackdrop(source: first.coverSource) }
        }
        .overlay {
            if series == nil {
                if model.library.isRefreshing { ProgressView() } else {
                    ContentUnavailableView("Series Not Found", systemImage: "books.vertical")
                }
            }
        }
    }

    private func header(name: String, books: [LibraryItem]) -> some View {
        let finished = books.filter { model.progress.snapshot(for: $0.id)?.isFinished == true }.count
        let next = books.first { model.progress.snapshot(for: $0.id)?.isFinished != true }
        let total = books.reduce(0) { $0 + $1.duration }
        return VStack(spacing: 14) {
            StackedCovers(items: books, size: 150)
                .padding(.top, 8)
            Text(name)
                .font(.bookTitle(.title))
                .multilineTextAlignment(.center)
            Text([books.count == 1 ? "1 book" : "\(books.count) books",
                  total > 0 ? Format.duration(total) : nil,
                  finished > 0 ? "\(finished) of \(books.count) finished" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let next {
                let started = model.progress.snapshot(for: next.id)?.isStarted == true
                Button {
                    model.player.open(next)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(started ? "Resume \(next.title)" : finished > 0 ? "Continue with \(next.title)" : "Start Series")
                            .lineLimit(1)
                    }
                    .font(.headline)
                    .foregroundStyle(.white) // Lists tint symbols with the accent colour otherwise.
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}
