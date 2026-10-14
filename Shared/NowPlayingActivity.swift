#if os(iOS)
import ActivityKit

/// The Live Activity shown while a book plays. Everything lives in the content state (the
/// snapshot), so one activity can carry on into the next book in a queue or series.
nonisolated struct NowPlayingAttributes: ActivityAttributes {
    typealias ContentState = NowPlayingSnapshot
}
#endif
