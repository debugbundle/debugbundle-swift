import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DebugBundleHTTPTransport: DebugBundleTransporting {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(events: [DebugBundleEventEnvelope], config: DebugBundleConfig) async throws -> DebugBundleTransportResult {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.projectToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(DebugBundleBatchRequest(batch: events))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return DebugBundleTransportResult(statusCode: 599)
        }

        let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = retryAfterValue.flatMap(TimeInterval.init).map { min($0, 300) }
        let probeDirectives = decodeProbeDirectives(from: data)
        return DebugBundleTransportResult(statusCode: httpResponse.statusCode, retryAfter: retryAfter, probeDirectives: probeDirectives)
    }

    private func decodeProbeDirectives(from data: Data) -> [DebugBundleRemoteProbeDirective]? {
        guard !data.isEmpty else {
            return nil
        }
        return try? decoder.decode(DebugBundleIngestionResponse.self, from: data).probeDirectives
    }
}

private struct DebugBundleIngestionResponse: Codable {
    var probeDirectives: [DebugBundleRemoteProbeDirective]?

    enum CodingKeys: String, CodingKey {
        case probeDirectives = "probe_directives"
    }
}