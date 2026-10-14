import Foundation
import UIKit

/// Pushes what's playing to everything outside the app: widgets and Control Centre, the Live
/// Activity and the watch. The player calls in on every real change (never on a timer); calls are
/// coalesced to one per run-loop turn, and each destination drops snapshots it would show the same.
final class PlaybackBroadcaster {
    let widgets = WidgetSnapshotWriter()
    let liveActivity: LiveActivityController
    let watch: WatchLink

    private let player: PlaybackController
    private let settings: Settings
    private var isScheduled = false
    /// Cover written to the App Group container: (cache key, file name).
    private var exportedCover: (key: String, file: String)?
    private var exportingCoverKey: String?

    init(player: PlaybackController, settings: Settings) {
        self.player = player
        self.settings = settings
        liveActivity = LiveActivityController(isEnabled: { settings.liveActivities })
        watch = WatchLink()
        exportedCover = Self.existingCover()
        player.onStateChange = { [weak self] in self?.schedule() }
    }

    func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        Task { [weak self] in
            guard let self else { return }
            isScheduled = false
            publish()
        }
    }

    private func publish() {
        let source = player.item?.coverSource
        if let source, exportedCover?.key != source.cacheKey { exportCover(source) }
        let coverFile = exportedCover.flatMap { $0.key == source?.cacheKey ? $0.file : nil }
        var snapshot = player.externalSnapshot(coverFile: coverFile)
        snapshot?.skipBackward = settings.skipBackward
        snapshot?.skipForward = settings.skipForward
        widgets.update(snapshot)
        liveActivity.update(snapshot)
        watch.update(snapshot)
    }

    func appWillEnterForeground() {
        liveActivity.retryPendingStart()
    }

    // MARK: - Cover

    /// Writes a small JPEG of the cover into the App Group container (widgets can't use the network
    /// or the app's caches), then publishes again so the snapshot points at it.
    private func exportCover(_ source: ImageSource) {
        guard exportingCoverKey != source.cacheKey else { return }
        exportingCoverKey = source.cacheKey
        Task {
            defer { exportingCoverKey = nil }
            guard let image = await ImagePipeline.shared.image(source, pixelWidth: 320) else { return }
            let name = "cover-\(source.cacheKey).jpg"
            guard await Self.writeCover(image, named: name) else { return }
            exportedCover = (source.cacheKey, name)
            schedule()
        }
    }

    @concurrent
    private static func writeCover(_ image: UIImage, named name: String) async -> Bool {
        guard let container = AppGroup.container, let data = image.jpegData(compressionQuality: 0.8) else { return false }
        let fileManager = FileManager.default
        do {
            try data.write(to: container.appending(path: name), options: .atomic)
        } catch {
            return false
        }
        // Only the current cover is kept.
        let old = (try? fileManager.contentsOfDirectory(atPath: container.path)) ?? []
        for file in old where file.hasPrefix("cover-") && file != name {
            try? fileManager.removeItem(at: container.appending(path: file))
        }
        return true
    }

    private static func existingCover() -> (key: String, file: String)? {
        guard let container = AppGroup.container,
              let file = (try? FileManager.default.contentsOfDirectory(atPath: container.path))?.first(where: { $0.hasPrefix("cover-") })
        else { return nil }
        let key = String(file.dropFirst("cover-".count).dropLast(".jpg".count))
        return (key, file)
    }
}

extension PlaybackController {
    /// What's loaded, for widgets, the Live Activity and the watch. nil when nothing is loaded.
    func externalSnapshot(coverFile: String?) -> NowPlayingSnapshot? {
        guard let item, let key else { return nil }
        let chapter = currentChapter
        let sleep: SleepSnapshot = switch sleepTimer {
        case .off: .off
        case .endOfChapter: .endOfChapter
        case let .countdown(remaining, endsAt): endsAt.map { .running(endsAt: $0) } ?? .paused(remaining: remaining)
        }
        return NowPlayingSnapshot(
            itemId: item.id, key: key, title: displayTitle, subtitle: displaySubtitle,
            chapterTitle: chapter?.title, chapterNumber: currentChapterIndex.map { $0 + 1 },
            chapterCount: chapters.isEmpty ? nil : chapters.count,
            isPlaying: isPlaying, isFinished: isFinishedAndIdle, rate: speed,
            position: currentTime, duration: duration,
            chapterStart: chapter?.start ?? 0, chapterEnd: chapter?.end ?? duration,
            capturedAt: .now, sleep: sleep, coverFile: coverFile
        )
    }
}
