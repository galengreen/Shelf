import AVFoundation
import Observation
import os
import UIKit

nonisolated private let log = Logger(subsystem: "nz.galengreen.shelf", category: "playback")

enum SleepTimerState: Equatable {
    case off
    /// `endsAt` is nil while paused; the countdown only runs during playback.
    case countdown(remaining: TimeInterval, endsAt: Date?)
    case endOfChapter
}

/// Something that can be played: a book, or one episode of a podcast.
struct QueueEntry: Hashable, Identifiable {
    let item: LibraryItem
    var episode: PodcastEpisode?

    var id: String { ProgressKey.make(item.id, episode?.id) }
    var title: String { episode?.displayTitle ?? item.title }
}

/// Owns everything about "what's playing": the server playback session, progress sync,
/// chapter tracking, the sleep timer, the up-next queue, and recovery from network/token failures.
@Observable
final class PlaybackController {
    private(set) var item: LibraryItem?
    /// Set when the item is a podcast and an episode is loaded.
    private(set) var episode: PodcastEpisode?
    private(set) var chapters: [Chapter] = []
    private(set) var duration: Double = 0
    private(set) var isLoading = false
    private(set) var isStreaming = false
    private(set) var speed: Double = 1
    private(set) var currentChapterIndex: Int?
    private(set) var sleepTimer: SleepTimerState = .off {
        didSet { if sleepTimer != oldValue { onStateChange?() } }
    }
    /// Plays automatically after the current item finishes (e.g. the rest of a playlist).
    private(set) var queue: [QueueEntry] = []
    private(set) var queueName: String?
    /// Offered after finishing a book: the next unfinished book in its series.
    private(set) var suggestedNext: LibraryItem?
    var errorMessage: String? {
        didSet { if errorMessage != nil { resolvePlayWaiters(playing: false) } }
    }

    let engine = AudioEngine()

    var isPlaying: Bool { engine.isPlaying }
    var isBuffering: Bool { engine.isBuffering || isLoading }

    /// Progress key of what's loaded ("itemId", or "itemId/episodeId").
    var key: String? { item.map { ProgressKey.make($0.id, episode?.id) } }
    var displayTitle: String { episode?.displayTitle ?? item?.title ?? "" }
    var displaySubtitle: String? { episode != nil ? item?.title : item?.authorName }

    /// Position for display. Reading this subscribes a view to ~2 Hz updates, so only small leaf
    /// views (scrubber, time labels) should touch it.
    var time: Double {
        guard let key else { return 0 }
        return engine.hasSources ? engine.observedTime : progress.resumePosition(for: key)
    }

    /// Position without subscribing to playhead updates (for one-off reads such as bookmarking).
    var currentTime: Double {
        guard let key else { return 0 }
        return engine.hasSources ? engine.currentTime : progress.resumePosition(for: key)
    }

    var currentChapter: Chapter? { currentChapterIndex.flatMap { chapters.indices.contains($0) ? chapters[$0] : nil } }

    /// Played to the end, with nothing loaded since.
    var isFinishedAndIdle: Bool {
        guard let key, !engine.hasSources else { return false }
        return progress.snapshot(for: key)?.isFinished == true
    }

    // MARK: Dependencies

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let progress: ProgressStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let localSessions: LocalSessionStore
    @ObservationIgnored var apiProvider: () -> APIClient? = { nil }
    /// Called after anything shown outside the app changes: item, chapter, play state, speed,
    /// position (seeks) and the sleep timer. Never called on a timer.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Server session id that this device is currently syncing (so socket echoes can be ignored).
    @ObservationIgnored var activeServerSessionId: String? { serverSessionId }

    // MARK: Session state

    @ObservationIgnored private let nowPlaying = NowPlaying()
    @ObservationIgnored private var serverSessionId: String?
    @ObservationIgnored private var localSessionId: String?
    @ObservationIgnored private var localSessionStart: Double = 0
    @ObservationIgnored private var streamTracks: [AudioTrack] = []
    @ObservationIgnored private var listeningSince: Date?
    @ObservationIgnored private var unsyncedListening: TimeInterval = 0
    @ObservationIgnored private var lastRecordedAt: Date = .distantPast
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var syncLoop: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryAttempts: [Date] = []
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var playWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private static let lastItemKey = "lastPlayedItemId"

