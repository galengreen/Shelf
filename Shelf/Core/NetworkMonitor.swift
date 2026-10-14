import Foundation
import Network
import Observation

@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    /// Cellular or personal hotspot.
    private(set) var isExpensive = false
    /// Low Data Mode is on.
    private(set) var isConstrained = false

    /// Called on the main actor whenever connectivity comes back.
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                self.isExpensive = expensive
                self.isConstrained = constrained
                if online && wasOffline { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor", qos: .utility))
    }
}
