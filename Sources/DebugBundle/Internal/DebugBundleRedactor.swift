import Foundation

struct DebugBundleRedactor {
    private let sensitiveKeys: Set<String>
    private let maxDepth: Int
    private let maxCollectionCount: Int
    private let maxStringLength: Int

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
    }

    func sanitize(_ value: Any?) -> JSONValue {
        sanitize(value, key: nil, depth: 0, visited: NSHashTable<AnyObject>.weakObjects())
    }

    func sanitizeDictionary(_ dictionary: [String: Any?]) -> [String: JSONValue] {
        dictionary.reduce(into: [String: JSONValue]()) { result, entry in
            result[entry.key] = sanitize(entry.value, key: entry.key, depth: 0, visited: NSHashTable<AnyObject>.weakObjects())
        }
    }

    func filterHeaders(_ headers: [String: String], allowlist: Set<String>) -> [String: JSONValue] {
        headers.reduce(into: [String: JSONValue]()) { result, entry in
            let normalizedName = entry.key.lowercased()
            if allowlist.contains(normalizedName) {
                result[normalizedName] = sanitize(entry.value)
            }
        }
    }

    private func sanitize(_ value: Any?, key: String?, depth: Int, visited: NSHashTable<AnyObject>) -> JSONValue {
        if let key, isSensitive(key) {
            return .string("[REDACTED]")
        }

        if depth >= maxDepth {
            return .string("[TRUNCATED]")
        }

        guard let value else {
            return .null
        }

        if let stringValue = value as? String {
            if stringValue.count > maxStringLength {
                let endIndex = stringValue.index(stringValue.startIndex, offsetBy: maxStringLength)
                return .string(String(stringValue[..<endIndex]) + "…")
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

        if let errorValue = value as? Error {
            let nsError = errorValue as NSError
            return .object([
                "type": .string(String(describing: type(of: errorValue))),
                "domain": .string(nsError.domain),
                "code": .number(Double(nsError.code)),
                "message": .string(nsError.localizedDescription)
            ])
        }

        if Mirror(reflecting: value).displayStyle == .class {
            let objectValue = value as AnyObject
            if visited.contains(objectValue) {
                return .string("[Circular]")
            }
            visited.add(objectValue)
        }

        if let dictionaryValue = value as? [String: Any?] {
            let limited = dictionaryValue.prefix(maxCollectionCount)
            let object = limited.reduce(into: [String: JSONValue]()) { result, entry in
                result[entry.key] = sanitize(entry.value, key: entry.key, depth: depth + 1, visited: visited)
            }
            if dictionaryValue.count > maxCollectionCount {
                var truncated = object
                truncated["_truncated_keys"] = .number(Double(dictionaryValue.count - maxCollectionCount))
                return .object(truncated)
            }
            return .object(object)
        }

        if let arrayValue = value as? [Any?] {
            let limited = Array(arrayValue.prefix(maxCollectionCount))
            var array = limited.map { sanitize($0, key: nil, depth: depth + 1, visited: visited) }
            if arrayValue.count > maxCollectionCount {
                array.append(.string("[TRUNCATED]"))
            }
            return .array(array)
        }

        return .string(String(describing: value))
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