    init(settings: Settings, progress: ProgressStore, library: LibraryStore, downloads: DownloadManager,
         network: NetworkMonitor, localSessions: LocalSessionStore) {
        self.settings = settings
        self.progress = progress
        self.library = library
        self.downloads = downloads
        self.network = network
        self.localSessions = localSessions
        configureAudioSession()
        wireEngine()
        registerRemoteCommands()
        observeAudioSession()
    }

    // MARK: - Opening

    /// Shows the last item in the mini player after launch without touching the network or
    /// loading audio until the user actually presses play.
    func restoreLastItem() {
        guard item == nil, let key = UserDefaults.standard.string(forKey: Self.lastItemKey) else { return }
        let (itemId, episodeId) = ProgressKey.split(key)
        guard let found = library.item(itemId) ?? downloads.manifests[key]?.item else { return }
        let foundEpisode = episodeId.flatMap { id in
            downloads.manifests[key]?.episode ?? found.media.episodes?.first { $0.id == id }
        }
        if episodeId != nil && foundEpisode == nil { return }
        item = found
        episode = foundEpisode
        duration = foundEpisode?.playDuration ?? found.duration
        speed = settings.speed(for: itemId)
        chapters = knownChapters(for: found, episode: foundEpisode)
        updateChapter(for: progress.resumePosition(for: key))
        onStateChange?()
        Task { await library.loadDetails(itemId, api: apiProvider()).map(applyDetails) }
    }

    func open(_ target: LibraryItem, episode: PodcastEpisode? = nil, at start: Double? = nil, autoplay: Bool = true) {
        // Picking the next queued entry by hand counts as playing it from the queue.
        if queue.first?.id == ProgressKey.make(target.id, episode?.id) { queue.removeFirst() }
        openTask?.cancel()
        openTask = Task { await performOpen(target, episode: episode, at: start, autoplay: autoplay) }
    }

    /// Plays the entries in order, starting with the first.
    func play(queue entries: [QueueEntry], named name: String?) {
        guard let first = entries.first else { return }
        queue = Array(entries.dropFirst())
        queueName = name
        openTask?.cancel()
        openTask = Task { await performOpen(first.item, episode: first.episode, at: nil, autoplay: true) }
    }

    func clearQueue() {
        queue = []
        queueName = nil
    }

    func removeFromQueue(_ entry: QueueEntry) {
        queue.removeAll { $0.id == entry.id }
        if queue.isEmpty { queueName = nil }
    }

    func dismissSuggestion() { suggestedNext = nil }

    private func performOpen(_ target: LibraryItem, episode targetEpisode: PodcastEpisode?, at start: Double?, autoplay: Bool) async {
        let targetKey = ProgressKey.make(target.id, targetEpisode?.id)
        if key == targetKey, engine.hasSources {
            if let start { await seek(to: start) }
            if autoplay { play() }
            return
        }
        if item != nil, engine.hasSources { await closeSession() }

        item = target
        episode = targetEpisode
        suggestedNext = nil
        duration = targetEpisode?.playDuration ?? target.duration
        speed = settings.speed(for: target.id)
        chapters = knownChapters(for: target, episode: targetEpisode)
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }
        UserDefaults.standard.set(targetKey, forKey: Self.lastItemKey)

        let position = start ?? progress.resumePosition(for: targetKey)
        let sources: [AudioEngine.Source]
        do {
            sources = try await makeSources(for: target, episode: targetEpisode)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        guard !Task.isCancelled, key == targetKey else { return }
        if chapters.isEmpty { chapters = Self.syntheticChapters(from: sources) }
        if duration <= 0 { duration = sources.last.map { $0.startOffset + $0.duration } ?? 0 }

        await engine.load(sources, at: position)
        engine.setRate(Float(speed))
        localSessionStart = position
        updateChapter(for: position, force: true)
        loadArtwork(for: target)
        if autoplay { play() } else { updateNowPlaying() }

        if settings.autoDownload, isStreaming, network.isOnline, downloads.state(for: targetKey) == .none,
           let details = await library.loadDetails(target.id, api: apiProvider()) {
            await downloads.download(details, episode: targetEpisode)
        }
    }

