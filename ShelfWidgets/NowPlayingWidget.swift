import AppIntents
import SwiftUI
import WidgetKit

/// The book you're listening to, with play/pause and skip. The app reloads it when the book,
/// chapter, play state or speed changes; progress in between is animated by the system.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.nowPlaying, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The book you're listening to, with its chapter, progress and controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

nonisolated struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let cover: UIImage?

    static func current() -> NowPlayingEntry {
        let snapshot = WidgetData.nowPlaying()
        return NowPlayingEntry(date: .now, snapshot: snapshot, cover: WidgetData.cover(for: snapshot))
    }

    static var preview: NowPlayingEntry { NowPlayingEntry(date: .now, snapshot: .preview, cover: nil) }
}

nonisolated struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let entry = NowPlayingEntry.current()
        completion(context.isPreview && entry.snapshot == nil ? .preview : entry)
    }

    /// A single entry: the app asks for a reload whenever something changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [.current()], policy: .never))
    }
}

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetData.playerURL)
            .containerBackground(for: .widget) {
                if family.isAccessory {
                    AccessoryWidgetBackground().opacity(family == .accessoryCircular ? 1 : 0)
                } else {
                    Color("WidgetBackground")
                }
            }
    }

    @ViewBuilder private var content: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemSmall: SmallNowPlaying(snapshot: snapshot, cover: entry.cover, date: entry.date)
            case .accessoryRectangular: RectangularNowPlaying(snapshot: snapshot, date: entry.date)
            case .accessoryCircular: CircularNowPlaying(snapshot: snapshot, date: entry.date)
            case .accessoryInline: InlineNowPlaying(snapshot: snapshot)
            default: MediumNowPlaying(snapshot: snapshot, cover: entry.cover, date: entry.date)
            }
        } else {
            NothingPlaying(family: family)
        }
    }
}

private struct SmallNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let cover: UIImage?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CoverImage(image: cover, cornerRadius: 8)
                    .frame(width: 58, height: 58)
                Spacer(minLength: 4)
                PlayPauseButton(isPlaying: snapshot.isPlaying, size: 38)
            }
            Spacer(minLength: 6)
            Text(snapshot.headline)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let detail = snapshot.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ChapterProgress(snapshot: snapshot, date: date)
                .padding(.top, 6)
        }
    }
}

private struct MediumNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let cover: UIImage?
    let date: Date

    var body: some View {
        HStack(spacing: 14) {
            CoverImage(image: cover, cornerRadius: 10)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let detail = snapshot.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                ChapterProgress(snapshot: snapshot, date: date)
                HStack {
                    ChapterTimeLeft(snapshot: snapshot, date: date)
                    Spacer()
                    if let number = snapshot.chapterNumber, let count = snapshot.chapterCount, count > 1 {
                        Text("\(number) of \(count)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                HStack {
                    SkipButton(forward: false, seconds: snapshot.skipBackward, size: 18)
                    Spacer()
                    PlayPauseButton(isPlaying: snapshot.isPlaying, size: 38)
                    Spacer()
                    SkipButton(forward: true, seconds: snapshot.skipForward, size: 18)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct RectangularNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.headline)
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
            if let detail = snapshot.detail {
                Text(detail).font(.caption).lineLimit(1)
            }
            ChapterProgress(snapshot: snapshot, date: date)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A ring of chapter progress that plays or pauses when tapped.
private struct CircularNowPlaying: View {
    let snapshot: NowPlayingSnapshot
    let date: Date

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            ZStack {
                if snapshot.isPlaying {
                    ProgressView(timerInterval: snapshot.chapterDates, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                    .progressViewStyle(.circular)
                } else {
                    ProgressView(value: snapshot.chapterFraction(at: date))
                        .progressViewStyle(.circular)
                }
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.isPlaying ? "Pause \(snapshot.title)" : "Play \(snapshot.title)")
    }
}

private struct InlineNowPlaying: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        Label(snapshot.headline, systemImage: snapshot.isPlaying ? "headphones" : "pause.fill")
    }
}

private struct NothingPlaying: View {
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("Nothing playing", systemImage: "books.vertical")
        case .accessoryCircular:
            Image(systemName: "books.vertical.fill").font(.title2)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("Shelf").font(.headline).widgetAccentable()
                Text("Nothing playing").font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(spacing: 6) {
                Image(systemName: "books.vertical.fill")
                    .font(.title)
                    .foregroundStyle(Color.shelfAccent)
                Text("Nothing Playing")
                    .font(.subheadline.weight(.semibold))
                Text("Choose a book in Shelf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }
}

extension WidgetFamily {
    var isAccessory: Bool {
        self == .accessoryCircular || self == .accessoryRectangular || self == .accessoryInline
    }
}
