import Foundation

// Wire models for the Audiobookshelf API (verified against server v2.37).
// Every field the server may omit is optional so a schema change on the server
// degrades a field rather than failing the whole decode.

nonisolated struct ServerStatus: Decodable, Sendable {
    let app: String?
    let serverVersion: String?
    let isInit: Bool?
    let authMethods: [String]?
    let authFormData: AuthFormData?

    nonisolated struct AuthFormData: Decodable, Sendable {
        let authOpenIDButtonText: String?
        let authOpenIDAutoLaunch: Bool?
        let authLoginCustomMessage: String?
    }

    var offersOpenID: Bool { authMethods?.contains("openid") == true }
    var offersPassword: Bool { authMethods.map { $0.contains("local") } ?? true }
}

nonisolated struct LoginResponse: Decodable, Sendable {
    let user: User
    let userDefaultLibraryId: String?
}

nonisolated struct User: Decodable, Sendable {
    let id: String
    let username: String
    let type: String?
    /// Legacy non-expiring token (pre-2.26 servers).
    let token: String?
    /// Short-lived JWT (2.26+).
    let accessToken: String?
    /// Rotating refresh token; only returned when `x-return-tokens: true` is sent.
    let refreshToken: String?
    let mediaProgress: [MediaProgress]?
    let librariesAccessible: [String]?
    let bookmarks: [Bookmark]?
    let permissions: Permissions?
}

nonisolated struct Permissions: Codable, Hashable, Sendable {
    let download: Bool?
    let update: Bool?
    let delete: Bool?
}

nonisolated struct Bookmark: Codable, Hashable, Identifiable, Sendable {
    let libraryItemId: String
    var time: Double
    var title: String
    var createdAt: Double?

    /// The server identifies a bookmark by item and time.
    var id: String { "\(libraryItemId)@\(time)" }
}

nonisolated struct Library: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mediaType: String?
    let displayOrder: Int?
    let icon: String?

    var isBookLibrary: Bool { (mediaType ?? "book") == "book" }
    var isPodcastLibrary: Bool { mediaType == "podcast" }
}

nonisolated struct LibrariesResponse: Decodable, Sendable {
    let libraries: [Library]
}

nonisolated struct ItemsPage: Decodable, Sendable {
    let results: [LibraryItem]
    let total: Int?

    enum CodingKeys: String, CodingKey { case results, total }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decode([Lossy<LibraryItem>].self, forKey: .results).compactMap(\.value)
        total = try? c.decodeIfPresent(Int.self, forKey: .total)
    }
}

nonisolated struct LibraryItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let libraryId: String?
    let mediaType: String?
    let addedAt: Double?
    let updatedAt: Double?
    let isMissing: Bool?
    var media: BookMedia
    var userMediaProgress: MediaProgress?
    /// Set on items in the "newest episodes" home shelf.
    var recentEpisode: PodcastEpisode?

    var isPodcast: Bool { mediaType == "podcast" }
    var title: String { media.metadata.title ?? "Untitled" }
    var authorName: String? {
        media.metadata.authorName.nonEmpty
            ?? media.metadata.authors?.map(\.name).joined(separator: ", ").nonEmpty
            ?? media.metadata.author.nonEmpty
    }
    var narratorName: String? { media.metadata.narratorName.nonEmpty ?? media.metadata.narrators?.joined(separator: ", ").nonEmpty }
    var duration: Double { media.duration ?? 0 }
    /// Used to bust the cover cache only when the item actually changes.
    var coverVersion: Int { Int((updatedAt ?? 0) / 1000) }
    var hasAudio: Bool { (media.numTracks ?? media.tracks?.count ?? 1) > 0 }
    /// Individual narrators, split from the minified "A, B" form when needed.
    var narratorList: [String] {
        if let narrators = media.metadata.narrators, !narrators.isEmpty { return narrators }
        return (media.metadata.narratorName ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

nonisolated struct BookMedia: Codable, Hashable, Sendable {
    var metadata: BookMetadata
    let coverPath: String?
    let duration: Double?
    let numTracks: Int?
    let numChapters: Int?
    let size: Int64?
    let chapters: [Chapter]?
    let tracks: [AudioTrack]?
    let tags: [String]?
    /// Podcasts only.
    let numEpisodes: Int?
    let episodes: [PodcastEpisode]?
}

nonisolated struct BookMetadata: Codable, Hashable, Sendable {
    let title: String?
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let authors: [AuthorRef]?
    let narrators: [String]?
    let series: [SeriesRef]?
    let genres: [String]?
    let publishedYear: String?
    let publisher: String?
    let description: String?
    let descriptionPlain: String?
    let language: String?
    let explicit: Bool?
    /// Podcasts use a plain `author` string instead of `authors`.
    let author: String?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, authorName, narratorName, seriesName, authors, narrators, series
        case genres, publishedYear, publisher, description, descriptionPlain, language, explicit, author
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
        narratorName = try? c.decodeIfPresent(String.self, forKey: .narratorName)
        seriesName = try? c.decodeIfPresent(String.self, forKey: .seriesName)
        authors = try? c.decodeIfPresent([AuthorRef].self, forKey: .authors)
        narrators = try? c.decodeIfPresent([String].self, forKey: .narrators)
        // `series` is an array on expanded items but a single object on author pages.
        if let many = try? c.decodeIfPresent([SeriesRef].self, forKey: .series) {
            series = many
        } else if let one = try? c.decodeIfPresent(SeriesRef.self, forKey: .series) {
            series = [one]
        } else {
            series = nil
        }
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        publishedYear = (try? c.decodeIfPresent(FlexibleString.self, forKey: .publishedYear))?.value
        publisher = try? c.decodeIfPresent(String.self, forKey: .publisher)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        descriptionPlain = try? c.decodeIfPresent(String.self, forKey: .descriptionPlain)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        explicit = try? c.decodeIfPresent(Bool.self, forKey: .explicit)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
    }
}

nonisolated struct AuthorRef: Codable, Hashable, Sendable {
    let id: String
    let name: String
}

nonisolated struct SeriesRef: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sequence: String?

    enum CodingKeys: String, CodingKey { case id, name, sequence }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sequence = (try? c.decodeIfPresent(FlexibleString.self, forKey: .sequence))?.value
    }

    var displayName: String {
        if let sequence, !sequence.isEmpty { return "\(name) #\(sequence)" }
        return name
    }
}

