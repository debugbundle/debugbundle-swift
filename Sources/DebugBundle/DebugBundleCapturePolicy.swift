import Foundation

public enum DebugBundleCapturePreset: String, Sendable, Codable {
    case minimal
    case balanced
    case investigative
}

public enum DebugBundleCaptureLogsMode: String, Sendable, Codable {
    case off
    case error
    case warning
    case info
}

public enum DebugBundleCaptureRequestEventsMode: String, Sendable, Codable {
    case off
    case failuresOnly = "failures_only"
    case filtered
    case all
}

public enum DebugBundleCaptureBreadcrumbsMode: String, Sendable, Codable {
    case localOnly = "local_only"
    case exceptionOnly = "exception_only"
    case standalone
}

public enum DebugBundleCaptureProbeEventsMode: String, Sendable, Codable {
    case bufferOnly = "buffer_only"
    case standaloneWhenActivated = "standalone_when_activated"
}

public struct DebugBundleRemoteCapturePolicy: Codable, Sendable, Equatable {
    public var preset: String
    public var captureLogs: String?
    public var captureRequestEvents: String?
    public var captureBreadcrumbs: String?
    public var captureProbeEvents: String?
    public var immediateClientErrorStatuses: [Int]
    public var immediateClientErrorPathRules: [DebugBundleImmediateClientErrorPathRule]

    public init(
        preset: String,
        captureLogs: String? = nil,
        captureRequestEvents: String? = nil,
        captureBreadcrumbs: String? = nil,
        captureProbeEvents: String? = nil,
        immediateClientErrorStatuses: [Int] = [],
        immediateClientErrorPathRules: [DebugBundleImmediateClientErrorPathRule] = []
    ) {
        self.preset = preset
        self.captureLogs = captureLogs
        self.captureRequestEvents = captureRequestEvents
        self.captureBreadcrumbs = captureBreadcrumbs
        self.captureProbeEvents = captureProbeEvents
        self.immediateClientErrorStatuses = immediateClientErrorStatuses
        self.immediateClientErrorPathRules = immediateClientErrorPathRules
    }

    enum CodingKeys: String, CodingKey {
        case preset
        case captureLogs = "capture_logs"
        case captureRequestEvents = "capture_request_events"
        case captureBreadcrumbs = "capture_breadcrumbs"
        case captureProbeEvents = "capture_probe_events"
        case immediateClientErrorStatuses = "immediate_client_error_statuses"
        case immediateClientErrorPathRules = "immediate_client_error_path_rules"
    }
}

public struct DebugBundleImmediateClientErrorPathRule: Codable, Sendable, Equatable {
    public var statusCode: Int
    public var pathPattern: String
    public var methods: [String]

    public init(statusCode: Int, pathPattern: String, methods: [String] = []) {
        self.statusCode = statusCode
        self.pathPattern = pathPattern
        self.methods = methods
    }

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case pathPattern = "path_pattern"
        case methods
    }
}

public struct DebugBundleCapturePolicy: Sendable, Equatable {
    public var preset: DebugBundleCapturePreset
    public var captureLogs: DebugBundleCaptureLogsMode
    public var captureRequestEvents: DebugBundleCaptureRequestEventsMode
    public var captureBreadcrumbs: DebugBundleCaptureBreadcrumbsMode
    public var captureProbeEvents: DebugBundleCaptureProbeEventsMode
    public var immediateClientErrorStatuses: Set<Int>
    public var immediateClientErrorPathRules: [DebugBundleImmediateClientErrorPathRule]

    public func capturesLog(_ level: DebugBundleLogLevel, localEnabled: Bool, localThreshold: DebugBundleLogLevel) -> Bool {
        guard localEnabled, level >= localThreshold else {
            return false
        }
        let policyThreshold: DebugBundleLogLevel
        switch captureLogs {
        case .off:
            return false
        case .error:
            policyThreshold = .error
        case .warning:
            policyThreshold = .warning
        case .info:
            policyThreshold = .info
        }
        return level >= policyThreshold
    }

    public func capturesStandaloneRequestEvent(_ responseStatus: Int?) -> Bool {
        capturesStandaloneRequestEvent(responseStatus, requestPath: nil, httpMethod: nil)
    }

    public func capturesStandaloneRequestEvent(_ responseStatus: Int?, requestPath: String?, httpMethod: String?) -> Bool {
        if isImmediateRequestIncident(responseStatus, requestPath: requestPath, httpMethod: httpMethod) {
            return true
        }
        switch captureRequestEvents {
        case .off:
            return false
        case .failuresOnly:
            return responseStatus.map { $0 >= 500 } ?? false
        case .filtered:
            return false
        case .all:
            return true
        }
    }

    public func capturesStandaloneBreadcrumbs() -> Bool {
        captureBreadcrumbs == .standalone
    }

    public func capturesStandaloneProbeEvents() -> Bool {
        captureProbeEvents == .standaloneWhenActivated
    }

    public func isImmediateRequestIncident(_ responseStatus: Int?) -> Bool {
        isImmediateRequestIncident(responseStatus, requestPath: nil, httpMethod: nil)
    }

