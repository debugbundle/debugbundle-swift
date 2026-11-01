import Foundation
import XCTest
import DebugBundleCrashReporter
@testable import DebugBundle

final class DebugBundleFatalEvidenceTests: XCTestCase {
    func testFatalSnapshotDoesNotRunCustomErrorAccessorsAndProtectsBeforeRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fatal.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: file)
        let error = FatalCustomError()
        let saved = DebugBundleCrashReporter.persistFatalCrash(error, store: store, stackTrace: ["0 App 0x123 token=fictional-secret + 42"])
        XCTAssertEqual(error.calls, 0)
        XCTAssertFalse(saved.message.contains("fictional-secret"))
        let native = NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "fatal token=fictional-secret"])
        let protected = DebugBundleCrashReporter.persistFatalCrash(native, store: store, stackTrace: ["0 App 0x123 token=fictional-secret + 42"])
        XCTAssertEqual(protected.message, "fatal token=[REDACTED]")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("fictional-secret"))
    }

    func testCrashStoreUsesPrivateFilesRejectsLinksAndLeavesUnrelatedDirectoriesUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fatal.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: file)
        let evidence = DebugBundleCrashEvidence(errorType: "Error", message: "fictional", occurredAt: "2026-10-28T00:00:00Z", threadName: "main")
        store.persist(evidence)
        for url in [directory, file] {
            let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(permissions.intValue & 0o077, 0)
        }
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let linked = DebugBundleCrashEvidenceStore(fileURL: link)
        linked.persist(evidence); linked.clear()
        XCTAssertTrue(linked.load() == nil)
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertNotNil(store.load())
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let throughParent = DebugBundleCrashEvidenceStore(fileURL: alias.appendingPathComponent("fatal.json"))
        throughParent.persist(evidence); throughParent.clear()
        XCTAssertTrue(throughParent.load() == nil)
        XCTAssertNotNil(store.load())
        let unrelated = directory.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let sentinel = unrelated.appendingPathComponent("retained.txt")
        try Data("retained".utf8).write(to: sentinel)
        let invalid = DebugBundleCrashEvidenceStore(fileURL: unrelated)
        invalid.persist(evidence); invalid.clear()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "retained")
        let blocked = DebugBundleCrashEvidenceStore(fileURL: file.appendingPathComponent("child.json"))
        blocked.persist(evidence)
        XCTAssertTrue(blocked.load() == nil)
        let invalidURL = DebugBundleCrashEvidenceStore(fileURL: URL(string: "https://example.invalid/fatal")!)
        invalidURL.persist(evidence); invalidURL.clear()
        XCTAssertTrue(invalidURL.load() == nil)
    }

    func testFatalFieldsStayBoundedAndInvalidDateDoesNotOverwriteRetainedEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebugBundleCrashEvidenceStore(fileURL: directory.appendingPathComponent("fatal.json"), redactFields: ["private_label"])
        let known = NSError(domain: "fictional", code: 1, userInfo: [NSLocalizedDescriptionKey: "private_label=fictional-private"])
        let saved = DebugBundleCrashReporter.persistFatalCrash(known, store: store, threadName: String(repeating: "x", count: 1000),
            stackTrace: Array(repeating: String(repeating: "🙂", count: 1000), count: 100))
        XCTAssertEqual(saved.message, "private_label=[REDACTED]")
        XCTAssertLessThanOrEqual(saved.threadName.utf8.count, 64)
        XCTAssertEqual(saved.stackTrace.count, 32)
        XCTAssertTrue(saved.stackTrace.allSatisfy { $0.utf8.count <= 512 })
        _ = DebugBundleCrashReporter.persistFatalCrash(known, store: store, occurredAt: Date(timeIntervalSince1970: .infinity), stackTrace: ["token=fictional-secret"])
        XCTAssertEqual(store.load()?.message, saved.message)
        let invalidFields = DebugBundleCrashEvidenceStore(fileURL: directory.appendingPathComponent("withheld.json"), redactFields: [String(repeating: "x", count: 1000)])
        invalidFields.persist(.init(errorType: "Error", message: "fictional", occurredAt: "2026-10-28T00:00:00Z", threadName: "main"))
        XCTAssertEqual(invalidFields.load()?.message, "[REDACTED]")
    }

    func testCrashFileReadsRejectOversizeUnknownVersionsAndInvalidUTF8() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fatal.json")
        let store = DebugBundleCrashEvidenceStore(fileURL: file)
        let valid = DebugBundleCrashEvidence(errorType: "Error", message: "fictional", occurredAt: "2026-10-28T00:00:00Z", threadName: "main")
        let encoded = try JSONEncoder().encode(valid)
        try (encoded + Data(repeating: 32, count: 262_144)).write(to: file)
        XCTAssertTrue(store.load() == nil)
        var unknown = valid; unknown.version = 9
        try JSONEncoder().encode(unknown).write(to: file)
        XCTAssertTrue(store.load() == nil)
        try (encoded + Data([255])).write(to: file)
        XCTAssertTrue(store.load() == nil)
    }
}

private final class FatalCustomError: LocalizedError, CustomNSError {
    var calls = 0
    var errorDescription: String? { calls += 1; return "unsafe token=fictional-secret" }
    var errorUserInfo: [String: Any] { calls += 1; return [NSLocalizedDescriptionKey: "unsafe token=fictional-secret"] }
}
