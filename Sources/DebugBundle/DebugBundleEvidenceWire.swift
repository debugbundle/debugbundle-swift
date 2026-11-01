import Foundation

enum DebugBundleEvidenceWire {
    static func accepts(_ event: JSONValue) throws -> Bool {
        try DebugBundleNativeJSONBudget.check(event)
        return try DebugBundleCanonicalEventSchema.accepts(event) && semantic(event)
    }
    static func freshId(_ text: String?) -> Bool {
        guard let text, DebugBundleCanonicalEventSchema.uuid(text) else { return false }
        let bytes = Array(text.utf8)
        return bytes[14] == 52 && [56, 57, 65, 66, 97, 98].contains(bytes[19])
    }
    static func scope(_ value: JSONValue?) -> Bool {
        guard let item = value?.objectValue, let kind = item["kind"]?.stringValue,
              ["page", "operation"].contains(kind) else { return false }
        let key = kind == "page" ? "page_id" : "operation_id"
        return Set(item.keys) == Set(["kind", key]) && freshId(item[key]?.stringValue)
    }
    static func reference(_ value: JSONValue?) -> Bool {
        guard let item = value?.objectValue else { return false }
        return Set(item.keys) == Set(["version", "failure_ref", "scope"]) && item["version"] == .number(1) && freshId(item["failure_ref"]?.stringValue) && scope(item["scope"])
    }
    private static func bounded(_ value: JSONValue?, _ maximum: Int) -> Bool {
        if value == .null { return true }
        guard let text = value?.stringValue else { return false }
        return text.utf8.prefix(maximum + 1).count <= maximum
    }
    private static func semantic(_ value: JSONValue) -> Bool {
        guard let event = value.objectValue, let payload = event["payload"]?.objectValue else { return false }
        let type = event["event_type"]?.stringValue
        if type == "frontend_exception" {
            let mobile = ["@debugbundle/sdk-swift", "@debugbundle/sdk-android", "@debugbundle/sdk-react-native"].contains(event["sdk_name"]?.stringValue ?? "")
            if payload[mobile ? "device" : "browser"]?.objectValue == nil { return false }
        }
        if type == "diagnostic_context" {
            guard freshId(payload["failure_ref"]?.stringValue), scope(payload["scope"]) else { return false }
            if payload["kind"]?.stringValue == "recovery" {
                if !freshId(payload["attempt_id"]?.stringValue) || payload["operation"] != nil && !bounded(payload["operation"], 64) { return false }
            } else if !resources(payload["observations"]) { return false }
            if payload["scope"]?.objectValue?["kind"]?.stringValue == "page" {
                guard let session = event["correlation"]?.objectValue?["session_id"]?.stringValue, !blank(session) else { return false }
            }
            return true
        }
        var additions: [String: JSONValue] = [:]
        for field in ["exception_evidence", "execution", "resource_observations"] {
            guard let item = payload[field] else { continue }
            if !(type == "backend_exception" && field != "resource_observations" || type == "frontend_exception" && field != "execution") { return false }
            if field == "exception_evidence" && !graph(item) { return false }
            if field == "execution" && !bounded(item.objectValue?["name"], 128) { return false }
            if field == "resource_observations" && !resources(item) { return false }
            additions[field] = item
        }
        if additions.isEmpty { return true }
        if let item = event["context"]?.objectValue?["evidence_reference"], reference(item) { additions["evidence_reference"] = item }
        return DebugBundleAcceptingJSONSize.bytes(.object(additions)) <= 32_768
    }
    private static func graph(_ value: JSONValue) -> Bool {
        guard let graph = value.objectValue, let nodes = graph["nodes"]?.arrayValue else { return false }
        var edges: [Double: [Double]] = [:]
        for item in nodes {
            guard let node = item.objectValue, let id = node["id"]?.doubleValue, edges[id] == nil,
                  bounded(node["name"], 256), bounded(node["message"], 2048), bounded(node["stack"], 16_384) else { return false }
            for frame in node["frames"]?.arrayValue ?? [] {
                guard let frame = frame.objectValue, bounded(frame["function"], 256), bounded(frame["file"], 2048) else { return false }
            }
            edges[id] = []
        }
        for item in nodes {
            guard let node = item.objectValue, let id = node["id"]?.doubleValue else { return false }
            var unique = Set<String>(); var causal = 0
            for relation in node["relationships"]?.arrayValue ?? [] {
                guard let edge = relation.objectValue, let target = edge["target_id"]?.doubleValue, let kind = edge["kind"]?.stringValue,
                      edges[target] != nil, unique.insert("\(kind):\(target)").inserted else { return false }
                if ["cause", "context"].contains(kind) { causal += 1 }
                edges[id]?.append(target)
            }
            if causal > 1 { return false }
        }
        var active = Set<Double>(), reached = Set<Double>()
        func visit(_ id: Double, _ depth: Int) -> Bool {
            guard depth <= 4, let children = edges[id], active.insert(id).inserted else { return false }
            reached.insert(id)
            for child in children { if !visit(child, depth + 1) { return false } }
            active.remove(id); return true
        }
        guard let root = graph["root_id"]?.doubleValue else { return false }
        return visit(root, 0) && reached.count == nodes.count && DebugBundleAcceptingJSONSize.bytes(value) <= 32_768
    }
    private static func resources(_ value: JSONValue?) -> Bool {
        guard let value, let items = value.objectValue?["items"]?.arrayValue else { return false }
        for item in items {
            guard let observation = item.objectValue else { return false }
            if observation["kind"]?.stringValue == "csp" {
                guard let directive = observation["effective_directive"]?.stringValue, (1...64).contains(directive.utf8.count),
                      directive.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }) else { return false }
            }
            if observation["source_url"] != .null, !url(observation["source_url"]?.stringValue ?? "") { return false }
        }
        return DebugBundleAcceptingJSONSize.bytes(value) <= 32_768
    }
    private static func url(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 2048, !text.hasPrefix("//"),
              !text.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || "\\?#".unicodeScalars.contains($0) }) else { return false }
        if text.hasPrefix("/") { return true }
        guard text.lowercased().hasPrefix("https://") || text.lowercased().hasPrefix("http://"),
              let components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.user?.isEmpty != false, components.password?.isEmpty != false,
              components.port.map({ $0 <= 65_535 }) != false else { return false }
        return true
    }
    private static func blank(_ text: String) -> Bool {
        let whitespace: Set<UInt32> = [9, 10, 11, 12, 13, 32, 160, 5760, 8192, 8193, 8194, 8195, 8196, 8197, 8198, 8199, 8200, 8201, 8202, 8232, 8233, 8239, 8287, 12_288, 65_279]
        return text.unicodeScalars.allSatisfy { whitespace.contains($0.value) }
    }
}

