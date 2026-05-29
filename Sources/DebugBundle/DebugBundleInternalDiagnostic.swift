import Foundation

struct DebugBundleInternalDiagnostic: Sendable, Equatable {
    var category: String
    var message: String
    var metadata: [String: JSONValue]
    var recordedAt: Date
}