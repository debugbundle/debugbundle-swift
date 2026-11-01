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
        let deadline = DebugBundleHTTPReply.deadline(timeout: config.requestTimeout)
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-DebugBundle-Evidence")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(config.projectToken)", forHTTPHeaderField: "Authorization")
        let body = try encoder.encode(DebugBundleBatchRequest(events: events))
        guard events.count <= 100, body.count <= DebugBundleIngestionWire.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        request.httpBody = body

        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw URLError(.timedOut) }
        let reply = try await DebugBundleHTTPReply.read(session: session, request: request, timeout: remaining)
        let (data, response) = (reply.data, reply.response)
        guard let httpResponse = response as? HTTPURLResponse else {
            return DebugBundleTransportResult(statusCode: 599)
        }

        let retryAfterValue = httpResponse.value(forHTTPHeaderField: "Retry-After")
        let retryAfter = retryAfterValue.flatMap(parseRetryAfter)
        let ingestionResponse = decodeIngestionResponse(from: data)
        var result = DebugBundleTransportResult(
            statusCode: httpResponse.statusCode,
            retryAfter: retryAfter,
            probeDirectives: ingestionResponse?.probeDirectives?.activeProbes,
            acknowledgement: ingestionResponse?.acknowledgement,
            acknowledgementRequired: (200 ..< 300).contains(httpResponse.statusCode)
        )
        result.evidenceCapabilities = ingestionResponse?.evidenceCapabilities
        return result
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
    var evidenceCapabilities: JSONValue?
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
        case evidenceCapabilities = "evidence_capabilities"
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
