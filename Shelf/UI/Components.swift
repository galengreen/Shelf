import SwiftUI

extension Font {
    /// Book titles use New York for a literary feel against SF body text.
    static func bookTitle(_ style: Font.TextStyle = .title) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }
}

/// Thin rounded progress bar.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 3
    var tint: Color = .accentColor
    var track: Color = .primary.opacity(0.12)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(height, proxy.size.width * fraction.clamped(to: 0...1)))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

/// Icon + text metadata line, e.g. narrator or author.
struct MetaLine: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: systemImage).imageScale(.small)
        }
        .labelStyle(CompactLabelStyle())
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.frame(width: 14)
            configuration.title
        }
    }
}

/// Small finished/downloaded badges drawn over covers.
struct CoverBadges: View {
    let isFinished: Bool
    let isDownloaded: Bool

    var body: some View {
        VStack {
            HStack {
                Spacer()
                if isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.system(size: 15))
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .padding(3)
                }
            }
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            trailing
        }
        .padding(.horizontal)
    }
}

/// Soft tint from the cover behind detail headers. Static, so it costs nothing per frame.
struct PaletteBackdrop: View {
    let source: ImageSource
    @State private var palette: CoverPalette?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                (palette?.average.color ?? .clear).opacity(colorScheme == .dark ? 0.45 : 0.28),
                .clear,
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.3), value: palette)
        .task(id: source) { palette = await ImagePipeline.shared.palette(source) }
        .allowsHitTesting(false)
    }
}

struct OfflineBanner: View {
    var body: some View {
        Label("Offline: showing downloads and saved data", systemImage: "wifi.slash")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Circular download control with progress ring. Hidden when the server doesn't allow downloads.
struct DownloadButton: View {
    let item: LibraryItem
    var episode: PodcastEpisode?
    var size: CGFloat = 22

    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    private var key: String { ProgressKey.make(item.id, episode?.id) }

    var body: some View {
        let state = model.downloads.state(for: key)
        if model.canDownload || state == .downloaded {
            Button {
                switch state {
                case .none, .failed:
                    Task { await model.download(item, episode: episode) }
                case .downloading:
                    model.downloads.cancel(key)
                case .downloaded:
                    confirmDelete = true
                }
            } label: {
                ZStack {
                    switch state {
                    case .none:
                        Image(systemName: "arrow.down.circle")
                    case .failed:
                        Image(systemName: "exclamationmark.arrow.circlepath")
                            .foregroundStyle(.orange)
                    case .downloading(let fraction):
                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, fraction))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: fraction)
                        Image(systemName: "stop.fill").font(.system(size: size * 0.32))
                    case .downloaded:
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .font(.system(size: size))
                .frame(width: size, height: size)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(accessibilityLabel(for: state))
            .confirmationDialog("Remove download?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) { model.downloads.delete(key) }
            } message: {
                Text("You can download it again any time.")
            }
        }
    }

    private func accessibilityLabel(for state: DownloadState) -> String {
        switch state {
        case .none: "Download"
        case .failed(let message): "Download failed: \(message). Retry"
        case .downloading(let fraction): "Downloading, \(Int(fraction * 100)) percent. Cancel"
        case .downloaded: "Downloaded. Remove download"
        }
    }
}

/// Up to three covers fanned out, for series, collections and playlists.
struct StackedCovers: View {
    let items: [LibraryItem]
    var size: CGFloat = 64

    var body: some View {
        let shown = Array(items.prefix(3))
        ZStack(alignment: .leading) {
            if shown.isEmpty {
                CoverView(source: nil, cornerRadius: size * 0.1)
                    .frame(width: size, height: size)
            }
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, item in
                CoverView(source: item.coverSource, title: item.title, cornerRadius: size * 0.1)
                    .frame(width: size, height: size)
                    .scaleEffect(1 - CGFloat(index) * 0.1, anchor: .trailing)
                    .offset(x: CGFloat(index) * size * 0.22)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: -1)
            }
        }
        .frame(width: size + CGFloat(max(shown.count - 1, 0)) * size * 0.22, height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// A browsable value such as a narrator or genre.
struct FacetValue: Hashable {
    let facet: Facet
    let value: String
}

/// Lists reachable from the Library tab.
enum BrowseList: Hashable {
    case series, collections, playlists, facet(Facet)
}

extension View {
    /// Registers navigation for everything that can be pushed in a stack.
    func appDestinations() -> some View {
        navigationDestination(for: LibraryItem.self) { BookDetailView(itemId: $0.id, seed: $0) }
            .navigationDestination(for: Author.self) { AuthorDetailView(author: $0) }
            .navigationDestination(for: AuthorRef.self) { AuthorDetailView(author: Author(id: $0.id, name: $0.name, description: nil, imagePath: nil, numBooks: nil, updatedAt: nil, libraryItems: nil, series: nil)) }
            .navigationDestination(for: Series.self) { SeriesDetailView(seriesId: $0.id, seed: $0) }
            .navigationDestination(for: SeriesRef.self) { SeriesDetailView(seriesId: $0.id, seed: nil, fallbackName: $0.name) }
            .navigationDestination(for: BookCollection.self) { CollectionDetailView(collection: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlistId: $0.id, seed: $0) }
            .navigationDestination(for: FacetValue.self) { FacetItemsView(value: $0) }
            .navigationDestination(for: BrowseList.self) { list in
                switch list {
                case .series: SeriesListView()
                case .collections: CollectionsView()
                case .playlists: PlaylistsView()
                case .facet(let facet): FacetListView(facet: facet)
                }
            }
    }
}

// MARK: - iPad

/// Sizes that grow in regular width (iPad). Compact width (iPhone) keeps the original values.
enum Layout {
    static func cardWidth(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat { sizeClass == .regular ? 180 : 140 }
}

extension View {
    /// Centres content at a comfortable reading width in regular width; no change on iPhone.
    func readableWidth(_ width: CGFloat = 720) -> some View {
        modifier(ReadableWidth(width: width))
    }
}

private struct ReadableWidth: ViewModifier {
    let width: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: sizeClass == .regular ? width : .infinity)
            .frame(maxWidth: .infinity)
    }
}
