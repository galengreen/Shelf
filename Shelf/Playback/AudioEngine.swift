import AVFoundation
import Observation

/// Thin wrapper over AVQueuePlayer that presents a multi-file audiobook as one continuous timeline.
///
/// Efficiency notes:
/// - Only the current file and the next one are queued (gapless without pre-buffering the whole book).
/// - The periodic time observer only exists while something is on screen to show it; in the
///   background, time is read on demand and chapter changes come from a single boundary observer.
@Observable
final class AudioEngine {
    struct Source: Equatable {
        let url: URL
        let startOffset: Double
        let duration: Double
        var isLocal: Bool { url.isFileURL }
    }

    private(set) var isPlaying = false
    private(set) var isBuffering = false
    /// Global position in the book. Only kept fresh while `observesTime` is true.
    private(set) var observedTime: Double = 0

    @ObservationIgnored var onPlayingChanged: ((Bool) -> Void)?
    @ObservationIgnored var onFailure: ((Error?) -> Void)?
    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onBoundary: (() -> Void)?
    @ObservationIgnored var onTick: ((Double) -> Void)?

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private(set) var sources: [Source] = []
    @ObservationIgnored private var itemIndex: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var itemObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var playerObservers: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var boundaryObserver: Any?
    @ObservationIgnored private var pendingBoundary: Double?
    @ObservationIgnored private var rate: Float = 1
    @ObservationIgnored private var lastKnownTime: Double = 0

    var observesTime = false {
        didSet { if observesTime != oldValue { updateTimeObserver() } }
    }

