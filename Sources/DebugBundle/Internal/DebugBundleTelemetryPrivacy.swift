import Foundation

/// Mandatory bounded protection for application-owned JSON, independent of custom fields.
struct DebugBundleTelemetryPrivacy {
    private static let marker = "[REDACTED]"
    private static let maxBytes = 256 * 1024
    private static let baseline = [
        "password", "secret", "token", "api_key", "apikey", "access_token", "refresh_token",
        "private_key", "passwd", "card_number", "credit_card", "cvv", "cvc", "pin", "expiry",
        "phone", "bearer", "session_id", "otp", "verification_code", "authorization", "cookie",
        "ssn", "client_secret", "x_api_key", "set_cookie", "proxy_authorization",
        "accessToken", "refreshToken", "privateKey", "clientSecret"
    ]

    private let additional: [String]
    private let keys: Set<String>
    private let assignment: NSRegularExpression?

    init(additionalFields: Set<String>) {
        additional = Array(additionalFields)
        keys = Set((Self.baseline + additional).map(Self.canonical))
        let fields = (Self.baseline + additional).map(NSRegularExpression.escapedPattern).joined(separator: "|")
        assignment = try? NSRegularExpression(pattern: #"\b("# + fields + #")\b(["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s&,;]+)"#, options: [.caseInsensitive])
    }

    func protect(_ input: JSONValue) -> JSONValue {
        guard additional.count <= 128, additional.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) else {
            return .string(Self.marker)
        }
        var work = Work()
        guard let result = visit(input, depth: 0, structured: true, work: &work),
              let bytes = try? JSONEncoder().encode(result), bytes.count <= Self.maxBytes else {
            return .string(Self.marker)
        }
        return result
    }

    private struct Work {
        var nodes = 0
        var bytes = 0

        mutating func count(_ text: String) -> Bool {
            bytes += text.utf8.count
            return bytes <= DebugBundleTelemetryPrivacy.maxBytes
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
                if isSensitive(key) {
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

    private func isSensitive(_ key: String) -> Bool {
        let segmented = Self.replace(Self.expression1, in: key, with: "$1_$2")
        let parts = segmented.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for start in parts.indices {
            var joined = ""
            for end in start..<parts.count {
                joined += parts[end]
                if keys.contains(joined) { return true }
            }
        }
        return false
    }

    private func scrubText(_ text: String, scanURLs: Bool = true) -> String {
        if Self.contains(Self.expression2, in: text) && !Self.contains(Self.expression3, in: text) { return Self.marker }
        var output = text
        if Self.contains(Self.expression4, in: text, caseInsensitive: true) {
            guard let decoded = text.removingPercentEncoding else { return Self.marker }
            output = decoded
        }
        output = Self.replace(Self.expression3, in: output, with: Self.marker, caseInsensitive: true)
        output = Self.replace(Self.expression5, in: output, with: "$1: [REDACTED]", caseInsensitive: true)
        output = Self.replace(Self.expression6, in: output, with: "$1 [REDACTED]", caseInsensitive: true)
        output = Self.replace(Self.expression7, in: output, with: Self.marker)
        output = Self.replace(assignment, in: output, with: "$1$2[REDACTED]")
        output = Self.mapMatches(Self.expression8, in: output) { candidate in
            validCard(candidate) ? Self.marker : candidate
        }
        if !scanURLs { return output }
        return Self.mapMatches(Self.expression9, in: output, caseInsensitive: true) { candidate in
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
                return URLQueryItem(name: item.name, value: isSensitive(item.name) || scrubText(value, scanURLs: false) != value ? Self.marker : item.value)
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
    private static let expression1 = try? NSRegularExpression(pattern: #"([a-z0-9])([A-Z])"#, options: [.caseInsensitive])
    private static let expression2 = try? NSRegularExpression(pattern: pemStart, options: [.caseInsensitive])
    private static let expression3 = try? NSRegularExpression(pattern: pem, options: [.caseInsensitive])
    private static let expression4 = try? NSRegularExpression(pattern: #"(?:password|token|secret|authorization|cookie)%3[ad]"#, options: [.caseInsensitive])
    private static let expression5 = try? NSRegularExpression(pattern: #"\b(Authorization|Proxy-Authorization|Cookie|Set-Cookie)\s*:\s*[^\r\n]*"#, options: [.caseInsensitive])
    private static let expression6 = try? NSRegularExpression(pattern: #"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/-]{6,}"#, options: [.caseInsensitive])
    private static let expression7 = try? NSRegularExpression(pattern: #"\bdbundle_(?:proj|mem|probe|agent)_[A-Za-z0-9_-]+\b"#, options: [.caseInsensitive])
    private static let expression8 = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_-])(?:[0-9][ -]?){12,18}[0-9](?![A-Za-z0-9_-])"#, options: [.caseInsensitive])
    private static let expression9 = try? NSRegularExpression(pattern: #"\bhttps?://[^\s<>"']+"#, options: [.caseInsensitive])

    private static func canonical(_ text: String) -> String {
        text.lowercased().filter { $0.isASCII && $0.isLetter || $0.isNumber && $0.isASCII }
    }

    private static func contains(_ expression: NSRegularExpression?, in text: String, caseInsensitive: Bool = false) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replace(_ expression: NSRegularExpression?, in text: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let expression else { return marker }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func mapMatches(_ expression: NSRegularExpression?, in text: String, caseInsensitive: Bool = false, transform: (String) -> String) -> String {
        guard let expression else { return marker }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { return marker }
            result.replaceSubrange(range, with: transform(String(result[range])))
        }
        return result
    }
}
