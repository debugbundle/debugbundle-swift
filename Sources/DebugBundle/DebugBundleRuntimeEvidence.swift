import Foundation

/// Internal bridge shared by DebugBundle's native adapter targets, including crash persistence.
@_spi(DebugBundleRuntime) public enum DebugBundleRuntimeEvidence {
    public static func boundedText(_ value: String, maximumBytes: Int, redactFields: Set<String> = DebugBundleConfig.defaultRedactFields) -> String {
        guard (1...16_384).contains(maximumBytes), redactFields.count <= 128,
              redactFields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { return "[REDACTED]" }
        let clipped = DebugBundleExceptionEvidence.clip(value, maximumBytes)
        let safe = DebugBundleRedactor(sensitiveKeys: redactFields).sanitizeJSON(.string(clipped)).stringValue ?? "[REDACTED]"
        return DebugBundleExceptionEvidence.clip(safe, maximumBytes)
    }
    public static func fatalErrorSnapshot(_ error: Error) -> (name: String, message: String) {
        let snapshot = debugBundleSafeErrorPayload(error)
        return (boundedText(snapshot["type"]?.stringValue ?? "Error", maximumBytes: 256),
            boundedText(snapshot["message"]?.stringValue ?? "Error details unavailable", maximumBytes: 512))
    }
    public static func validEventId(_ text: String) -> Bool { text.utf8.prefix(65).count <= 64 && DebugBundleCanonicalEventSchema.uuid(text) }
    public static func validTimestamp(_ text: String) -> Bool { DebugBundleCanonicalEventSchema.timestamp(text) }
}
