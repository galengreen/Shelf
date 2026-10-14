import Foundation
import Observation

nonisolated struct DownloadManifest: Codable, Sendable {
    struct Track: Codable, Sendable {
        let index: Int
        let startOffset: Double
        let duration: Double
        let filename: String
        let expectedBytes: Int64?
        var isComplete: Bool
    }

    var item: LibraryItem
    /// Set when this download is a podcast episode rather than a whole book.
    var episode: PodcastEpisode?
    var tracks: [Track]
    var chapters: [Chapter]
    var createdAt: Date

    var key: String { ProgressKey.make(item.id, episode?.id) }
    var title: String { episode?.displayTitle ?? item.title }
    var isComplete: Bool { !tracks.isEmpty && tracks.allSatisfy(\.isComplete) }
    var totalBytes: Int64 { tracks.reduce(0) { $0 + ($1.expectedBytes ?? 0) } }
}

enum DownloadState: Equatable {
    case none
    case downloading(Double)
    case downloaded
    case failed(String)
}

/// Offline downloads over a background URLSession, so they continue while the app is suspended.
/// Playing a downloaded book never touches the network for audio — the biggest single saving for
/// both data and battery (the cellular radio can stay asleep).
@Observable
final class DownloadManager {
    private(set) var manifests: [String: DownloadManifest] = [:]
    private(set) var progress: [String: Double] = [:]
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored var apiProvider: () -> APIClient? = { nil }
    @ObservationIgnored var allowsCellular: () -> Bool = { false }
    /// The server can turn downloads off per user.
    @ObservationIgnored var isPermitted: () -> Bool = { true }
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private var bytes: [Int: (itemId: String, received: Int64, expected: Int64)] = [:]
    @ObservationIgnored private var retries: [String: Int] = [:]
    @ObservationIgnored private let delegate = SessionDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "nz.galengreen.shelf.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    nonisolated static let root: URL = {
        var url = URL.applicationSupportDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    init() {
        loadManifests()
        delegate.owner = self
        // Touch the session so the system reconnects any transfers that ran while we were suspended.
        session.getAllTasks { tasks in
            let active = tasks.compactMap { $0.taskDescription.flatMap(TaskTag.init) }
            Task { @MainActor in
                for tag in active where self.progress[tag.itemId] == nil {
                    self.progress[tag.itemId] = self.completedFraction(tag.itemId)
                }
            }
        }
    }

    // MARK: - Queries

    // Everything is keyed by progress key: the item id for books, "itemId/episodeId" for episodes.

    func state(for key: String) -> DownloadState {
        if let fraction = progress[key] { return .downloading(fraction) }
        if let message = failures[key] { return .failed(message) }
        if manifests[key]?.isComplete == true { return .downloaded }
        return .none
    }

    func isDownloaded(_ key: String) -> Bool { manifests[key]?.isComplete == true }

    /// Downloaded books (not episodes), newest first.
    var downloadedItems: [LibraryItem] {
        manifests.values.filter { $0.isComplete && $0.episode == nil }.sorted { $0.createdAt > $1.createdAt }.map(\.item)
    }

    nonisolated static func folder(for key: String) -> URL {
        root.appending(path: key.replacingOccurrences(of: "/", with: "_"), directoryHint: .isDirectory)
    }

    var usedBytes: Int64 { FileManager.default.directorySize(Self.root) }

    func localTracks(for key: String) -> [(url: URL, startOffset: Double, duration: Double)]? {
        guard let manifest = manifests[key], manifest.isComplete else { return nil }
        let folder = Self.folder(for: key)
        let tracks = manifest.tracks.sorted { $0.startOffset < $1.startOffset }.map {
            (url: folder.appending(path: $0.filename), startOffset: $0.startOffset, duration: $0.duration)
        }
        // Guard against files removed behind our back (e.g. storage cleanup).
        guard tracks.allSatisfy({ FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }) else { return nil }
        return tracks
    }

    // MARK: - Actions

