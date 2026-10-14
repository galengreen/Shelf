import ActivityKit
import Foundation
import os

nonisolated private let log = Logger(subsystem: "nz.galengreen.shelf", category: "live-activity")

/// Lock Screen and Dynamic Island while a book plays. Started when playback starts, updated only when
/// something it shows changes (chapter, play state, speed, sleep timer, a seek), and ended when
/// playback stops or the book finishes. Progress and countdowns are drawn by the system from dates,
/// so nothing is sent while the chapter simply plays on.
final class LiveActivityController {
    private typealias NowPlayingActivity = Activity<NowPlayingAttributes>

    private let isEnabled: () -> Bool
    /// The activity is looked up by id when needed (`Activity` isn't `Sendable`).
    private var activityId: String?
    /// What the activity is showing.
    private var shown: NowPlayingSnapshot?
    /// Latest snapshot, even when no activity is running.
    private var latest: NowPlayingSnapshot?
    /// A start that failed because the app was in the background; retried in the foreground.
    private var pendingStart = false
    private var endTask: Task<Void, Never>?

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        // Pick up an activity left running by a previous launch, and drop any extras.
        let existing = NowPlayingActivity.activities
        let kept = existing.first { $0.activityState == .active }
        activityId = kept?.id
        shown = kept?.content.state
        for other in existing where other.id != kept?.id {
            let id = other.id
            Task { await Self.end(id) }
        }
    }

    private var activity: NowPlayingActivity? {
        guard let activityId else { return nil }
        return NowPlayingActivity.activities.first { $0.id == activityId }
    }

    func update(_ snapshot: NowPlayingSnapshot?) {
        let previous = latest
        latest = snapshot
        guard isEnabled(), let snapshot else {
            end(after: nil)
            return
        }
        if snapshot.isFinished {
            // Wait a moment: a queue or series may start the next book straight away.
            end(after: .seconds(4))
            return
        }
        endTask?.cancel()
        endTask = nil
        let state = activity?.activityState
        if state == nil || state == .dismissed || state == .ended {
            activityId = nil
            shown = nil
        }

        if let activityId {
            guard shown.map({ $0.differsVisibly(from: snapshot, tolerance: 3) }) ?? true else { return }
            shown = snapshot
            Task { await Self.update(activityId, to: snapshot) }
        } else if snapshot.isPlaying, previous?.isPlaying != true || previous?.key != snapshot.key || pendingStart {
            // Only when playback starts, so a dismissed activity stays dismissed until you press play.
            start(snapshot)
        }
    }

    /// Activities can only be started from the foreground; playback started from the background
    /// (headphones, Siri, a widget) gets its activity the next time the app is opened.
    func retryPendingStart() {
        guard pendingStart, activityId == nil, let latest, latest.isPlaying, isEnabled() else { return }
        start(latest)
    }

    /// Settings toggle: ends any activity when turned off, starts one if playing when turned on.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            if activityId == nil, let latest, latest.isPlaying { start(latest) }
        } else {
            end(after: nil)
        }
    }

    private func start(_ snapshot: NowPlayingSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try NowPlayingActivity.request(attributes: NowPlayingAttributes(),
                                                          content: ActivityContent(state: snapshot, staleDate: nil))
            activityId = activity.id
            shown = snapshot
            pendingStart = false
        } catch {
            log.notice("Live Activity not started: \(error.localizedDescription, privacy: .public)")
            pendingStart = true
        }
    }

    private func end(after delay: Duration?) {
        pendingStart = false
        guard let id = activityId else { return }
        if delay != nil, endTask != nil { return }
        endTask?.cancel()
        endTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await Self.end(id)
            guard let self, self.activityId == id else { return }
            self.activityId = nil
            self.shown = nil
            self.endTask = nil
        }
    }

    private nonisolated static func update(_ id: String, to state: NowPlayingSnapshot) async {
        guard let activity = NowPlayingActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func end(_ id: String) async {
        guard let activity = NowPlayingActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
