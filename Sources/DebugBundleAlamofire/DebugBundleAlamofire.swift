import Alamofire
import DebugBundle
import DebugBundleURLSession
import Foundation

public struct DebugBundleAlamofireInterceptor: RequestInterceptor, Sendable {
    private let tracePropagationTargets: [DebugBundleTracePropagationTarget]
    private let traceIDProvider: @Sendable () -> String

    public init(
        tracePropagationTargets: [DebugBundleTracePropagationTarget],
        traceIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.tracePropagationTargets = tracePropagationTargets
        self.traceIDProvider = traceIDProvider
    }

    public func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void
    ) {
        let instrumented = urlRequest.debugBundleInstrumented(
            tracePropagationTargets: tracePropagationTargets,
            traceID: traceIDProvider()
        )
        completion(.success(instrumented))
    }
}

public final class DebugBundleAlamofireMonitor: EventMonitor, @unchecked Sendable {
    private struct RequestState {
        let requestInfo: DebugBundleRequestInfo
        let startedAt: Date
    }

    public let queue: DispatchQueue

    private let recordRequest: (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void
    private let now: () -> Date
    private var requestStates: [UUID: RequestState] = [:]

    public init(
        queue: DispatchQueue = DispatchQueue(label: "DebugBundleAlamofireMonitor"),
        recordRequest: @escaping (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void = { request, response in
            DebugBundle.captureRequest(request, response: response)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.recordRequest = recordRequest
        self.now = now
    }

    public func request(_ request: Request, didCreateURLRequest urlRequest: URLRequest) {
        let traceID = urlRequest.value(forHTTPHeaderField: DebugBundleURLSessionInstrumentation.traceHeaderName)
        requestStates[request.id] = RequestState(
            requestInfo: DebugBundleRequestInfo(
                method: urlRequest.httpMethod ?? "GET",
                url: urlRequest.url?.absoluteString ?? "",
                headers: urlRequest.allHTTPHeaderFields ?? [:],
                traceId: traceID
            ),
            startedAt: now()
        )
    }

    public func request(_ request: Request, didCompleteTask task: URLSessionTask, with error: AFError?) {
        guard let state = requestStates.removeValue(forKey: request.id) else {
            return
        }

        let durationMillis = max(0, Int(now().timeIntervalSince(state.startedAt) * 1000))
        let responseInfo = Self.buildResponseInfo(
            from: task.response,
            durationMillis: durationMillis,
            error: error
        )
        recordRequest(state.requestInfo, responseInfo)
    }

    private static func buildResponseInfo(
        from response: URLResponse?,
        durationMillis: Int,
        error: AFError?
    ) -> DebugBundleResponseInfo {
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

        if error != nil {
            return DebugBundleResponseInfo(statusCode: 0, durationMillis: durationMillis)
        }

        return DebugBundleResponseInfo(statusCode: 0, durationMillis: durationMillis)
    }
}

public extension Session {
    static func debugBundleInstrumented(
        configuration: URLSessionConfiguration = .default,
        tracePropagationTargets: [DebugBundleTracePropagationTarget],
        recordRequest: @escaping (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void = { request, response in
            DebugBundle.captureRequest(request, response: response)
        },
        startRequestsImmediately: Bool = true,
        now: @escaping () -> Date = Date.init,
        traceIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) -> Session {
        let interceptor = DebugBundleAlamofireInterceptor(
            tracePropagationTargets: tracePropagationTargets,
            traceIDProvider: traceIDProvider
        )
        let monitor = DebugBundleAlamofireMonitor(recordRequest: recordRequest, now: now)
        return Session(
            configuration: configuration,
            startRequestsImmediately: startRequestsImmediately,
            interceptor: interceptor,
            eventMonitors: [monitor]
        )
    }

    static func debugBundleInstrumented(
        configuration: URLSessionConfiguration = .default,
        tracePropagationTargets: [String],
        recordRequest: @escaping (DebugBundleRequestInfo, DebugBundleResponseInfo) -> Void = { request, response in
            DebugBundle.captureRequest(request, response: response)
        },
        startRequestsImmediately: Bool = true,
        now: @escaping () -> Date = Date.init,
        traceIDProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) -> Session {
        debugBundleInstrumented(
            configuration: configuration,
            tracePropagationTargets: tracePropagationTargets.map(debugBundleTracePropagationTarget(from:)),
            recordRequest: recordRequest,
            startRequestsImmediately: startRequestsImmediately,
            now: now,
            traceIDProvider: traceIDProvider
        )
    }

    private static func debugBundleTracePropagationTarget(from value: String) -> DebugBundleTracePropagationTarget {
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
}