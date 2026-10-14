import Foundation
import ImageIO
import UIKit
import WatchConnectivity

/// The phone's side of the watch remote. The watch is sent the latest snapshot as application
/// context, which the system delivers when it can and only ever keeps the newest of, so nothing is
/// sent unless the Shelf watch app is installed and something it shows has changed.
final class WatchLink {
    var onCommand: ((WatchCommand) -> Void)?

    private var session: WCSession?
    private var delegate: Delegate?
    private var last: NowPlayingSnapshot?
    private var hasSent = false
    private var thumbnail: (file: String, data: Data)?

    init() {
        guard WCSession.isSupported() else { return }
        let delegate = Delegate(
            onCommand: { [weak self] command in self?.onCommand?(command) },
            onStateChange: { [weak self] in self?.resend() }
        )
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        self.session = session
        self.delegate = delegate
    }

    func update(_ snapshot: NowPlayingSnapshot?) {
        if hasSent {
            switch (last, snapshot) {
            case (nil, nil): return
            case let (old?, new?) where !old.differsVisibly(from: new, tolerance: 5): return
            default: break
            }
        }
        last = snapshot
        send()
    }

    private func resend() {
        send()
    }

    private func send() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var context: [String: Any] = [:]
        if let last, let data = AppGroup.encode(last) {
            context[WatchMessage.snapshotKey] = data
            if let cover = coverThumbnail(for: last) { context[WatchMessage.coverKey] = cover }
        }
        do {
            try session.updateApplicationContext(context)
            hasSent = true
        } catch {}
    }

    /// A ~100 px JPEG of the exported cover, made once per cover.
    private func coverThumbnail(for snapshot: NowPlayingSnapshot) -> Data? {
        guard let file = snapshot.coverFile else { return nil }
        if let thumbnail, thumbnail.file == file { return thumbnail.data }
        guard let url = AppGroup.coverFile(named: file), let data = try? Data(contentsOf: url),
              let small = ImagePipeline.downsample(data, to: 120)?.jpegData(compressionQuality: 0.7) else { return nil }
        thumbnail = (file, small)
        return small
    }

    /// WatchConnectivity calls back on a background queue; everything is handed to the main actor.
    private final class Delegate: NSObject, WCSessionDelegate, Sendable {
        let onCommand: @MainActor @Sendable (WatchCommand) -> Void
        let onStateChange: @MainActor @Sendable () -> Void

        init(onCommand: @escaping @MainActor @Sendable (WatchCommand) -> Void, onStateChange: @escaping @MainActor @Sendable () -> Void) {
            self.onCommand = onCommand
            self.onStateChange = onStateChange
        }

        nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
            Task { @MainActor in self.onStateChange() }
        }

        nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

        /// After switching watches: activate again for the new one.
        nonisolated func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }

        /// The watch app was installed or removed.
        nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
            Task { @MainActor in self.onStateChange() }
        }

        nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
            handle(message)
        }

        nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
            handle(message)
            replyHandler([:])
        }

        private nonisolated func handle(_ message: [String: Any]) {
            guard let raw = message[WatchMessage.commandKey] as? String, let command = WatchCommand(rawValue: raw) else { return }
            Task { @MainActor in self.onCommand(command) }
        }
    }
}