    /// Best chapter list available without a network round trip.
    private func knownChapters(for target: LibraryItem, episode: PodcastEpisode?) -> [Chapter] {
        let key = ProgressKey.make(target.id, episode?.id)
        if let episode {
            return [episode.chapters, downloads.manifests[key]?.chapters].compactMap { $0 }.first { !$0.isEmpty } ?? []
        }
        return [library.item(target.id)?.media.chapters, target.media.chapters, downloads.manifests[key]?.chapters]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? []
    }

    private func makeSources(for target: LibraryItem, episode: PodcastEpisode?) async throws -> [AudioEngine.Source] {
        let api = apiProvider()
        let key = ProgressKey.make(target.id, episode?.id)
        if let local = downloads.localTracks(for: key) {
            isStreaming = false
            streamTracks = []
            if let manifest = downloads.manifests[key], chapters.isEmpty { chapters = manifest.chapters }
            // Still open a server session so listening stats and cross-device sync work.
            if let api, network.isOnline {
                Task { [weak self] in
                    guard let session = try? await self?.startServerSession(target.id, episodeId: episode?.id, api: api) else { return }
                    guard let self, self.key == key else { return }
                    self.adoptServerSession(session.id)
                }
            }
            return local.map { AudioEngine.Source(url: $0.url, startOffset: $0.startOffset, duration: $0.duration) }
        }

        guard let api else { throw APIError.unauthorized }
        guard network.isOnline else {
            throw PlaybackError.notDownloaded
        }
        let session = try await startServerSession(target.id, episodeId: episode?.id, api: api)
        serverSessionId = session.id
        isStreaming = true
        streamTracks = session.audioTracks
        if let full = session.libraryItem {
            library.cacheDetails(full)
            applyDetails(full)
        }
        if let sessionChapters = session.chapters, !sessionChapters.isEmpty { chapters = sessionChapters }
        if let total = session.duration, total > 0 { duration = total }
        return try await streamingSources(api: api)
    }

    private func streamingSources(api: APIClient) async throws -> [AudioEngine.Source] {
        var sources: [AudioEngine.Source] = []
        for track in streamTracks {
            sources.append(.init(url: try await api.mediaURL(for: track.contentUrl), startOffset: track.startOffset, duration: track.duration))
        }
        return sources
    }

    private func startServerSession(_ itemId: String, episodeId: String?, api: APIClient) async throws -> PlaybackSession {
        struct Body: Encodable, Sendable {
            let deviceInfo = DeviceInfo.payload
            let forceDirectPlay = false
            let forceTranscode = false
            let supportedMimeTypes = PlaybackFormats.directPlayMimeTypes
            let mediaPlayer = "AVPlayer"
        }
        let path = "api/items/\(itemId)/play" + (episodeId.map { "/\($0)" } ?? "")
        return try await api.post(path, json: Body(), as: PlaybackSession.self)
    }

    /// A server session opened late (downloaded book): listening up to now stays in the local session.
    private func adoptServerSession(_ id: String) {
        moveListeningToLocalSession()
        localSessionId = nil
        serverSessionId = id
    }

