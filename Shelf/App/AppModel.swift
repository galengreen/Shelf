import AppIntents
import Foundation
import Observation

@Observable
final class AppModel {
    enum Phase { case signedOut, signedIn }

    private(set) var phase: Phase = .signedOut
    private(set) var api: APIClient?
    private(set) var credentials: Credentials?
    private(set) var serverVersion: String?
    /// From the server's user permissions; admins can turn downloads off per user.
    private(set) var canDownload = true
    var presentingPlayer = false
    /// Drives the Add to Playlist sheet, which is presented from the root so context menus can open it.
    var addingToPlaylist: QueueEntry?
    var signOutReason: String?

    let settings: Settings
    let network: NetworkMonitor
    let progress: ProgressStore
    let library: LibraryStore
    let downloads: DownloadManager
    let bookmarks: BookmarkStore
    let localSessions: LocalSessionStore
    let player: PlaybackController
    /// Widgets, Control Centre, the Live Activity and the watch.
    let broadcaster: PlaybackBroadcaster

    @ObservationIgnored private let realtime = RealtimeClient()
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var libraryRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastForegroundRefresh: Date = .distantPast
    /// Loading the cached library and last-played item from disk (no network).
    @ObservationIgnored private var restored: Task<Void, Never>?
    @ObservationIgnored private var lastListeningFetch: Date = .distantPast
    private static let canDownloadKey = "canDownload"

    init() {
        settings = Settings()
        network = NetworkMonitor()
        progress = ProgressStore()
        library = LibraryStore(settings: settings)
        downloads = DownloadManager()
        bookmarks = BookmarkStore()
        localSessions = LocalSessionStore()
        player = PlaybackController(settings: settings, progress: progress, library: library, downloads: downloads,
                                    network: network, localSessions: localSessions)
        broadcaster = PlaybackBroadcaster(player: player, settings: settings)
        canDownload = UserDefaults.standard.object(forKey: Self.canDownloadKey) as? Bool ?? true

        player.apiProvider = { [weak self] in self?.api }
        downloads.apiProvider = { [weak self] in self?.api }
        downloads.allowsCellular = { [weak self] in self?.settings.downloadOverCellular ?? false }
        downloads.isPermitted = { [weak self] in self?.canDownload ?? true }
        network.onReconnect = { [weak self] in
            Task { await self?.refresh() }
            self?.connectRealtime()
        }
        realtime.onEvent = { [weak self] name, payload in self?.handleEvent(name, payload) }
        broadcaster.watch.onCommand = { [weak self] command in self?.handle(command) }

        if let saved = Keychain.load() {
            configure(saved)
            phase = .signedIn
            // Started here rather than in `start()` so an intent that launched the app can wait on it.
            restored = Task { await restoreFromCache() }
            Task { await start() }
        }
        #if DEBUG
        Task { await signInFromEnvironment() }
        #endif
    }

    #if DEBUG
    /// Test hook for simulator automation (debug builds only): launching with SHELF_SERVER plus
    /// SHELF_API_KEY, or SHELF_USERNAME and SHELF_PASSWORD, signs in without the login form.
    private func signInFromEnvironment() async {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["SHELF_SERVER"] else { return }
        do {
            let url = try await APIClient.resolve(server).url
            let credentials: Credentials
            if let key = env["SHELF_API_KEY"] {
                credentials = try await APIClient.login(server: url, apiKey: key)
            } else if let username = env["SHELF_USERNAME"], let password = env["SHELF_PASSWORD"] {
                credentials = try await APIClient.login(server: url, username: username, password: password)
            } else {
                return
            }
            if phase == .signedIn { await signOut() }
            await signIn(credentials)
        } catch {
            signOutReason = "Test sign-in failed: \(error.localizedDescription)"
        }
    }
    #endif

    // MARK: - Session

    func signIn(_ credentials: Credentials) async {
        Keychain.save(credentials)
        signOutReason = nil
        // Start in the library the server picks for this user (falls back to the first one).
        settings.selectedLibraryId = credentials.defaultLibraryId
        configure(credentials)
        phase = .signedIn
        await start()
    }

    func signOut(reason: String? = nil) async {
        if let api {
            await progress.flushPending(using: api)
            await localSessions.upload(using: api)
            await bookmarks.flush(api: api)
        }
        await player.stop()
        realtime.disconnect()
        Keychain.clear()
        await api?.clearCache()
        ImagePipeline.shared.setClient(nil)
        library.reset()
        settings.selectedLibraryId = nil
        progress.reset()
        bookmarks.reset()
        localSessions.reset()
        broadcaster.widgets.reset()
        api = nil
        credentials = nil
        restored = nil
        signOutReason = reason
        phase = .signedOut
    }

    private func configure(_ credentials: Credentials) {
        self.credentials = credentials
        let client = APIClient(credentials: credentials) { [weak self] updated in
            Task { @MainActor in self?.credentialsChanged(updated) }
        }
        api = client
        ImagePipeline.shared.setClient(client)
    }

    private func credentialsChanged(_ updated: Credentials?) {
        if let updated {
            credentials = updated
            Keychain.save(updated)
        } else if phase == .signedIn {
            Task { await signOut(reason: "Your session expired. Please sign in again.") }
        }
    }

    // MARK: - Data

    private func start() async {
        if restored == nil { restored = Task { await restoreFromCache() } }
        await restored?.value
        connectRealtime()
        await refresh()
    }

    private func restoreFromCache() async {
        guard let api else { return }
        await library.loadCached(api: api)
        if let data = await api.cachedData("api/me"), let user = try? JSONDecoder().decode(User.self, from: data) {
            apply(user)
        }
        player.restoreLastItem()
    }

