import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DebugBundleRemoteConfigRequest: Sendable {
    public var projectToken: String
    public var endpoint: URL
    public var timeout: TimeInterval
    public var eTag: String?

    public init(projectToken: String, endpoint: URL, timeout: TimeInterval, eTag: String? = nil) {
        self.projectToken = projectToken
        self.endpoint = endpoint
        self.timeout = timeout
        self.eTag = eTag
    }
}

public enum DebugBundleRemoteConfigResult: Sendable, Equatable {
    case loaded(DebugBundleRemoteConfigResponse, eTag: String?)
    case notModified(eTag: String?)
    case failed
}

public protocol DebugBundleRemoteConfigClienting {
    func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult
}

public struct DebugBundleRemoteConfigResponse: Codable, Sendable, Equatable {
    public var probesEnabled: Bool
    public var remoteProbesEnabled: Bool
    public var activeProbes: [DebugBundleRemoteProbeDirective]
    public var pollIntervalMillis: Int
    public var triggerTokenKey: String?
    public var capturePolicy: DebugBundleRemoteCapturePolicy?

    public init(
        probesEnabled: Bool = true,
        remoteProbesEnabled: Bool = false,
        activeProbes: [DebugBundleRemoteProbeDirective] = [],
        pollIntervalMillis: Int = 0,
        triggerTokenKey: String? = nil,
        capturePolicy: DebugBundleRemoteCapturePolicy? = nil
    ) {
        self.probesEnabled = probesEnabled
        self.remoteProbesEnabled = remoteProbesEnabled
        self.activeProbes = activeProbes
        self.pollIntervalMillis = pollIntervalMillis
        self.triggerTokenKey = triggerTokenKey
        self.capturePolicy = capturePolicy
    }

    enum CodingKeys: String, CodingKey {
        case probesEnabled = "probes_enabled"
        case remoteProbesEnabled = "remote_probes_enabled"
        case activeProbes = "active_probes"
        case pollIntervalMillis = "poll_interval_ms"
        case triggerTokenKey = "trigger_token_key"
        case capturePolicy = "capture_policy"
    }
}

public struct DebugBundleHTTPRemoteConfigClient: DebugBundleRemoteConfigClienting {
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(request: DebugBundleRemoteConfigRequest) async -> DebugBundleRemoteConfigResult {
        var urlRequest = URLRequest(url: sdkConfigURL(for: request.endpoint))
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.setValue("Bearer \(request.projectToken)", forHTTPHeaderField: "Authorization")
        if let eTag = request.eTag {
            urlRequest.setValue(eTag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed
            }
            switch httpResponse.statusCode {
            case 304:
                return .notModified(eTag: httpResponse.value(forHTTPHeaderField: "ETag"))
            case 200 ..< 300:
                let decoded = try decoder.decode(DebugBundleRemoteConfigResponse.self, from: data)
                return .loaded(decoded, eTag: httpResponse.value(forHTTPHeaderField: "ETag"))
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private func sdkConfigURL(for endpoint: URL) -> URL {
        let endpointString = endpoint.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if endpointString.hasSuffix("/v1/events") {
            return URL(string: String(endpointString.dropLast("/v1/events".count)) + "/v1/sdk/config") ?? endpoint
        }
        if endpointString.hasSuffix("/events") {
            return URL(string: String(endpointString.dropLast("/events".count)) + "/sdk/config") ?? endpoint
        }
        return URL(string: endpointString + "/sdk/config") ?? endpoint
    }
}