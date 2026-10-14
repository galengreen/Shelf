import Foundation
import ImageIO
import Synchronization
import UIKit

nonisolated enum ImageSource: Hashable, Sendable {
    case cover(itemId: String, version: Int)
    case author(authorId: String, version: Int)

    var cacheKey: String {
        switch self {
        case let .cover(id, version): "c_\(id)_\(version)"
        case let .author(id, version): "a_\(id)_\(version)"
        }
    }
}

/// Loads artwork with three layers of savings:
/// 1. The server resizes and re-encodes to WebP, so a list thumbnail is ~10 KB instead of a multi-MB original.
/// 2. Sizes are bucketed and any cached larger size satisfies a smaller request, so each cover is
///    usually downloaded once, ever.
/// 3. Decoding downsamples straight to display size off the main thread (no full-size bitmaps in memory).
nonisolated final class ImagePipeline: @unchecked Sendable { // NSCache is thread-safe; other state is in Mutexes
    static let shared = ImagePipeline()

    private static let buckets = [160, 320, 640, 1024]

    private let memory = NSCache<NSString, UIImage>()
    private let palettes = NSCache<NSString, CoverPaletteBox>()
    private let inflight = Mutex<[String: Task<Data?, Never>]>([:])
    private let client = Mutex<APIClient?>(nil)
    private let lowData = Mutex(false)
    private let session: URLSession
    private let directory: URL

    private init() {
        memory.totalCostLimit = 48 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
        directory = URL.cachesDirectory.appending(path: "images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setClient(_ api: APIClient?) { client.withLock { $0 = api } }
    func setLowDataMode(_ on: Bool) { lowData.withLock { $0 = on } }

    /// Synchronous memory-cache hit, so cells that scroll back into view never flash a placeholder.
    func cachedImage(_ source: ImageSource, pixelWidth: Int) -> UIImage? {
        memory.object(forKey: memoryKey(source, pixelWidth) as NSString)
    }

    /// The smallest copy already on disk, without downloading anything (for Siri and Shortcuts).
    func cachedData(_ source: ImageSource) -> Data? {
        for bucket in Self.buckets {
            if let data = try? Data(contentsOf: file(source, bucket: bucket)) { return data }
        }
        return nil
    }

    @concurrent
    func image(_ source: ImageSource, pixelWidth: Int) async -> UIImage? {
        let key = memoryKey(source, pixelWidth) as NSString
        if let hit = memory.object(forKey: key) { return hit }
        guard let data = await data(for: source, minimumWidth: pixelWidth) else { return nil }
        guard let image = Self.downsample(data, to: pixelWidth) else { return nil }
        memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    @concurrent
    func palette(_ source: ImageSource) async -> CoverPalette? {
        let key = source.cacheKey as NSString
        if let hit = palettes.object(forKey: key) { return hit.palette }
        guard let data = await data(for: source, minimumWidth: 160),
              let palette = CoverPalette(imageData: data) else { return nil }
        palettes.setObject(CoverPaletteBox(palette), forKey: key)
        return palette
    }

    func clearDisk() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func diskSize() -> Int64 { FileManager.default.directorySize(directory) }

    // MARK: - Private

    private func memoryKey(_ source: ImageSource, _ width: Int) -> String {
        "\(source.cacheKey)@\(width)"
    }

    private func file(_ source: ImageSource, bucket: Int) -> URL {
        directory.appending(path: "\(source.cacheKey)_\(bucket)")
    }

    private func data(for source: ImageSource, minimumWidth: Int) async -> Data? {
        let wanted = Self.buckets.first { $0 >= minimumWidth } ?? Self.buckets.last!
        // Any cached bucket at least as large will do.
        for bucket in Self.buckets where bucket >= wanted {
            if let data = try? Data(contentsOf: file(source, bucket: bucket)) { return data }
        }
        let cap = lowData.withLock { $0 } ? 320 : Int.max
        let bucket = min(wanted, cap)
        // A smaller cached copy is better than nothing on a constrained network.
        if bucket < wanted, let data = try? Data(contentsOf: file(source, bucket: bucket)) { return data }

        let key = "\(source.cacheKey)_\(bucket)"
        let task: Task<Data?, Never> = inflight.withLock { tasks in
            if let existing = tasks[key] { return existing }
            let task = Task<Data?, Never> { await self.download(source, bucket: bucket) }
            tasks[key] = task
            return task
        }
        let result = await task.value
        inflight.withLock { $0[key] = nil }
        return result
    }

    private func download(_ source: ImageSource, bucket: Int) async -> Data? {
        guard let api = client.withLock({ $0 }) else { return nil }
        let request: URLRequest
        do {
            switch source {
            case let .cover(id, version): request = try await api.coverRequest(itemId: id, width: bucket, version: version)
            case let .author(id, version): request = try await api.authorImageRequest(authorId: id, width: bucket, version: version)
            }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
            try? data.write(to: file(source, bucket: bucket), options: .atomic)
            return data
        } catch {
            return nil
        }
    }

    static func downsample(_ data: Data, to pixelWidth: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, 1),
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

nonisolated final class CoverPaletteBox: Sendable {
    let palette: CoverPalette
    init(_ palette: CoverPalette) { self.palette = palette }
}