    /// `item` must be the expanded item (with tracks or episodes).
    func download(_ item: LibraryItem, episode: PodcastEpisode? = nil) async {
        guard let api = apiProvider() else { return }
        let key = ProgressKey.make(item.id, episode?.id)
        guard isPermitted() else {
            failures[key] = "Downloads are turned off for your account"
            return
        }
        let tracks = episode.map { $0.audioTrack.map { [$0] } ?? [] } ?? item.media.tracks ?? []
        guard !tracks.isEmpty else {
            failures[key] = "No audio files"
            return
        }
        let unsupported = tracks.contains { !PlaybackFormats.directPlayMimeTypes.contains($0.mimeType ?? "") }
        if unsupported {
            failures[key] = "This audio format can't be played offline"
            return
        }
        failures[key] = nil

        try? FileManager.default.createDirectory(at: Self.folder(for: key), withIntermediateDirectories: true)

        var manifest = manifests[key] ?? DownloadManifest(
            item: item,
            episode: episode,
            tracks: tracks.enumerated().map { offset, track in
                .init(index: offset, startOffset: track.startOffset, duration: track.duration,
                      filename: "\(offset).\(track.fileExtension)", expectedBytes: track.metadata?.size, isComplete: false)
            },
            chapters: episode?.chapters ?? item.media.chapters ?? [],
            createdAt: .now
        )
        manifest.item = item
        manifests[key] = manifest
        saveManifest(manifest)
        progress[key] = completedFraction(key)

        for track in manifest.tracks where !track.isComplete {
            await enqueue(itemId: key, track: track, contentUrl: tracks[track.index].contentUrl, api: api)
        }
    }

