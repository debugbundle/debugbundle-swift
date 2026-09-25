import Foundation

/// Only a weak reference crosses admission. Value errors never retain an arbitrary raw graph.
final class DebugBundleDeferredError {
    private weak var reference: AnyObject?
    init?(_ error: Error) {
        guard type(of: error) is AnyClass, type(of: error) != NSError.self else { return nil }
        reference = error as AnyObject
    }

    func workerMessage() -> String? {
        guard let error = reference as? Error else { return nil }
        // Custom reference accessors run only on the existing bounded worker.
        return (error as NSError).localizedDescription
    }
}

func debugBundleSafeErrorPayload(_ error: Error) -> [String: JSONValue] {
    let typeName = String(reflecting: type(of: error))
    if type(of: error) == NSError.self {
        let native = error as NSError
        let userInfo = native.userInfo
        let description = userInfo.count <= 50 ? userInfo[NSLocalizedDescriptionKey] : nil
        let message: String
        if let description, debugBundleIsSafeFoundationValue(description),
           let text = description as? String, text.utf8.prefix(4_097).count <= 4_096 {
            message = text
        } else {
            message = "NSError details unavailable"
        }
        return ["type": .string(typeName), "domain": .string(native.domain),
                "code": .number(Double(native.code)), "message": .string(message)]
    }
    let kind = type(of: error) is AnyClass ? "reference" : "value"
    return ["type": .string(typeName), "message": .string("Error details unavailable (custom \(kind) type)")]
}

/// Native Swift primitives need no object accessors. Only known Foundation class-cluster
/// implementations may be bridged; custom subclasses fail closed without description or Mirror.
func debugBundleIsSafeFoundationValue(_ value: Any) -> Bool {
    guard type(of: value) is AnyClass else {
        let name = String(reflecting: type(of: value))
        return safeNativeTypes.contains(name) || name.hasPrefix("Swift.Dictionary<Swift.String,") || name.hasPrefix("Swift.Array<")
    }
    let name = NSStringFromClass(type(of: value as AnyObject))
    return safeFoundationClasses.contains(name)
}

private let safeFoundationClasses: Set<String> = [
    "NSString", "NSMutableString", "NSTaggedPointerString", "NSConstantString", "__NSCFConstantString", "__NSCFString",
    "NSNumber", "__NSCFNumber", "__NSCFBoolean", "NSDecimalNumber",
    "NSDate", "__NSDate", "__NSTaggedDate", "__NSCFDate", "NSURL", "__NSCFURL", "NSNull",
    "NSDictionary", "NSMutableDictionary", "__NSDictionaryI", "__NSDictionaryM", "__NSDictionary0",
    "__NSSingleEntryDictionaryI", "__NSCFDictionary", "__SwiftNativeNSDictionary", "_SwiftDeferredNSDictionary",
    "NSArray", "NSMutableArray", "__NSArrayI", "__NSArrayM", "__NSArray0", "__NSArrayI_Transfer",
    "__NSSingleObjectArrayI", "__NSCFArray", "__SwiftNativeNSArray", "_SwiftDeferredNSArray"
]

private let safeNativeTypes: Set<String> = [
    "Swift.String", "Swift.Bool", "Swift.Int", "Swift.Int8", "Swift.Int16", "Swift.Int32", "Swift.Int64",
    "Swift.UInt", "Swift.UInt8", "Swift.UInt16", "Swift.UInt32", "Swift.UInt64", "Swift.Float", "Swift.Double",
    "Foundation.URL", "FoundationEssentials.URL", "Foundation.Date", "FoundationEssentials.Date", "DebugBundle.JSONValue"
]

protocol DebugBundleOptionalValue { var debugBundleWrappedValue: Any? { get } }
extension Optional: DebugBundleOptionalValue {
    var debugBundleWrappedValue: Any? { switch self { case let .some(value): return value; case .none: return nil } }
}