/// Typed hook values project directly, before legacy encoder migration can discard invalid fields.
func debugBundleAuthoredWire(_ event: DebugBundleEventEnvelope) -> JSONValue {
    var service: [String: JSONValue] = ["name": .string(event.service), "environment": .string(event.environment)]
    if !event.serviceRuntimeIsAbsent { service["runtime"] = .string(event.serviceRuntime) }
    if let framework = event.serviceFramework { service["framework"] = .string(framework) }
    var value: [String: JSONValue] = ["schema_version": .string(event.schemaVersion), "event_id": .string(event.eventId), "event_type": .string(event.eventType),
        "sdk_name": .string(event.sdkName), "sdk_version": .string(event.sdkVersion), "service": .object(service), "occurred_at": .string(event.occurredAt), "payload": .object(event.payload)]
    if let context = event.context { value["context"] = .object(context) }
    if let correlation = event.correlation {
        var fields: [String: JSONValue] = [:]
        if let trace = correlation.traceId { fields["trace_id"] = .string(trace) }
        if let request = correlation.requestId { fields["request_id"] = .string(request) }
        if let session = correlation.sessionId { fields["session_id"] = .string(session) }
        if let user = correlation.userIdHash { fields["user_id_hash"] = .string(user) }
        value["correlation"] = .object(fields)
    }
    return .object(value)
}
