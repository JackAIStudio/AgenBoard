import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var isCellular = false
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.agenboard.networkmonitor", qos: .utility)
    private var hasObservedInitialState = false
    private var previousWasConnected = true

    var onNetworkRestored: (@MainActor () -> Void)?

    private init() {
        startMonitoring()
    }

    deinit {
        monitor.cancel()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let currentlyConnected = (path.status == .satisfied)
                let currentlyCellular = path.usesInterfaceType(.cellular)
                let isRestored = !self.previousWasConnected && currentlyConnected

                self.isConnected = currentlyConnected
                self.isCellular = currentlyCellular
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained

                if self.hasObservedInitialState && isRestored {
                    self.onNetworkRestored?()
                }

                self.previousWasConnected = currentlyConnected
                self.hasObservedInitialState = true
            }
        }
        monitor.start(queue: monitorQueue)
    }
}
