import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let hero = self.hero
        ScrollView {
            VStack(spacing: 30) {
                if !model.network.isOnline {
                    OfflineBanner()
                }
                if let hero {
                    let item = model.library.item(hero.item.id) ?? hero.item
                    if sizeClass == .regular {
                        // iPad: the book beside its chapters.
                        HStack(alignment: .center, spacing: 40) {
                            HeroSection(item: item, episode: hero.episode, label: hero.label)
                                .frame(width: 400)
                            if hero.episode == nil {
                                UpNextChapters(item: item, count: 7)
                                    .frame(maxWidth: 560)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                    } else {
                        HeroSection(item: item, episode: hero.episode, label: hero.label)
                        if hero.episode == nil {
                            UpNextChapters(item: item)
                        }
                    }
                }
                ForEach(shelves(excluding: hero?.item.id)) { shelf in
                    ShelfView(shelf: shelf)
                }
                if hero == nil && model.library.shelves.allSatisfy(\.isEmpty) {
                    emptyState
                }
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) {
            if let hero { PaletteBackdrop(source: hero.item.coverSource) }
        }
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            LibraryMenu()
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Listening Stats", systemImage: "chart.bar.xaxis")
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private struct Hero {
        let item: LibraryItem
        var episode: PodcastEpisode?
        let label: String
    }

    /// What you're most likely to want next: the next book in a series you just finished, what's
    /// loaded in the player, the most recently played in-progress book, or the server's
    /// continue-listening shelf.
    private var hero: Hero? {
        let player = model.player
        if let next = player.suggestedNext {
            let series = model.library.series(containing: next.id)?.name
            return Hero(item: next, label: series.map { "Up next in \($0)" } ?? "Up next")
        }
        let libraryId = model.library.selectedLibrary?.id
        // The loaded item, unless it's finished and idle (then a book in progress is more useful).
        if let item = player.item, let key = player.key, item.libraryId == nil || item.libraryId == libraryId,
           player.isPlaying || model.progress.snapshot(for: key)?.isFinished != true {
            return Hero(item: item, episode: player.episode, label: "Where you left off")
        }
        guard !model.library.isPodcastLibrary else { return nil }
        for id in model.progress.inProgressIds.prefix(5) {
            if let item = model.library.item(id) ?? model.downloads.manifests[id]?.item, item.libraryId == nil || item.libraryId == libraryId {
                return Hero(item: item, label: "Where you left off")
            }
        }
        return model.library.shelves.first { $0.id == "continue-listening" }?.items.first
            .map { Hero(item: $0, label: "Where you left off") }
    }

    private func shelves(excluding heroId: String?) -> [HomeShelf] {
        model.library.shelves.compactMap { shelf in
            var shelf = shelf
            // Episode shelves list the same podcast several times; only filter whole items.
            if shelf.type != "episode" {
                // The server's shelf can lag behind what just happened on this device.
                shelf.items = shelf.items.filter { item in
                    guard item.id != heroId else { return false }
                    guard shelf.id == "continue-listening" else { return true }
                    return !model.progress.isHidden(item.id) && model.progress.snapshot(for: item.id)?.isFinished != true
                }
            }
            return shelf.isEmpty ? nil : shelf
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.library.isRefreshing {
            ProgressView().padding(.top, 120)
        } else if let error = model.library.lastError {
            ContentUnavailableView("Couldn't Load Library", systemImage: "exclamationmark.triangle", description: Text(error))
                .padding(.top, 60)
        } else {
            ContentUnavailableView("Nothing Here Yet", systemImage: model.library.isPodcastLibrary ? "mic" : "books.vertical",
                                   description: Text(model.library.isPodcastLibrary
                                                     ? "Episodes you start listening to will show up here."
                                                     : "Books you start listening to will show up here."))
                .padding(.top, 60)
        }
    }
}

// MARK: - Hero

private struct HeroSection: View {
    let item: LibraryItem
    let episode: PodcastEpisode?
    let label: String
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let key = ProgressKey.make(item.id, episode?.id)
        let coverSize: CGFloat = sizeClass == .regular ? 280 : 220
        let snapshot = model.progress.snapshot(for: key)
        let isCurrent = model.player.key == key
        VStack(spacing: 16) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .textCase(.uppercase)
                .kerning(0.6)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            NavigationLink(value: item) {
                CoverView(source: item.coverSource, title: item.title, cornerRadius: 12)
                    .frame(width: coverSize, height: coverSize)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(item.title)")
            .contextMenu { if episode == nil { BookActions(item: item) } }

            VStack(spacing: 6) {
                Text(episode?.displayTitle ?? item.title)
                    .font(.bookTitle(.title))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if episode != nil {
                    Text(item.title).foregroundStyle(Color.accentColor)
                } else if let author = item.media.metadata.authors?.first {
                    NavigationLink(value: author) {
                        Text(item.authorName ?? author.name).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else if let author = item.authorName {
                    Text(author).foregroundStyle(Color.accentColor)
                }
                if episode == nil { MetaSummary(item: item) }
            }
            .padding(.horizontal, 32)

            if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                VStack(spacing: 6) {
                    ProgressBar(fraction: snapshot.fraction, height: 4)
                        .frame(width: 180)
                    Text("\(Format.timeLeft(snapshot.remaining)) · \(Int(snapshot.fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                if isCurrent { model.player.togglePlayPause() } else { model.player.open(item, episode: episode) }
            } label: {
                Label(buttonTitle(snapshot: snapshot, isCurrent: isCurrent),
                      systemImage: isCurrent && model.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(.top, 8)
    }

    private func buttonTitle(snapshot: ProgressStore.Snapshot?, isCurrent: Bool) -> String {
        if isCurrent && model.player.isPlaying { return "Pause" }
        if snapshot?.isFinished == true { return "Listen Again" }
        if snapshot?.isStarted == true { return "Resume" }
        return "Play"
    }
}

/// "Narrator · 2010 · 11h 14m" line, as in plappa.
struct MetaSummary: View {
    let item: LibraryItem

    var body: some View {
        let parts: [(icon: String, text: String)] = [
            item.narratorName.map { ("person.wave.2", $0) },
            item.media.metadata.publishedYear.map { ("calendar", $0) },
            item.duration > 0 ? ("hourglass", Format.duration(item.duration)) : nil,
        ].compactMap { $0 }
        HStack(spacing: 6) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·") }
                MetaLine(systemImage: part.icon, text: part.text)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Up next

private struct UpNextChapters: View {
    let item: LibraryItem
    var count = 5
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let isCurrent = player.item?.id == item.id
        let chapters = isCurrent ? player.chapters : (item.media.chapters ?? [])
        let currentIndex = isCurrent ? player.currentChapterIndex : chapterIndex(in: chapters)

        if chapters.count > 1 {
            let start = max(0, (currentIndex ?? 0) - 1)
            let visible = Array(chapters.enumerated()).dropFirst(start).prefix(count)
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "Chapters", trailing: AnyView(
                    NavigationLink("See All", value: item).font(.subheadline)
                ))
                VStack(spacing: 0) {
                    ForEach(Array(visible), id: \.element.id) { index, chapter in
                        Button {
                            if isCurrent { player.playChapter(chapter) } else { player.open(item, at: chapter.start) }
                        } label: {
                            ChapterRow(chapter: chapter, number: index + 1,
                                       state: ChapterRow.state(index: index, current: currentIndex),
                                       isPlaying: isCurrent && player.isPlaying)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func chapterIndex(in chapters: [Chapter]) -> Int? {
        let time = model.progress.resumePosition(for: item.id)
        return chapters.lastIndex { $0.start <= time + 0.01 }
    }
}

// MARK: - Shelves

/// One server shelf, laid out for its kind of content.
private struct ShelfView: View {
    let shelf: HomeShelf

    var body: some View {
        switch shelf.type {
        case "series":
            ShelfScroller(title: shelf.label) {
                ForEach(shelf.series) { series in
                    NavigationLink(value: series) { SeriesCard(series: series) }
                        .buttonStyle(.plain)
                }
            }
        case "authors":
            ShelfScroller(title: shelf.label) {
                ForEach(shelf.authors) { author in
                    NavigationLink(value: author) {
                        VStack(spacing: 8) {
                            AuthorImage(author: author, size: 96)
                            Text(author.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 104)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        case "episode":
            ShelfScroller(title: shelf.label) {
                ForEach(shelf.items.filter { $0.recentEpisode != nil }, id: \.recentEpisode!.id) { item in
                    EpisodeCard(item: item, episode: item.recentEpisode!)
                }
            }
        default:
            ShelfRow(title: shelf.label, items: shelf.items)
        }
    }
}

private struct ShelfScroller<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .scrollTargetLayout()
                    .padding(.horizontal)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

struct ShelfRow: View {
    let title: String
    let items: [LibraryItem]

    var body: some View {
        ShelfScroller(title: title) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    ShelfCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SeriesCard: View {
    let series: Series
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let width = Layout.cardWidth(sizeClass) + 20
        VStack(alignment: .leading, spacing: 6) {
            StackedCovers(items: series.books ?? [], size: width * 0.7)
                .frame(width: width, height: width * 0.875, alignment: .leading)
            Text(series.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            let count = series.books?.count ?? 0
            Text(count == 1 ? "1 book" : "\(count) books")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShelfCard: View {
    let item: LibraryItem
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let snapshot = model.progress.snapshot(for: item.id)
        let width = Layout.cardWidth(sizeClass)
        VStack(alignment: .leading, spacing: 6) {
            CoverView(source: item.coverSource, title: item.title, cornerRadius: 10)
                .frame(width: width, height: width)
                .overlay { CoverBadges(isFinished: snapshot?.isFinished == true, isDownloaded: false) }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                ProgressBar(fraction: snapshot.fraction).frame(width: width)
            }
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
            if let author = item.authorName {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .contextMenu { BookActions(item: item) }
        .accessibilityElement(children: .combine)
    }
}

/// Library picker shown when the server has more than one library.
struct LibraryMenu: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        if model.library.libraries.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(model.library.libraries) { library in
                        Button {
                            Task { await model.selectLibrary(library) }
                        } label: {
                            if library.id == model.library.selectedLibrary?.id {
                                Label(library.name, systemImage: "checkmark")
                            } else {
                                Label(library.name, systemImage: library.isPodcastLibrary ? "mic" : "books.vertical")
                            }
                        }
                    }
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
            }
        }
    }
}
