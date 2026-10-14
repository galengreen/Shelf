import Foundation

/// Intents reuse the same `PlaybackController` as the UI. Anything that starts audio waits until
/// it's really playing, because an intent can launch the app in the background, and the app may be
/// suspended again as soon as `perform()` returns.
extension AppModel: PlaybackIntentHandling {
    func resumeListening() async throws {
        try await prepareForIntent()
        guard player.item != nil else { throw ShelfIntentError.nothingToPlay }
        player.play()
        try await confirmPlaying()
    }

    func pausePlayback() {
        player.pause()
    }

    func togglePlayback() async throws {
        if player.isPlaying {
            player.pause()
        } else {
            try await resumeListening()
        }
    }

    func skip(forward: Bool, seconds: Double?) {
        let interval = seconds ?? (forward ? settings.skipForward : settings.skipBackward)
        player.skip(by: forward ? interval : -interval)
    }

    func setSleepTimer(minutes: Double) {
        player.setSleepTimer(minutes: minutes)
    }

    func setSleepTimerToEndOfChapter() throws {
        guard !player.chapters.isEmpty else { throw ShelfIntentError.noChapters }
        player.setSleepAtEndOfChapter()
    }

    func cancelSleepTimer() {
        player.cancelSleepTimer()
    }

    // MARK: - Library intents (app only)

    func playFromIntent(itemId: String) async throws {
        try await prepareForIntent()
        guard let item = library.item(itemId) ?? downloads.manifests[itemId]?.item else { throw ShelfIntentError.bookNotFound }
        player.open(item)
        try await confirmPlaying()
    }

    /// The next unfinished book in the series of the one you're listening to.
    func playNextInSeries() async throws {
        try await prepareForIntent()
        let isFinished: (String) -> Bool = { [progress] in progress.snapshot(for: $0)?.isFinished == true }
        guard let next = player.suggestedNext
                ?? player.item.flatMap({ library.nextInSeries(after: $0.id, isFinished: isFinished) })
        else { throw ShelfIntentError.noNextInSeries }
        player.open(next)
        try await confirmPlaying()
    }

    func prepareForIntent() async throws {
        await waitUntilRestored()
        guard phase == .signedIn else { throw ShelfIntentError.notSignedIn }
    }

    private func confirmPlaying() async throws {
        if await player.waitUntilPlaying() { return }
        if let message = player.errorMessage { throw ShelfIntentError.playbackFailed(message) }
        // Otherwise it's still buffering on a slow connection; it starts on its own when ready.
    }
}
