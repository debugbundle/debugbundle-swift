import Foundation
import CoreFoundation

/// Own plain bridge JSON before validation/privacy, retaining structured frame depth without formatters.
enum DebugBundleBridgeJSON {
    static func object(_ source: [String: Any?]) -> [String: JSONValue]? {
        do {
            let state = Copy()
            let value = try state.visit(source, 0)
            guard let object = value.objectValue, let encoded = try? JSONEncoder().encode(value), encoded.count <= 262_144 else { return nil }
            return object
        } catch { return nil }
    }
    fileprivate enum Failure: Error { case invalid }
    private final class Copy {
        private var remaining = 262_144, nodes = 4096
        private func use(_ count: Int) throws { remaining -= count; if remaining < 0 { throw Failure.invalid } }
        private func text(_ value: String) throws -> String {
            let bytes = value.utf8.prefix(remaining + 1).count
            try use(bytes + 2)
            return value
        }
        private func number(_ value: Double) throws -> JSONValue {
            guard value.isFinite else { throw Failure.invalid }
            try use(24)
            return .number(value)
        }
        private func object(_ count: Int, _ pairs: ((String, Any?) throws -> Void) throws -> Void, _ depth: Int) throws -> JSONValue {
            guard count <= 256 else { throw Failure.invalid }
            try use(2 + count * 2)
            var output: [String: JSONValue] = [:]
            try pairs { key, child in output[try self.text(key)] = try self.visit(child, depth + 1) }
            return .object(output)
        }
        private func array(_ count: Int, _ items: ((Any?) throws -> Void) throws -> Void, _ depth: Int) throws -> JSONValue {
            guard count <= 256 else { throw Failure.invalid }
            try use(2 + count)
            var output: [JSONValue] = []
            try items { child in output.append(try self.visit(child, depth + 1)) }
            return .array(output)
        }
        func visit(_ raw: Any?, _ depth: Int) throws -> JSONValue {
            nodes -= 1
            guard nodes >= 0, depth <= 16 else { throw Failure.invalid }
            guard let value = raw else { try use(4); return .null }
            if let optional = value as? DebugBundleOptionalValue { return try visit(optional.debugBundleWrappedValue, depth) }
            if let json = value as? JSONValue {
                switch json {
                case .null: try use(4); return .null
                case let .bool(value): try use(5); return .bool(value)
                case let .number(value): return try number(value)
                case let .string(value): return .string(try text(value))
                case let .array(values): return try array(values.count, { body in for item in values { try body(item) } }, depth)
                case let .object(values): return try object(values.count, { body in for (key, child) in values { try body(key, child) } }, depth)
                }
            }
            if type(of: value) is AnyClass {
                guard debugBundleIsSafeFoundationValue(value) else { throw Failure.invalid }
                if value is NSNull { try use(4); return .null }
                if let string = value as? NSString {
                    guard string.length <= remaining else { throw Failure.invalid }
                    return .string(try text(string as String))
                }
                if let value = value as? NSNumber {
                    if CFGetTypeID(value) == CFBooleanGetTypeID() { try use(5); return .bool(value.boolValue) }
                    return try number(value.doubleValue)
                }
                if let values = value as? NSArray {
                    return try array(values.count, { body in for index in 0..<values.count { try body(values.object(at: index)) } }, depth)
                }
                if let values = value as? NSDictionary {
                    guard values.count <= 256 else { throw Failure.invalid }
                    return try object(values.count, { body in
                        for (key, child) in values {
                            guard debugBundleIsSafeFoundationValue(key), let nativeKey = key as? NSString, nativeKey.length <= self.remaining else { throw Failure.invalid }
                            try body(nativeKey as String, child)
                        }
                    }, depth)
                }
                throw Failure.invalid
            }
            if let value = value as? String { return .string(try text(value)) }
            if let value = value as? Bool { try use(5); return .bool(value) }
            if let value = value as? Int { return try number(Double(value)) }
            if let value = value as? Int8 { return try number(Double(value)) }
            if let value = value as? Int16 { return try number(Double(value)) }
            if let value = value as? Int32 { return try number(Double(value)) }
            if let value = value as? Int64 { return try number(Double(value)) }
            if let value = value as? UInt { return try number(Double(value)) }
            if let value = value as? UInt8 { return try number(Double(value)) }
            if let value = value as? UInt16 { return try number(Double(value)) }
            if let value = value as? UInt32 { return try number(Double(value)) }
            if let value = value as? UInt64 { return try number(Double(value)) }
            if let value = value as? Double { return try number(value) }
            if let value = value as? Float { return try number(Double(value)) }
            if let values = value as? DebugBundleBridgeObject { return try object(values.debugBundleCount, values.debugBundlePairs, depth) }
            if let values = value as? DebugBundleBridgeArray { return try array(values.debugBundleCount, values.debugBundleItems, depth) }
            throw Failure.invalid
        }
    }
}

// Native generic containers use standard storage; no Objective-C bridging or foreign enumeration is needed.
private protocol DebugBundleBridgeObject {
    var debugBundleCount: Int { get }
    func debugBundlePairs(_ body: (String, Any?) throws -> Void) throws
}
extension Dictionary: DebugBundleBridgeObject {
    fileprivate var debugBundleCount: Int { count }
    fileprivate func debugBundlePairs(_ body: (String, Any?) throws -> Void) throws {
        for (key, value) in self {
            // Swift's untyped empty dictionaries use AnyHashable keys. Accept their
            // ordinary string keys without coercing non-string keys or using formatters.
            let rawKey = AnyHashable(key).base
            guard !(type(of: rawKey) is AnyClass) || debugBundleIsSafeFoundationValue(rawKey),
                  let name = rawKey as? String else { throw DebugBundleBridgeJSON.Failure.invalid }
            try body(name, value)
        }
    }
}
private protocol DebugBundleBridgeArray {
    var debugBundleCount: Int { get }
    func debugBundleItems(_ body: (Any?) throws -> Void) rethrows
}
extension Array: DebugBundleBridgeArray {
    fileprivate var debugBundleCount: Int { count }
    fileprivate func debugBundleItems(_ body: (Any?) throws -> Void) rethrows { for value in self { try body(value) } }
}
