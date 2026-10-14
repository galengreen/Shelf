import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Reads what the app wrote into the App Group container. Widgets never touch the network.
nonisolated enum WidgetData {
    static func nowPlaying() -> NowPlayingSnapshot? {
        AppGroup.read(NowPlayingSnapshot.self, from: AppGroup.nowPlayingFile)
    }

    static func listening() -> ListeningSnapshot? {
        AppGroup.read(ListeningSnapshot.self, from: AppGroup.listeningFile)
    }

    static func cover(for snapshot: NowPlayingSnapshot?) -> UIImage? {
        guard let name = snapshot?.coverFile, let url = AppGroup.coverFile(named: name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Tapping a widget or the Live Activity opens the player.
    static let playerURL = URL(string: "shelf://player")!
}

extension NowPlayingSnapshot {
    /// Shown in the widget gallery and as a placeholder.
    nonisolated static let preview = NowPlayingSnapshot(
        itemId: "preview", key: "preview", title: "The Long Road", subtitle: "Ada Long",
        chapterTitle: "Chapter 3: Crossing the River", chapterNumber: 3, chapterCount: 12,
        isPlaying: false, isFinished: false, rate: 1, position: 1_260, duration: 36_000,
        chapterStart: 900, chapterEnd: 2_100, capturedAt: .now, sleep: .off, coverFile: nil
    )

    /// The chapter when there is one, otherwise the book or episode.
    var headline: String { chapterTitle ?? title }
    /// The book under a chapter title, otherwise the author or podcast.
    var detail: String? { chapterTitle == nil ? subtitle : title }
}

extension Color {
    /// Shelf's orange. Widgets don't pick up the app's global accent, so it's named explicitly.
    static let shelfAccent = Color("AccentColor")
}

/// Square cover with a placeholder in the accent colour.
struct CoverImage: View {
    let image: UIImage?
    var cornerRadius: CGFloat = 8

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.shelfAccent.opacity(0.55), Color.shelfAccent.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "book.closed.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Chapter progress. While playing, the system animates it from dates; nothing is redrawn by us.
struct ChapterProgress: View {
    let snapshot: NowPlayingSnapshot
    var date: Date = .now

    var body: some View {
        Group {
            if snapshot.isPlaying {
                ProgressView(timerInterval: snapshot.chapterDates, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: snapshot.isFinished ? 1 : snapshot.chapterFraction(at: date))
            }
        }
        .progressViewStyle(.linear)
        .tint(Color.shelfAccent)
        .labelsHidden()
    }
}

/// "12:34 left" in the chapter (wall-clock time at the current speed).
struct ChapterTimeLeft: View {
    let snapshot: NowPlayingSnapshot
    var date: Date = .now

    var body: some View {
        Group {
            if snapshot.isFinished {
                Text("Finished")
            } else if snapshot.isPlaying {
                Text("\(Text(timerInterval: snapshot.chapterDates, countsDown: true)) left")
            } else {
                Text("\(Format.clock(snapshot.chapterRemaining(at: date))) left")
            }
        }
        .monospacedDigit()
    }
}

/// Play/pause, running the same intent as Siri and Shortcuts (in the app's process).
struct PlayPauseButton: View {
    let isPlaying: Bool
    var size: CGFloat = 36

    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .background(Color.shelfAccent, in: .circle)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }
}

struct SkipButton: View {
    let forward: Bool
    let seconds: Double
    var size: CGFloat = 20

    var body: some View {
        Group {
            if forward {
                Button(intent: SkipForwardIntent()) { icon(SkipSymbol.forward(seconds)) }
            } else {
                Button(intent: SkipBackIntent()) { icon(SkipSymbol.backward(seconds)) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(forward ? "Skip forward \(Int(seconds)) seconds" : "Skip back \(Int(seconds)) seconds")
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .medium))
            .frame(width: size * 1.8, height: size * 1.8)
            .contentShape(.rect)
    }
}

/// Sleep timer state as a small moon badge with its countdown.
struct SleepBadge: View {
    let sleep: SleepSnapshot

    var body: some View {
        switch sleep {
        case .off:
            EmptyView()
        case .endOfChapter:
            Label("End of chapter", systemImage: "moon.zzz.fill")
        case let .running(endsAt):
            Label {
                Text(timerInterval: Date.now...max(endsAt, .now), countsDown: true).monospacedDigit()
            } icon: {
                Image(systemName: "moon.zzz.fill")
            }
        case let .paused(remaining):
            Label(Format.clock(remaining), systemImage: "moon.zzz")
                .monospacedDigit()
        }
    }
}
