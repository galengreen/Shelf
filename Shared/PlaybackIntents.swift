#if os(iOS)
import AppIntents

// Transport intents for Siri, Shortcuts, widgets, the Live Activity and Control Centre.
//
// These files are compiled into the app and the widget extension (widgets need the types for their
// buttons), but every intent here is an `AudioPlaybackIntent`, so the system always performs it in
// the app's process, launching it in the background if needed. The extension never registers a
// handler, and never needs one.

/// What playback intents act on. `AppModel` registers itself at launch.
@MainActor protocol PlaybackIntentHandling: AnyObject {
    /// Plays what's loaded, or the last book you listened to. Returns once audio has started.
    func resumeListening() async throws
    func pausePlayback()
    func togglePlayback() async throws
    /// `seconds` nil uses the skip interval from Settings.
    func skip(forward: Bool, seconds: Double?)
    func setSleepTimer(minutes: Double)
    func setSleepTimerToEndOfChapter() throws
    func cancelSleepTimer()
}

@MainActor enum PlaybackIntentTarget {
    static weak var handler: (any PlaybackIntentHandling)?

    static func resolve() throws -> any PlaybackIntentHandling {
        guard let handler else { throw ShelfIntentError.unavailable }
        return handler
    }
}

nonisolated enum ShelfIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    case notSignedIn
    case nothingToPlay
    case noChapters
    case bookNotFound
    case noNextInSeries
    case playbackFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Shelf isn't ready yet. Open the app and try again."
        case .notSignedIn: "Sign in to your Audiobookshelf server in Shelf first."
        case .nothingToPlay: "There's nothing to resume yet. Choose a book in Shelf first."
        case .noChapters: "This book doesn't have chapters."
        case .bookNotFound: "Couldn't find that book in your library."
        case .noNextInSeries: "There's no next book in this series."
        case let .playbackFailed(message): "\(message)"
        }
    }
}

// MARK: - Transport

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Plays the book you're listening to from where you left off.")

    @MainActor func perform() async throws -> some IntentResult {
        try await PlaybackIntentTarget.resolve().resumeListening()
        return .result()
    }
}

struct PauseListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Listening"
    static let description = IntentDescription("Pauses the book that's playing.")

    @MainActor func perform() async throws -> some IntentResult {
        try PlaybackIntentTarget.resolve().pausePlayback()
        return .result()
    }
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Pauses if a book is playing, otherwise resumes it.")

    @MainActor func perform() async throws -> some IntentResult {
        try await PlaybackIntentTarget.resolve().togglePlayback()
        return .result()
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skips ahead in the book that's playing.")

    @Parameter(title: "Seconds", description: "Leave empty to use the interval from Shelf's settings.", inclusiveRange: (1, 3600))
    var seconds: Int?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Skip forward \(\.$seconds) seconds")
    }

    @MainActor func perform() async throws -> some IntentResult {
        try PlaybackIntentTarget.resolve().skip(forward: true, seconds: seconds.map(Double.init))
        return .result()
    }
}

struct SkipBackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Goes back a little in the book that's playing.")

    @Parameter(title: "Seconds", description: "Leave empty to use the interval from Shelf's settings.", inclusiveRange: (1, 3600))
    var seconds: Int?

    init() {}

    static var parameterSummary: some ParameterSummary {
        Summary("Skip back \(\.$seconds) seconds")
    }

    @MainActor func perform() async throws -> some IntentResult {
        try PlaybackIntentTarget.resolve().skip(forward: false, seconds: seconds.map(Double.init))
        return .result()
    }
}

// MARK: - Sleep timer

nonisolated enum SleepTimerDuration: String, AppEnum {
    case five, ten, fifteen, thirty, fortyFive, sixty, ninety, endOfChapter, custom

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Timer"
    static let caseDisplayRepresentations: [SleepTimerDuration: DisplayRepresentation] = [
        .five: "5 minutes",
        .ten: "10 minutes",
        .fifteen: "15 minutes",
        .thirty: "30 minutes",
        .fortyFive: "45 minutes",
        .sixty: "1 hour",
        .ninety: "90 minutes",
        .endOfChapter: "End of chapter",
        .custom: "Custom",
    ]

    var minutes: Double? {
        switch self {
        case .five: 5
        case .ten: 10
        case .fifteen: 15
        case .thirty: 30
        case .fortyFive: 45
        case .sixty: 60
        case .ninety: 90
        case .endOfChapter, .custom: nil
        }
    }
}

struct SetSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Pauses Shelf after a while, or at the end of the chapter.")

    @Parameter(title: "Duration", requestValueDialog: "How long should the sleep timer be?")
    var duration: SleepTimerDuration

    @Parameter(title: "Minutes", default: 20, inclusiveRange: (1, 600))
    var minutes: Int

    init() {}

    init(duration: SleepTimerDuration) {
        self.duration = duration
    }

    static var parameterSummary: some ParameterSummary {
        When(\.$duration, .equalTo, .custom) {
            Summary("Set a sleep timer for \(\.$minutes) minutes")
        } otherwise: {
            Summary("Set a sleep timer for \(\.$duration)")
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let handler = try PlaybackIntentTarget.resolve()
        if duration == .endOfChapter {
            try handler.setSleepTimerToEndOfChapter()
            return .result(dialog: "Shelf will pause at the end of the chapter.")
        }
        let length = duration.minutes ?? Double(minutes)
        handler.setSleepTimer(minutes: length)
        return .result(dialog: "Shelf will pause in \(Int(length)) minutes.")
    }
}

struct CancelSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Turn Off Sleep Timer"
    static let description = IntentDescription("Cancels the sleep timer so the book keeps playing.")

    @MainActor func perform() async throws -> some IntentResult {
        try PlaybackIntentTarget.resolve().cancelSleepTimer()
        return .result()
    }
}

/// Backs the Control Centre sleep timer toggle.
struct SetSleepTimerOnIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Turn Sleep Timer On or Off"
    static let isDiscoverable = false

    @Parameter(title: "On")
    var value: Bool

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (1, 600))
    var minutes: Int

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    @MainActor func perform() async throws -> some IntentResult {
        let handler = try PlaybackIntentTarget.resolve()
        if value {
            handler.setSleepTimer(minutes: Double(minutes))
        } else {
            handler.cancelSleepTimer()
        }
        return .result()
    }
}

/// Backs the Control Centre play/pause toggle, which needs a settable value.
struct SetPlayingIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause Shelf"
    static let isDiscoverable = false

    @Parameter(title: "Playing")
    var value: Bool

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        let handler = try PlaybackIntentTarget.resolve()
        if value {
            try await handler.resumeListening()
        } else {
            handler.pausePlayback()
        }
        return .result()
    }
}
#endif
