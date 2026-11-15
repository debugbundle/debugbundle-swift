import Foundation

struct DebugBundleInternalDiagnostic: Sendable, Equatable {
    var category: String
    var message: String
    var metadata: [String: JSONValue]
    var recordedAt: Date

    // ACK decision-making keeps the original reason. Local diagnostics retain
    // only bounded protocol codes, never server/custom-transport free text.
    static func safeReason(_ reason: String) -> String {
        let bytes = reason.utf8.prefix(65)
        guard !bytes.isEmpty, bytes.count <= 64, !reason.hasPrefix("dbundle_"),
              bytes.first.map({ (97 ... 122).contains($0) }) == true,
              bytes.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 95 }) else {
            return "unknown_rejection"
        }
        return reason
    }
}
