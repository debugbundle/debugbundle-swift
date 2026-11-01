import Foundation

/// Native SDK HTTP only: one monotonic deadline and bounded, identity-encoded UTF-8 replies.
enum DebugBundleHTTPReply {
    static let maximumBytes = 262_144
    struct Reply: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }
    static func deadline(timeout: TimeInterval) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + (timeout.isFinite ? min(max(timeout, 0.001), 60) : 0.001)
    }
    static func read(session: URLSession, request: URLRequest, timeout: TimeInterval) async throws -> Reply {
        try await withDeadline(timeout: timeout) {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse {
                let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard encoding.isEmpty || encoding == "identity",
                      (response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init) ?? 0) <= maximumBytes else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
            }
            guard data.isEmpty || String(data: data, encoding: .utf8) != nil else { throw URLError(.cannotDecodeContentData) }
            return Reply(data: data, response: response)
        }
    }

    static func withDeadline(timeout: TimeInterval, operation: @escaping @Sendable () async throws -> Reply) async throws -> Reply {
        let deadline = deadline(timeout: timeout)
        let completion = ReplyCompletion()
        // A task group waits for its cancelled children before returning. Older
        // Foundation callbacks can finish cancellation late; the request deadline
        // must release the sender independently while still cancelling that read.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let reader = Task {
                    guard !Task.isCancelled else { return }
                    do { completion.finish(.success(try await operation())) }
                    catch { completion.finish(.failure(error)) }
                }
                completion.own(reader, timer: false)
                let timer = Task {
                    do {
                        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        completion.finish(.failure(URLError(.timedOut)))
                    } catch { }
                }
                completion.own(timer, timer: true)
            }
        } onCancel: {
            completion.finish(.failure(URLError(.cancelled)))
        }
    }
}

/// One terminal result owns the continuation and both cancellation handles. No
/// continuation is retained by a late callback after timeout or caller cancellation.
private final class ReplyCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DebugBundleHTTPReply.Reply, Error>?
    private var continuation: CheckedContinuation<DebugBundleHTTPReply.Reply, Error>?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<DebugBundleHTTPReply.Reply, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func own(_ task: Task<Void, Never>, timer: Bool) {
        lock.lock()
        if result != nil {
            lock.unlock()
            task.cancel()
        } else {
            if timer { self.timer = task } else { reader = task }
            lock.unlock()
        }
    }

    func finish(_ result: Result<DebugBundleHTTPReply.Reply, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, reader = self.reader, timer = self.timer
        self.continuation = nil
        self.reader = nil
        self.timer = nil
        lock.unlock()
        reader?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
