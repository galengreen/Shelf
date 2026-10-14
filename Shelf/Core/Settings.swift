import Foundation
import Observation

@Observable
final class Settings {
    private let defaults = UserDefaults.standard

    var skipBackward: Double { didSet { defaults.set(skipBackward, forKey: "skipBackward") } }
    var skipForward: Double { didSet { defaults.set(skipForward, forKey: "skipForward") } }
    /// Rewinds a little after a long pause so you don't lose your place mid-sentence.
    var smartRewind: Bool { didSet { defaults.set(smartRewind, forKey: "smartRewind") } }
    /// Lock screen / Control Centre scrubber shows the current chapter instead of the whole book.
    var lockScreenUsesChapter: Bool { didSet { defaults.set(lockScreenUsesChapter, forKey: "lockScreenUsesChapter") } }
    var defaultSpeed: Double { didSet { defaults.set(defaultSpeed, forKey: "defaultSpeed") } }
    var downloadOverCellular: Bool { didSet { defaults.set(downloadOverCellular, forKey: "downloadOverCellular") } }
    /// Downloads a book in the background when you start it, so the rest plays from disk.
    var autoDownload: Bool { didSet { defaults.set(autoDownload, forKey: "autoDownload") } }
    var deleteFinishedDownloads: Bool { didSet { defaults.set(deleteFinishedDownloads, forKey: "deleteFinishedDownloads") } }
    /// Starts the next book in a series when one finishes (otherwise it's offered on screen).
    var autoplayNextInSeries: Bool { didSet { defaults.set(autoplayNextInSeries, forKey: "autoplayNextInSeries") } }
    /// Shows the book on the Lock Screen and in the Dynamic Island while it plays.
    var liveActivities: Bool { didSet { defaults.set(liveActivities, forKey: "liveActivities") } }
    var selectedLibraryId: String? { didSet { defaults.set(selectedLibraryId, forKey: "selectedLibraryId") } }
    var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: "librarySort") } }
    var librarySortAscending: Bool { didSet { defaults.set(librarySortAscending, forKey: "librarySortAscending") } }

    private var speeds: [String: Double] { didSet { defaults.set(speeds, forKey: "bookSpeeds") } }

    init() {
        defaults.register(defaults: [
            "skipBackward": 15.0,
            "skipForward": 30.0,
            "smartRewind": true,
            "lockScreenUsesChapter": true,
            "defaultSpeed": 1.0,
            "downloadOverCellular": false,
            "autoDownload": false,
            "deleteFinishedDownloads": false,
            "autoplayNextInSeries": false,
            "liveActivities": true,
            "librarySortAscending": true,
        ])
        skipBackward = defaults.double(forKey: "skipBackward")
        skipForward = defaults.double(forKey: "skipForward")
        smartRewind = defaults.bool(forKey: "smartRewind")
        lockScreenUsesChapter = defaults.bool(forKey: "lockScreenUsesChapter")
        defaultSpeed = defaults.double(forKey: "defaultSpeed")
        downloadOverCellular = defaults.bool(forKey: "downloadOverCellular")
        autoDownload = defaults.bool(forKey: "autoDownload")
        deleteFinishedDownloads = defaults.bool(forKey: "deleteFinishedDownloads")
        autoplayNextInSeries = defaults.bool(forKey: "autoplayNextInSeries")
        liveActivities = defaults.bool(forKey: "liveActivities")
        selectedLibraryId = defaults.string(forKey: "selectedLibraryId")
        librarySort = LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "") ?? .title
        librarySortAscending = defaults.bool(forKey: "librarySortAscending")
        speeds = defaults.dictionary(forKey: "bookSpeeds") as? [String: Double] ?? [:]
    }

    func speed(for itemId: String) -> Double { speeds[itemId] ?? defaultSpeed }

    func setSpeed(_ speed: Double, for itemId: String) {
        speeds[itemId] = speed == defaultSpeed ? nil : speed
    }

    static let skipIntervals: [Double] = [5, 10, 15, 30, 45, 60, 90]
    static let speedPresets: [Double] = [0.75, 0.9, 1.0, 1.1, 1.2, 1.25, 1.3, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0]
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case title, author, recentlyAdded, publishedYear, duration, recentlyPlayed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .recentlyAdded: "Recently Added"
        case .publishedYear: "Published"
        case .duration: "Length"
        case .recentlyPlayed: "Recently Played"
        }
    }
}
