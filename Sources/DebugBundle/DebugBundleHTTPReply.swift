import Foundation

/// Native SDK HTTP only: one monotonic deadline and bounded, identity-encoded UTF-8 replies.
enum DebugBundleHTTPReply {
    static let maximumBytes = 262_144
    struct Reply: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }
    static func read(session: URLSession, request: URLRequest, timeout: TimeInterval) async throws -> Reply {
        let duration = timeout.isFinite ? min(max(timeout, 0.001), 60) : 0.001
        return try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                if let response = response as? HTTPURLResponse {
                    let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    guard encoding.isEmpty || encoding == "identity",
                          (response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0) <= maximumBytes else {
                        throw URLError(.dataLengthExceedsMaximum)
                    }
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                guard data.isEmpty || String(data: data, encoding: .utf8) != nil else { throw URLError(.cannotDecodeContentData) }
                return Reply(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let reply = try await group.next() else { throw URLError(.cancelled) }
            return reply
        }
    }
}
