import Foundation

// Wire models for browsing, podcasts and stats (verified against server v2.37).

nonisolated struct PodcastEpisode: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let libraryItemId: String?
    let title: String?
    let subtitle: String?
    let description: String?
    let pubDate: String?
    /// Milliseconds since 1970.
    let publishedAt: Double?
    let duration: Double?
    let size: Int64?
    let season: String?
    let episode: String?
    let chapters: [Chapter]?
    let audioTrack: AudioTrack?
    let audioFile: AudioFile?

    nonisolated struct AudioFile: Codable, Hashable, Sendable {
        let duration: Double?
        let mimeType: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, libraryItemId, title, subtitle, description, pubDate, publishedAt, duration, size
        case season, episode, chapters, audioTrack, audioFile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        libraryItemId = try? c.decodeIfPresent(String.self, forKey: .libraryItemId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        pubDate = try? c.decodeIfPresent(String.self, forKey: .pubDate)
        publishedAt = try? c.decodeIfPresent(Double.self, forKey: .publishedAt)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        size = try? c.decodeIfPresent(Int64.self, forKey: .size)
        season = (try? c.decodeIfPresent(FlexibleString.self, forKey: .season))?.value
        episode = (try? c.decodeIfPresent(FlexibleString.self, forKey: .episode))?.value
        chapters = try? c.decodeIfPresent([Chapter].self, forKey: .chapters)
        audioTrack = try? c.decodeIfPresent(AudioTrack.self, forKey: .audioTrack)
        audioFile = try? c.decodeIfPresent(AudioFile.self, forKey: .audioFile)
    }

    var displayTitle: String { title.nonEmpty ?? "Untitled Episode" }
    var playDuration: Double { duration ?? audioTrack?.duration ?? audioFile?.duration ?? 0 }
    var publishedDate: Date? { publishedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

nonisolated struct Series: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let addedAt: Double?
    let totalDuration: Double?
    var books: [LibraryItem]?
}

nonisolated struct BookCollection: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let libraryId: String?
    let name: String
    let description: String?
    let books: [LibraryItem]
    let lastUpdate: Double?
}

nonisolated struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let libraryId: String?
    let name: String
    let description: String?
    let items: [Entry]
    let lastUpdate: Double?

    nonisolated struct Entry: Codable, Hashable, Sendable {
        let libraryItemId: String
        let episodeId: String?
        let libraryItem: LibraryItem?
        let episode: PodcastEpisode?
    }
}

/// `{ results, total }` list responses, skipping malformed entries.
nonisolated struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    let results: [T]
    let total: Int?

    enum CodingKeys: String, CodingKey { case results, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = (try? c.decode([Lossy<T>].self, forKey: .results))?.compactMap(\.value) ?? []
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }
}

nonisolated struct SearchResults: Decodable, Sendable {
    nonisolated struct ItemMatch: Decodable, Sendable { let libraryItem: LibraryItem }
    nonisolated struct SeriesMatch: Decodable, Sendable {
        let series: Series
        let books: [LibraryItem]?
    }
    nonisolated struct NameCount: Decodable, Hashable, Sendable {
        let name: String
        let numBooks: Int?
        let numItems: Int?
        var count: Int { numBooks ?? numItems ?? 0 }
    }

    var books: [LibraryItem] = []
    var podcasts: [LibraryItem] = []
    /// Podcast items with the matching episode in `recentEpisode`.
    var episodes: [LibraryItem] = []
    var series: [SeriesMatch] = []
    var authors: [Author] = []
    var narrators: [NameCount] = []
    var genres: [NameCount] = []
    var tags: [NameCount] = []

    enum CodingKeys: String, CodingKey { case book, podcast, episodes, series, authors, narrators, genres, tags }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable & Sendable>(_ key: CodingKeys, _ type: T.Type) -> [T] {
            (try? c.decodeIfPresent([Lossy<T>].self, forKey: key))?.compactMap(\.value) ?? []
        }
        books = list(.book, ItemMatch.self).map(\.libraryItem)
        podcasts = list(.podcast, ItemMatch.self).map(\.libraryItem)
        episodes = list(.episodes, ItemMatch.self).map(\.libraryItem).filter { $0.recentEpisode != nil }
        series = list(.series, SeriesMatch.self)
        authors = list(.authors, Author.self)
        narrators = list(.narrators, NameCount.self)
        genres = list(.genres, NameCount.self)
        tags = list(.tags, NameCount.self)
    }

    var isEmpty: Bool {
        books.isEmpty && podcasts.isEmpty && episodes.isEmpty && series.isEmpty && authors.isEmpty && narrators.isEmpty && genres.isEmpty && tags.isEmpty
    }
}

// MARK: - Stats

nonisolated struct ListeningStats: Decodable, Sendable {
    let totalTime: Double
    let today: Double?
    /// "YYYY-MM-DD" → seconds.
    let days: [String: Double]
    let dayOfWeek: [String: Double]?
    let items: [String: Item]?
    let recentSessions: [ListeningSession]?

    nonisolated struct Item: Decodable, Sendable {
        let id: String
        let timeListening: Double
        let mediaMetadata: SessionMetadata?
    }
}

nonisolated struct SessionMetadata: Decodable, Sendable {
    let title: String?
    let author: String?
    let authors: [AuthorRef]?

    var authorName: String? { authors?.map(\.name).joined(separator: ", ").nonEmpty ?? author.nonEmpty }
}

nonisolated struct ListeningSession: Decodable, Identifiable, Sendable {
    let id: String
    let libraryItemId: String?
    let episodeId: String?
    let displayTitle: String?
    let displayAuthor: String?
    let duration: Double?
    let timeListening: Double?
    let startTime: Double?
    let currentTime: Double?
    /// Milliseconds since 1970.
    let startedAt: Double?
    let updatedAt: Double?
    let deviceInfo: Device?

    nonisolated struct Device: Decodable, Sendable {
        let clientName: String?
        let deviceName: String?
        let model: String?
        let osName: String?
    }

    var updatedDate: Date? { (updatedAt ?? startedAt).map { Date(timeIntervalSince1970: $0 / 1000) } }
}

nonisolated struct YearStats: Decodable, Sendable {
    let totalListeningSessions: Int?
    let totalListeningTime: Double?
    let numBooksFinished: Int?
    let numBooksListened: Int?
    let topAuthors: [NamedTime]?
    let topGenres: [GenreTime]?
    let mostListenedNarrator: NamedTime?
    let mostListenedMonth: MonthTime?
    let finishedBooksWithCovers: [String]?

    nonisolated struct NamedTime: Decodable, Sendable { let name: String?; let time: Double? }
    nonisolated struct GenreTime: Decodable, Sendable { let genre: String?; let time: Double? }
    nonisolated struct MonthTime: Decodable, Sendable { let month: Int?; let time: Double? }
}

/// Listening that happened without a server session (offline), uploaded later through
/// `/api/session/local-all` so it counts towards the server's stats. Uploading the same id
/// again updates the session rather than duplicating it.
nonisolated struct LocalSession: Codable, Sendable {
    let id: String
    let libraryItemId: String
    let episodeId: String?
    let mediaType: String
    let displayTitle: String
    let displayAuthor: String?
    let duration: Double
    var playMethod = 3
    var mediaPlayer = "AVPlayer"
    let startTime: Double
    var currentTime: Double
    var timeListening: Double
    /// Milliseconds since 1970.
    let startedAt: Double
    var updatedAt: Double
    let date: String
    let dayOfWeek: String
}
