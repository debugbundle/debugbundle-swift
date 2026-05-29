import DebugBundle
import Foundation

public final class DebugBundleURLProtocol: URLProtocol, URLSessionDataDelegate {
    static let handledKey = "DebugBundleURLProtocolHandled"
    static let configurationHeaderName = "X-DebugBundle-Internal-Trace-Targets"

    private var session: URLSession?
    private var activeTask: URLSessionDataTask?
    private var startedAt = Date()
    private var forwardedRequest: URLRequest?
    private var receivedResponse: URLResponse?

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return URLProtocol.property(forKey: handledKey, in: request) == nil
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        let tracePropagationTargets = Self.decodeTracePropagationTargets(from: request)
        var requestToSend = Self.removingInternalConfiguration(from: request)
        let mutableRequest = (requestToSend as NSURLRequest).mutableCopy() as? NSMutableURLRequest ?? NSMutableURLRequest(url: requestToSend.url!)
        mutableRequest.allHTTPHeaderFields = requestToSend.allHTTPHeaderFields
        if let httpMethod = requestToSend.httpMethod {
            mutableRequest.httpMethod = httpMethod
        }
        mutableRequest.httpBody = requestToSend.httpBody
        mutableRequest.httpBodyStream = requestToSend.httpBodyStream
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        requestToSend = mutableRequest as URLRequest
        requestToSend = requestToSend.debugBundleInstrumented(tracePropagationTargets: tracePropagationTargets)

        forwardedRequest = requestToSend
        startedAt = Date()

        let configuration = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        activeTask = session?.dataTask(with: requestToSend)
        activeTask?.resume()
    }

    override public func stopLoading() {
        activeTask?.cancel()
        session?.invalidateAndCancel()
        activeTask = nil
        session = nil
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        receivedResponse = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        return .allow
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        recordRequest(using: error)

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }

        session.finishTasksAndInvalidate()
        self.activeTask = nil
        self.session = nil
    }

    private func recordRequest(using error: Error?) {
        guard let forwardedRequest else {
            return
        }

        let durationMillis = Int(Date().timeIntervalSince(startedAt) * 1000)
        let traceID = forwardedRequest.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName)
        let requestInfo = DebugBundleRequestInfo(
            method: forwardedRequest.httpMethod ?? "GET",
            url: forwardedRequest.url?.absoluteString ?? "",
            headers: forwardedRequest.allHTTPHeaderFields ?? [:],
            traceId: traceID
        )

        if let httpResponse = receivedResponse as? HTTPURLResponse {
            DebugBundle.captureRequest(
                requestInfo,
                response: DebugBundleResponseInfo(
                    statusCode: httpResponse.statusCode,
                    durationMillis: durationMillis,
                    headers: httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                        guard let key = entry.key as? String else {
                            return
                        }
                        result[key] = String(describing: entry.value)
                    }
                )
            )
            return
        }

        if error != nil {
            DebugBundle.captureRequest(
                requestInfo,
                response: DebugBundleResponseInfo(statusCode: 0, durationMillis: durationMillis)
            )
        }
    }

    static func encodeTracePropagationTargets(_ targets: [DebugBundleTracePropagationTarget]) -> String {
        targets.map { target in
            switch target.matchKind {
            case let .host(value):
                return "host:\(value)"
            case let .prefix(value):
                return "prefix:\(value)"
            }
        }.joined(separator: ",")
    }

    static func decodeTracePropagationTargets(from request: URLRequest) -> [DebugBundleTracePropagationTarget] {
        let headerValue = request.allHTTPHeaderFields?.first(where: { $0.key.lowercased() == configurationHeaderName.lowercased() })?.value
        guard let headerValue, !headerValue.isEmpty else {
            return []
        }

        return headerValue.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                return nil
            }
            switch parts[0] {
            case "host":
                return .host(String(parts[1]))
            case "prefix":
                return .prefix(String(parts[1]))
            default:
                return nil
            }
        }
    }

    static func removingInternalConfiguration(from request: URLRequest) -> URLRequest {
        var sanitizedRequest = request
        request.allHTTPHeaderFields?.forEach { header, _ in
            if header.lowercased() == configurationHeaderName.lowercased() {
                sanitizedRequest.setValue(nil, forHTTPHeaderField: header)
            }
        }
        return sanitizedRequest
    }
}

public struct DebugBundleTracePropagationTarget: Sendable, Equatable {
    public enum MatchKind: Sendable, Equatable {
        case host(String)
        case prefix(String)
    }

    let matchKind: MatchKind

    public static func host(_ value: String) -> DebugBundleTracePropagationTarget {
        DebugBundleTracePropagationTarget(matchKind: .host(value.lowercased()))
    }

    public static func prefix(_ value: String) -> DebugBundleTracePropagationTarget {
        DebugBundleTracePropagationTarget(matchKind: .prefix(value.lowercased()))
    }

