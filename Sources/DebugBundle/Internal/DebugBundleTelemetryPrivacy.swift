import Foundation

/// Mandatory bounded protection for application-owned JSON, independent of custom fields.
struct DebugBundleTelemetryPrivacy {
    static let maxProtectedBytes = 256 * 1024
    private static let marker = "[REDACTED]"
    private static let maxCustomKeys = 128
    private static let maxCustomKeyBytes = 64
    private static let baseline = [
        "password", "secret", "token", "api_key", "apikey", "access_token", "refresh_token",
        "private_key", "passwd", "card_number", "credit_card", "cvv", "cvc", "pin", "expiry",
        "phone", "bearer", "session_id", "otp", "verification_code", "authorization", "cookie",
        "ssn", "client_secret", "x_api_key", "set_cookie", "proxy_authorization",
        "accessToken", "refreshToken", "privateKey", "clientSecret"
    ]

    let isValidConfiguration: Bool
    private let keys: Set<String>
    private let broadNormalized: Set<String>
    private let exactKeys: Set<String>
    private let assignment: NSRegularExpression?
    private let exactAssignment: NSRegularExpression?

    static func areValidCustomKeys(additionalFields: Set<String>, exactFields: Set<String>) -> Bool {
        guard additionalFields.count + exactFields.count <= maxCustomKeys else { return false }
        return additionalFields.allSatisfy(isValidCustomKey) && exactFields.allSatisfy(isValidCustomKey)
    }

    private static func isValidCustomKey(_ key: String) -> Bool {
        key.utf8.prefix(maxCustomKeyBytes + 1).count <= maxCustomKeyBytes
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(additionalFields: Set<String>, exactFields: Set<String> = []) {
        let valid = Self.areValidCustomKeys(additionalFields: additionalFields, exactFields: exactFields)
        self.isValidConfiguration = valid
        guard valid else {
            self.keys = []
            self.broadNormalized = []
            self.exactKeys = []
            self.assignment = nil
            self.exactAssignment = nil
            return
        }
        let additionalTrimmed = additionalFields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let exactTrimmed = exactFields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let broadList = Self.baseline + additionalTrimmed
        self.keys = Set(broadList.map(Self.canonical).filter { !$0.isEmpty })
        self.broadNormalized = Set(broadList.map(Self.asciiLowercased))
        self.exactKeys = Set(exactTrimmed.map(Self.asciiLowercased))
        let broadPatterns = Self.longestFirstUnique(broadList).map(NSRegularExpression.escapedPattern).joined(separator: "|")
        self.assignment = try? NSRegularExpression(
            pattern: #"\b("# + broadPatterns + #")\b(["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s&,;]+)"#,
            options: [.caseInsensitive]
        )
        if exactTrimmed.isEmpty {
            self.exactAssignment = nil
        } else {
            let exactPatterns = Self.longestFirstUnique(exactTrimmed).map(NSRegularExpression.escapedPattern).joined(separator: "|")
            // Non-identifier boundaries keep `tag=secret` redacted while preserving `tag_name=script` and `x-tag-name=script`.
            self.exactAssignment = try? NSRegularExpression(
                pattern: #"(?<![A-Za-z0-9_-])("# + exactPatterns + #")(?![A-Za-z0-9_-])(["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s&,;]+)"#,
                options: [.caseInsensitive]
            )
        }
    }

    func protect(_ input: JSONValue) -> JSONValue {
        protectResult(input) ?? .string(Self.marker)
    }

    func protectResult(_ input: JSONValue) -> JSONValue? {
        guard isValidConfiguration else { return nil }
        var work = Work()
        guard let result = visit(input, depth: 0, structured: true, work: &work),
              let bytes = try? JSONEncoder().encode(result), bytes.count <= Self.maxProtectedBytes else {
            return nil
        }
        return result
    }

    func isSensitiveKey(_ key: String) -> Bool {
        guard isValidConfiguration else { return true }
        return isBroadSensitive(key) || isExactSensitive(key)
    }

    private struct Work {
        var nodes = 0
        var bytes = 0

        mutating func count(_ text: String) -> Bool {
            bytes += text.utf8.count
            return bytes <= DebugBundleTelemetryPrivacy.maxProtectedBytes
        }
    }

    private func visit(_ value: JSONValue, depth: Int, structured: Bool, work: inout Work) -> JSONValue? {
        work.nodes += 1
        guard work.nodes <= 4_096 else { return nil }
        if depth > 16 { return .string(Self.marker) }
        switch value {
        case let .object(object):
            if object.count > 256 { return .string(Self.marker) }
            var result: [String: JSONValue] = [:]
            for (key, nested) in object.sorted(by: { $0.key < $1.key }) {
                if key.utf8.prefix(129).count > 128 { continue }
                guard work.count(key) else { return nil }
                if scrubText(key) != key { continue }
                if isSensitiveKey(key) {
                    result[key] = .string(Self.marker)
                } else {
                    guard let cleaned = visit(nested, depth: depth + 1, structured: structured, work: &work) else { return nil }
                    result[key] = cleaned
                }
            }
            return .object(result)
        case let .array(array):
            if array.count > 256 { return .string(Self.marker) }
            var result: [JSONValue] = []
            for item in array {
                guard let cleaned = visit(item, depth: depth + 1, structured: structured, work: &work) else { return nil }
                result.append(cleaned)
            }
            return .array(result)
        case let .string(text):
            if text.utf8.prefix(16 * 1024 + 1).count > 16 * 1024 { return .string(Self.marker) }
            guard work.count(text) else { return nil }
            if structured && (text.hasPrefix("{") || text.hasPrefix("[")),
               let data = text.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                guard let cleaned = visit(decoded, depth: 0, structured: false, work: &work) else { return nil }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                if let serialized = try? encoder.encode(cleaned), let encoded = String(data: serialized, encoding: .utf8) {
                    return .string(encoded)
                }
                return .string(Self.marker)
            }
            let cleaned = scrubText(text)
            if cleaned == text && (text.hasPrefix("{") || text.hasPrefix("[")) && Self.contains(Self.expression0, in: text) {
                return .string(Self.marker)
            }
            return .string(cleaned)
        default:
            return value
        }
    }

