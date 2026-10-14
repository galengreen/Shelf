import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut: LoginView()
            case .signedIn: MainTabs()
            }
        }
        .animation(.smooth, value: model.phase)
        .onChange(of: model.network.isConstrained, initial: true) { _, constrained in
            ImagePipeline.shared.setLowDataMode(constrained)
        }
    }
}

enum AppTab: Hashable {
    case home, library, authors, settings, search
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .home
    @Namespace private var playerTransition

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                NavigationStack { HomeView().appDestinations() }
            }
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                NavigationStack { LibraryView().appDestinations() }
            }
            if !model.library.isPodcastLibrary {
                Tab("Authors", systemImage: "person.2.fill", value: .authors) {
                    NavigationStack { AuthorsView().appDestinations() }
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack { SettingsView().appDestinations() }
            }
            Tab(value: .search, role: .search) {
                NavigationStack { SearchView().appDestinations() }
            }
        }
        // A sidebar in regular width (iPad); the usual tab bar on iPhone.
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: model.library.isPodcastLibrary) { _, podcasts in
            if podcasts && tab == .authors { tab = .library }
        }
        .sheet(item: $model.addingToPlaylist) { entry in
            AddToPlaylistView(item: entry.item, episode: entry.episode)
        }
        .tabViewBottomAccessory(isEnabled: model.player.item != nil) {
            MiniPlayer(transition: playerTransition)
        }
        .fullScreenCover(isPresented: $model.presentingPlayer) {
            PlayerView()
                .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
        }
        .onOpenURL { url in
            // shelf://player, from widgets and the Live Activity.
            if url.scheme == "shelf", url.host() == "player", model.player.item != nil { model.presentingPlayer = true }
        }
        .alert(
            "Playback Problem",
            isPresented: Binding(get: { model.player.errorMessage != nil }, set: { if !$0 { model.player.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.player.errorMessage ?? "")
        }
    }
}
