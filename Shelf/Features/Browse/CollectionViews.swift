import SwiftUI

// MARK: - Collections (curated by the server admin, shared by everyone)

struct CollectionsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let collections = model.library.collections ?? []
        List(collections) { collection in
            NavigationLink(value: collection) {
                HStack(spacing: 14) {
                    StackedCovers(items: collection.books, size: 58)
                        .frame(width: 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(collection.name).font(.body.weight(.medium))
                        Text(collection.books.count == 1 ? "1 book" : "\(collection.books.count) books")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Collections")
        .overlay {
            if model.library.collections == nil {
                ProgressView()
            } else if collections.isEmpty {
                ContentUnavailableView("No Collections", systemImage: "square.stack",
                                       description: Text("Collections are created on your server by an admin."))
            }
        }
        .task { await model.library.loadCollections(api: model.api) }
        .refreshable { await model.library.loadCollections(api: model.api) }
    }
}

struct CollectionDetailView: View {
    let collection: BookCollection
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.library.collections?.first { $0.id == collection.id } ?? collection
        List {
            Section {
                VStack(spacing: 12) {
                    StackedCovers(items: current.books, size: 140)
                    Text(current.name)
                        .font(.bookTitle(.title))
                        .multilineTextAlignment(.center)
                    if let description = current.description.nonEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(current.books) { book in
                    NavigationLink(value: model.library.item(book.id) ?? book) { BookRow(item: model.library.item(book.id) ?? book) }
                        .contextMenu { BookActions(item: book) }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Playlists (personal, and playable as a queue)

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var newName = ""
    @State private var error: String?

    var body: some View {
        let playlists = model.library.playlists ?? []
        List {
            ForEach(playlists) { playlist in
                NavigationLink(value: playlist) {
                    HStack(spacing: 14) {
                        StackedCovers(items: playlist.items.compactMap(\.libraryItem), size: 58)
                            .frame(width: 84, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name).font(.body.weight(.medium))
                            Text(playlist.items.count == 1 ? "1 item" : "\(playlist.items.count) items")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { playlists[$0] }
                Task {
                    for playlist in doomed { await run { try await model.library.deletePlaylist(playlist, api: model.api) } }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .toolbar {
            Button("New Playlist", systemImage: "plus") { creating = true }
                .disabled(!model.network.isOnline)
        }
        .overlay {
            if model.library.playlists == nil {
                ProgressView()
            } else if playlists.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list",
                                       description: Text("Make a playlist to line up what you'll listen to next. It plays straight through and syncs with your other devices."))
            }
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                Task { await run { try await model.library.createPlaylist(named: name, itemId: nil, api: model.api) } }
            }
        }
        .alert("Couldn't Update Playlist", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
        .task { await model.library.loadPlaylists(api: model.api) }
        .refreshable { await model.library.loadPlaylists(api: model.api) }
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

struct PlaylistDetailView: View {
    let playlistId: String
    let seed: Playlist

    @Environment(AppModel.self) private var model

    var body: some View {
        let playlist = model.library.playlists?.first { $0.id == playlistId } ?? seed
        let entries = queueEntries(playlist)
        List {
            Section {
                VStack(spacing: 12) {
                    StackedCovers(items: entries.map(\.item), size: 140)
                    Text(playlist.name)
                        .font(.bookTitle(.title))
                        .multilineTextAlignment(.center)
                    if let description = playlist.description.nonEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    let remaining = unfinished(entries)
                    if !remaining.isEmpty {
                        Button {
                            model.player.play(queue: remaining, named: playlist.name)
                        } label: {
                            Label(remaining.count < entries.count ? "Continue Playlist" : "Play All", systemImage: "play.fill")
                                .font(.headline)
                                .foregroundStyle(.white) // Lists tint symbols with the accent colour otherwise.
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        Text("Plays straight through, skipping anything you've finished.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(entries) { entry in
                    Group {
                        if let episode = entry.episode {
                            EpisodeRow(item: entry.item, episode: episode, showsPodcast: true)
                        } else {
                            NavigationLink(value: entry.item) { BookRow(item: entry.item) }
                                .contextMenu { BookActions(item: entry.item) }
                        }
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) {
                            Task { try? await model.library.removeFromPlaylist(playlist, itemId: entry.item.id, episodeId: entry.episode?.id, api: model.api) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Empty Playlist", systemImage: "music.note.list",
                                       description: Text("Add books from their menu with Add to Playlist."))
            }
        }
        .task { if model.library.playlists == nil { await model.library.loadPlaylists(api: model.api) } }
    }

    private func queueEntries(_ playlist: Playlist) -> [QueueEntry] {
        playlist.items.compactMap { entry in
            guard let item = model.library.item(entry.libraryItemId) ?? entry.libraryItem else { return nil }
            return QueueEntry(item: item, episode: entry.episode)
        }
    }

    private func unfinished(_ entries: [QueueEntry]) -> [QueueEntry] {
        entries.filter { model.progress.snapshot(for: $0.id)?.isFinished != true }
    }
}

/// Picker for adding a book or episode to one of your playlists.
struct AddToPlaylistView: View {
    let item: LibraryItem
    var episode: PodcastEpisode?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Playlist…", systemImage: "plus") { creating = true }
                }
                Section {
                    ForEach(model.library.playlists ?? []) { playlist in
                        let contains = playlist.items.contains { $0.libraryItemId == item.id && $0.episodeId == episode?.id }
                        Button {
                            Task {
                                await run {
                                    if contains {
                                        try await model.library.removeFromPlaylist(playlist, itemId: item.id, episodeId: episode?.id, api: model.api)
                                    } else {
                                        try await model.library.addToPlaylist(playlist, itemId: item.id, episodeId: episode?.id, api: model.api)
                                        dismiss()
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(playlist.name).foregroundStyle(.primary)
                                Spacer()
                                if contains { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .overlay { if model.library.playlists == nil { ProgressView() } }
            .alert("New Playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    newName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        await run { try await model.library.createPlaylist(named: name, itemId: item.id, episodeId: episode?.id, api: model.api) }
                        if error == nil { dismiss() }
                    }
                }
            }
            .alert("Couldn't Update Playlist", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .task { await model.library.loadPlaylists(api: model.api) }
        }
        .presentationDetents([.medium, .large])
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

// MARK: - Narrators, genres, tags, languages

struct FacetListView: View {
    let facet: Facet
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let values = model.library.values(for: facet).filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        List(values, id: \.name) { entry in
            NavigationLink(value: FacetValue(facet: facet, value: entry.name)) {
                HStack {
                    Label(entry.name, systemImage: facet.systemImage)
                    Spacer()
                    Text("\(entry.count)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(facet.title)
        .searchable(text: $query, prompt: "Search \(facet.title.lowercased())")
        .overlay {
            if values.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("No \(facet.title)", systemImage: facet.systemImage)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}

struct FacetItemsView: View {
    let value: FacetValue
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.library.items(matching: value.facet, value: value.value)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        List(items) { item in
            NavigationLink(value: item) { BookRow(item: item) }
                .contextMenu { BookActions(item: item) }
        }
        .listStyle(.plain)
        .navigationTitle(value.value)
        .overlay {
            if items.isEmpty { ContentUnavailableView("No Books", systemImage: "books.vertical") }
        }
    }
}