nonisolated struct Chapter: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let title: String

    var duration: Double { max(0, end - start) }
}

nonisolated struct AudioTrack: Codable, Hashable, Sendable {
    let index: Int?
    let startOffset: Double
    let duration: Double
    let title: String?
    let contentUrl: String
    let mimeType: String?
    let metadata: FileMetadata?

    nonisolated struct FileMetadata: Codable, Hashable, Sendable {
        let filename: String?
        let ext: String?
        let size: Int64?
    }

    var fileExtension: String {
        if let ext = metadata?.ext?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), !ext.isEmpty { return ext }
        return "m4b"
    }
}

nonisolated struct MediaProgress: Codable, Hashable, Sendable {
    let id: String?
    let libraryItemId: String?
    let episodeId: String?
    var duration: Double?
    var progress: Double?
    var currentTime: Double?
    var isFinished: Bool?
    var hideFromContinueListening: Bool?
    /// Milliseconds since 1970.
    var lastUpdate: Double?
    let startedAt: Double?
    let finishedAt: Double?
}

nonisolated struct PlaybackSession: Decodable, Sendable {
    let id: String
    let libraryItemId: String
    let displayTitle: String?
    let displayAuthor: String?
    let duration: Double?
    let currentTime: Double?
    let playMethod: Int?
    let chapters: [Chapter]?
    let audioTracks: [AudioTrack]
    let libraryItem: LibraryItem?
    let episodeId: String?
}

nonisolated struct Author: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let imagePath: String?
    let numBooks: Int?
    let updatedAt: Double?
    let libraryItems: [LibraryItem]?
    let series: [AuthorSeries]?

    var imageVersion: Int { Int((updatedAt ?? 0) / 1000) }
}

nonisolated struct AuthorSeries: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let items: [LibraryItem]
}

nonisolated struct AuthorsPage: Decodable, Sendable {
    let results: [Author]?
    let authors: [Author]?
    let total: Int?

    var all: [Author] { results ?? authors ?? [] }
}

/// One row on the server's personalised home page.
nonisolated struct HomeShelf: Decodable, Identifiable, Sendable {
    let id: String
    let label: String
    let type: String
    /// Book, podcast and episode shelves.
    var items: [LibraryItem] = []
    var series: [Series] = []
    var authors: [Author] = []

    enum CodingKeys: String, CodingKey { case id, label, type, entities }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        type = try c.decode(String.self, forKey: .type)
        switch type {
        case "book", "podcast", "episode":
            items = (try? c.decode([Lossy<LibraryItem>].self, forKey: .entities))?.compactMap(\.value) ?? []
        case "series":
            series = (try? c.decode([Lossy<Series>].self, forKey: .entities))?.compactMap(\.value) ?? []
        case "authors":
            authors = (try? c.decode([Lossy<Author>].self, forKey: .entities))?.compactMap(\.value) ?? []
        default:
            break
        }
    }

    var isEmpty: Bool { items.isEmpty && series.isEmpty && authors.isEmpty }
}

nonisolated struct ProgressUpdate: Codable, Sendable {
    let libraryItemId: String
    var episodeId: String?
    var duration: Double
    var currentTime: Double
    var progress: Double
    /// Only ever sent as true. The server treats an explicit false on a finished book as
    /// "mark unfinished" and resets it to the start; a plain position change unfinishes it anyway.
    var isFinished: Bool?
}

nonisolated struct SyncPayload: Encodable, Sendable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

// MARK: - Decoding helpers

/// Decodes a value that the server sometimes sends as a number and sometimes as a string.
nonisolated struct FlexibleString: Decodable, Sendable {
    let value: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(d) }
        else { value = nil }
    }
}

/// Skips individual malformed elements in an array instead of failing the whole response.
nonisolated struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension Optional where Wrapped == String {
    nonisolated var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return self
    }
}

extension String {
    nonisolated var nonEmpty: String? {
        trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
    }
}
