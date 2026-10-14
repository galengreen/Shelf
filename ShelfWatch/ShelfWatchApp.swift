// Linked so the build's App Intents metadata step has a framework to inspect (otherwise it warns).
import AppIntents
import SwiftUI

/// Remote control for Shelf on the paired iPhone.
@main
struct ShelfWatchApp: App {
    @State private var remote = WatchRemote()

    var body: some Scene {
        WindowGroup {
            NowPlayingView()
                .environment(remote)
        }
    }
}
