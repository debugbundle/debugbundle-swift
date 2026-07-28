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

    public init(from decoder: Decoder) throws {
        let canonical = try decoder.container(keyedBy: CodingKeys.self)
        if let traceId = try canonical.decodeIfPresent(String.self, forKey: .traceId) {
            self.traceId = traceId
            return
        }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        traceId = try legacy.decodeIfPresent(String.self, forKey: .traceId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(traceId, forKey: .traceId)
    }

    private enum CodingKeys: String, CodingKey {
        case traceId = "trace_id"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case traceId
    }
}

public struct DebugBundleEventEnvelope: Codable, Sendable, Equatable {
    public var schemaVersion: String
    public var eventId: String
    public var sdkName: String
    public var sdkVersion: String
    public var service: String
    public var serviceRuntime: String
    public var serviceFramework: String?
    public var environment: String
    public var eventType: String
    public var occurredAt: String
    public var correlation: DebugBundleCorrelation?
    public var context: [String: JSONValue]?
    public var payload: [String: JSONValue]
    /**
     Retained as a source-compatible inspection surface. Canonical delivery
     serializes device data inside the event payload.
     */
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
        buildNumber: String?,
        schemaVersion: String = "2026-03-01",
        eventId: String = UUID().uuidString.lowercased(),
        serviceRuntime: String = "swift",
        serviceFramework: String? = nil,
        context: [String: JSONValue]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.service = service
        self.serviceRuntime = serviceRuntime
        self.serviceFramework = serviceFramework
        self.environment = environment
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.correlation = correlation
        self.context = context
        self.payload = payload
        self.device = device
        self.releaseChannel = releaseChannel
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sdkName = try container.decode(String.self, forKey: .sdkName)
        sdkVersion = try container.decode(String.self, forKey: .sdkVersion)
        if let descriptor = try? container.decode(DebugBundleServiceDescriptor.self, forKey: .service) {
            service = descriptor.name
            environment = descriptor.environment
            serviceRuntime = descriptor.runtime ?? "swift"
            serviceFramework = descriptor.framework
        } else {
            service = try container.decode(String.self, forKey: .service)
            environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? "production"
            serviceRuntime = "swift"
            serviceFramework = nil
        }
        eventType = try container.decode(String.self, forKey: .eventType)
        occurredAt = try container.decode(String.self, forKey: .occurredAt)
        correlation = try container.decodeIfPresent(DebugBundleCorrelation.self, forKey: .correlation)
        context = try container.decodeIfPresent([String: JSONValue].self, forKey: .context)
        let decodedPayload = try container.decode([String: JSONValue].self, forKey: .payload)
        let decodedDevice = try container.decodeIfPresent(DebugBundleDeviceContext.self, forKey: .device)
            ?? swiftDeviceContext(fromCanonicalPayload: decodedPayload)
            ?? DebugBundleDeviceContext()
        releaseChannel = try container.decodeIfPresent(String.self, forKey: .releaseChannel)
            ?? decodedDevice.releaseChannel
            ?? "production"
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
            ?? decodedDevice.appVersion
        buildNumber = try container.decodeIfPresent(String.self, forKey: .buildNumber)
            ?? decodedDevice.buildNumber
        schemaVersion = try container.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "2026-03-01"
        eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
            ?? deterministicLegacySwiftEventId(
                sdkName: sdkName,
                eventType: eventType,
                service: service,
                occurredAt: occurredAt,
                payload: decodedPayload
            )
        device = decodedDevice
        let canonical = canonicalizeSwiftEvent(
            eventType: eventType,
            payload: decodedPayload,
            device: decodedDevice,
            occurredAt: occurredAt
        )
        payload = canonical.payload
        context = context ?? canonical.context
    }

    public func encode(to encoder: Encoder) throws {
        let canonical = canonicalizeSwiftEvent(
            eventType: eventType,
            payload: payload,
            device: device,
            occurredAt: occurredAt
        )
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(sdkName, forKey: .sdkName)
        try container.encode(sdkVersion, forKey: .sdkVersion)
        try container.encode(
            DebugBundleServiceDescriptor(
                name: service,
                environment: environment,
                runtime: serviceRuntime,
                framework: serviceFramework
            ),
            forKey: .service
        )
        try container.encode(eventType, forKey: .eventType)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encodeIfPresent(correlation, forKey: .correlation)
        try container.encodeIfPresent(context ?? canonical.context, forKey: .context)
        try container.encode(canonical.payload, forKey: .payload)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventId = "event_id"
        case sdkName = "sdk_name"
        case sdkVersion = "sdk_version"
        case service
        case environment
        case eventType = "event_type"
        case occurredAt = "occurred_at"
        case correlation
        case context
        case payload
        case device
        case releaseChannel = "release_channel"
        case appVersion = "app_version"
        case buildNumber = "build_number"
    }
}

public struct DebugBundleServiceDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var environment: String
    public var runtime: String?
    public var framework: String?

    public init(name: String, environment: String, runtime: String? = "swift", framework: String? = nil) {
        self.name = name
        self.environment = environment
        self.runtime = runtime
        self.framework = framework
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
    public var acknowledgement: DebugBundleIngestionAcknowledgement?
    public var acknowledgementRequired: Bool

    public init(
        statusCode: Int,
        retryAfter: TimeInterval? = nil,
        probeDirectives: [DebugBundleRemoteProbeDirective]? = nil,
        acknowledgement: DebugBundleIngestionAcknowledgement? = nil,
        acknowledgementRequired: Bool = false
    ) {
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.probeDirectives = probeDirectives
        self.acknowledgement = acknowledgement
        self.acknowledgementRequired = acknowledgementRequired
    }
}

public struct DebugBundleIngestionError: Codable, Sendable, Equatable {
    public var index: Int
    public var reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

public struct DebugBundleIngestionAcknowledgement: Codable, Sendable, Equatable {
    public var accepted: Int
    public var rejected: Int
    public var errors: [DebugBundleIngestionError]

    public init(accepted: Int, rejected: Int, errors: [DebugBundleIngestionError] = []) {
        self.accepted = accepted
        self.rejected = rejected
        self.errors = errors
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
    var events: [DebugBundleEventEnvelope]
}
