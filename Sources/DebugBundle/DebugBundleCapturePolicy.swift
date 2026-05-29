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

    public init(
        preset: String,
        captureLogs: String? = nil,
        captureRequestEvents: String? = nil,
        captureBreadcrumbs: String? = nil,
        captureProbeEvents: String? = nil,
        immediateClientErrorStatuses: [Int] = []
    ) {
        self.preset = preset
        self.captureLogs = captureLogs
        self.captureRequestEvents = captureRequestEvents
        self.captureBreadcrumbs = captureBreadcrumbs
        self.captureProbeEvents = captureProbeEvents
        self.immediateClientErrorStatuses = immediateClientErrorStatuses
    }

    enum CodingKeys: String, CodingKey {
        case preset
        case captureLogs = "capture_logs"
        case captureRequestEvents = "capture_request_events"
        case captureBreadcrumbs = "capture_breadcrumbs"
        case captureProbeEvents = "capture_probe_events"
        case immediateClientErrorStatuses = "immediate_client_error_statuses"
    }
}

public struct DebugBundleCapturePolicy: Sendable, Equatable {
    public var preset: DebugBundleCapturePreset
    public var captureLogs: DebugBundleCaptureLogsMode
    public var captureRequestEvents: DebugBundleCaptureRequestEventsMode
    public var captureBreadcrumbs: DebugBundleCaptureBreadcrumbsMode
    public var captureProbeEvents: DebugBundleCaptureProbeEventsMode
    public var immediateClientErrorStatuses: Set<Int>

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
        if isImmediateRequestIncident(responseStatus) {
            return true
        }
        switch captureRequestEvents {
        case .off:
            return false
        case .failuresOnly:
            return requestAnomalyCandidate(responseStatus)
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
        guard let responseStatus else {
            return false
        }
        if responseStatus >= 500 {
            return true
        }
        if immediateClientErrorStatuses.contains(responseStatus) {
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
        immediateClientErrorStatuses: []
    )

    public static let balanced = DebugBundleCapturePolicy(
        preset: .balanced,
        captureLogs: .warning,
        captureRequestEvents: .failuresOnly,
        captureBreadcrumbs: .exceptionOnly,
        captureProbeEvents: .bufferOnly,
        immediateClientErrorStatuses: []
    )

    public static let investigative = DebugBundleCapturePolicy(
        preset: .investigative,
        captureLogs: .info,
        captureRequestEvents: .all,
        captureBreadcrumbs: .standalone,
        captureProbeEvents: .standaloneWhenActivated,
        immediateClientErrorStatuses: [401, 403, 409, 422]
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
            immediateClientErrorStatuses: Set(policy.immediateClientErrorStatuses.filter { 400 ... 499 ~= $0 })
        )
    }

    private func requestAnomalyCandidate(_ responseStatus: Int?) -> Bool {
        guard let responseStatus, 400 ..< 500 ~= responseStatus else {
            return false
        }
        switch preset {
        case .minimal:
            return false
        case .balanced:
            return [400, 401, 403, 404, 409, 410, 422].contains(responseStatus)
        case .investigative:
            return [400, 401, 403, 404, 409, 410, 422].contains(responseStatus)
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
}