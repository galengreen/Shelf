import AppIntents

// Intents that need the library, so they're only built into the app (not the widget extension).

struct PlayBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Book"
    static let description = IntentDescription("Plays a book from your library, from where you left off.")

    @Parameter(title: "Book", requestValueDialog: "Which book?")
    var book: BookEntity

    init() {}

    init(book: BookEntity) {
        self.book = book
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$book)")
    }

    @MainActor func perform() async throws -> some IntentResult {
        guard let model = AppDelegate.model else { throw ShelfIntentError.unavailable }
        try await model.playFromIntent(itemId: book.id)
        return .result()
    }
}

struct PlayNextInSeriesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Next in Series"
    static let description = IntentDescription("Starts the next unfinished book in the series you're listening to.")

    @MainActor func perform() async throws -> some IntentResult {
        guard let model = AppDelegate.model else { throw ShelfIntentError.unavailable }
        try await model.playNextInSeries()
        return .result()
    }
}

/// Siri phrases that work without any setup. Every phrase has to include the app's name.
nonisolated struct ShelfShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeListeningIntent(),
            phrases: [
                "Resume my audiobook in \(.applicationName)",
                "Resume listening in \(.applicationName)",
                "Continue my book in \(.applicationName)",
                "Play my audiobook in \(.applicationName)",
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
                "Play a book in \(.applicationName)",
            ],
            shortTitle: "Play Book",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Sleep timer in \(.applicationName)",
                "Set a sleep timer in \(.applicationName)",
                "Set a sleep timer for \(\.$duration) in \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: PlayNextInSeriesIntent(),
            phrases: [
                "Play the next book in \(.applicationName)",
                "Start the next book in the series in \(.applicationName)",
            ],
            shortTitle: "Next in Series",
            systemImageName: "books.vertical.fill"
        )
        AppShortcut(
            intent: PauseListeningIntent(),
            phrases: ["Pause my audiobook in \(.applicationName)", "Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SkipBackIntent(),
            phrases: ["Skip back in \(.applicationName)", "Go back in \(.applicationName)"],
            shortTitle: "Skip Back",
            systemImageName: "gobackward"
        )
        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: ["Skip forward in \(.applicationName)"],
            shortTitle: "Skip Forward",
            systemImageName: "goforward"
        )
    }
}
