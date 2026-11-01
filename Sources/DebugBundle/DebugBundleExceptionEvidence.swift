import Foundation

/// Worker-local NSError relationships. No raw error is retained by the resulting value.
enum DebugBundleExceptionEvidence {
    static func capture(error: Error?, name: String, message: String, stack: String,
        unavailableReason: String = "unsupported", redactor: DebugBundleRedactor) -> JSONValue? {
        let snapshot = Snapshot(redactor)
        _ = snapshot.add(error, depth: 0, root: (name, message, stack))
        let graph: JSONValue = .object(["version": .number(1), "runtime": .string("swift"), "root_id": .number(0),
            "nodes": .array(snapshot.nodes.map(JSONValue.object)), "truncated": .bool(snapshot.truncated),
            "unavailable_reason": snapshot.unsafe ? .string("unsafe") : error == nil ? .string(unavailableReason) : .null])
        let safe = redactor.sanitizeJSON(graph)
        return DebugBundleAcceptingJSONSize.bytes(safe) <= 31_000 ? safe : nil
    }

    static func clip(_ text: String, _ maximum: Int) -> String {
        var count = 0
        var end = text.startIndex
        for scalar in text.unicodeScalars {
            let width = scalar.utf8.count
            if count + width > maximum { break }
            count += width
            end = text.unicodeScalars.index(after: end)
        }
        return String(text[..<end])
    }

    private final class Snapshot {
        var nodes: [[String: JSONValue]] = []
        var truncated = false, unsafe = false
        private var ids: [ObjectIdentifier: Int] = [:]
        private var active = Set<ObjectIdentifier>()
        private var remaining = 22_000
        private let redactor: DebugBundleRedactor
        init(_ redactor: DebugBundleRedactor) { self.redactor = redactor }

        private func text(_ raw: String, _ maximum: Int) -> String {
            let bound = min(maximum, remaining)
            let clipped = DebugBundleExceptionEvidence.clip(raw, bound)
            let safe = redactor.sanitizeJSON(.string(clipped)).stringValue ?? "Unavailable"
            let result = DebugBundleExceptionEvidence.clip(safe, bound)
            if clipped != raw || result != safe { truncated = true }
            remaining -= result.utf8.count
            return result
        }

        func add(_ raw: Any?, depth: Int, root: (String, String, String)? = nil) -> Int? {
            guard depth <= 4 else { truncated = true; return nil }
            // Checking the concrete type precedes any NSError bridge or overridable accessor.
            let native: NSError? = raw.flatMap { type(of: $0) == NSError.self ? ($0 as! NSError) : nil }
            let identity = native.map(ObjectIdentifier.init)
            if let identity {
                if active.contains(identity) { truncated = true; return nil }
                if let existing = ids[identity] {
                    if fits(existing, depth: depth, path: []) { return existing }
                    truncated = true; return nil
                }
            }
            guard nodes.count < 8 else { truncated = true; return nil }
            let id = nodes.count
            if let identity { ids[identity] = id; active.insert(identity) }
            defer { if let identity { active.remove(identity) } }
            let known = native.map(debugBundleSafeErrorPayload)
            let name = root?.0 ?? known?["domain"]?.stringValue ?? "Unavailable underlying error"
            let message = root?.1 ?? known?["message"]?.stringValue ?? "Underlying error details unavailable"
            if raw != nil && native == nil { unsafe = true }
            var node: [String: JSONValue] = ["id": .number(Double(id)), "name": .string(text(name, 256)),
                "message": .string(text(message, 2048)), "stack": .null,
                "trace_origin": .string(root == nil ? "unavailable" : "capture"),
                "parsing_status": .string("unavailable"), "frames": .array([]), "relationships": .array([])]
            nodes.append(node)
            if let stack = root?.2, !stack.isEmpty {
                let source = DebugBundleExceptionEvidence.clip(stack, 16_384)
                let lines = source.split(separator: "\n", omittingEmptySubsequences: true)
                var frames: [JSONValue] = []
                for line in lines.prefix(128) {
                    guard frames.count < 32 else { truncated = true; break }
                    let input = DebugBundleExceptionEvidence.clip(String(line), 2048)
                    guard let function = DebugBundleExceptionEvidence.parsedFunction(input) else { continue }
                    let frame: JSONValue = .object(["function": .string(text(function, 256)), "file": .null,
                        "line": .null, "column": .null,
                        "classification": .string(function.contains("DebugBundle") ? "sdk" : "unknown")])
                    let bytes = DebugBundleAcceptingJSONSize.bytes(frame)
                    guard bytes <= remaining else { truncated = true; break }
                    remaining -= bytes; frames.append(frame)
                }
                if source != stack || lines.count > 128 { truncated = true }
                node["frames"] = .array(frames)
                node["parsing_status"] = .string(truncated ? "truncated" : frames.isEmpty ? "unparsed" : "parsed")
            }
            nodes[id] = node
            var relationships: [JSONValue] = []
            func edge(_ value: Any?, _ kind: String) {
                guard let value else { return }
                guard relationships.count < 5 else { truncated = true; return }
                guard let child = add(value, depth: depth + 1) else { return }
                let relationship: JSONValue = .object(["kind": .string(kind), "target_id": .number(Double(child))])
                if !relationships.contains(relationship) { relationships.append(relationship) }
            }
            if let native {
                let info = native.userInfo
                if info.count <= 50 {
                    edge(info[NSUnderlyingErrorKey], "cause")
                    if let multiple = info[NSMultipleUnderlyingErrorsKey] {
                        if debugBundleIsSafeFoundationValue(multiple), let array = multiple as? NSArray {
                            if array.count > 5 { truncated = true }
                            for index in 0..<min(array.count, 5) { edge(array.object(at: index), "aggregate") }
                        } else { unsafe = true }
                    }
                } else { truncated = true }
            }
            nodes[id]["relationships"] = .array(relationships)
            return id
        }

        private func fits(_ id: Int, depth: Int, path: Set<Int>) -> Bool {
            guard depth <= 4, !path.contains(id) else { return false }
            var next = path; next.insert(id)
            return (nodes[id]["relationships"]?.arrayValue ?? []).allSatisfy {
                guard let child = $0.objectValue?["target_id"]?.intValue else { return false }
                return fits(child, depth: depth + 1, path: next)
            }
        }

    }
    private static let expression = try? NSRegularExpression(pattern: #"^\s*\d+\s+\S+\s+0x[\da-fA-F]+\s+(.+?)\s+\+\s+\d+\s*$"#)
    static func parsedFunction(_ line: String) -> String? {
            guard let match = expression?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range])
        }
}
