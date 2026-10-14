import AppIntents
import Foundation

/// A book in the current library, so Siri and Shortcuts can pick one by title. Everything comes from
/// the cached library listing, so resolving a book never waits on the server.
nonisolated struct BookEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Book", numericFormat: "\(placeholder: .int) books")
    static let defaultQuery = BookQuery()

    let id: String
    let title: String
    let author: String?
    /// A small cached cover, if one is on disk already (never downloaded just for this).
    let cover: Data?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: author.map { "\($0)" },
            image: cover.map { .init(data: $0) }
        )
    }
}

@MainActor extension BookEntity {
    init(_ item: LibraryItem) {
        self.init(id: item.id, title: item.title, author: item.authorName,
                  cover: ImagePipeline.shared.cachedData(item.coverSource))
    }
}

nonisolated struct BookQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [BookEntity] {
        guard let model = await IntentModel.restored() else { return [] }
        return identifiers.compactMap { id in
            (model.library.item(id) ?? model.downloads.manifests[id]?.item).map(BookEntity.init)
        }
    }

    @MainActor func entities(matching string: String) async throws -> [BookEntity] {
        guard let model = await IntentModel.restored() else { return [] }
        let terms = string.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        return Self.books(in: model)
            .filter { item in
                let haystack = [item.title, item.authorName, item.media.metadata.seriesName].compactMap { $0 }.joined(separator: " ")
                return terms.allSatisfy { haystack.localizedStandardContains($0) }
            }
            .prefix(25)
            .map(BookEntity.init)
    }

    /// Books in progress first (most recent first), then the rest of the library by title. Siri
    /// learns these titles for the "Play … in Shelf" phrase.
    @MainActor func suggestedEntities() async throws -> [BookEntity] {
        guard let model = await IntentModel.restored() else { return [] }
        let inProgress = model.progress.inProgressIds.compactMap { model.library.item($0) }.filter { !$0.isPodcast }
        let started = Set(inProgress.map(\.id))
        let rest = Self.books(in: model)
            .filter { !started.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (inProgress + rest).prefix(60).map(BookEntity.init)
    }

    @MainActor private static func books(in model: AppModel) -> [LibraryItem] {
        model.library.items.filter { !$0.isPodcast }
    }
}

/// The app's model for code that runs outside SwiftUI (intents, CarPlay), once the cached library
/// and last-played item are loaded.
@MainActor enum IntentModel {
    static func restored() async -> AppModel? {
        guard let model = AppDelegate.model else { return nil }
        await model.waitUntilRestored()
        return model
    }
}
