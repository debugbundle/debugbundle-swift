import Foundation

public struct DebugBundleEvidenceScope: Sendable, Equatable {
    public var kind: String
    public var operationId: String?
    public var pageId: String?
    public init(kind: String = "operation", operationId: String? = nil, pageId: String? = nil) {
        self.kind = kind; self.operationId = operationId; self.pageId = pageId
    }
    var wire: JSONValue? {
        let key = kind == "operation" ? "operation_id" : kind == "page" ? "page_id" : ""
        let id = kind == "operation" ? operationId : pageId
        guard !key.isEmpty, DebugBundleEvidenceWire.freshId(id), let id else { return nil }
        return .object(["kind": .string(kind), key: .string(id)])
    }
}

/// Manual scopes are synchronous/thread-local. Use withOperationContext across await points.
public final class DebugBundleOperationScope: @unchecked Sendable {
    private let lease: DebugBundleOperationLease?
    init(_ lease: DebugBundleOperationLease?) { self.lease = lease }
    public var operationId: String? { lease.flatMap { $0.active ? $0.id : nil } }
    public var evidenceScope: DebugBundleEvidenceScope? { operationId.map { .init(operationId: $0) } }
    public func close() { lease?.close() }
    deinit { close() }
}

private enum DebugBundleOperationContext {
    @TaskLocal static var leases: [UUID: DebugBundleOperationLease] = [:]
}

final class DebugBundleOperationLease: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    let owner: DebugBundleOperations
    let previous: DebugBundleOperationLease?
    private let lock = NSLock()
    private var ended = false
    init(owner: DebugBundleOperations, previous: DebugBundleOperationLease?) { self.owner = owner; self.previous = previous }
    var active: Bool {
        guard !owner.isClosed else { return false }
        var current: DebugBundleOperationLease? = self, depth = 0
        while let lease = current {
            depth += 1
            if depth > 32 || lease.lock.withLock({ lease.ended }) { return false }
            current = lease.previous
        }
        return true
    }
    func close() {
        lock.withLock { ended = true }
        owner.restoreThread(self)
    }
}

final class DebugBundleOperations: @unchecked Sendable {
    private let id = UUID()
    private let key = "com.debugbundle.operation." + UUID().uuidString
    private let lock = NSLock()
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }
    private func currentLease() -> DebugBundleOperationLease? {
        if let task = DebugBundleOperationContext.leases[id] { return task.active ? task : nil }
        guard let thread = Thread.current.threadDictionary[key] as? DebugBundleOperationLease else { return nil }
        if thread.active { return thread }
        Thread.current.threadDictionary.removeObject(forKey: key)
        return nil
    }
    func current() -> DebugBundleEvidenceScope? { currentLease().map { .init(operationId: $0.id) } }
    private func makeLease() -> DebugBundleOperationLease? {
        guard !isClosed else { return nil }
        let parent = currentLease()
        var previous = parent, depth = 0
        while let item = previous { depth += 1; if depth >= 32 { return nil }; previous = item.previous }
        return DebugBundleOperationLease(owner: self, previous: parent)
    }
    func begin() -> DebugBundleOperationScope {
        let lease = makeLease()
        if let lease { Thread.current.threadDictionary[key] = lease }
        return DebugBundleOperationScope(lease)
    }
    func run<T>(_ operation: () throws -> T) rethrows -> T {
        guard let lease = makeLease(), DebugBundleOperationContext.leases[id] != nil || DebugBundleOperationContext.leases.count < 32 else {
            return try operation()
        }
        var context = DebugBundleOperationContext.leases; context[id] = lease
        defer { lease.close() }
        return try DebugBundleOperationContext.$leases.withValue(context, operation: operation)
    }
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        guard let lease = makeLease(), DebugBundleOperationContext.leases[id] != nil || DebugBundleOperationContext.leases.count < 32 else {
            return try await operation()
        }
        var context = DebugBundleOperationContext.leases; context[id] = lease
        defer { lease.close() }
        return try await DebugBundleOperationContext.$leases.withValue(context, operation: operation)
    }
    func restoreThread(_ lease: DebugBundleOperationLease) {
        if Thread.current.threadDictionary[key] as? DebugBundleOperationLease === lease {
            if let previous = lease.previous, previous.active { Thread.current.threadDictionary[key] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
    }
    func close() { lock.withLock { closed = true }; Thread.current.threadDictionary.removeObject(forKey: key) }
}

public enum DebugBundleEvidenceContext {
    public static func forFailure(_ failureRef: String, scope: DebugBundleEvidenceScope? = nil) -> [String: Any?] {
        var context: [String: Any?] = ["failure_ref": failureRef]
        if let wire = scope?.wire { context["evidence_scope"] = wire }
        return context
    }
}
