import Foundation

public enum DebugBundleFileProtection: String, Sendable {
    case complete
    case completeUnlessOpen
    case completeUntilFirstUserAuthentication
    case none
}

public struct DebugBundleConfig: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.debugbundle.com/v1/events")!

    public static let defaultRedactFields: Set<String> = [
        "password",
        "secret",
        "token",
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "private_key",
        "passwd",
        "card_number",
        "cvv",
        "cvc",
        "pin",
        "expiry",
        "phone",
        "bearer",
        "session_id",
        "otp",
        "verification_code",
        "authorization",
        "cookie",
        "ssn"
    ]

    public static let defaultHeaderAllowlist: Set<String> = [
        "user-agent",
        "content-type",
        "accept",
        "x-request-id",
        "x-correlation-id",
        "x-debugbundle-trace-id",
        "traceparent"
    ]

    public var projectToken: String
    public var enabled: Bool
    public var environment: String
    public var service: String
    public var endpoint: URL
    public var batchSize: Int
    public var flushInterval: TimeInterval
    public var sampleRate: Double
    public var sessionSampleRate: Double
    public var requestTimeout: TimeInterval
    public var releaseChannel: String
    public var appVersion: String?
    public var buildNumber: String?
    public var maxEventsPerSession: Int
    public var maxBreadcrumbs: Int
    public var captureScreens: Bool
    public var captureActions: Bool
    public var captureNetwork: Bool
    public var captureLogs: Bool
    public var logLevel: DebugBundleLogLevel
    public var tracePropagationTargets: [String]
    public var offlineQueueMaxEvents: Int
    public var offlineQueueMaxBytes: Int
    public var offlineQueueTtl: TimeInterval
    public var fileProtection: DebugBundleFileProtection
    public var offlineQueueURL: URL?
    public var maxProbeLabels: Int
    public var maxProbeEntriesPerLabel: Int
    public var probeFlushOnError: Bool
    public var redactFields: Set<String>
    public var headerAllowlist: Set<String>
    public var sdkVersion: String

    public init(
        projectToken: String = "",
        enabled: Bool = true,
        environment: String = "production",
        service: String = "ios-app",
        endpoint: URL = DebugBundleConfig.defaultEndpoint,
        batchSize: Int = 10,
        flushInterval: TimeInterval = 3,
        sampleRate: Double = 1.0,
        sessionSampleRate: Double = 1.0,
        requestTimeout: TimeInterval = 5,
        releaseChannel: String = "production",
        appVersion: String? = nil,
        buildNumber: String? = nil,
        maxEventsPerSession: Int = 100,
        maxBreadcrumbs: Int = 20,
        captureScreens: Bool = true,
        captureActions: Bool = false,
        captureNetwork: Bool = true,
        captureLogs: Bool = true,
        logLevel: DebugBundleLogLevel = .warning,
        tracePropagationTargets: [String] = [],
        offlineQueueMaxEvents: Int = 500,
        offlineQueueMaxBytes: Int = 5 * 1024 * 1024,
        offlineQueueTtl: TimeInterval = 72 * 60 * 60,
        fileProtection: DebugBundleFileProtection = .completeUntilFirstUserAuthentication,
        offlineQueueURL: URL? = nil,
        maxProbeLabels: Int = 50,
        maxProbeEntriesPerLabel: Int = 10,
        probeFlushOnError: Bool = true,
        redactFields: Set<String> = DebugBundleConfig.defaultRedactFields,
        headerAllowlist: Set<String> = DebugBundleConfig.defaultHeaderAllowlist,
        sdkVersion: String = "1.0.0"
    ) {
        self.projectToken = projectToken
        self.enabled = enabled
        self.environment = environment
        self.service = service
        self.endpoint = endpoint
        self.batchSize = max(1, batchSize)
        self.flushInterval = max(0.1, flushInterval)
        self.sampleRate = min(max(0, sampleRate), 1)
        self.sessionSampleRate = min(max(0, sessionSampleRate), 1)
        self.requestTimeout = max(0.1, requestTimeout)
        self.releaseChannel = releaseChannel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.maxEventsPerSession = max(1, maxEventsPerSession)
        self.maxBreadcrumbs = max(1, maxBreadcrumbs)
        self.captureScreens = captureScreens
        self.captureActions = captureActions
        self.captureNetwork = captureNetwork
        self.captureLogs = captureLogs
        self.logLevel = logLevel
        self.tracePropagationTargets = tracePropagationTargets
        self.offlineQueueMaxEvents = max(1, offlineQueueMaxEvents)
        self.offlineQueueMaxBytes = max(1024, offlineQueueMaxBytes)
        self.offlineQueueTtl = max(60, offlineQueueTtl)
        self.fileProtection = fileProtection
        self.offlineQueueURL = offlineQueueURL
        self.maxProbeLabels = max(1, maxProbeLabels)
        self.maxProbeEntriesPerLabel = max(1, maxProbeEntriesPerLabel)
        self.probeFlushOnError = probeFlushOnError
        self.redactFields = redactFields
        self.headerAllowlist = headerAllowlist.map { $0.lowercased() }.reduce(into: Set<String>()) { result, value in
            result.insert(value)
        }
        self.sdkVersion = sdkVersion
    }
}