    private func applyDetails(_ details: LibraryItem) {
        guard details.id == item?.id else { return }
        item = details
        if let episode, let fresh = details.media.episodes?.first(where: { $0.id == episode.id }) {
            self.episode = fresh
        }
        let detailChapters = episode?.chapters ?? details.media.chapters
        if let detailChapters, !detailChapters.isEmpty, chapters.count <= 1 {
            chapters = detailChapters
            updateChapter(for: currentTime, force: true)
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let item else { return }
        wantsToPlay = true
        guard engine.hasSources else {
            if !isLoading { open(item, episode: episode, autoplay: true) }
            return
        }
        Task {
            await prepareToResume()
            guard wantsToPlay else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play()
        }
    }

    func pause() {
        wantsToPlay = false
        engine.pause()
    }

    func seek(to time: Double) async {
        let target = time.clamped(to: 0...max(duration, 0))
        await engine.seek(to: target)
        updateChapter(for: target, force: true)
        recordLocally()
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        Task { await seek(to: engine.currentTime + seconds) }
    }

    func nextChapter() {
        guard let index = currentChapterIndex, index + 1 < chapters.count else { return }
        Task { await seek(to: chapters[index + 1].start) }
    }

    /// Restarts the current chapter, or goes to the previous one if within its first few seconds.
    func previousChapter() {
        guard let index = currentChapterIndex else { return }
        let elapsed = engine.currentTime - chapters[index].start
        let target = elapsed < 4 && index > 0 ? chapters[index - 1].start : chapters[index].start
        Task { await seek(to: target) }
    }

    func playChapter(_ chapter: Chapter) {
        jump(to: chapter.start)
    }

    /// Seeks and plays, loading the item first if needed.
    func jump(to time: Double) {
        guard let item else { return }
        if engine.hasSources {
            Task {
                await seek(to: time)
                play()
            }
        } else {
            open(item, episode: episode, at: time, autoplay: true)
        }
    }

    func setSpeed(_ value: Double) {
        speed = value
        engine.setRate(Float(value))
        if let item { settings.setSpeed(value, for: item.id) }
        updateNowPlaying()
    }

    /// Stops playback entirely (e.g. on sign-out).
    func stop() async {
        wantsToPlay = false
        engine.pause()
        await closeSession()
        engine.unload()
        nowPlaying.clear()
        cancelSleepTimer()
        item = nil
        episode = nil
        chapters = []
        clearQueue()
        suggestedNext = nil
        UserDefaults.standard.removeObject(forKey: Self.lastItemKey)
        onStateChange?()
    }

    /// Waits until audio is actually playing, or opening it failed. An intent that launched the app
    /// in the background uses this so it doesn't finish, letting the app be suspended, before the
    /// stream has started.
    func waitUntilPlaying(timeout: Duration = .seconds(20)) async -> Bool {
        if isPlaying { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            playWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.playWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func resolvePlayWaiters(playing: Bool) {
        guard !playWaiters.isEmpty else { return }
        let waiters = playWaiters
        playWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: playing) }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Double) {
        sleepTask?.cancel()
        let seconds = minutes * 60
        sleepTimer = .countdown(remaining: seconds, endsAt: isPlaying ? .now + seconds : nil)
        scheduleSleep()
    }

    func setSleepAtEndOfChapter() {
        sleepTask?.cancel()
        engine.setVolume(1)
        sleepTimer = .endOfChapter
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        engine.setVolume(1)
        sleepTimer = .off
    }

    private func scheduleSleep() {
        sleepTask?.cancel()
        guard case let .countdown(_, endsAt?) = sleepTimer else { return }
        sleepTask = Task { [weak self] in
            let fade: TimeInterval = 8
            let untilFade = endsAt.timeIntervalSinceNow - fade
            if untilFade > 0 { try? await Task.sleep(for: .seconds(untilFade)) }
            guard !Task.isCancelled else { return }
            await self?.fadeOutAndPause(over: min(fade, max(endsAt.timeIntervalSinceNow, 0.5)))
        }
    }

    private func fadeOutAndPause(over seconds: TimeInterval) async {
        let steps = 16
        for step in 1...steps {
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
            if Task.isCancelled { engine.setVolume(1); return }
            engine.setVolume(1 - Float(step) / Float(steps))
        }
        pause()
        try? await Task.sleep(for: .milliseconds(300))
        engine.setVolume(1)
        sleepTimer = .off
    }

    private func sleepTimerPlaybackChanged(_ playing: Bool) {
        guard case let .countdown(remaining, endsAt) = sleepTimer else { return }
        if playing, endsAt == nil {
            sleepTimer = .countdown(remaining: remaining, endsAt: .now + remaining)
            scheduleSleep()
        } else if !playing, let endsAt {
            sleepTask?.cancel()
            engine.setVolume(1)
            sleepTimer = .countdown(remaining: max(endsAt.timeIntervalSinceNow, 0), endsAt: nil)
        }
    }

    // MARK: - Progress & sync

    private func recordLocally() {
        guard let key, engine.hasSources else { return }
        progress.record(key: key, currentTime: engine.currentTime, duration: duration, uploaded: false)
        lastRecordedAt = .now
    }

    private func takeListenedTime() {
        if let since = listeningSince {
            unsyncedListening += Date.now.timeIntervalSince(since)
            listeningSince = isPlaying ? .now : nil
        }
    }

    /// Without a server session, listening time goes into a local session that's uploaded later.
    private func moveListeningToLocalSession() {
        guard let item, unsyncedListening > 0 else { return }
        localSessionId = localSessions.record(
            sessionId: localSessionId, item: item, episode: episode, duration: duration,
            startTime: localSessionStart, currentTime: engine.currentTime, listened: unsyncedListening.rounded()
        )
        unsyncedListening = 0
    }

    func sync() async {
        guard let key, engine.hasSources else { return }
        takeListenedTime()
        let time = engine.currentTime
        recordLocally()
        if serverSessionId == nil { moveListeningToLocalSession() }
        guard let api = apiProvider(), network.isOnline else { return }
        if let sessionId = serverSessionId {
            let payload = SyncPayload(currentTime: time, timeListened: unsyncedListening.rounded(), duration: duration)
            do {
                try await api.send("POST", "api/session/\(sessionId)/sync", json: payload)
                unsyncedListening = 0
                if progress.local[key]?.currentTime == time { progress.markUploaded(key) }
            } catch APIError.http(404) {
                log.notice("Server session expired; falling back to progress updates")
                // Server restarted or expired the session; keep counting locally instead.
                serverSessionId = nil
                moveListeningToLocalSession()
                await progress.flushPending(using: api)
            } catch {}
        } else {
            await progress.flushPending(using: api)
            await localSessions.upload(using: api)
        }
    }

    /// Ends the server session. Progress is recorded locally first and the network call runs
    /// in the background, so switching books or stopping never waits on a slow/unreachable server
    /// (if it fails, the local record is uploaded on the next reconnect).
    private func closeSession() async {
        stopSyncLoop()
        guard let key, engine.hasSources else { return }
        takeListenedTime()
        let time = engine.currentTime
        recordLocally()
        if serverSessionId == nil { moveListeningToLocalSession() }
        let payload = SyncPayload(currentTime: time, timeListened: unsyncedListening.rounded(), duration: duration)
        let sessionId = serverSessionId
        serverSessionId = nil
        localSessionId = nil
        unsyncedListening = 0
        listeningSince = nil
        guard let api = apiProvider(), network.isOnline else { return }
        let progress = self.progress
        let localSessions = self.localSessions
        Task {
            do {
                if let sessionId {
                    try await api.send("POST", "api/session/\(sessionId)/close", json: payload)
                    if progress.local[key]?.currentTime == time { progress.markUploaded(key) }
                } else {
                    await progress.flushPending(using: api)
                    await localSessions.upload(using: api)
                }
            } catch {}
        }
    }

    private func startSyncLoop() {
        guard syncLoop == nil else { return }
        syncLoop = Task { [weak self] in
            while !Task.isCancelled {
                let interval: Double = (self?.isInBackground ?? false) ? 60 : 30
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    private func stopSyncLoop() {
        syncLoop?.cancel()
        syncLoop = nil
    }

    /// Before resuming: refresh an about-to-expire stream token at a pause boundary (seamless,
    /// rather than failing mid-sentence later), pick up progress made on another device, and
    /// apply smart rewind.
    private func prepareToResume() async {
        guard let key else { return }
        if isStreaming, let api = apiProvider(), await api.tokenExpiresSoon(within: 15 * 60) {
            log.notice("Stream token expiring soon; refreshing before resuming")
            if (try? await api.refresh()) != nil, let sources = try? await streamingSources(api: api) {
                await engine.load(sources, at: engine.currentTime)
            }
        }
        if let remote = progress.server[key], let lastUpdate = remote.lastUpdate,
           Date(timeIntervalSince1970: lastUpdate / 1000) > lastRecordedAt.addingTimeInterval(5),
           let remoteTime = remote.currentTime, abs(remoteTime - engine.currentTime) > 5, remote.isFinished != true {
            await seek(to: remoteTime)
        } else if settings.smartRewind, let pausedAt {
            let paused = Date.now.timeIntervalSince(pausedAt)
            let rewind: Double = paused > 3600 ? 20 : paused > 300 ? 10 : paused > 30 ? 3 : 0
            if rewind > 0 { await seek(to: engine.currentTime - rewind) }
        }
        pausedAt = nil
    }

    /// Another device moved this item's position while we're paused: follow it now, so the
    /// mini player and lock screen are right before you press play.
    func remoteProgressChanged(for changedKey: String) {
        guard changedKey == key, !isPlaying, engine.hasSources,
              let remote = progress.server[changedKey], remote.isFinished != true,
              let lastUpdate = remote.lastUpdate,
              Date(timeIntervalSince1970: lastUpdate / 1000) > lastRecordedAt.addingTimeInterval(5),
              let remoteTime = remote.currentTime, abs(remoteTime - engine.currentTime) > 5 else { return }
        Task { await seek(to: remoteTime) }
    }

    // MARK: - Engine events

    private func wireEngine() {
        engine.onPlayingChanged = { [weak self] playing in
            guard let self else { return }
            if playing {
                listeningSince = .now
                pausedAt = nil
                startSyncLoop()
                resolvePlayWaiters(playing: true)
            } else {
                takeListenedTime()
                listeningSince = nil
                pausedAt = .now
                stopSyncLoop()
                Task { await self.sync() }
            }
            sleepTimerPlaybackChanged(playing)
            updateNowPlaying()
        }
        engine.onTick = { [weak self] time in
            self?.updateChapter(for: time)
        }
        engine.onBoundary = { [weak self] in
            guard let self else { return }
            let time = engine.currentTime
            if sleepTimer == .endOfChapter {
                sleepTimer = .off
                Task { await self.fadeOutAndPause(over: 1.5) }
            }
            updateChapter(for: time + 0.05, force: true)
            updateNowPlaying()
        }
        engine.onFinished = { [weak self] in
            Task { await self?.finished() }
        }
        engine.onFailure = { [weak self] error in
            log.error("Player item failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            Task { await self?.recover() }
        }
    }

    private func finished() async {
        guard let item, let key else { return }
        wantsToPlay = false
        let sleepPending = sleepTimer != .off
        cancelSleepTimer()
        engine.pause()
        await closeSession()
        // Unload before any network wait: with no audio loaded, a sync triggered by the pause
        // can't record the end position as "not finished" and race the finished flag to the server.
        // Unloading rather than rewinding also means nothing is recorded until it's replayed.
        engine.unload()
        progress.record(key: key, currentTime: duration, duration: duration, isFinished: true, uploaded: false)
        updateChapter(for: 0, force: true)
        updateNowPlaying()
        await progress.setFinished(true, key: key, duration: duration, api: apiProvider())
        if settings.deleteFinishedDownloads { downloads.delete(key) }

        // A sleep timer means you're drifting off: don't start something new.
        guard !sleepPending else { return }
        if let next = queue.first {
            queue.removeFirst()
            if queue.isEmpty { queueName = nil }
            await performOpen(next.item, episode: next.episode, at: nil, autoplay: true)
        } else if episode == nil, let next = library.nextInSeries(after: item.id, isFinished: { self.progress.snapshot(for: $0)?.isFinished == true }) {
            if settings.autoplayNextInSeries {
                await performOpen(next, episode: nil, at: nil, autoplay: true)
            } else {
                suggestedNext = next
            }
        }
    }

    /// Rebuilds the player at the current position after a failure (typically an expired
    /// stream token or a dropped connection), at most a few times per minute.
    private func recover() async {
        guard let key, !isRecovering else { return }
        recoveryAttempts = recoveryAttempts.filter { $0.timeIntervalSinceNow > -60 } + [.now]
        guard recoveryAttempts.count <= 3 else {
            errorMessage = network.isOnline ? "Playback failed. Check your connection to the server." : PlaybackError.notDownloaded.localizedDescription
            return
        }
        isRecovering = true
        defer { isRecovering = false }
        let position = engine.currentTime
        log.notice("Recovering playback at \(position, format: .fixed(precision: 1))s (attempt \(self.recoveryAttempts.count))")
        let resume = wantsToPlay
        try? await Task.sleep(for: .seconds(Double(recoveryAttempts.count)))
        do {
            let sources: [AudioEngine.Source]
            if let local = downloads.localTracks(for: key) {
                sources = local.map { .init(url: $0.url, startOffset: $0.startOffset, duration: $0.duration) }
            } else {
                guard let api = apiProvider() else { return }
                if await api.tokenIsRefreshable { try await api.refresh() }
                sources = try await streamingSources(api: api)
            }
            await engine.load(sources, at: position)
            engine.setRate(Float(speed))
            if resume { engine.play() }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Chapters & Now Playing

    private func updateChapter(for time: Double, force: Bool = false) {
        guard !chapters.isEmpty else { currentChapterIndex = nil; return }
        if !force, let index = currentChapterIndex, chapters.indices.contains(index),
           time >= chapters[index].start, time < chapters[index].end { return }
        let index = chapters.lastIndex { $0.start <= time + 0.01 } ?? 0
        let changed = index != currentChapterIndex
        currentChapterIndex = index
        engine.setBoundary(chapters[index].end)
        if changed { updateNowPlaying() }
    }

    func updateNowPlaying() {
        guard item != nil else { return }
        let time = currentTime
        var info = NowPlaying.Info(
            title: displayTitle, album: item?.title ?? displayTitle, artist: displaySubtitle,
            elapsed: time, duration: duration, rate: Float(speed), isPlaying: isPlaying,
            chapterNumber: currentChapterIndex.map { $0 + 1 }, chapterCount: chapters.isEmpty ? nil : chapters.count
        )
        if settings.lockScreenUsesChapter, let chapter = currentChapter {
            info.title = chapter.title
            info.elapsed = max(0, time - chapter.start)
            info.duration = chapter.duration
        }
        nowPlaying.update(info)
        onStateChange?()
    }

    private func loadArtwork(for item: LibraryItem) {
        Task {
            let image = await ImagePipeline.shared.image(item.coverSource, pixelWidth: 640)
            nowPlaying.setArtwork(image, key: item.id)
        }
    }

    private func registerRemoteCommands() {
        nowPlaying.register(.init(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skipForward: { [weak self] in self.map { $0.skip(by: $0.settings.skipForward) } },
            skipBackward: { [weak self] in self.map { $0.skip(by: -$0.settings.skipBackward) } },
            nextChapter: { [weak self] in self?.nextChapter() },
            previousChapter: { [weak self] in self?.previousChapter() },
            seek: { [weak self] position in
                guard let self else { return }
                let base = settings.lockScreenUsesChapter ? (currentChapter?.start ?? 0) : 0
                Task { await self.seek(to: base + position) }
            },
            rate: { [weak self] rate in self?.setSpeed(Double(rate)) }
        ), skipBackward: settings.skipBackward, skipForward: settings.skipForward)
    }

    /// Call after the skip interval settings change so the lock screen shows the right icons.
    func refreshRemoteCommands() { registerRemoteCommands() }

    // MARK: - App lifecycle

    func appDidEnterBackground() {
        isInBackground = true
        engine.observesTime = false
        if engine.hasSources { Task { await sync() } }
    }

    func appWillEnterForeground() {
        isInBackground = false
        if engine.hasSources { updateChapter(for: engine.currentTime) }
    }

    /// Whether any UI that displays the playhead is visible.
    func setTimeObservation(_ on: Bool) {
        engine.observesTime = on && !isInBackground
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                guard let self, type == .ended else { return }
                if options?.contains(.shouldResume) == true, self.wantsToPlay {
                    self.play()
                } else {
                    self.wantsToPlay = false
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                // Headphones unplugged / Bluetooth disconnected: the system pauses; remember it was deliberate.
                if reason == .oldDeviceUnavailable { self?.wantsToPlay = false }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.configureAudioSession()
                Task { await self.recover() }
            }
        }
    }

    static func syntheticChapters(from sources: [AudioEngine.Source]) -> [Chapter] {
        guard sources.count > 1 else { return [] }
        return sources.enumerated().map { index, source in
            Chapter(id: index, start: source.startOffset, end: source.startOffset + source.duration, title: "Part \(index + 1)")
        }
    }
}

enum PlaybackError: LocalizedError {
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .notDownloaded: "This isn't downloaded. Connect to the internet to stream it."
        }
    }
}
