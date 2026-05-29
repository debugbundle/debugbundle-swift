import Dispatch
import Foundation

public enum DebugBundleConnectivityStatus: Sendable {
    case connected
    case disconnected
    case unknown
}

public protocol DebugBundleConnectivityMonitoring: AnyObject {
    var currentStatus: DebugBundleConnectivityStatus { get }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?)
}

#if canImport(Network)
import Network

public final class DebugBundleNWPathConnectivityMonitor: DebugBundleConnectivityMonitoring {
    private let monitor: NWPathMonitor
    private let stateQueue = DispatchQueue(label: "com.debugbundle.connectivity.state")
    private var statusValue: DebugBundleConnectivityStatus = .unknown
    private var handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?

    public init(queue: DispatchQueue = DispatchQueue(label: "com.debugbundle.connectivity.monitor")) {
        self.monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleStatus(path.status == .satisfied ? .connected : .disconnected)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public var currentStatus: DebugBundleConnectivityStatus {
        stateQueue.sync { statusValue }
    }

    public func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {
        stateQueue.sync {
            self.handler = handler
        }
    }

    private func handleStatus(_ status: DebugBundleConnectivityStatus) {
        let handler = stateQueue.sync {
            statusValue = status
            return self.handler
        }
        handler?(status)
    }
}
#else
public final class DebugBundleNWPathConnectivityMonitor: DebugBundleConnectivityMonitoring {
    public init(queue: DispatchQueue = DispatchQueue(label: "com.debugbundle.connectivity.monitor")) {}

    public var currentStatus: DebugBundleConnectivityStatus {
        .unknown
    }

    public func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}
#endif