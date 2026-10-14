import SwiftUI
import UIKit

@main
struct ShelfApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
        }
        .onChange(of: scenePhase) { old, new in
            switch new {
            case .background: delegate.model.didEnterBackground()
            case .active where old == .background: delegate.model.willEnterForeground()
            default: break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The one model, for code that runs outside SwiftUI's environment: intents, CarPlay and the watch.
    private(set) static var model: AppModel?
    let model: AppModel

    override init() {
        model = AppModel()
        super.init()
        Self.model = model
        PlaybackIntentTarget.handler = model
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        model.downloads.backgroundCompletion = completionHandler
    }
}
