import Foundation

extension AppModel {
    /// Commands from the watch remote, handled exactly as the same buttons in the app.
    func handle(_ command: WatchCommand) {
        switch command {
        case .togglePlayback: player.togglePlayPause()
        case .skipBack: player.skip(by: -settings.skipBackward)
        case .skipForward: player.skip(by: settings.skipForward)
        case .previousChapter: player.previousChapter()
        case .nextChapter: player.nextChapter()
        case .sleepEndOfChapter: if !player.chapters.isEmpty { player.setSleepAtEndOfChapter() }
        case .sleepOff: player.cancelSleepTimer()
        case .sleep15, .sleep30, .sleep45, .sleep60: player.setSleepTimer(minutes: command.sleepMinutes ?? 30)
        }
    }
}
