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
        request.httpBody = try encoder.encode(DebugBundleBatchRequest(events: events))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return DebugBundleTransportResult(statusCode: 599)
        }

        let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = retryAfterValue.flatMap(parseRetryAfter)
        let ingestionResponse = decodeIngestionResponse(from: data)
        return DebugBundleTransportResult(
            statusCode: httpResponse.statusCode,
            retryAfter: retryAfter,
            probeDirectives: ingestionResponse?.probeDirectives?.activeProbes,
            acknowledgement: ingestionResponse?.acknowledgement,
            acknowledgementRequired: (200 ..< 300).contains(httpResponse.statusCode)
        )
    }

    private func parseRetryAfter(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value) {
            return seconds.isFinite ? min(max(0, seconds), 300) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone
        formatter.twoDigitStartDate = calendar.date(byAdding: .year, value: -50, to: Date())
        for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return min(max(0, date.timeIntervalSinceNow), 300)
            }
        }
        return nil
    }

    private func decodeIngestionResponse(from data: Data) -> DebugBundleIngestionResponse? {
        guard !data.isEmpty else {
            return nil
        }
        return try? decoder.decode(DebugBundleIngestionResponse.self, from: data)
    }
}

private struct DebugBundleIngestionResponse: Codable {
    var accepted: Int?
    var rejected: Int?
    var errors: [DebugBundleIngestionError]?
    var probeDirectives: DebugBundleIngestionProbeDirectives?

    var acknowledgement: DebugBundleIngestionAcknowledgement? {
        guard let accepted, let rejected, let errors else {
            return nil
        }
        return DebugBundleIngestionAcknowledgement(
            accepted: accepted,
            rejected: rejected,
            errors: errors
        )
    }

    enum CodingKeys: String, CodingKey {
        case accepted
        case rejected
        case errors
        case probeDirectives = "probe_directives"
    }
}

private struct DebugBundleIngestionProbeDirectives: Codable {
    var activeProbes: [DebugBundleRemoteProbeDirective]

    enum CodingKeys: String, CodingKey {
        case activeProbes = "active_probes"
    }
}
