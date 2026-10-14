import Foundation

/// Files the app shares with its widgets, Live Activity and Control Centre controls through the
/// App Group container. The app is the only writer; the extension only reads.
nonisolated enum AppGroup {
    static let identifier = "group.nz.galengreen.shelf"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var nowPlayingFile: URL? { container?.appending(path: "now-playing.json") }
    static var listeningFile: URL? { container?.appending(path: "listening.json") }

    /// Covers are named after the cover's cache key, so a snapshot never points at another book's art.
    static func coverFile(named name: String) -> URL? { container?.appending(path: name) }

    static func read<T: Decodable>(_ type: T.Type, from file: URL?) -> T? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(value)
    }
}

/// Widget and control kinds, shared so the app can reload exactly the ones that changed.
nonisolated enum WidgetKinds {
    static let nowPlaying = "nz.galengreen.shelf.now-playing"
    static let streak = "nz.galengreen.shelf.streak"
    static let activity = "nz.galengreen.shelf.activity"
    static let playbackControl = "nz.galengreen.shelf.control.playback"
    static let skipBackControl = "nz.galengreen.shelf.control.skip-back"
    static let sleepControl = "nz.galengreen.shelf.control.sleep"
}
