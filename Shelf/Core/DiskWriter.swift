import Foundation

/// Serial background writer: writes land in the order they were requested, off the main thread.
nonisolated enum DiskWriter {
    private static let queue = DispatchQueue(label: "disk-writer", qos: .utility)

    static func write<T: Encodable & Sendable>(_ value: T, to file: URL) {
        queue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
        }
    }

    static func remove(_ file: URL) {
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    static func read<T: Decodable>(_ type: T.Type, from file: URL) -> T? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
