import Foundation

/// What's loaded in the player, as seen from outside the app: widgets, the Live Activity, Control
/// Centre and the watch. Positions are captured at `capturedAt`; while playing, everything else is
/// extrapolated from the rate, so the snapshot only needs rewriting when something really changes.
nonisolated struct NowPlayingSnapshot: Codable, Hashable, Sendable {
    var itemId: String
    /// Progress key ("itemId", or "itemId/episodeId").
    var key: String
    /// Book or episode title.
    var title: String
    /// Author, or the podcast's name for an episode.
    var subtitle: String?
    var chapterTitle: String?
    var chapterNumber: Int?
    var chapterCount: Int?
    var isPlaying: Bool
    /// The book was played to the end and nothing has been loaded since.
    var isFinished: Bool
    var rate: Double
    /// Position in the whole book, in seconds, at `capturedAt`.
    var position: Double
    var duration: Double
    /// Bounds of the current chapter in book time (the whole book when there are no chapters).
    var chapterStart: Double
    var chapterEnd: Double
    var capturedAt: Date
    var sleep: SleepSnapshot
    /// File name of the cover in the App Group container, once it's been written.
    var coverFile: String?
    /// Skip intervals from Settings, so skip buttons outside the app show the right symbol.
    var skipBackward: Double = 15
    var skipForward: Double = 30

    var chapterLength: Double { max(chapterEnd - chapterStart, 0.001) }

    /// Book position now (extrapolated while playing).
    func position(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(capturedAt) * rate)
    }

    func chapterElapsed(at date: Date) -> Double {
        (position(at: date) - chapterStart).clamped(to: 0...chapterLength)
    }

    func chapterFraction(at date: Date) -> Double { chapterElapsed(at: date) / chapterLength }

    func bookFraction(at date: Date) -> Double {
        isFinished ? 1 : duration > 0 ? (position(at: date) / duration).clamped(to: 0...1) : 0
    }

    /// Wall-clock span of the current chapter at the current speed, for views the system animates
    /// itself (`ProgressView(timerInterval:)`, `Text(timerInterval:)`). Only meaningful while playing.
    var chapterDates: ClosedRange<Date> {
        let rate = max(self.rate, 0.1)
        let start = capturedAt.addingTimeInterval(-(position - chapterStart) / rate)
        let end = capturedAt.addingTimeInterval((chapterEnd - position) / rate)
        return start...max(start, end)
    }

    /// Wall-clock time left in the chapter at the current speed.
    func chapterRemaining(at date: Date) -> Double {
        (chapterLength - chapterElapsed(at: date)) / max(rate, 0.1)
    }

    /// True when `other` differs in a way someone would see: anything but the playhead, or a
    /// playhead that has moved away from where this snapshot predicts it (a seek or skip).
    func differsVisibly(from other: NowPlayingSnapshot, tolerance: Double = 5) -> Bool {
        var a = self, b = other
        a.position = 0; b.position = 0
        a.capturedAt = .distantPast; b.capturedAt = .distantPast
        if a != b { return true }
        return abs(position(at: other.capturedAt) - other.position) > tolerance
    }
}

nonisolated enum SleepSnapshot: Codable, Hashable, Sendable {
    case off
    case endOfChapter
    /// Counting down during playback.
    case running(endsAt: Date)
    /// Set, but playback is paused so the countdown is too.
    case paused(remaining: Double)
}
