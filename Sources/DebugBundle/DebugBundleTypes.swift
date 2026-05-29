import Foundation

public enum DebugBundleStatus: String, Sendable {
    case healthy
    case degraded
    case disconnected
}

public enum DebugBundleLogLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case debug = 10
    case info = 20
    case warning = 30
    case error = 40
    case critical = 50

    public static func < (lhs: DebugBundleLogLevel, rhs: DebugBundleLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ProbeOptions: Sendable, Equatable {
    public var heavy: Bool

    public init(heavy: Bool = false) {
        self.heavy = heavy
    }
}

public struct DebugBundleRequestInfo: Sendable, Equatable {
    public var method: String
    public var url: String
    public var routeTemplate: String?
    public var headers: [String: String]
    public var traceId: String?

    public init(
        method: String,
        url: String,
        routeTemplate: String? = nil,
        headers: [String: String] = [:],
        traceId: String? = nil
    ) {
        self.method = method
        self.url = url
        self.routeTemplate = routeTemplate
        self.headers = headers
        self.traceId = traceId
    }
}

public struct DebugBundleResponseInfo: Sendable, Equatable {
    public var statusCode: Int
    public var durationMillis: Int?
    public var headers: [String: String]

    public init(statusCode: Int, durationMillis: Int? = nil, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.durationMillis = durationMillis
        self.headers = headers
    }
}

public struct DebugBundleBreadcrumb: Codable, Sendable, Equatable {
    public var occurredAt: String
    public var breadcrumbType: String
    public var route: String?
    public var data: [String: JSONValue]

    public init(occurredAt: String, breadcrumbType: String, route: String? = nil, data: [String: JSONValue] = [:]) {
        self.occurredAt = occurredAt
        self.breadcrumbType = breadcrumbType
        self.route = route
        self.data = data
    }

    public var payload: [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "breadcrumb_type": .string(breadcrumbType),
            "occurred_at": .string(occurredAt),
            "data": .object(data)
        ]
        if let route {
            payload["route"] = .string(route)
        }
        return payload
    }
}

public struct DebugBundleDeviceContext: Codable, Sendable, Equatable {
    public var appVersion: String?
    public var buildNumber: String?
    public var releaseChannel: String?
    public var osName: String?
    public var osVersion: String?
    public var manufacturer: String?
    public var model: String?
    public var deviceType: String?
    public var screenResolution: String?
    public var locale: String?
    public var timezone: String?
    public var networkConnectionType: String?
    public var batteryLevel: Double?
    public var charging: Bool?
    public var freeDiskBytes: Int64?
    public var freeMemoryBytes: Int64?
    public var jailbroken: Bool?

    public init(
        appVersion: String? = nil,
        buildNumber: String? = nil,
        releaseChannel: String? = nil,
        osName: String? = nil,
        osVersion: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        deviceType: String? = nil,
        screenResolution: String? = nil,
        locale: String? = nil,
        timezone: String? = nil,
        networkConnectionType: String? = nil,
        batteryLevel: Double? = nil,
        charging: Bool? = nil,
        freeDiskBytes: Int64? = nil,
        freeMemoryBytes: Int64? = nil,
        jailbroken: Bool? = nil
    ) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.releaseChannel = releaseChannel
        self.osName = osName
        self.osVersion = osVersion
        self.manufacturer = manufacturer
        self.model = model
        self.deviceType = deviceType
        self.screenResolution = screenResolution
        self.locale = locale
        self.timezone = timezone
        self.networkConnectionType = networkConnectionType
        self.batteryLevel = batteryLevel
        self.charging = charging
        self.freeDiskBytes = freeDiskBytes
        self.freeMemoryBytes = freeMemoryBytes
        self.jailbroken = jailbroken
    }
}

public struct DebugBundleCorrelation: Codable, Sendable, Equatable {
    public var traceId: String?

    public init(traceId: String? = nil) {
        self.traceId = traceId
    }
}

public struct DebugBundleEventEnvelope: Codable, Sendable, Equatable {
    public var sdkName: String
    public var sdkVersion: String
    public var service: String
    public var environment: String
    public var eventType: String
    public var occurredAt: String
    public var correlation: DebugBundleCorrelation?
    public var payload: [String: JSONValue]
    public var device: DebugBundleDeviceContext
    public var releaseChannel: String
    public var appVersion: String?
    public var buildNumber: String?

    public init(
        sdkName: String,
        sdkVersion: String,
        service: String,
        environment: String,
        eventType: String,
        occurredAt: String,
        correlation: DebugBundleCorrelation?,
        payload: [String: JSONValue],
        device: DebugBundleDeviceContext,
        releaseChannel: String,
        appVersion: String?,
        buildNumber: String?
    ) {
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.service = service
        self.environment = environment
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.correlation = correlation
        self.payload = payload
        self.device = device
        self.releaseChannel = releaseChannel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    enum CodingKeys: String, CodingKey {
        case sdkName = "sdk_name"
        case sdkVersion = "sdk_version"
        case service
        case environment
        case eventType = "event_type"
        case occurredAt = "occurred_at"
        case correlation
        case payload
        case device
        case releaseChannel = "release_channel"
        case appVersion = "app_version"
        case buildNumber = "build_number"
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public enum DebugBundleEventType {
    public static let frontendException = "frontend_exception"
    public static let frontendBreadcrumb = "frontend_breadcrumb"
    public static let requestEvent = "request_event"
    public static let logEvent = "log_event"
    public static let errorSuppressed = "error_suppressed"
    public static let probeEvent = "probe_event"
}

public struct DebugBundleTransportResult: Sendable, Equatable {
    public var statusCode: Int
    public var retryAfter: TimeInterval?
    public var probeDirectives: [DebugBundleRemoteProbeDirective]?

    public init(
        statusCode: Int,
        retryAfter: TimeInterval? = nil,
        probeDirectives: [DebugBundleRemoteProbeDirective]? = nil
    ) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.probeDirectives = probeDirectives
    }
}

public protocol DebugBundleTransporting {
    func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult
}

public struct DebugBundleNoopTransport: DebugBundleTransporting {
    public init() {}

    public func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        DebugBundleTransportResult(statusCode: 204)
    }
}

struct DebugBundleBatchRequest: Codable {
    var batch: [DebugBundleEventEnvelope]
}