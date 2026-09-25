import Foundation

struct DebugBundleRedactor {
    private let sensitiveKeys: Set<String>
    private let maxDepth: Int
    private let maxCollectionCount: Int
    private let maxStringLength: Int
    private let privacy: DebugBundleTelemetryPrivacy

    init(
        sensitiveKeys: Set<String>,
        maxDepth: Int = 6,
        maxCollectionCount: Int = 50,
        maxStringLength: Int = 4096
    ) {
        self.sensitiveKeys = sensitiveKeys
        self.maxDepth = maxDepth
        self.maxCollectionCount = maxCollectionCount
        self.maxStringLength = maxStringLength
        self.privacy = DebugBundleTelemetryPrivacy(additionalFields: sensitiveKeys)
    }

    func sanitize(_ value: Any?) -> JSONValue {
        var remaining = 4_096
        return privacy.protect(sanitize(value, key: nil, depth: 0, visited: NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality]), remaining: &remaining))
    }

    func sanitizeJSON(_ value: JSONValue) -> JSONValue {
        privacy.protect(value)
    }

    func sanitizeDictionary(_ dictionary: [String: Any?]) -> [String: JSONValue] {
        if dictionary.count > maxCollectionCount { return ["_redacted": .string("[REDACTED]")] }
        var remaining = 4_096
        let converted = dictionary.reduce(into: [String: JSONValue]()) { result, entry in
            result[entry.key] = sanitize(entry.value, key: entry.key, depth: 0, visited: NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality]), remaining: &remaining)
        }
        if case let .object(safe) = privacy.protect(.object(converted)) { return safe }
        return ["_redacted": .string("[REDACTED]")]
    }

    func filterHeaders(_ headers: [String: String], allowlist: Set<String>) -> [String: JSONValue] {
        guard headers.count <= 256 else { return [:] }
        return headers.reduce(into: [String: JSONValue]()) { result, entry in
            let normalizedName = entry.key.lowercased()
            if allowlist.contains(normalizedName) {
                result[normalizedName] = sanitize(entry.value)
            }
        }
    }

    private func sanitize(_ value: Any?, key: String?, depth: Int, visited: NSHashTable<AnyObject>, remaining: inout Int) -> JSONValue {
        guard remaining > 0 else { return .string("[TRUNCATED]") }
        remaining -= 1
        if let key, key.utf8.prefix(129).count > 128 { return .string("[REDACTED]") }
        if let key, isSensitive(key) {
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

    private func isSensitive(_ key: String) -> Bool {
        let normalized = key.replacingOccurrences(of: "-", with: "_")
        let snakeCase = normalized.unicodeScalars.reduce(into: "") { partialResult, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if !partialResult.isEmpty {
                    partialResult.append("_")
                }
                partialResult.append(String(scalar).lowercased())
            } else {
                partialResult.append(String(scalar).lowercased())
            }
        }
        let segments = snakeCase.split(whereSeparator: { $0 == "_" || $0 == "." }).map(String.init)
        return !sensitiveKeys.isDisjoint(with: segments)
    }
}
