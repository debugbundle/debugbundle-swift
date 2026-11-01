import Foundation

/// Counts the receiving JSON.stringify representation, separately from native transport bytes.
enum DebugBundleAcceptingJSONSize {
    static func bytes(_ value: JSONValue) -> Int {
        var remaining = 32_768, nodes = 4096
        func use(_ count: Int) throws { remaining -= count; if remaining < 0 { throw DebugBundleEvidenceValidationError.unavailable } }
        func string(_ text: String) throws {
            guard text.utf8.prefix(remaining + 1).count <= remaining else { throw DebugBundleEvidenceValidationError.unavailable }
            try use(2)
            for scalar in text.unicodeScalars {
                let value = scalar.value
                if [34, 92, 8, 12, 10, 13, 9].contains(value) { try use(2) }
                else if value < 32 { try use(6) }
                else { try use(value < 128 ? 1 : value < 2048 ? 2 : value < 65_536 ? 3 : 4) }
            }
        }
        func count(_ item: JSONValue, _ depth: Int) throws {
            nodes -= 1
            guard nodes >= 0, depth <= 16 else { throw DebugBundleEvidenceValidationError.unavailable }
            switch item {
            case .null: try use(4)
            case let .bool(value): try use(value ? 4 : 5)
            case let .number(value):
                guard let representation = number(value) else { throw DebugBundleEvidenceValidationError.invalidNative }
                try use(representation.utf8.count)
            case let .string(value): try string(value)
            case let .array(items):
                guard items.count <= 256 else { throw DebugBundleEvidenceValidationError.unavailable }
                try use(2 + max(0, items.count - 1))
                for child in items { try count(child, depth + 1) }
            case let .object(items):
                guard items.count <= 256 else { throw DebugBundleEvidenceValidationError.unavailable }
                try use(2 + max(0, items.count - 1))
                for (key, child) in items { try string(key); try use(1); try count(child, depth + 1) }
            }
        }
        do { try count(value, 0); return 32_768 - remaining } catch { return 32_769 }
    }

    private static func number(_ value: Double) -> String? {
        guard value.isFinite else { return nil }
        if value == 0 { return "0" }
        let pieces = String(abs(value)).lowercased().split(separator: "e")
        let mantissa = String(pieces[0]); let exponent = pieces.count == 2 ? Int(pieces[1]) ?? 0 : 0
        var digits = Array(mantissa.filter { $0 != "." })
        var position = (mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) } ?? mantissa.count) + exponent
        while digits.first == "0" { digits.removeFirst(); position -= 1 }
        while digits.last == "0" { digits.removeLast() }
        let scientific = position - 1
        let magnitude: String
        if (-6...20).contains(scientific) {
            if position <= 0 { magnitude = "0." + String(repeating: "0", count: -position) + String(digits) }
            else if position >= digits.count { magnitude = String(digits) + String(repeating: "0", count: position - digits.count) }
            else { magnitude = String(digits.prefix(position)) + "." + String(digits.dropFirst(position)) }
        } else {
            magnitude = String(digits.prefix(1)) + (digits.count > 1 ? "." + String(digits.dropFirst()) : "") + "e" + (scientific >= 0 ? "+" : "") + String(scientific)
        }
        return (value < 0 ? "-" : "") + magnitude
    }
}

/// Native value enums already have independent value semantics; bound work before encoding or validation.
enum DebugBundleNativeJSONBudget {
    static func check(_ value: JSONValue) throws {
        var nodes = 4096, bytes = 8 * 1024 * 1024
        func text(_ value: String) throws {
            let count = value.utf8.prefix(bytes + 1).count
            bytes -= count
            if bytes < 0 { throw DebugBundleEvidenceValidationError.unavailable }
        }
        func visit(_ value: JSONValue, _ depth: Int) throws {
            nodes -= 1
            guard nodes >= 0, depth <= 16 else { throw DebugBundleEvidenceValidationError.unavailable }
            switch value {
            case let .object(items): for (key, child) in items { try text(key); try visit(child, depth + 1) }
            case let .array(items): for child in items { try visit(child, depth + 1) }
            case let .string(value): try text(value)
            case let .number(value): if !value.isFinite { throw DebugBundleEvidenceValidationError.invalidNative }
            default: break
            }
        }
        try visit(value, 0)
    }
}
