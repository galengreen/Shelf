import SwiftUI

struct PodcastDetailView: View {
    let itemId: String
    let seed: LibraryItem

    @Environment(AppModel.self) private var model
    @State private var showFullDescription = false
    @State private var filter: EpisodeFilter = .all

    enum EpisodeFilter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", downloaded = "Downloaded"
        var id: String { rawValue }
    }

    private var item: LibraryItem { model.library.item(itemId) ?? seed }

    var body: some View {
        let item = self.item
        let episodes = visibleEpisodes(item)
        List {
            Section {
                header(item)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(EpisodeFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                ForEach(episodes) { episode in
                    EpisodeRow(item: item, episode: episode)
                }
            } header: {
                Text("\(item.media.episodes?.count ?? item.media.numEpisodes ?? 0) Episodes")
            }
        }
        .listStyle(.plain)
        .readableWidth(820)
        .navigationBarTitleDisplayMode(.inline)
        .background(alignment: .top) { PaletteBackdrop(source: item.coverSource) }
        .overlay {
            if item.media.episodes == nil {
                ProgressView()
            } else if episodes.isEmpty {
                ContentUnavailableView("No Episodes", systemImage: "waveform")
            }
        }
        .task(id: itemId) { await model.library.loadDetails(itemId, api: model.api) }
        .refreshable { await model.library.loadDetails(itemId, api: model.api) }
    }

    private func header(_ item: LibraryItem) -> some View {
        VStack(spacing: 12) {
            CoverView(source: item.coverSource, title: item.title, cornerRadius: 12)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            Text(item.title)
                .font(.bookTitle(.title))
                .multilineTextAlignment(.center)
            if let author = item.authorName {
                Text(author).foregroundStyle(Color.accentColor).font(.body.weight(.medium))
            }
            if let description = item.media.metadata.description.nonEmpty {
                VStack(spacing: 4) {
                    Text(description.strippingHTML)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullDescription ? nil : 3)
                    Button(showFullDescription ? "Less" : "More") {
                        withAnimation(.smooth) { showFullDescription.toggle() }
                    }
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func visibleEpisodes(_ item: LibraryItem) -> [PodcastEpisode] {
        let sorted = (item.media.episodes ?? []).sorted { ($0.publishedAt ?? 0) > ($1.publishedAt ?? 0) }
        switch filter {
        case .all: return sorted
        case .unplayed:
            return sorted.filter { model.progress.snapshot(for: ProgressKey.make(item.id, $0.id))?.isFinished != true }
        case .downloaded:
            return sorted.filter { model.downloads.isDownloaded(ProgressKey.make(item.id, $0.id)) }
        }
    }
}

/// One episode with its progress and a play button.
struct EpisodeRow: View {
    let item: LibraryItem
    let episode: PodcastEpisode
    var showsPodcast = false

    @Environment(AppModel.self) private var model

    var body: some View {
        let key = ProgressKey.make(item.id, episode.id)
        let snapshot = model.progress.snapshot(for: key)
        let isCurrent = model.player.key == key
        let playing = isCurrent && model.player.isPlaying
        HStack(alignment: .top, spacing: 12) {
            if showsPodcast {
                CoverView(source: item.coverSource, title: item.title, cornerRadius: 6)
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let date = episode.publishedDate {
                    Text(date, format: .dateTime.day().month(.abbreviated).year())
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(episode.displayTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(snapshot?.isFinished == true ? .secondary : .primary)
                    .lineLimit(2)
                if let subtitle = (episode.subtitle ?? episode.description)?.strippingHTML.nonEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 10) {
                    Button {
                        if isCurrent { model.player.togglePlayPause() } else { model.player.open(item, episode: episode) }
                    } label: {
                        Label(playing ? "Pause" : label(snapshot), systemImage: playing ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                        ProgressBar(fraction: snapshot.fraction, height: 3).frame(width: 50)
                    }
                    Spacer()
                    DownloadButton(item: item, episode: episode, size: 20)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            let finished = snapshot?.isFinished == true
            Button(finished ? "Mark as Unplayed" : "Mark as Played", systemImage: finished ? "arrow.uturn.backward" : "checkmark.circle") {
                Task { await model.setFinished(!finished, item: item, episode: episode) }
            }
            Button("Add to Playlist…", systemImage: "music.note.list") { model.addingToPlaylist = QueueEntry(item: item, episode: episode) }
                .disabled(!model.network.isOnline)
        }
    }

    private func label(_ snapshot: ProgressStore.Snapshot?) -> String {
        if snapshot?.isFinished == true { return "Played" }
        if let snapshot, snapshot.isStarted { return Format.timeLeft(snapshot.remaining) }
        return episode.playDuration > 0 ? Format.duration(episode.playDuration) : "Play"
    }
}

/// Square card for an episode on the home screen.
struct EpisodeCard: View {
    let item: LibraryItem
    let episode: PodcastEpisode

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let key = ProgressKey.make(item.id, episode.id)
        let snapshot = model.progress.snapshot(for: key)
        let width = Layout.cardWidth(sizeClass)
        Button {
            model.player.open(item, episode: episode)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CoverView(source: item.coverSource, title: item.title, cornerRadius: 10)
                    .frame(width: width, height: width)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: snapshot?.isFinished == true ? "checkmark.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(radius: 3)
                            .padding(6)
                    }
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                if let snapshot, snapshot.isStarted, !snapshot.isFinished {
                    ProgressBar(fraction: snapshot.fraction).frame(width: width)
                }
                Text(episode.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(episode.displayTitle), \(item.title)")
    }
}
