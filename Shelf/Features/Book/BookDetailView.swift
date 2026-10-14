import SwiftUI

struct BookDetailView: View {
    let itemId: String
    let seed: LibraryItem

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showFullDescription = false

    private var item: LibraryItem { model.library.item(itemId) ?? seed }

    var body: some View {
        if seed.isPodcast {
            PodcastDetailView(itemId: itemId, seed: seed)
        } else {
            book
        }
    }

    private var book: some View {
        let item = self.item
        let description = (item.media.metadata.descriptionPlain ?? item.media.metadata.description).nonEmpty
        return ScrollView {
            if sizeClass == .regular {
                // iPad: the book and its details on the left, what's inside it on the right.
                HStack(alignment: .top, spacing: 44) {
                    VStack(spacing: 26) {
                        header(item)
                        actions(item)
                        details(item)
                    }
                    .frame(width: 400)
                    VStack(spacing: 26) {
                        if let description { descriptionSection(description) }
                        BookmarkList(item: item)
                        chapters(item)
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 1160)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 26) {
                    header(item)
                    actions(item)
                    if let description { descriptionSection(description) }
                    BookmarkList(item: item)
                    chapters(item)
                    details(item)
                }
                .padding(.bottom, 32)
            }
        }
        .background(alignment: .top) { PaletteBackdrop(source: item.coverSource) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    BookActions(item: item)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .task(id: itemId) { await model.library.loadDetails(itemId, api: model.api) }
    }

    // MARK: Sections

    private func header(_ item: LibraryItem) -> some View {
        let coverSize: CGFloat = sizeClass == .regular ? 300 : 230
        return VStack(spacing: 14) {
            CoverView(source: item.coverSource, title: item.title, cornerRadius: 12)
                .frame(width: coverSize, height: coverSize)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(item.title)
                    .font(.bookTitle(.title))
                    .multilineTextAlignment(.center)
                if let subtitle = item.media.metadata.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                authors(item)
                MetaSummary(item: item)
                if let series = item.media.metadata.series?.first {
                    NavigationLink(value: series) {
                        Label(series.displayName, systemImage: "books.vertical")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityHint("Shows every book in the series")
                }
            }
            .padding(.horizontal, 28)
        }
    }

    @ViewBuilder private func authors(_ item: LibraryItem) -> some View {
        if let authors = item.media.metadata.authors, !authors.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(authors.enumerated()), id: \.element.id) { index, author in
                    NavigationLink(value: author) {
                        Text(author.name + (index < authors.count - 1 ? "," : ""))
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Color.accentColor)
            .font(.body.weight(.medium))
        } else if let author = item.authorName {
            Text(author)
                .foregroundStyle(Color.accentColor)
                .font(.body.weight(.medium))
        }
    }

    private func actions(_ item: LibraryItem) -> some View {
        let snapshot = model.progress.snapshot(for: item.id)
        let isCurrent = model.player.item?.id == item.id
        let playing = isCurrent && model.player.isPlaying
        return VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if isCurrent { model.player.togglePlayPause() } else { model.player.open(item) }
                } label: {
                    Label(playing ? "Pause" : snapshot?.isFinished == true ? "Listen Again" : snapshot?.isStarted == true ? "Resume" : "Play",
                          systemImage: playing ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                DownloadButton(item: item, size: 26)
                    .frame(width: 50, height: 50)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .padding(.horizontal, 24)

            if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                VStack(spacing: 6) {
                    ProgressBar(fraction: snapshot.fraction, height: 4)
                    HStack {
                        Text("\(Int(snapshot.fraction * 100))% complete")
                        Spacer()
                        Text(Format.timeLeft(snapshot.remaining))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
            }

            if case .failed(let message) = model.downloads.state(for: item.id) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3.weight(.bold))
            Text(text.strippingHTML)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(showFullDescription ? nil : 5)
            Button(showFullDescription ? "Less" : "More") {
                withAnimation(.smooth) { showFullDescription.toggle() }
            }
            .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder private func chapters(_ item: LibraryItem) -> some View {
        let player = model.player
        let isCurrent = player.item?.id == item.id
        let chapters = isCurrent && !player.chapters.isEmpty ? player.chapters : (item.media.chapters ?? [])
        if chapters.count > 1 {
            let currentIndex = isCurrent ? player.currentChapterIndex : {
                let time = model.progress.resumePosition(for: item.id)
                return time > 0 ? chapters.lastIndex { $0.start <= time + 0.01 } : nil
            }()
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "\(chapters.count) Chapters")
                LazyVStack(spacing: 0) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
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

    private func details(_ item: LibraryItem) -> some View {
        let meta = item.media.metadata
        let rows: [(String, String)] = [
            ("Publisher", meta.publisher),
            ("Published", meta.publishedYear),
            ("Language", meta.language),
            ("Length", item.duration > 0 ? Format.duration(item.duration) : nil),
            ("Size", (item.media.size).map { Format.bytes($0) }),
        ].compactMap { label, value in value.map { (label, $0) } }
        let links: [(String, Facet, [String])] = [
            ("Narrated by", .narrator, item.narratorList),
            ("Genres", .genre, meta.genres ?? []),
            ("Tags", .tag, item.media.tags ?? []),
        ].filter { !$0.2.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.title3.weight(.bold))
            VStack(spacing: 0) {
                ForEach(links, id: \.0) { label, facet, values in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        FlowLinks(facet: facet, values: values)
                    }
                    .font(.callout)
                    .padding(.vertical, 9)
                    Divider()
                }
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(.secondary)
                        Spacer(minLength: 16)
                        Text(value).multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 9)
                    Divider()
                }
            }
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Comma-separated values that each open a list of matching books.
private struct FlowLinks: View {
    let facet: Facet
    let values: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { links }
            VStack(alignment: .trailing, spacing: 4) { links }
        }
    }

    @ViewBuilder private var links: some View {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            NavigationLink(value: FacetValue(facet: facet, value: value)) {
                Text(value + (index < values.count - 1 ? ", " : ""))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }
}

extension String {
    /// Book descriptions from metadata providers often contain HTML.
    var strippingHTML: String {
        guard contains("<") else { return self }
        return replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
