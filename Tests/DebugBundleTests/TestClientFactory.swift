import Foundation
@testable import DebugBundle

// Unit clients use independent storage and no external configuration request.
// Tests with an explicit queue URL still exercise the real file store.
func makeIsolatedClient(
    config: DebugBundleConfig,
    transport: DebugBundleTransporting? = nil,
    queueStore: DebugBundleQueueStoring? = nil,
    remoteConfigClient: DebugBundleRemoteConfigClienting? = nil,
    connectivityMonitor: DebugBundleConnectivityMonitoring? = nil,
    clock: @escaping () -> Date = Date.init,
    sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
    random: @escaping () -> Double = { Double.random(in: 0...1) },
    deviceContextProvider: (() -> DebugBundleDeviceContext)? = nil
) -> DebugBundleClient {
    DebugBundleClient(
        config: config,
        transport: transport,
        queueStore: queueStore ?? (config.offlineQueueURL == nil ? IsolatedQueueStore() : nil),
        remoteConfigClient: remoteConfigClient ?? NoopRemoteConfigClient(),
        connectivityMonitor: connectivityMonitor ?? ConnectedTestMonitor(),
        clock: clock,
        sleep: sleep,
        random: random,
        deviceContextProvider: deviceContextProvider
    )
}

private final class IsolatedQueueStore: DebugBundleQueueStoring {
    private let lock = NSLock()
    private var events: [DebugBundleEventEnvelope] = []

    func load(now: Date, ttl: TimeInterval) -> [DebugBundleEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func persist(_ events: [DebugBundleEventEnvelope]) {
        lock.lock()
        defer { lock.unlock() }
        self.events = events
    }
}

private struct NoopRemoteConfigClient: DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult { .failed }
}

private final class ConnectedTestMonitor: DebugBundleConnectivityMonitoring {
    var currentStatus: DebugBundleConnectivityStatus { .connected }
    func setUpdateHandler(_ handler: (@Sendable (DebugBundleConnectivityStatus) -> Void)?) {}
}
