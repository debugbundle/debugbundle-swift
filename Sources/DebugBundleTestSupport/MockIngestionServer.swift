import Foundation
import Network

public actor DebugBundleMockIngestionServer {
    public struct Response: Sendable {
        public var statusCode: Int
        public var headers: [String: String]
        public var body: Data

        public init(statusCode: Int = 202, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    public struct CapturedRequest: Sendable {
        public var method: String
        public var path: String
        public var headers: [String: String]
        public var body: Data

        public init(method: String, path: String, headers: [String: String], body: Data) {
            self.method = method
            self.path = path
            self.headers = headers
            self.body = body
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DebugBundleMockIngestionServer")
    private var response: Response
    private var capturedRequests: [CapturedRequest] = []
    private var hasStarted = false

    public init(response: Response = Response()) throws {
        self.listener = try NWListener(using: .tcp, on: .any)
        self.response = response
    }

    public func start() async throws {
        guard !hasStarted else {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case let .failed(error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                Task {
                    await self.handle(connection)
                }
            }

            listener.start(queue: queue)
        }

        hasStarted = true
    }

    public func stop() {
        listener.cancel()
    }

    public func endpointURL(path: String = "/v1/events") -> URL? {
        guard let port = listener.port?.rawValue else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    public func setResponse(_ response: Response) {
        self.response = response
    }

    public func recordedRequests() -> [CapturedRequest] {
        capturedRequests
    }

    private func handle(_ connection: NWConnection) {
        let buffer = ConnectionBuffer()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Task {
                    await self.receive(on: connection, buffer: buffer)
                }
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: ConnectionBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            Task {
                await self.didReceive(on: connection, buffer: buffer, data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func didReceive(on connection: NWConnection, buffer: ConnectionBuffer, data: Data?, isComplete: Bool, error: NWError?) {
        if let data {
            buffer.data.append(data)
        }

        if let request = parseRequest(from: buffer.data) {
            capturedRequests.append(request)
            send(response: response, on: connection)
            return
        }

        if error != nil || isComplete {
            connection.cancel()
            return
        }

        receive(on: connection, buffer: buffer)
    }

    private func parseRequest(from buffer: Data) -> CapturedRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: delimiter) else {
            return nil
        }

        let headerBytes = buffer.subdata(in: 0 ..< headerRange.lowerBound)
        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let separator = line.firstIndex(of: ":") else {
                return
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStartIndex = headerRange.upperBound
        let availableBodyLength = buffer.count - bodyStartIndex
        guard availableBodyLength >= contentLength else {
            return nil
        }

        let body = buffer.subdata(in: bodyStartIndex ..< bodyStartIndex + contentLength)
        return CapturedRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func send(response: Response, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil, !response.body.isEmpty {
            headers["Content-Type"] = "application/json"
        }

        let headerLines = headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\r\n")
        let statusLine = "HTTP/1.1 \(response.statusCode) \(reasonPhrase(for: response.statusCode))\r\n"
        let responseHead = statusLine + headerLines + "\r\n\r\n"

        var payload = Data(responseHead.utf8)
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 202:
            return "Accepted"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 429:
            return "Too Many Requests"
        case 500:
            return "Internal Server Error"
        default:
            return "Response"
        }
    }
}

private final class ConnectionBuffer: @unchecked Sendable {
    var data = Data()
}