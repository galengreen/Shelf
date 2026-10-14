import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false
    @State private var cacheBytes: Int64 = 0
    @State private var downloadBytes: Int64 = 0

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                if let credentials = model.credentials {
                    LabeledContent("Server", value: credentials.serverURL.host() ?? credentials.serverURL.absoluteString)
                    LabeledContent("User", value: credentials.username)
                }
                if let version = model.serverVersion {
                    LabeledContent("Server Version", value: version)
                }
                if model.library.libraries.count > 1 {
                    Picker("Library", selection: Binding(
                        get: { model.library.selectedLibrary?.id ?? "" },
                        set: { id in
                            if let library = model.library.libraries.first(where: { $0.id == id }) {
                                Task { await model.selectLibrary(library) }
                            }
                        }
                    )) {
                        ForEach(model.library.libraries) { Text($0.name).tag($0.id) }
                    }
                }
            } header: {
                Text("Account")
            }

            Section {
                Picker("Skip Back", selection: $settings.skipBackward) {
                    ForEach(Settings.skipIntervals, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Picker("Skip Forward", selection: $settings.skipForward) {
                    ForEach(Settings.skipIntervals, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Picker("Default Speed", selection: $settings.defaultSpeed) {
                    ForEach(Settings.speedPresets, id: \.self) { Text(Format.speed($0)).tag($0) }
                }
                Toggle(isOn: $settings.smartRewind) {
                    Text("Smart Rewind")
                    Text("Rewinds a few seconds when you resume after a break.")
                }
                Toggle(isOn: $settings.lockScreenUsesChapter) {
                    Text("Chapter Progress on Lock Screen")
                    Text("Show the current chapter instead of the whole book.")
                }
                Toggle(isOn: $settings.autoplayNextInSeries) {
                    Text("Continue Series Automatically")
                    Text("When you finish a book, start the next one in its series. Otherwise it's offered on screen.")
                }
                Toggle(isOn: $settings.liveActivities) {
                    Text("Live Activity")
                    Text("Show the chapter and controls on the Lock Screen and in the Dynamic Island while you listen.")
                }
            } header: {
                Text("Playback")
            }
            .onChange(of: settings.skipBackward) {
                model.player.refreshRemoteCommands()
                model.broadcaster.schedule()
            }
            .onChange(of: settings.skipForward) {
                model.player.refreshRemoteCommands()
                model.broadcaster.schedule()
            }
            .onChange(of: settings.lockScreenUsesChapter) { model.player.updateNowPlaying() }
            .onChange(of: settings.liveActivities) { _, on in model.broadcaster.liveActivity.setEnabled(on) }

            Section {
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Listening Stats", systemImage: "chart.bar.xaxis")
                }
            }

            Section {
                Toggle(isOn: $settings.autoDownload) {
                    Text("Download While Listening")
                    Text("When you start a book, download it so the rest plays from your device. Saves battery and data.")
                }
                Toggle("Download Over Cellular", isOn: $settings.downloadOverCellular)
                Toggle("Remove Finished Downloads", isOn: $settings.deleteFinishedDownloads)
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Downloads", value: Format.bytes(downloadBytes))
                }
            } header: {
                Text("Downloads")
            } footer: {
                if !model.canDownload {
                    Text("Your server admin has turned off downloads for your account.")
                }
            }

            Section {
                LabeledContent("Cached Artwork & Data", value: Format.bytes(cacheBytes))
                Button("Clear Cache") {
                    Task {
                        ImagePipeline.shared.clearDisk()
                        await model.api?.clearCache()
                        await measure()
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Artwork is fetched at the size it's shown and kept on your device, and library data is only re-downloaded when it changes on the server. In Low Data Mode, artwork is fetched at a lower resolution.")
            }

            Section {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
            } footer: {
                Text("Shelf \(DeviceInfo.clientVersion)")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .navigationTitle("Settings")
        .task { await measure() }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            Text("Downloaded books stay on this device.")
        }
    }

    private func measure() async {
        let api = model.api
        async let apiBytes = api?.cacheSize() ?? 0
        let (images, downloads) = await Task.detached(priority: .utility) {
            (ImagePipeline.shared.diskSize(), FileManager.default.directorySize(DownloadManager.root))
        }.value
        cacheBytes = await apiBytes + images
        downloadBytes = downloads
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDeleteAll = false

    var body: some View {
        let manifests = model.downloads.manifests.values.sorted { $0.createdAt > $1.createdAt }
        List {
            ForEach(manifests, id: \.key) { manifest in
                HStack(spacing: 12) {
                    NavigationLink(value: manifest.item) {
                        HStack(spacing: 12) {
                            CoverView(source: manifest.item.coverSource, title: manifest.item.title, cornerRadius: 6)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(manifest.title).font(.body.weight(.medium)).lineLimit(1)
                                Text(subtitle(for: manifest)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DownloadButton(item: manifest.item, episode: manifest.episode)
                }
                .swipeActions {
                    Button(role: .destructive) { model.downloads.delete(manifest.key) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .overlay {
            if manifests.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download books to listen without a connection."))
            }
        }
        .toolbar {
            if !manifests.isEmpty {
                Button("Remove All", role: .destructive) { confirmDeleteAll = true }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { model.downloads.deleteAll() }
        }
    }

    private func subtitle(for manifest: DownloadManifest) -> String {
        switch model.downloads.state(for: manifest.key) {
        case .downloading(let fraction): "Downloading… \(Int(fraction * 100))%"
        case .failed(let message): message
        default: Format.bytes(manifest.totalBytes)
        }
    }
}