    private func isBroadSensitive(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if broadNormalized.contains(Self.asciiLowercased(trimmed)) {
            return true
        }
        let segmented = Self.replace(Self.expression1, in: trimmed, with: "$1_$2")
        let parts = Self.asciiLowercased(segmented).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for start in parts.indices {
            var joined = ""
            for end in start..<parts.count {
                joined += parts[end]
                if keys.contains(joined) { return true }
            }
        }
        return false
    }

    /// ASCII case-insensitive whole-key match with punctuation significant (e.g. `tag` does not match `tag_name`).
    private func isExactSensitive(_ key: String) -> Bool {
        guard !exactKeys.isEmpty else { return false }
        return exactKeys.contains(Self.asciiLowercased(key.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func scrubText(_ text: String, scanURLs: Bool = true) -> String {
        if Self.contains(Self.expression2, in: text) && !Self.contains(Self.expression3, in: text) { return Self.marker }
        var output = text
        if Self.contains(Self.expression4, in: text) {
            guard let decoded = text.removingPercentEncoding else { return Self.marker }
            output = decoded
        }
        output = Self.replace(Self.expression3, in: output, with: Self.marker)
        output = Self.replace(Self.expression5, in: output, with: "$1: [REDACTED]")
        output = Self.replace(Self.expression6, in: output, with: "$1 [REDACTED]")
        output = Self.replace(Self.expression7, in: output, with: Self.marker)
        output = Self.replace(assignment, in: output, with: "$1$2[REDACTED]")
        if !exactKeys.isEmpty {
            output = Self.replace(exactAssignment, in: output, with: "$1$2[REDACTED]")
        }
        output = Self.mapMatches(Self.expression8, in: output) { candidate in
            validCard(candidate) ? Self.marker : candidate
        }
        if !scanURLs { return output }
        return Self.mapMatches(Self.expression9, in: output) { candidate in
            let raw = String(candidate.dropLast(candidate.reversed().prefix(while: { ").,;".contains($0) }).count))
            return scrubURL(raw) + candidate.dropFirst(raw.count)
        }
    }

    private func scrubURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.host != nil else {
            return Self.marker
        }
        if components.user != nil || components.password != nil {
            components.user = "REDACTED"
            components.password = nil
        }
        components.fragment = nil
        if let items = components.queryItems {
            components.queryItems = items.compactMap { item in
                guard item.name.utf8.prefix(129).count <= 128, scrubText(item.name, scanURLs: false) == item.name else { return nil }
                let value = item.value ?? ""
                return URLQueryItem(name: item.name, value: isSensitiveKey(item.name) || scrubText(value, scanURLs: false) != value ? Self.marker : item.value)
            }
        }
        return components.string ?? Self.marker
    }

    private func validCard(_ candidate: String) -> Bool {
        let digits = candidate.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            let doubled = index.isMultiple(of: 2) ? digit : digit * 2
            sum += doubled > 9 ? doubled - 9 : doubled
        }
        return sum.isMultiple(of: 10)
    }

    private static let pemStart = #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#
    private static let pem = #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"#
    private static let malformedLabel = #"(?:password|token|secret|authorization|cookie)["']?\s*[:=]"#

    private static let expression0 = try? NSRegularExpression(pattern: malformedLabel, options: [.caseInsensitive])
    // Camel-case boundary splitting must stay case-sensitive so plain words (e.g. `preference`) are not split mid-word.
    private static let expression1 = try? NSRegularExpression(pattern: #"([a-z0-9])([A-Z])"#, options: [])
    private static let expression2 = try? NSRegularExpression(pattern: pemStart, options: [.caseInsensitive])
    private static let expression3 = try? NSRegularExpression(pattern: pem, options: [.caseInsensitive])
    private static let expression4 = try? NSRegularExpression(pattern: #"(?:password|token|secret|authorization|cookie)%3[ad]"#, options: [.caseInsensitive])
    private static let expression5 = try? NSRegularExpression(pattern: #"\b(Authorization|Proxy-Authorization|Cookie|Set-Cookie)\s*:\s*[^\r\n]*"#, options: [.caseInsensitive])
    private static let expression6 = try? NSRegularExpression(pattern: #"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/-]{6,}"#, options: [.caseInsensitive])
    private static let expression7 = try? NSRegularExpression(pattern: #"\bdbundle_(?:proj|mem|probe|agent|invite|org_invite|org_transfer)_[A-Za-z0-9_-]+\b"#, options: [.caseInsensitive])
    private static let expression8 = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])(?:[0-9][ -]?){12,18}[0-9](?![A-Za-z0-9_-])"#, options: [])
    private static let expression9 = try? NSRegularExpression(pattern: #"\bhttps?://[^\s<>"']+"#, options: [.caseInsensitive])

    private static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    private static func canonical(_ text: String) -> String {
        asciiLowercased(text).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func longestFirstUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { left, right in
            left.utf8.count == right.utf8.count ? left < right : left.utf8.count > right.utf8.count
        }
    }

    private static func contains(_ expression: NSRegularExpression?, in text: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ expression: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let expression else { return marker }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func mapMatches(_ expression: NSRegularExpression?, in text: String, transform: (String) -> String) -> String {
        guard let expression else { return marker }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { return marker }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
