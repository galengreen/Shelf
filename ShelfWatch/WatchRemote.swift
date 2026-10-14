import Foundation
import Observation
import UIKit
import WatchConnectivity

/// The watch's side of the remote. The phone pushes the latest snapshot as application context
/// (only when something changes); commands go back as messages, which wake the iPhone app if needed.
/// Nothing polls: progress between snapshots is drawn from dates by the system.
@Observable
final class WatchRemote {
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var cover: UIImage?
    private(set) var problem: String?

    @ObservationIgnored private var delegate: Delegate?

    init() {
        guard WCSession.isSupported() else { return }
        let delegate = Delegate { [weak self] snapshot, cover in
            self?.apply(snapshot, cover: cover)
        }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        self.delegate = delegate
    }

    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            problem = "Your iPhone isn't reachable."
            return
        }
        problem = nil
        session.sendMessage([WatchMessage.commandKey: command.rawValue], replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.problem = "Couldn't reach Shelf on your iPhone." }
        }
    }

    private func apply(_ data: Data?, cover: Data?) {
        snapshot = data.flatMap { AppGroup.read(NowPlayingSnapshot.self, from: $0) }
        self.cover = cover.flatMap(UIImage.init(data:))
        problem = nil
    }

    /// WatchConnectivity calls back on a background queue; only Sendable data crosses to the main actor.
    private final class Delegate: NSObject, WCSessionDelegate, Sendable {
        let onContext: @MainActor @Sendable (Data?, Data?) -> Void

        init(onContext: @escaping @MainActor @Sendable (Data?, Data?) -> Void) {
            self.onContext = onContext
        }

        nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
            // The last context the phone sent, from before the app was opened.
            deliver(session.receivedApplicationContext)
        }

        nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
            deliver(applicationContext)
        }

        private nonisolated func deliver(_ context: [String: Any]) {
            let snapshot = context[WatchMessage.snapshotKey] as? Data
            let cover = context[WatchMessage.coverKey] as? Data
            Task { @MainActor in self.onContext(snapshot, cover) }
        }
    }
}

extension AppGroup {
    /// Decodes a snapshot sent by the phone (same encoding as the App Group files).
    nonisolated static func read<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }
}
