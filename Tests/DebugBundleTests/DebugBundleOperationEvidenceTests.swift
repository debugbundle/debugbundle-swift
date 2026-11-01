import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleOperationEvidenceTests: XCTestCase {
    func testNestedScopesRestoreAndExceptionsEscapeUnchanged() throws {
        let operations = DebugBundleOperations()
        let other = DebugBundleOperations()
        XCTAssertNil(operations.current())
        let outer = operations.begin()
        let outerId = try XCTUnwrap(outer.operationId)
        XCTAssertTrue(DebugBundleEvidenceWire.freshId(outerId))
        XCTAssertNil(other.current())
        let original = OperationFailure()
        do {
            try operations.run {
                XCTAssertNotEqual(operations.current()?.operationId, outerId)
                throw original
            }
        } catch { XCTAssertTrue(error as AnyObject === original) }
        XCTAssertEqual(operations.current()?.operationId, outerId)
        let child = operations.begin()
        outer.close()
        XCTAssertNil(child.evidenceScope)
        XCTAssertNil(operations.current())
        child.close()
        XCTAssertNil(operations.current())
    }

    func testAsyncTaskScopePropagatesButOutlivingChildCannotReuseIt() async throws {
        let operations = DebugBundleOperations()
        let child = await operations.run {
            let expected = operations.current()?.operationId
            XCTAssertNotNil(expected)
            await Task.yield()
            XCTAssertEqual(operations.current()?.operationId, expected)
            let nested = await operations.run { () async -> String? in
                XCTAssertNotEqual(operations.current()?.operationId, expected)
                return operations.current()?.operationId
            }
            XCTAssertNotNil(nested)
            return Task { () -> Bool in
                try? await Task.sleep(nanoseconds: 20_000_000)
                return operations.current() == nil
            }
        }
        let revoked = await child.value
        XCTAssertTrue(revoked)
        XCTAssertNil(operations.current())
    }

    func testDepthAndOwnerClosureAreBounded() {
        let operations = DebugBundleOperations()
        let scopes = (0..<40).map { _ in operations.begin() }
        XCTAssertNil(scopes.last?.operationId)
        operations.close()
        XCTAssertNil(operations.current())
        XCTAssertTrue(scopes.allSatisfy { $0.evidenceScope == nil })
        XCTAssertNil(operations.begin().operationId)
        for scope in scopes.reversed() { scope.close() }
    }

    func testExplicitScopeRequiresFreshOpaqueIdentifier() {
        XCTAssertNil(DebugBundleEvidenceScope(kind: "operation", operationId: "resource/path").wire)
        XCTAssertNil(DebugBundleEvidenceScope(kind: "unknown", operationId: UUID().uuidString).wire)
        XCTAssertNotNil(DebugBundleEvidenceScope(kind: "page", pageId: UUID().uuidString).wire)
    }
}
private final class OperationFailure: Error {}