    /// For work that can arrive before any UI (intents, CarPlay, the watch): waits until the cached
    /// library and the last-played item are loaded, which only reads from disk.
    func waitUntilRestored() async {
        await restored?.value
    }

    func refresh() async {
        guard let api, network.isOnline else { return }
        // Upload anything recorded offline first, so the fresh server state already includes it.
        await progress.flushPending(using: api)
        await bookmarks.flush(api: api)
        await localSessions.upload(using: api)
        async let libraryRefresh: Void = library.refresh(api: api)
        async let userRefresh: Void = refreshUser()
        _ = await (libraryRefresh, userRefresh)
        player.restoreLastItem()
        // Siri learns book titles for "Play … in Shelf" from the suggested entities.
        ShelfShortcuts.updateAppShortcutParameters()
        await library.prefetchDetails(progress.inProgressIds.prefix(20).map { $0 }, api: api)
        if serverVersion == nil, let server = credentials?.serverURL {
            serverVersion = try? await APIClient.status(of: server).serverVersion
        }
        await refreshListeningForWidgets()
    }

    /// Keeps the streak and activity widgets current without opening the stats screen: only when
    /// one of them is on a Home or Lock Screen, at most every half hour, and ETag-cached, so an
    /// unchanged answer is an empty 304.
    func refreshListeningForWidgets() async {
        guard let api, network.isOnline, Date.now.timeIntervalSince(lastListeningFetch) > 30 * 60,
              await broadcaster.widgets.hasListeningWidgets() else { return }
        lastListeningFetch = .now
        if let stats = try? await api.get("api/me/listening-stats", cached: true, as: ListeningStats.self) {
            broadcaster.widgets.updateListening(stats.days)
        }
    }

    /// `/api/me` carries progress, bookmarks and permissions in one (ETag-cached) response.
    func refreshUser() async {
        guard let api, let user = try? await api.get("api/me", cached: true, as: User.self) else { return }
        apply(user)
    }

    func apply(_ user: User) {
        progress.apply(serverProgress: user.mediaProgress ?? [])
        bookmarks.apply(server: user.bookmarks ?? [])
        if let download = user.permissions?.download {
            canDownload = download
            UserDefaults.standard.set(download, forKey: Self.canDownloadKey)
        }
    }

    func selectLibrary(_ library: Library) async {
        guard let api else { return }
        await self.library.selectLibrary(library, api: api)
    }

    // MARK: - Lifecycle

    func didEnterBackground() {
        isActive = false
        player.appDidEnterBackground()
        // Live updates only matter while you're looking; the socket would cost battery in the background.
        realtime.disconnect()
    }

    func willEnterForeground() {
        isActive = true
        player.appWillEnterForeground()
        broadcaster.appWillEnterForeground()
        connectRealtime()
        // Conditional requests make this cheap, but there's still no need to do it every app switch.
        guard Date.now.timeIntervalSince(lastForegroundRefresh) > 120 else { return }
        lastForegroundRefresh = .now
        Task { await refresh() }
    }

    // MARK: - Live updates

    private func connectRealtime() {
        guard let api, phase == .signedIn, isActive, network.isOnline else { return }
        realtime.connect(api: api)
    }

    private func handleEvent(_ name: String, _ payload: Data) {
        let decoder = JSONDecoder()
        switch name {
        case "user_item_progress_updated":
            // Another device (or our own session) synced. Echoes of our own syncs are harmless.
            nonisolated struct Update: Decodable { let sessionId: String?; let data: MediaProgress }
            guard let update = try? decoder.decode(Update.self, from: payload),
                  let itemId = update.data.libraryItemId else { return }
            progress.apply(remote: update.data)
            if update.sessionId != player.activeServerSessionId {
                player.remoteProgressChanged(for: ProgressKey.make(itemId, update.data.episodeId))
            }
        case "user_updated":
            // Bookmarks, finished/hidden flags, and progress batches from other devices.
            if let user = try? decoder.decode(User.self, from: payload) { apply(user) }
        case "item_added", "item_updated", "item_removed", "items_added", "items_updated",
             "series_added", "series_updated", "author_added", "author_updated", "author_removed":
            scheduleLibraryRefresh()
        case "playlist_added", "playlist_updated", "playlist_removed":
            if library.playlists != nil { Task { await library.loadPlaylists(api: api) } }
        case "collection_added", "collection_updated", "collection_removed":
            if library.collections != nil { Task { await library.loadCollections(api: api) } }
        default:
            break
        }
    }

    /// Library events arrive in bursts during a scan; refresh once things settle.
    private func scheduleLibraryRefresh() {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, let api = self.api else { return }
            await self.library.refresh(api: api)
        }
    }

    // MARK: - Actions

    func setFinished(_ finished: Bool, item: LibraryItem, episode: PodcastEpisode? = nil) async {
        let key = ProgressKey.make(item.id, episode?.id)
        await progress.setFinished(finished, key: key, duration: episode?.playDuration ?? item.duration, api: api)
        if finished, settings.deleteFinishedDownloads { downloads.delete(key) }
    }

    func hideFromContinueListening(_ item: LibraryItem) async {
        library.hideFromShelves(item.id)
        await progress.hideFromContinueListening(item.id, api: api)
    }

    func download(_ item: LibraryItem, episode: PodcastEpisode? = nil) async {
        let details = await library.loadDetails(item.id, api: api) ?? item
        let fresh = episode.flatMap { ep in details.media.episodes?.first { $0.id == ep.id } } ?? episode
        await downloads.download(details, episode: fresh)
    }

    func addBookmark() async {
        guard let item = player.item, player.episode == nil else { return }
        let time = player.currentTime
        let title = player.currentChapter.map { "\($0.title) · \(Format.clock(time - $0.start))" } ?? Format.clock(time)
        await bookmarks.add(itemId: item.id, time: time, title: title, api: api)
    }
}
