import Foundation

public final class DebugBundle {
    private static let lock = NSLock()
    private static var client: DebugBundleClient = DebugBundleClient(
        config: DebugBundleConfig(enabled: false),
        transport: DebugBundleNoopTransport()
    )

    public init(_ config: DebugBundleConfig) {
        Self.initialize(config)
    }

    public static var status: DebugBundleStatus {
        lock.withLock { client.status }
    }

    public static var lastEventAt: Date? {
        lock.withLock { client.lastEventAt }
    }

    @discardableResult
    public static func initialize(_ config: DebugBundleConfig, transport: DebugBundleTransporting = DebugBundleNoopTransport()) -> DebugBundleClient {
        lock.withLock {
            client = DebugBundleClient(config: config, transport: transport)
            return client
        }
    }

    public static func captureException(_ error: Error, context: [String: Any?] = [:]) {
        lock.withLock { client }.captureException(error, context: context)
    }

    public static func captureError(_ error: Error, context: [String: Any?] = [:]) {
        lock.withLock { client }.captureError(error, context: context)
    }

    public static func captureLog(_ message: String, level: DebugBundleLogLevel = .warning, context: [String: Any?] = [:]) {
        lock.withLock { client }.captureLog(message, level: level, context: context)
    }

    public static func captureRequest(_ request: DebugBundleRequestInfo, response: DebugBundleResponseInfo, context: [String: Any?] = [:]) {
        lock.withLock { client }.captureRequest(request, response: response, context: context)
    }

    public static func captureMessage(_ message: String, level: DebugBundleLogLevel = .warning, context: [String: Any?] = [:]) {
        lock.withLock { client }.captureMessage(message, level: level, context: context)
    }

    public static func setContext(_ key: String, value: Any?) {
        lock.withLock { client }.setContext(key, value: value)
    }

    public static func probe(_ label: String, data: Any?, options: ProbeOptions = ProbeOptions()) {
        lock.withLock { client }.probe(label, data: data, options: options)
    }

    public static func probe(_ label: String, options: ProbeOptions = ProbeOptions(), producer: () -> Any?) {
        lock.withLock { client }.probe(label, options: options, producer: producer)
    }

    public static func recordBreadcrumb(_ breadcrumbType: String, route: String? = nil, data: [String: Any?] = [:]) {
        lock.withLock { client }.recordBreadcrumb(breadcrumbType: breadcrumbType, route: route, data: data)
    }

    public static func recordScreen(_ screenName: String, previousScreen: String? = nil, source: String = "manual") {
        lock.withLock { client }.recordScreen(screenName, previousScreen: previousScreen, source: source)
    }

    public static func recordAppForeground() {
        lock.withLock { client }.recordAppForeground()
    }

    public static func recordAppBackground() {
        lock.withLock { client }.recordAppBackground()
    }

    public static func recordAction(_ actionType: String, targetType: String, resourceName: String? = nil) {
        lock.withLock { client }.recordAction(actionType, targetType: targetType, resourceName: resourceName)
    }

    public static func activateProbeTriggerToken(_ token: String) -> Bool {
        lock.withLock { client }.activateProbeTriggerToken(token)
    }

    public static func refreshRemoteConfig() async {
        await lock.withLock { client }.refreshRemoteConfig()
    }

    public static func captureAsync<T>(context: [String: Any?] = [:], operation: () async throws -> T) async throws -> T {
        try await lock.withLock { client }.captureAsync(context: context, operation: operation)
    }

    @discardableResult
    public static func captureTask<T: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) -> Task<T?, Never> {
        lock.withLock { client }.captureTask(priority: priority, operation: operation)
    }

    public static func flush() async {
        await lock.withLock { client }.flush()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}