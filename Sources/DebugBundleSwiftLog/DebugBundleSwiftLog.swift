import Foundation
import DebugBundle
import Logging

public struct DebugBundleLogHandler: LogHandler {
    private static let recursionKey = "com.debugbundle.swiftlog.recursing"

    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata
    public let label: String

    private let emit: (DebugBundleLogLevel, String, [String: Any?]) -> Void

    public init(
        label: String,
        logLevel: Logger.Level = .info,
        metadata: Logger.Metadata = [:],
        emit: @escaping (DebugBundleLogLevel, String, [String: Any?]) -> Void = { level, message, context in
            DebugBundle.captureLog(message, level: level, context: context)
        }
    ) {
        self.label = label
        self.logLevel = logLevel
        self.metadata = metadata
        self.emit = emit
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            metadata[key]
        }
        set {
            metadata[key] = newValue
        }
    }

    public func log(event: LogEvent) {
        emitLog(
            level: event.level,
            message: event.message,
            metadata: event.metadata,
            source: event.source,
            file: event.file,
            function: event.function,
            line: event.line,
            error: event.error
        )
    }

    public func log(level: Logger.Level, message: Logger.Message, metadata explicitMetadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
        emitLog(
            level: level,
            message: message,
            metadata: explicitMetadata,
            source: source,
            file: file,
            function: function,
            line: line,
            error: nil
        )
    }

    private func emitLog(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicitMetadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt,
        error: (any Error)?
    ) {
        guard level >= logLevel else {
            return
        }
        guard Self.enterRecursionGuard() else {
            return
        }
        defer { Self.exitRecursionGuard() }

        var mergedMetadata = metadata
        if let explicitMetadata {
            mergedMetadata.merge(explicitMetadata) { _, new in new }
        }

        var context = mergedMetadata.reduce(into: [String: Any?]()) { result, entry in
            result[entry.key] = Self.stringify(entry.value)
        }
        context["logger_label"] = label
        context["source"] = source
        context["file"] = URL(fileURLWithPath: file).lastPathComponent
        context["function"] = function
        context["line"] = Int(line)
        if let error {
            context["error"] = String(describing: error)
        }

        emit(Self.map(level), message.description, context)
    }

    private static func map(_ level: Logger.Level) -> DebugBundleLogLevel {
        switch level {
        case .trace, .debug:
            return .debug
        case .info, .notice:
            return .info
        case .warning:
            return .warning
        case .error, .critical:
            return .error
        }
    }

    private static func stringify(_ metadata: Logger.Metadata.Value) -> Any {
        switch metadata {
        case let .string(value):
            return value
        case let .stringConvertible(value):
            return value.description
        case let .array(value):
            return value.map(stringify)
        case let .dictionary(value):
            return value.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = stringify(entry.value)
            }
        }
    }

    private static func enterRecursionGuard() -> Bool {
        let threadDictionary = Thread.current.threadDictionary
        if threadDictionary[recursionKey] as? Bool == true {
            return false
        }
        threadDictionary[recursionKey] = true
        return true
    }

    private static func exitRecursionGuard() {
        Thread.current.threadDictionary.removeObject(forKey: recursionKey)
    }
}