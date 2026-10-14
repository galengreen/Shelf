import Foundation

/// The watch remote's protocol. The phone sends the latest `NowPlayingSnapshot` (and a small cover)
/// as application context; the watch sends commands back as messages.
nonisolated enum WatchMessage {
    static let snapshotKey = "snapshot"
    static let coverKey = "cover"
    static let commandKey = "command"
}

nonisolated enum WatchCommand: String, Sendable, CaseIterable {
    case togglePlayback, skipBack, skipForward, previousChapter, nextChapter
    case sleep15, sleep30, sleep45, sleep60, sleepEndOfChapter, sleepOff

    var sleepMinutes: Double? {
        switch self {
        case .sleep15: 15
        case .sleep30: 30
        case .sleep45: 45
        case .sleep60: 60
        default: nil
        }
    }
}