    var hasSources: Bool { !sources.isEmpty }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        playerObservers = Self.observe(player,
            status: { [weak self] status in Task { @MainActor in self?.timeControlChanged(status) } },
            item: { [weak self] in Task { @MainActor in self?.currentItemChanged() } })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { self?.itemDidEnd(item) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let item = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, let item, self.itemIndex[item] != nil else { return }
                self.onFailure?(error)
            }
        })
    }

    // MARK: - Loading

    func load(_ sources: [Source], at time: Double) async {
        self.sources = sources.sorted { $0.startOffset < $1.startOffset }
        await rebuild(at: time)
    }

    func unload() {
        player.pause()
        clearQueue()
        sources = []
        lastKnownTime = 0
        observedTime = 0
    }

    /// The authoritative current position.
    var currentTime: Double {
        guard let item = player.currentItem, let index = itemIndex[ObjectIdentifier(item)] else { return lastKnownTime }
        let local = player.currentTime().seconds
        guard local.isFinite else { return lastKnownTime }
        let time = sources[index].startOffset + local
        lastKnownTime = time
        return time
    }

    var totalDuration: Double {
        sources.last.map { $0.startOffset + $0.duration } ?? 0
    }

    // MARK: - Transport

    func play() {
        guard player.currentItem != nil else { return }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        lastKnownTime = currentTime
        player.pause()
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.defaultRate = newRate
        if player.timeControlStatus != .paused { player.rate = newRate }
    }

    func seek(to time: Double) async {
        let target = time.clamped(to: 0...max(0, totalDuration - 0.5))
        lastKnownTime = target
        observedTime = target
        if let item = player.currentItem, let index = itemIndex[ObjectIdentifier(item)],
           target >= sources[index].startOffset, target < sources[index].startOffset + sources[index].duration {
            let local = CMTime(seconds: target - sources[index].startOffset, preferredTimescale: 1000)
            await player.seek(to: local, toleranceBefore: .zero, toleranceAfter: .zero)
            armBoundary()
        } else {
            let wasPlaying = player.timeControlStatus != .paused
            await rebuild(at: target)
            if wasPlaying { play() }
        }
        onTick?(target)
    }

    /// Fires `onBoundary` once playback crosses `time` (e.g. the end of the current chapter).
    func setBoundary(_ time: Double?) {
        pendingBoundary = time
        armBoundary()
    }

    func setVolume(_ volume: Float) { player.volume = volume }
    var volume: Float { player.volume }

    // MARK: - Queue management

    private func rebuild(at time: Double) async {
        clearQueue()
        guard !sources.isEmpty else { return }
        let index = sourceIndex(for: time)
        enqueue(index)
        if index + 1 < sources.count { enqueue(index + 1) }
        let local = max(0, time - sources[index].startOffset)
        lastKnownTime = sources[index].startOffset + local
        observedTime = lastKnownTime
        if local > 0.5 {
            await player.seek(to: CMTime(seconds: local, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        armBoundary()
    }

    private func enqueue(_ index: Int) {
        let source = sources[index]
        // Precise timing makes seeks in VBR MP3s accurate; it's free for local files but would
        // require extra reads over the network, where the server's durations are used instead.
        let asset = AVURLAsset(url: source.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: source.isLocal])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        let id = ObjectIdentifier(item)
        itemIndex[id] = index
        itemObservers[id] = Self.observeFailure(of: item) { [weak self] error in
            Task { @MainActor in self?.onFailure?(error) }
        }
        player.insert(item, after: nil)
    }

    private func clearQueue() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        player.removeAllItems()
        itemObservers.values.forEach { $0.invalidate() }
        itemObservers = [:]
        itemIndex = [:]
    }

    private func sourceIndex(for time: Double) -> Int {
        sources.lastIndex { $0.startOffset <= time + 0.001 } ?? 0
    }

    private func currentItemChanged() {
        guard let item = player.currentItem, let index = itemIndex[ObjectIdentifier(item)] else { return }
        // Drop bookkeeping for items that have left the queue.
        let queued = Set(player.items().map(ObjectIdentifier.init))
        for id in itemIndex.keys where !queued.contains(id) {
            itemIndex[id] = nil
            itemObservers[id]?.invalidate()
            itemObservers[id] = nil
        }
        if index + 1 < sources.count, !itemIndex.values.contains(index + 1) {
            enqueue(index + 1)
        }
        armBoundary()
    }

    private func itemDidEnd(_ id: ObjectIdentifier?) {
        guard let id, let index = itemIndex[id] else { return }
        if index == sources.count - 1 {
            lastKnownTime = totalDuration
            onFinished?()
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        // With an empty queue (book ended) the player reports "waiting", which isn't playing.
        let playing = status != .paused && player.currentItem != nil
        isBuffering = status == .waitingToPlayAtSpecifiedRate && player.currentItem != nil
        if playing != isPlaying {
            isPlaying = playing
            onPlayingChanged?(playing)
        }
    }

    private func armBoundary() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        guard let boundary = pendingBoundary,
              let item = player.currentItem, let index = itemIndex[ObjectIdentifier(item)] else { return }
        let source = sources[index]
        // A boundary in a later file is armed when that file becomes current.
        guard boundary > source.startOffset, boundary <= source.startOffset + source.duration else { return }
        let local = CMTime(seconds: boundary - source.startOffset, preferredTimescale: 1000)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: local)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.onBoundary?() }
        }
    }

    // KVO can fire on any thread. Building the observers in nonisolated functions keeps the
    // closures non-isolated, and they hop to the main actor explicitly.
    nonisolated private static func observe(
        _ player: AVQueuePlayer,
        status: @escaping @Sendable (AVPlayer.TimeControlStatus) -> Void,
        item: @escaping @Sendable () -> Void
    ) -> [NSKeyValueObservation] {
        [
            player.observe(\.timeControlStatus, options: [.new]) { player, _ in status(player.timeControlStatus) },
            player.observe(\.currentItem, options: [.new]) { _, _ in item() },
        ]
    }

    nonisolated private static func observeFailure(of item: AVPlayerItem, handler: @escaping @Sendable (NSError?) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            handler(item.error as NSError?)
        }
    }

    private func updateTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        guard observesTime else { return }
        observedTime = currentTime
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let time = self.currentTime
                // Avoid invalidating views when nothing changed (e.g. while buffering).
                if abs(time - self.observedTime) >= 0.25 {
                    self.observedTime = time
                    self.onTick?(time)
                }
            }
        }
    }
}
