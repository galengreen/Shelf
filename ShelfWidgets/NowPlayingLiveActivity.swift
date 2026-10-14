import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island while a book plays. Progress, time left and the sleep countdown
/// are all date-driven, so the system animates them and the app only updates on real changes.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenActivity(snapshot: context.state)
                .activitySystemActionForegroundColor(Color.shelfAccent)
                .widgetURL(WidgetData.playerURL)
        } dynamicIsland: { context in
            let snapshot = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    CoverImage(image: WidgetData.cover(for: snapshot), cornerRadius: 10)
                        .frame(width: 56, height: 56)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        ChapterTimeLeft(snapshot: snapshot)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.shelfAccent)
                        SleepBadge(sleep: snapshot.sleep)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let detail = snapshot.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ChapterProgress(snapshot: snapshot)
                        ActivityTransport(snapshot: snapshot)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                CoverImage(image: WidgetData.cover(for: snapshot), cornerRadius: 5)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                if snapshot.isPlaying {
                    Text(timerInterval: snapshot.chapterDates, countsDown: true)
                        .monospacedDigit()
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.shelfAccent)
                        .frame(maxWidth: 48)
                } else {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(Color.shelfAccent)
                }
            } minimal: {
                if snapshot.isPlaying {
                    ProgressView(timerInterval: snapshot.chapterDates, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "headphones").font(.caption2)
                    }
                    .progressViewStyle(.circular)
                    .tint(Color.shelfAccent)
                } else {
                    Image(systemName: "pause.fill").foregroundStyle(Color.shelfAccent)
                }
            }
            .widgetURL(WidgetData.playerURL)
            .keylineTint(Color.shelfAccent)
        }
    }
}

private struct LockScreenActivity: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                CoverImage(image: WidgetData.cover(for: snapshot), cornerRadius: 8)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.headline)
                        .font(.headline)
                        .lineLimit(1)
                    if let detail = snapshot.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SleepBadge(sleep: snapshot.sleep)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.shelfAccent)
            }
            ChapterProgress(snapshot: snapshot)
            HStack {
                ChapterTimeLeft(snapshot: snapshot)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActivityTransport(snapshot: snapshot)
                    .fixedSize()
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .padding(16)
    }
}

/// Skip back, play/pause and skip forward, run as intents in the app's process.
private struct ActivityTransport: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        HStack(spacing: 22) {
            SkipButton(forward: false, seconds: snapshot.skipBackward, size: 18)
            PlayPauseButton(isPlaying: snapshot.isPlaying, size: 40)
            SkipButton(forward: true, seconds: snapshot.skipForward, size: 18)
        }
    }
}
