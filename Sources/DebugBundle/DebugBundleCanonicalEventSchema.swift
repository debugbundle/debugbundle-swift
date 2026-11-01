import Foundation

/// Immutable after initialization; matching uses Foundation's immutable regular expressions.
final class DebugBundleCanonicalEventSchema: @unchecked Sendable {
    private let root: JSONValue
    private var references: [String: JSONValue] = [:]
    private var patterns: [String: NSRegularExpression] = [:]
    private static let keywords: Set<String> = ["$schema", "$id", "$comment", "$ref", "type", "anyOf", "const", "enum", "properties", "required", "additionalProperties", "items", "minimum", "maximum", "exclusiveMinimum", "minLength", "maxLength", "minItems", "maxItems", "format", "pattern"]
    private static let types: Set<String> = ["null", "boolean", "number", "integer", "string", "array", "object"]
    private static let engine: DebugBundleCanonicalEventSchema? = {
        guard let data = DebugBundleCanonicalSchemaData.load(),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return try? DebugBundleCanonicalEventSchema(root)
    }()

    init(_ root: JSONValue) throws { self.root = root; try compile(root) }
    static func accepts(_ value: JSONValue) throws -> Bool {
        guard let engine else { throw DebugBundleEvidenceValidationError.unavailable }
        return try engine.accepts(value)
    }
    func accepts(_ value: JSONValue) throws -> Bool {
        var steps = 100_000
        return try check(root, value, &steps, 0)
    }
    private func compile(_ schema: JSONValue) throws {
        if case .bool = schema { return }
        guard let node = schema.objectValue, Set(node.keys).isSubset(of: Self.keywords),
              alternatives(node["type"]).allSatisfy({ Self.types.contains($0.stringValue ?? "") }),
              node["format"] == nil || ["uuid", "date-time"].contains(node["format"]?.stringValue ?? "")
        else { throw DebugBundleEvidenceValidationError.unavailable }
        if let pattern = node["pattern"]?.stringValue { patterns[pattern] = try NSRegularExpression(pattern: pattern) }
        if let ref = node["$ref"]?.stringValue, references[ref] == nil {
            let target = try resolve(ref); references[ref] = target; try compile(target)
        }
        for child in node["properties"]?.objectValue?.values ?? Dictionary<String, JSONValue>().values { try compile(child) }
        for child in node["anyOf"]?.arrayValue ?? [] { try compile(child) }
        for key in ["items", "additionalProperties"] { if let child = node[key] { try compile(child) } }
    }
    private func resolve(_ ref: String) throws -> JSONValue {
        if let cached = references[ref] { return cached }
        guard ref.hasPrefix("#/") else { throw DebugBundleEvidenceValidationError.unavailable }
        var current = root
        for part in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current.objectValue, let child = object[key] { current = child }
            else if let array = current.arrayValue, let index = Int(key), array.indices.contains(index) { current = array[index] }
            else { throw DebugBundleEvidenceValidationError.unavailable }
        }
        return current
    }
    private func check(_ schema: JSONValue, _ value: JSONValue, _ steps: inout Int, _ depth: Int) throws -> Bool {
        steps -= 1
        guard steps >= 0, depth <= 64 else { throw DebugBundleEvidenceValidationError.unavailable }
        if case let .bool(allowed) = schema { return allowed }
        guard let node = schema.objectValue else { throw DebugBundleEvidenceValidationError.unavailable }
        if let ref = node["$ref"]?.stringValue { return try check(resolve(ref), value, &steps, depth + 1) }
        if let choices = node["anyOf"]?.arrayValue {
            var matched = false
            for child in choices { if try check(child, value, &steps, depth + 1) { matched = true; break } }
            if !matched { return false }
        }
        if node["type"] != nil && !alternatives(node["type"]).contains(where: { matches(value, $0.stringValue ?? "") }) { return false }
        if let constant = node["const"], constant != value { return false }
        if let choices = node["enum"]?.arrayValue, !choices.contains(value) { return false }
        if case let .object(object) = value {
            if (node["required"]?.arrayValue ?? []).contains(where: { object[$0.stringValue ?? ""] == nil }) { return false }
            let fields = node["properties"]?.objectValue ?? [:]
            for (key, child) in object {
                if try !check(fields[key] ?? node["additionalProperties"] ?? .bool(true), child, &steps, depth + 1) { return false }
            }
        }
        if case let .array(array) = value {
            if let min = node["minItems"]?.doubleValue, Double(array.count) < min { return false }
            if let max = node["maxItems"]?.doubleValue, Double(array.count) > max { return false }
            if let items = node["items"] { for child in array { if try !check(items, child, &steps, depth + 1) { return false } } }
        }
        if case let .string(text) = value {
            // Generated bounds inherit the accepting Zod contract's UTF16 length semantics.
            let length = text.utf16.count
            if let min = node["minLength"]?.doubleValue, Double(length) < min { return false }
            if let max = node["maxLength"]?.doubleValue, Double(length) > max { return false }
            if let pattern = node["pattern"]?.stringValue,
               patterns[pattern]?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { return false }
            if node["format"]?.stringValue == "uuid", !Self.uuid(text) { return false }
            if node["format"]?.stringValue == "date-time", !Self.timestamp(text) { return false }
        }
        if case let .number(number) = value {
            if let min = node["minimum"]?.doubleValue, number < min { return false }
            if let max = node["maximum"]?.doubleValue, number > max { return false }
            if let min = node["exclusiveMinimum"]?.doubleValue, number <= min { return false }
        }
        return true
    }
    private func alternatives(_ value: JSONValue?) -> [JSONValue] {
        guard let value else { return [] }
        return value.arrayValue ?? [value]
    }
    private func matches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("object", .object), ("array", .array): return true
        case let ("number", .number(number)): return number.isFinite
        case let ("integer", .number(number)): return number.isFinite && number.rounded() == number
        default: return false
        }
    }
    static func uuid(_ text: String) -> Bool {
        guard text.utf8.count == 36 else { return false }
        for (index, byte) in text.utf8.enumerated() {
            if [8, 13, 18, 23].contains(index) { if byte != 45 { return false } }
            else if !(48...57).contains(byte) && !(65...70).contains(byte) && !(97...102).contains(byte) { return false }
        }
        return true
    }
    static func timestamp(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84, bytes[13] == 58, bytes[16] == 58, bytes.last == 90 else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] { guard (48...57).contains(byte) else { return nil }; value = value * 10 + Int(byte - 48) }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10), let hour = number(11..<13),
              let minute = number(14..<16), let second = number(17..<19), (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return false }
        if bytes.count != 20 {
            guard bytes.count > 21, bytes[19] == 46, bytes[20..<(bytes.count - 1)].allSatisfy({ (48...57).contains($0) }) else { return false }
        }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day >= 1 && day <= days[month - 1]
    }
}

enum DebugBundleEvidenceValidationError: Error { case unavailable, invalidNative }
