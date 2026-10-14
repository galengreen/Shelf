import AppIntents
import SwiftUI
import WidgetKit

// Control Centre (and Lock Screen / Action button) controls. Values come from the snapshot the app
// writes; the app reloads the controls when play state or the sleep timer changes.

nonisolated struct PlaybackControlValue: Sendable {
    let isPlaying: Bool
    let title: String?
}

nonisolated struct PlaybackValueProvider: ControlValueProvider {
    var previewValue: PlaybackControlValue { PlaybackControlValue(isPlaying: false, title: nil) }

    func currentValue() async throws -> PlaybackControlValue {
        let snapshot = WidgetData.nowPlaying()
        return PlaybackControlValue(isPlaying: snapshot?.isPlaying ?? false, title: snapshot?.title)
    }
}

struct PlaybackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.playbackControl, provider: PlaybackValueProvider()) { value in
            ControlWidgetToggle(value.title ?? "Shelf", isOn: value.isPlaying, action: SetPlayingIntent()) { isOn in
                Label(isOn ? "Playing" : "Paused", systemImage: isOn ? "pause.fill" : "play.fill")
            }
            .tint(Color.shelfAccent)
        }
        .displayName("Play or Pause")
        .description("Resume or pause your audiobook.")
    }
}

nonisolated struct SkipIntervalProvider: ControlValueProvider {
    var previewValue: Double { 15 }

    func currentValue() async throws -> Double {
        WidgetData.nowPlaying()?.skipBackward ?? 15
    }
}

struct SkipBackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.skipBackControl, provider: SkipIntervalProvider()) { seconds in
            ControlWidgetButton(action: SkipBackIntent()) {
                Label("Skip Back", systemImage: SkipSymbol.backward(seconds))
            }
        }
        .displayName("Skip Back")
        .description("Go back a little in your audiobook.")
    }
}

/// Lets you choose the sleep timer's length when adding the control.
struct SleepTimerControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Sleep Timer"

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 600))
    var minutes: Int

    init() {}
}

nonisolated struct SleepControlValue: Sendable {
    let isOn: Bool
    let minutes: Int
}

nonisolated struct SleepTimerValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SleepTimerControlConfiguration) -> SleepControlValue {
        SleepControlValue(isOn: false, minutes: configuration.minutes)
    }

    func currentValue(configuration: SleepTimerControlConfiguration) async throws -> SleepControlValue {
        let sleep = WidgetData.nowPlaying()?.sleep ?? .off
        return SleepControlValue(isOn: sleep != .off, minutes: configuration.minutes)
    }
}

struct SleepTimerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: WidgetKinds.sleepControl, provider: SleepTimerValueProvider()) { value in
            ControlWidgetToggle("Sleep Timer", isOn: value.isOn, action: SetSleepTimerOnIntent(minutes: value.minutes)) { isOn in
                Label(isOn ? "On" : "\(value.minutes) min", systemImage: isOn ? "moon.zzz.fill" : "moon.zzz")
            }
            .tint(Color.shelfAccent)
        }
        .displayName("Sleep Timer")
        .description("Pause your audiobook after a while.")
    }
}
