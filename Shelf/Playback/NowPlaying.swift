import MediaPlayer
import UIKit

/// Lock screen, Control Centre, CarPlay "Now Playing", AirPods and car controls.
///
/// The system extrapolates elapsed time from (elapsed, rate), so info is only pushed on real
/// changes — play/pause, seek, rate, chapter — never on a timer.
final class NowPlaying {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skipForward: () -> Void
        var skipBackward: () -> Void
        var nextChapter: () -> Void
        var previousChapter: () -> Void
        var seek: (Double) -> Void
        var rate: (Float) -> Void
    }

    struct Info: Equatable {
        var title: String
        var album: String
        var artist: String?
        var elapsed: Double
        var duration: Double
        var rate: Float
        var isPlaying: Bool
        var chapterNumber: Int?
        var chapterCount: Int?
    }

    private var artwork: MPMediaItemArtwork?
    private var artworkKey: String?
    private var lastInfo: Info?

    func register(_ handlers: Handlers, skipBackward: Double, skipForward: Double) {
        let center = MPRemoteCommandCenter.shared()
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
         center.skipBackwardCommand, center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
         center.nextTrackCommand, center.previousTrackCommand].forEach { $0.removeTarget(nil) }

        center.playCommand.addTarget { _ in handlers.play(); return .success }
        center.pauseCommand.addTarget { _ in handlers.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in handlers.toggle(); return .success }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForward)]
        center.skipForwardCommand.addTarget { _ in handlers.skipForward(); return .success }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackward)]
        center.skipBackwardCommand.addTarget { _ in handlers.skipBackward(); return .success }

        // Headphone double/triple-press arrive as next/previous track.
        center.nextTrackCommand.addTarget { _ in handlers.skipForward(); return .success }
        center.previousTrackCommand.addTarget { _ in handlers.skipBackward(); return .success }

        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            handlers.seek(event.positionTime)
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Settings.speedPresets.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            handlers.rate(event.playbackRate)
            return .success
        }
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
         center.skipBackwardCommand, center.changePlaybackPositionCommand, center.changePlaybackRateCommand,
         center.nextTrackCommand, center.previousTrackCommand].forEach { $0.isEnabled = true }
    }

    func update(_ info: Info) {
        guard info != lastInfo else { return }
        lastInfo = info
        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyAlbumTitle: info.album,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? Double(info.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(info.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artist = info.artist { dict[MPMediaItemPropertyArtist] = artist }
        if let number = info.chapterNumber { dict[MPNowPlayingInfoPropertyChapterNumber] = number }
        if let count = info.chapterCount { dict[MPNowPlayingInfoPropertyChapterCount] = count }
        if let artwork { dict[MPMediaItemPropertyArtwork] = artwork }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = dict
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    func setArtwork(_ image: UIImage?, key: String) {
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = image.map(Self.makeArtwork)
        if let info = lastInfo {
            lastInfo = nil
            update(info)
        }
    }

    func clear() {
        lastInfo = nil
        artwork = nil
        artworkKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// The artwork handler is called on a background thread, so it must not be main-actor isolated.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