    public func isImmediateRequestIncident(_ responseStatus: Int?, requestPath: String?, httpMethod: String?) -> Bool {
        guard let responseStatus else {
            return false
        }
        if responseStatus >= 500 {
            return true
        }
        if immediateClientErrorStatuses.contains(responseStatus) {
            return true
        }
        if matchesImmediateClientErrorPathRule(responseStatus, requestPath: requestPath, httpMethod: httpMethod) {
            return true
        }
        switch preset {
        case .minimal:
            return false
        case .balanced:
            return [408, 423, 424, 425, 429].contains(responseStatus)
        case .investigative:
            return [408, 409, 423, 424, 425, 429].contains(responseStatus)
        }
    }

    public static let minimal = DebugBundleCapturePolicy(
        preset: .minimal,
        captureLogs: .error,
        captureRequestEvents: .failuresOnly,
        captureBreadcrumbs: .localOnly,
        captureProbeEvents: .bufferOnly,
        immediateClientErrorStatuses: [],
        immediateClientErrorPathRules: []
    )

    public static let balanced = DebugBundleCapturePolicy(
        preset: .balanced,
        captureLogs: .warning,
        captureRequestEvents: .failuresOnly,
        captureBreadcrumbs: .exceptionOnly,
        captureProbeEvents: .bufferOnly,
        immediateClientErrorStatuses: [],
        immediateClientErrorPathRules: []
    )

    public static let investigative = DebugBundleCapturePolicy(
        preset: .investigative,
        captureLogs: .info,
        captureRequestEvents: .all,
        captureBreadcrumbs: .standalone,
        captureProbeEvents: .standaloneWhenActivated,
        immediateClientErrorStatuses: [401, 403, 409, 422],
        immediateClientErrorPathRules: []
    )

    public static func defaultWhenConfigFetchFails() -> DebugBundleCapturePolicy {
        .minimal
    }

    public static func defaultWhenResponseOmitsPolicy() -> DebugBundleCapturePolicy {
        .balanced
    }

    public static func fromRemotePolicy(_ policy: DebugBundleRemoteCapturePolicy?) -> DebugBundleCapturePolicy {
        guard let policy, let preset = DebugBundleCapturePreset(rawValue: policy.preset.lowercased()) else {
            return defaultWhenResponseOmitsPolicy()
        }

        let defaults = defaultsForPreset(preset)
        return DebugBundleCapturePolicy(
            preset: preset,
            captureLogs: DebugBundleCaptureLogsMode(rawValue: policy.captureLogs?.lowercased() ?? "") ?? defaults.captureLogs,
            captureRequestEvents: DebugBundleCaptureRequestEventsMode(rawValue: policy.captureRequestEvents?.lowercased() ?? "") ?? defaults.captureRequestEvents,
            captureBreadcrumbs: DebugBundleCaptureBreadcrumbsMode(rawValue: policy.captureBreadcrumbs?.lowercased() ?? "") ?? defaults.captureBreadcrumbs,
            captureProbeEvents: DebugBundleCaptureProbeEventsMode(rawValue: policy.captureProbeEvents?.lowercased() ?? "") ?? defaults.captureProbeEvents,
            immediateClientErrorStatuses: Set(policy.immediateClientErrorStatuses.filter { 400 ... 499 ~= $0 }),
            immediateClientErrorPathRules: policy.immediateClientErrorPathRules.filter { rule in
                400 ... 499 ~= rule.statusCode &&
                    isValidPathPattern(rule.pathPattern) &&
                    rule.methods.count <= 7 &&
                    rule.methods.allSatisfy { validMethods.contains($0.uppercased()) }
            }.map { rule in
                DebugBundleImmediateClientErrorPathRule(
                    statusCode: rule.statusCode,
                    pathPattern: rule.pathPattern,
                    methods: Array(Set(rule.methods.map { $0.uppercased() })).sorted()
                )
            }
        )
    }

    private func matchesImmediateClientErrorPathRule(_ responseStatus: Int, requestPath: String?, httpMethod: String?) -> Bool {
        guard 400 ... 499 ~= responseStatus, let requestPath else {
            return false
        }
        let normalizedPath = Self.normalizeRequestPath(requestPath)
        let normalizedMethod = httpMethod?.uppercased()
        return immediateClientErrorPathRules.contains { rule in
            guard rule.statusCode == responseStatus else {
                return false
            }
            if !rule.methods.isEmpty && (normalizedMethod == nil || !rule.methods.contains(normalizedMethod!)) {
                return false
            }
            if rule.pathPattern.hasSuffix("*") {
                return normalizedPath.hasPrefix(String(rule.pathPattern.dropLast()))
            }
            return normalizedPath == rule.pathPattern
        }
    }

    private static func defaultsForPreset(_ preset: DebugBundleCapturePreset) -> DebugBundleCapturePolicy {
        switch preset {
        case .minimal:
            return .minimal
        case .balanced:
            return .balanced
        case .investigative:
            return .investigative
        }
    }

    private static let validMethods: Set<String> = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    private static func isValidPathPattern(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256, value.hasPrefix("/"), !value.contains("?"), !value.contains("#") else {
            return false
        }
        guard let wildcardIndex = value.firstIndex(of: "*") else {
            return true
        }
        return wildcardIndex == value.index(before: value.endIndex)
    }

    private static func normalizeRequestPath(_ value: String) -> String {
        if let url = URL(string: value), !url.path.isEmpty {
            return url.path
        }
        let path = value.split(separator: "?", maxSplits: 1).first?.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        return path.hasPrefix("/") && !path.isEmpty ? path : "/"
    }
}
