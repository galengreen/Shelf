import CarPlay
import UIKit

/// CarPlay: Continue Listening, Library and Downloads tabs, and the system Now Playing screen.
///
/// Compiled in but inactive: CarPlay only connects once Apple grants the
/// `com.apple.developer.carplay-audio` entitlement and it's added to Config/Shelf.entitlements
/// (see "CarPlay" in the README). Playback goes through the same `PlaybackController` as the phone,
/// and Now Playing is driven by the lock screen info and remote commands it already publishes.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var templates: CarPlayTemplates?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        Task {
            guard let model = await IntentModel.restored() else { return }
            let templates = CarPlayTemplates(model: model, interfaceController: interfaceController)
            self.templates = templates
            interfaceController.setRootTemplate(templates.root, animated: false, completion: nil)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        templates = nil
    }
}

/// Builds the CarPlay lists from what's already on the phone (cached library, progress and
/// downloads), so browsing in the car costs no requests. Lists are rebuilt when their tab is shown.
final class CarPlayTemplates: NSObject, CPTabBarTemplateDelegate {
    let root: CPTabBarTemplate

    private let model: AppModel
    private weak var interfaceController: CPInterfaceController?
    private let continueListening: CPListTemplate
    private let library: CPListTemplate
    private let downloads: CPListTemplate

    init(model: AppModel, interfaceController: CPInterfaceController) {
        self.model = model
        self.interfaceController = interfaceController
        continueListening = CPListTemplate(title: "Continue", sections: [])
        continueListening.tabImage = UIImage(systemName: "play.circle")
        continueListening.emptyViewTitleVariants = ["Nothing in Progress"]
        library = CPListTemplate(title: "Library", sections: [])
        library.tabImage = UIImage(systemName: "books.vertical")
        library.emptyViewTitleVariants = ["No Books"]
        downloads = CPListTemplate(title: "Downloads", sections: [])
        downloads.tabImage = UIImage(systemName: "arrow.down.circle")
        downloads.emptyViewTitleVariants = ["No Downloads"]
        root = CPTabBarTemplate(templates: [continueListening, library, downloads])
        super.init()
        root.delegate = self
        configureNowPlaying()
        reload(continueListening)
    }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if let list = selectedTemplate as? CPListTemplate { reload(list) }
    }

    private func reload(_ template: CPListTemplate) {
        let items: [LibraryItem]
        switch template {
        case continueListening:
            items = model.progress.inProgressIds.compactMap { model.library.item($0) ?? model.downloads.manifests[$0]?.item }
        case downloads:
            items = model.downloads.downloadedItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default:
            items = model.library.items
                .filter { !$0.isPodcast }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        // CarPlay caps list length; the first screenful also gets covers.
        let limit = CPListTemplate.maximumItemCount
        let listItems = items.prefix(limit).enumerated().map { index, item in listItem(for: item, loadCover: index < 24) }
        template.updateSections([CPListSection(items: listItems)])
    }

    private func listItem(for item: LibraryItem, loadCover: Bool) -> CPListItem {
        let snapshot = model.progress.snapshot(for: item.id)
        let listItem = CPListItem(text: item.title, detailText: item.authorName,
                                  image: ImagePipeline.shared.cachedImage(item.coverSource, pixelWidth: 160))
        if let snapshot, snapshot.isStarted, !snapshot.isFinished { listItem.playbackProgress = snapshot.fraction }
        listItem.isPlaying = model.player.item?.id == item.id && model.player.isPlaying
        listItem.accessoryType = .none
        listItem.handler = { [weak self] _, completion in
            self?.play(item)
            completion()
        }
        if loadCover, listItem.image == nil {
            Task {
                if let image = await ImagePipeline.shared.image(item.coverSource, pixelWidth: 160) { listItem.setImage(image) }
            }
        }
        return listItem
    }

    private func play(_ item: LibraryItem) {
        if model.player.item?.id == item.id {
            model.player.play()
        } else {
            model.player.open(item)
        }
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    /// Speed button on Now Playing; everything else comes from the remote commands.
    private func configureNowPlaying() {
        let speed = CPNowPlayingPlaybackRateButton { [weak self] _ in
            guard let self else { return }
            let player = model.player
            let presets: [Double] = [1, 1.25, 1.5, 1.75, 2]
            let next = presets.first { $0 > player.speed + 0.01 } ?? presets[0]
            player.setSpeed(next)
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([speed])
    }
}