    static func parse(_ value: String) -> DebugBundleTracePropagationTarget {
        if let url = URL(string: value), let host = url.host {
            let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if normalizedPath.isEmpty, url.query == nil, url.fragment == nil {
                return .host(host)
            }
        }

        if value.contains("://") {
            return .prefix(value)
        }

        return .host(value)
    }

    func matches(_ url: URL) -> Bool {
        switch matchKind {
        case let .host(host):
            return url.host?.lowercased() == host
        case let .prefix(prefix):
            return url.absoluteString.lowercased().hasPrefix(prefix)
        }
    }
}

public enum DebugBundleURLSessionInstrumentation {
    public static let traceHeaderName = "X-DebugBundle-Trace-Id"

    public static func instrument(
        _ request: URLRequest,
        tracePropagationTargets: [DebugBundleTracePropagationTarget],
        traceID: String = UUID().uuidString.lowercased()
    ) -> URLRequest {
        guard let url = request.url else {
            return request
        }
        guard tracePropagationTargets.contains(where: { $0.matches(url) }) else {
            return request
        }
        guard request.value(forHTTPHeaderField: traceHeaderName) == nil else {
            return request
        }

        var instrumentedRequest = request
        instrumentedRequest.setValue(traceID, forHTTPHeaderField: traceHeaderName)
        return instrumentedRequest
    }
}

public extension URLSessionConfiguration {
    @discardableResult
    func debugBundleInstrumented(
        tracePropagationTargets: [DebugBundleTracePropagationTarget]
    ) -> URLSessionConfiguration {
        var protocolClasses = protocolClasses ?? []
        if !protocolClasses.contains(where: { $0 == DebugBundleURLProtocol.self }) {
            protocolClasses.insert(DebugBundleURLProtocol.self, at: 0)
        }
        self.protocolClasses = protocolClasses

        var headers = (httpAdditionalHeaders as? [String: Any]) ?? [:]
        headers[DebugBundleURLProtocol.configurationHeaderName] = DebugBundleURLProtocol.encodeTracePropagationTargets(tracePropagationTargets)
        self.httpAdditionalHeaders = headers
        return self
    }

    @discardableResult
    func debugBundleInstrumented(
        tracePropagationTargets: [String]
    ) -> URLSessionConfiguration {
        debugBundleInstrumented(
            tracePropagationTargets: tracePropagationTargets.map(DebugBundleTracePropagationTarget.parse)
        )
    }
}

public struct DebugBundleInstrumentedURLSession {
    private let session: URLSession
    private let tracePropagationTargets: [DebugBundleTracePropagationTarget]
    private let recordRequest: (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void
    private let now: () -> Date

    public init(
        session: URLSession = .shared,
        tracePropagationTargets: [DebugBundleTracePropagationTarget],
        recordRequest: @escaping (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void = { request, response in
            DebugBundle.captureRequest(request, response: response)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.tracePropagationTargets = tracePropagationTargets
        self.recordRequest = recordRequest
        self.now = now
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let traceID = UUID().uuidString.lowercased()
        let instrumentedRequest = request.debugBundleInstrumented(
            tracePropagationTargets: tracePropagationTargets,
            traceID: traceID
        )
        let startedAt = now()
        do {
            let (data, response) = try await session.data(for: instrumentedRequest)
            let durationMillis = Int(now().timeIntervalSince(startedAt) * 1000)
            recordRequest(
                buildRequestInfo(from: instrumentedRequest, traceID: instrumentedRequest.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName)),
                buildResponseInfo(from: response, durationMillis: durationMillis)
            )
            return (data, response)
        } catch {
            let durationMillis = Int(now().timeIntervalSince(startedAt) * 1000)
            recordRequest(
                buildRequestInfo(from: instrumentedRequest, traceID: instrumentedRequest.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName)),
                DebugBundleResponseInfo(statusCode: 0, durationMillis: durationMillis)
            )
            throw error
        }
    }

    private func buildRequestInfo(from request: URLRequest, traceID: String?) -> DebugBundleRequestInfo {
        DebugBundleRequestInfo(
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            traceId: traceID
        )
    }

    private func buildResponseInfo(from response: URLResponse, durationMillis: Int) -> DebugBundleResponseInfo {
        if let httpResponse = response as? HTTPURLResponse {
            return DebugBundleResponseInfo(
                statusCode: httpResponse.statusCode,
                durationMillis: durationMillis,
                headers: httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                    guard let key = entry.key as? String else {
                        return
                    }
                    result[key] = String(describing: entry.value)
                }
            )
        }
        return DebugBundleResponseInfo(statusCode: 0, durationMillis: durationMillis)
    }
}

public extension URLRequest {
    func debugBundleInstrumented(
        tracePropagationTargets: [DebugBundleTracePropagationTarget],
        traceID: String = UUID().uuidString.lowercased()
    ) -> URLRequest {
        DebugBundleURLSessionInstrumentation.instrument(
            self,
            tracePropagationTargets: tracePropagationTargets,
            traceID: traceID
        )
    }
}