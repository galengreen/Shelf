import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, inProgress, notStarted, finished, downloaded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All Books"
        case .inProgress: "In Progress"
        case .notStarted: "Not Started"
        case .finished: "Finished"
        case .downloaded: "Downloaded"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "books.vertical"
        case .inProgress: "play.circle"
        case .notStarted: "circle"
        case .finished: "checkmark.circle"
        case .downloaded: "arrow.down.circle"
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var query = ""
    @State private var filter: LibraryFilter = .all

    var body: some View {
        let items = visibleItems
        Group {
            if sizeClass == .regular {
                grid(items)
            } else {
                list(items)
            }
        }
        .navigationTitle(model.library.selectedLibrary?.name ?? "Books")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: model.library.isPodcastLibrary ? "Search podcasts" : "Title, author, narrator or series")
        .toolbar {
            LibraryMenu()
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
        .overlay { emptyState(isEmpty: items.isEmpty) }
        .refreshable { await model.refresh() }
        .animation(.default, value: filter)
    }

    private func list(_ items: [LibraryItem]) -> some View {
        List {
            if !model.network.isOnline {
                OfflineBanner()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
            if query.isEmpty && !model.library.isPodcastLibrary {
                BrowseChips()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            ForEach(items) { item in
                NavigationLink(value: item) {
                    BookRow(item: item)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                .swipeActions(edge: .trailing) { SwipeActions(item: item) }
                .contextMenu { BookActions(item: item) }
            }
        }
        .listStyle(.plain)
    }

    /// iPad: covers in a grid that fills the width.
    private func grid(_ items: [LibraryItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.network.isOnline {
                    OfflineBanner().frame(maxWidth: .infinity)
                }
                if query.isEmpty && !model.library.isPodcastLibrary {
                    BrowseChips()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20, alignment: .top)], spacing: 26) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            BookGridCell(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { BookActions(item: item) }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
    }

    private var sortMenu: some View {
        @Bindable var settings = model.settings
        return Menu {
            Picker("Filter", selection: $filter) {
                ForEach(LibraryFilter.allCases) { Label($0.label, systemImage: $0.systemImage).tag($0) }
            }
            Section("Sort By") {
                Picker("Sort", selection: $settings.librarySort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                Picker("Order", selection: $settings.librarySortAscending) {
                    Label("Ascending", systemImage: "arrow.up").tag(true)
                    Label("Descending", systemImage: "arrow.down").tag(false)
                }
            }
        } label: {
            Label("Sort and Filter", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    @ViewBuilder private func emptyState(isEmpty: Bool) -> some View {
        if isEmpty {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if model.library.isRefreshing && model.library.items.isEmpty {
                ProgressView()
            } else if filter != .all {
                ContentUnavailableView("No \(filter.label)", systemImage: filter.systemImage)
            } else if let error = model.library.lastError {
                ContentUnavailableView("Couldn't Load Library", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("No Books", systemImage: "books.vertical")
            }
        }
    }

    // MARK: - Filtering & sorting (local, so it's instant and works offline)

    private var visibleItems: [LibraryItem] {
        var items = model.library.items
        if filter == .downloaded {
            // Include downloads that aren't in the current library listing (e.g. offline cold start).
            let known = Set(items.map(\.id))
            items = items.filter { model.downloads.isDownloaded($0.id) }
                + model.downloads.downloadedItems.filter { !known.contains($0.id) }
        } else if filter != .all {
            items = items.filter { item in
                let snapshot = model.progress.snapshot(for: item.id)
                switch filter {
                case .inProgress: return snapshot?.isStarted == true && snapshot?.isFinished != true
                case .notStarted: return snapshot?.isStarted != true
                case .finished: return snapshot?.isFinished == true
                default: return true
                }
            }
        }
        let terms = query.split(separator: " ").map(String.init)
        if !terms.isEmpty {
            items = items.filter { item in
                let haystack = [item.title, item.authorName, item.narratorName, item.media.metadata.seriesName, item.media.metadata.subtitle]
                    .compactMap { $0 }.joined(separator: " ")
                return terms.allSatisfy { haystack.localizedStandardContains($0) }
            }
        }
        return sort(items)
    }

    private func sort(_ items: [LibraryItem]) -> [LibraryItem] {
        let ascending = model.settings.librarySortAscending
        func order<T: Comparable>(_ a: T, _ b: T) -> Bool { ascending ? a < b : a > b }
        switch model.settings.librarySort {
        case .title:
            return items.sorted {
                let r = $0.title.localizedStandardCompare($1.title)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            }
        case .author:
            return items.sorted {
                let r = ($0.authorName ?? "").localizedStandardCompare($1.authorName ?? "")
                if r == .orderedSame { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return ascending ? r == .orderedAscending : r == .orderedDescending
            }
        case .recentlyAdded:
            return items.sorted { order($1.addedAt ?? 0, $0.addedAt ?? 0) }
        case .publishedYear:
            return items.sorted { order($0.media.metadata.publishedYear ?? "", $1.media.metadata.publishedYear ?? "") }
        case .duration:
            return items.sorted { order($0.duration, $1.duration) }
        case .recentlyPlayed:
            let dates = Dictionary(items.map { ($0.id, model.progress.lastUpdated($0.id) ?? .distantPast) }, uniquingKeysWith: { a, _ in a })
            return items.sorted { order(dates[$1.id] ?? .distantPast, dates[$0.id] ?? .distantPast) }
        }
    }
}

// MARK: - Row

struct BookRow: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.progress.snapshot(for: item.id)
        let downloaded = model.downloads.isDownloaded(item.id)
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                CoverView(source: item.coverSource, title: item.title, cornerRadius: 6)
                    .frame(width: 64, height: 64)
                    .overlay { CoverBadges(isFinished: snapshot?.isFinished == true, isDownloaded: downloaded) }
                if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                    ProgressBar(fraction: snapshot.fraction, height: 3)
                        .frame(width: 64)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Group {
                    if let narrator = item.narratorName {
                        MetaLine(systemImage: "person.wave.2", text: narrator)
                    }
                    if let author = item.authorName {
                        MetaLine(systemImage: item.isPodcast ? "mic" : "pencil.line", text: author)
                    }
                    if item.isPodcast, let count = item.media.numEpisodes ?? item.media.episodes?.count {
                        MetaLine(systemImage: "waveform", text: count == 1 ? "1 episode" : "\(count) episodes")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing) {
                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Downloaded")
                }
                Spacer(minLength: 0)
                if let year = item.media.metadata.publishedYear {
                    Text(year)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// A book in the iPad grid: cover, progress, title and author.
private struct BookGridCell: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        let snapshot = model.progress.snapshot(for: item.id)
        let downloaded = model.downloads.isDownloaded(item.id)
        VStack(alignment: .leading, spacing: 6) {
            CoverView(source: item.coverSource, title: item.title, cornerRadius: 10)
                .overlay { CoverBadges(isFinished: snapshot?.isFinished == true, isDownloaded: downloaded) }
                .overlay(alignment: .bottomTrailing) {
                    if downloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .font(.system(size: 17))
                            .padding(5)
                            .accessibilityLabel("Downloaded")
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                ProgressBar(fraction: snapshot.fraction)
            }
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            if let author = item.authorName {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SwipeActions: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        if !item.isPodcast {
            let finished = model.progress.snapshot(for: item.id)?.isFinished == true
            Button {
                Task { await model.setFinished(!finished, item: item) }
            } label: {
                Label(finished ? "Unfinished" : "Finished", systemImage: finished ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(.accentColor)

            switch model.downloads.state(for: item.id) {
            case .downloaded:
                Button(role: .destructive) { model.downloads.delete(item.id) } label: {
                    Label("Remove", systemImage: "trash")
                }
            case .downloading:
                Button { model.downloads.cancel(item.id) } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            default:
                if model.canDownload {
                    Button {
                        Task { await model.download(item) }
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .tint(.indigo)
                }
            }
        }
    }
}

/// Context-menu actions shared by every place a book appears.
struct BookActions: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model

    var body: some View {
        if !item.isPodcast {
            bookActions
        }
    }

    @ViewBuilder private var bookActions: some View {
        let snapshot = model.progress.snapshot(for: item.id)
        let finished = snapshot?.isFinished == true
        Button("Play", systemImage: "play.fill") { model.player.open(item) }
        Button(finished ? "Mark as Unfinished" : "Mark as Finished", systemImage: finished ? "arrow.uturn.backward" : "checkmark.circle") {
            Task { await model.setFinished(!finished, item: item) }
        }
        if snapshot?.isStarted == true, !finished, !model.progress.isHidden(item.id) {
            Button("Hide from Continue Listening", systemImage: "eye.slash") {
                Task { await model.hideFromContinueListening(item) }
            }
            .disabled(!model.network.isOnline)
        }
        Button("Add to Playlist…", systemImage: "music.note.list") { model.addingToPlaylist = QueueEntry(item: item) }
            .disabled(!model.network.isOnline)
        switch model.downloads.state(for: item.id) {
        case .downloaded:
            Button("Remove Download", systemImage: "trash", role: .destructive) { model.downloads.delete(item.id) }
        case .downloading:
            Button("Cancel Download", systemImage: "xmark") { model.downloads.cancel(item.id) }
        default:
            if model.canDownload {
                Button("Download", systemImage: "arrow.down.circle") {
                    Task { await model.download(item) }
                }
            }
        }
    }
}

/// Shortcuts to the other ways of browsing a book library.
private struct BrowseChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("Series", "books.vertical", .series)
                chip("Collections", "square.stack", .collections)
                chip("Playlists", "music.note.list", .playlists)
                ForEach(Facet.allCases) { facet in
                    if !model.library.values(for: facet).isEmpty {
                        chip(facet.title, facet.systemImage, .facet(facet))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, _ icon: String, _ list: BrowseList) -> some View {
        NavigationLink(value: list) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.7), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
