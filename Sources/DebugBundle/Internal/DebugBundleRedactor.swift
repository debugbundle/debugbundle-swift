import Foundation

struct DebugBundleRedactor {
    private let maxDepth: Int
    private let maxCollectionCount: Int
    private let maxStringLength: Int
    private let privacy: DebugBundleTelemetryPrivacy

    init(
        sensitiveKeys: Set<String>,
        exactKeys: Set<String> = [],
        maxDepth: Int = 6,
        maxCollectionCount: Int = 50,
        maxStringLength: Int = 4096
    ) {
        self.maxDepth = maxDepth
        self.maxCollectionCount = maxCollectionCount
        self.maxStringLength = maxStringLength
        self.privacy = DebugBundleTelemetryPrivacy(additionalFields: sensitiveKeys, exactFields: exactKeys)
    }

    var isValidConfiguration: Bool {
        privacy.isValidConfiguration
    }

    func sanitize(_ value: Any?) -> JSONValue {
        var remaining = 4_096
        return privacy.protect(sanitize(value, key: nil, depth: 0, visited: NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality]), remaining: &remaining))
    }

    func sanitizeJSON(_ value: JSONValue) -> JSONValue {
        privacy.protect(value)
    }

    func sanitizeProtocolJSON(_ value: JSONValue) -> JSONValue? {
        privacy.protectResult(value)
    }

    func sanitizeProtocolString(_ value: String) -> String? {
        privacy.protectResult(.string(value))?.stringValue
    }

    func sanitizeDictionary(_ dictionary: [String: Any?]) -> [String: JSONValue] {
        if !privacy.isValidConfiguration || dictionary.count > maxCollectionCount {
            return ["_redacted": .string("[REDACTED]")]
        }
        var remaining = 4_096
        let converted = dictionary.reduce(into: [String: JSONValue]()) { result, entry in
            result[entry.key] = sanitize(entry.value, key: entry.key, depth: 0, visited: NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality]), remaining: &remaining)
        }
        if case let .object(safe) = privacy.protect(.object(converted)) { return safe }
        return ["_redacted": .string("[REDACTED]")]
    }

    /// Preserves validated closed SDK-owned context metadata while redacting application-owned entries.
    func sanitizeContextDictionary(_ dictionary: [String: Any?]) -> [String: JSONValue] {
        if !privacy.isValidConfiguration || dictionary.count > maxCollectionCount {
            return ["_redacted": .string("[REDACTED]")]
        }
        var remaining = dictionary
        var preserved: [String: JSONValue] = [:]
        if let rawRef = remaining["evidence_reference"] ?? nil,
           let candidate = validatedJSONValue(rawRef),
           DebugBundleEvidenceWire.reference(candidate) {
            preserved["evidence_reference"] = candidate
            remaining.removeValue(forKey: "evidence_reference")
        }
        if let rawLimits = remaining["evidence_limits"] ?? nil,
           let candidate = validatedJSONValue(rawLimits),
           isValidDebugBundleEvidenceLimits(candidate) {
            preserved["evidence_limits"] = candidate
            remaining.removeValue(forKey: "evidence_limits")
        }
        var sanitized = sanitizeDictionary(remaining)
        for (key, value) in preserved {
            sanitized[key] = value
        }
        return sanitized
    }

    func filterHeaders(_ headers: [String: String], allowlist: Set<String>) -> [String: JSONValue] {
        guard headers.count <= 256 else { return [:] }
        return headers.reduce(into: [String: JSONValue]()) { result, entry in
            let normalizedName = entry.key.lowercased()
            if allowlist.contains(normalizedName) {
                result[normalizedName] = privacy.isSensitiveKey(normalizedName) ? .string("[REDACTED]") : sanitize(entry.value)
            }
        }
    }

    private func validatedJSONValue(_ raw: Any) -> JSONValue? {
        if let json = raw as? JSONValue {
            return json
        }
        if let dict = raw as? [String: Any?], let bridged = DebugBundleBridgeJSON.object(dict) {
            return .object(bridged)
        }
        return nil
    }

    private func sanitize(_ value: Any?, key: String?, depth: Int, visited: NSHashTable<AnyObject>, remaining: inout Int) -> JSONValue {
        guard remaining > 0 else { return .string("[TRUNCATED]") }
        remaining -= 1
        if let key, key.utf8.prefix(129).count > 128 { return .string("[REDACTED]") }
        if let key, privacy.isSensitiveKey(key) {
            return .string("[REDACTED]")
        }

        if depth >= maxDepth {
            return .string("[TRUNCATED]")
        }

        guard let value else {
            return .null
        }

        if let optional = value as? DebugBundleOptionalValue {
            return sanitize(optional.debugBundleWrappedValue, key: key, depth: depth, visited: visited, remaining: &remaining)
        }
        if type(of: value) == NSError.self { return .object(debugBundleSafeErrorPayload(value as! NSError)) }
        guard debugBundleIsSafeFoundationValue(value) else { return .string("[Unsupported value]") }
        if type(of: value) is AnyClass {
            if let text = value as? NSString, text.length > maxStringLength { return .string("[REDACTED]") }
            if let object = value as? NSDictionary, object.count > maxCollectionCount { return .string("[REDACTED]") }
            if let array = value as? NSArray, array.count > maxCollectionCount { return .string("[REDACTED]") }
        }
        if let json = value as? JSONValue { return json }
        if let stringValue = value as? String {
            if stringValue.utf8.prefix(maxStringLength + 1).count > maxStringLength {
                return .string("[REDACTED]")
            }
            return .string(stringValue)
        }

        if let boolValue = value as? Bool {
            return .bool(boolValue)
        }

        if let intValue = value as? Int {
            return .number(Double(intValue))
        }

        if let doubleValue = value as? Double {
            return .number(doubleValue)
        }

        if let floatValue = value as? Float {
            return .number(Double(floatValue))
        }

        if let numberValue = value as? NSNumber {
            return .number(numberValue.doubleValue)
        }

        if let urlValue = value as? URL {
            return .string(urlValue.absoluteString)
        }

        if let dateValue = value as? Date {
            return .string(ISO8601DateFormatter().string(from: dateValue))
        }

        if type(of: value) is AnyClass {
            let objectValue = value as AnyObject
            if visited.contains(objectValue) { return .string("[Circular]") }
            visited.add(objectValue)
        }

        if let dictionaryValue = value as? [String: Any?] {
            if dictionaryValue.count > maxCollectionCount { return .string("[REDACTED]") }
            let limited = dictionaryValue.prefix(maxCollectionCount)
            let object = limited.reduce(into: [String: JSONValue]()) { result, entry in
                result[entry.key] = sanitize(entry.value, key: entry.key, depth: depth + 1, visited: visited, remaining: &remaining)
            }
            return .object(object)
        }

        if let arrayValue = value as? [Any?] {
            if arrayValue.count > maxCollectionCount { return .string("[REDACTED]") }
            let limited = Array(arrayValue.prefix(maxCollectionCount))
            let array = limited.map { sanitize($0, key: nil, depth: depth + 1, visited: visited, remaining: &remaining) }
            return .array(array)
        }

        return .string("[Unsupported value]")
    }
}
