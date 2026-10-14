import Foundation
import WidgetKit

/// Writes the widgets' data into the App Group container and asks WidgetKit to reload, only when
/// something a widget shows has changed. While audio is playing these reloads don't count against
/// the widgets' daily budget.
final class WidgetSnapshotWriter {
    private var lastNowPlaying: NowPlayingSnapshot?
    private var hasWrittenNowPlaying = false
    private var lastListening: [String: Double]?

    func update(_ snapshot: NowPlayingSnapshot?) {
        let previous = lastNowPlaying
        if hasWrittenNowPlaying {
            switch (previous, snapshot) {
            case (nil, nil): return
            case let (old?, new?) where !old.differsVisibly(from: new, tolerance: 10): return
            default: break
            }
        }
        lastNowPlaying = snapshot
        hasWrittenNowPlaying = true
        // Controls only show play state and the sleep timer.
        let controlsChanged = previous?.isPlaying != snapshot?.isPlaying || previous?.sleep != snapshot?.sleep
        Self.write(snapshot.flatMap(AppGroup.encode), to: AppGroup.nowPlayingFile) {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.nowPlaying)
            if controlsChanged {
                ControlCenter.shared.reloadControls(ofKind: WidgetKinds.playbackControl)
                ControlCenter.shared.reloadControls(ofKind: WidgetKinds.sleepControl)
            }
        }
    }

    /// Daily listening for the streak and activity widgets ("YYYY-MM-DD" → seconds).
    func updateListening(_ days: [String: Double]) {
        // The widgets draw a year at most.
        let keep = Set(ListeningDays.lastDays(380))
        let recent = days.filter { keep.contains($0.key) }
        guard recent != lastListening else { return }
        lastListening = recent
        let snapshot = ListeningSnapshot(days: recent, updatedAt: .now)
        Self.write(AppGroup.encode(snapshot), to: AppGroup.listeningFile) {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.streak)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.activity)
        }
    }

    /// Whether a streak or activity widget is on a Home or Lock Screen, so stats are only fetched
    /// for widgets when someone will see them.
    func hasListeningWidgets() async -> Bool {
        guard let configurations = try? await WidgetCenter.shared.currentConfigurations() else { return false }
        return configurations.contains { $0.kind == WidgetKinds.streak || $0.kind == WidgetKinds.activity }
    }

    func reset() {
        update(nil)
        lastListening = nil
        Self.write(nil, to: AppGroup.listeningFile) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Serial, so writes land in the order they were made.
    private static let queue = DispatchQueue(label: "widget-snapshots", qos: .utility)

    /// Writes (or removes, for nil) off the main thread, then reloads on the main actor.
    private static func write(_ data: Data?, to file: URL?, then reload: @escaping @MainActor @Sendable () -> Void) {
        guard let file else { return }
        queue.async {
            if let data {
                try? data.write(to: file, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: file)
            }
            Task { @MainActor in reload() }
        }
    }
}