    func cancel(_ itemId: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription.flatMap(TaskTag.init)?.itemId == itemId }.forEach { $0.cancel() }
        }
        progress[itemId] = nil
        failures[itemId] = nil
        if manifests[itemId]?.isComplete != true { delete(itemId) }
    }

    func delete(_ itemId: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription.flatMap(TaskTag.init)?.itemId == itemId }.forEach { $0.cancel() }
        }
        manifests[itemId] = nil
        progress[itemId] = nil
        failures[itemId] = nil
        try? FileManager.default.removeItem(at: Self.folder(for: itemId))
    }

    func deleteAll() {
        for id in Array(manifests.keys) { delete(id) }
    }

    // MARK: - Internals

    private func enqueue(itemId: String, track: DownloadManifest.Track, contentUrl: String, api: APIClient) async {
        guard let url = try? await api.mediaURL(for: contentUrl) else {
            failures[itemId] = "Couldn't reach the server"
            progress[itemId] = nil
            return
        }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular()
        let task = session.downloadTask(with: request)
        task.taskDescription = TaskTag(itemId: itemId, trackIndex: track.index, contentUrl: contentUrl).description
        if let expected = track.expectedBytes { task.countOfBytesClientExpectsToReceive = expected }
        task.resume()
    }

    fileprivate func trackFinished(_ tag: TaskTag, taskId: Int) {
        bytes[taskId] = nil
        guard var manifest = manifests[tag.itemId],
              let index = manifest.tracks.firstIndex(where: { $0.index == tag.trackIndex }) else { return }
        manifest.tracks[index].isComplete = true
        manifests[tag.itemId] = manifest
        saveManifest(manifest)
        if manifest.isComplete {
            progress[tag.itemId] = nil
            retries = retries.filter { !$0.key.hasPrefix(tag.itemId) }
        } else {
            progress[tag.itemId] = completedFraction(tag.itemId)
        }
    }

    fileprivate func trackFailed(_ tag: TaskTag, taskId: Int, status: Int?, cancelled: Bool) {
        bytes[taskId] = nil
        guard !cancelled, manifests[tag.itemId] != nil else { return }
        let key = "\(tag.itemId)#\(tag.trackIndex)"
        let attempt = (retries[key] ?? 0) + 1
        retries[key] = attempt
        // Expired token or a dropped connection: retry with a fresh URL a few times.
        if attempt <= 3, let api = apiProvider(),
           let track = manifests[tag.itemId]?.tracks.first(where: { $0.index == tag.trackIndex }) {
            Task {
                if status == 401 || status == 403 { _ = try? await api.refresh() }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                await enqueue(itemId: tag.itemId, track: track, contentUrl: tag.contentUrl, api: api)
            }
            return
        }
        progress[tag.itemId] = nil
        failures[tag.itemId] = status.map { "Download failed (\($0))" } ?? "Download interrupted"
    }

    fileprivate func bytesWritten(taskId: Int, tag: TaskTag, received: Int64, expected: Int64) {
        bytes[taskId] = (tag.itemId, received, expected)
        let fraction = completedFraction(tag.itemId)
        // Only publish whole-percent changes to keep SwiftUI work (and battery) down.
        if let old = progress[tag.itemId], abs(old - fraction) < 0.01 { return }
        progress[tag.itemId] = fraction
    }

    private func completedFraction(_ itemId: String) -> Double {
        guard let manifest = manifests[itemId] else { return 0 }
        let total = max(manifest.totalBytes, 1)
        let done = manifest.tracks.filter(\.isComplete).reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) }
        let inflight = bytes.values.filter { $0.itemId == itemId }.reduce(Int64(0)) { $0 + $1.received }
        if manifest.totalBytes == 0 {
            return Double(manifest.tracks.filter(\.isComplete).count) / Double(max(manifest.tracks.count, 1))
        }
        return min(1, Double(done + inflight) / Double(total))
    }

    private func loadManifests() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let manifest = DiskWriter.read(DownloadManifest.self, from: folder.appending(path: "manifest.json")) {
                manifests[manifest.key] = manifest
                if !manifest.isComplete { failures[manifest.key] = "Paused" }
            }
        }
    }

    private func saveManifest(_ manifest: DownloadManifest) {
        DiskWriter.write(manifest, to: Self.folder(for: manifest.key).appending(path: "manifest.json"))
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

nonisolated enum PlaybackFormats {
    static let directPlayMimeTypes = ["audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-aiff", "audio/x-caf", "audio/wav", "audio/x-wav"]
}

nonisolated struct TaskTag: CustomStringConvertible, Sendable {
    /// Progress key of the download (item id, or "itemId/episodeId").
    let itemId: String
    let trackIndex: Int
    let contentUrl: String

    init(itemId: String, trackIndex: Int, contentUrl: String) {
        self.itemId = itemId
        self.trackIndex = trackIndex
        self.contentUrl = contentUrl
    }

    init?(_ string: String) {
        let parts = string.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, let index = Int(parts[1]) else { return nil }
        itemId = parts[0]; trackIndex = index; contentUrl = parts[2]
    }

    var description: String { "\(itemId)|\(trackIndex)|\(contentUrl)" }
}

/// URLSession delegate callbacks arrive on a background queue; file moves must happen before
/// returning from `didFinishDownloadingTo`, everything else hops to the main actor.
private nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: DownloadManager?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = downloadTask.taskDescription.flatMap(TaskTag.init) else { return }
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            Task { @MainActor in self.owner?.trackFailed(tag, taskId: id, status: status, cancelled: false) }
            return
        }
        let folder = DownloadManager.folder(for: tag.itemId)
        let manifest = DiskWriter.read(DownloadManifest.self, from: folder.appending(path: "manifest.json"))
        let filename = manifest?.tracks.first { $0.index == tag.trackIndex }?.filename ?? "\(tag.trackIndex).audio"
        let destination = folder.appending(path: filename)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.owner?.trackFinished(tag, taskId: id) }
        } catch {
            Task { @MainActor in self.owner?.trackFailed(tag, taskId: id, status: nil, cancelled: false) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = downloadTask.taskDescription.flatMap(TaskTag.init) else { return }
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            self.owner?.bytesWritten(taskId: id, tag: tag, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let tag = task.taskDescription.flatMap(TaskTag.init) else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let id = task.taskIdentifier
        Task { @MainActor in self.owner?.trackFailed(tag, taskId: id, status: status, cancelled: cancelled) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.owner?.finishBackgroundEvents() }
    }
}
