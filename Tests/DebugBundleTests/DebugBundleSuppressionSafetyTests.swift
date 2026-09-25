import Foundation
import XCTest
@testable import DebugBundle

final class DebugBundleSuppressionSafetyTests: XCTestCase {
    func testUniqueBurstEvictsOldestFingerprintAndRepeatedBurstKeepsBoundedHistory() {
        let tracker = DebugBundleSuppressionTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        for index in 0 ..< 2_049 {
            _ = tracker.register(fingerprint: "unique-\(index)", now: start.addingTimeInterval(Double(index) / 10_000))
        }
        if case .allow = tracker.register(fingerprint: "unique-0", now: start.addingTimeInterval(1)).action {} else {
            XCTFail("Oldest fingerprint must be evicted at the fixed capacity")
        }
        for _ in 0 ..< 10_000 { _ = tracker.register(fingerprint: "repeating", now: start) }
        let fields = Mirror(reflecting: tracker).children
        let entries = fields.first { $0.label == "entries" }!.value
        let reflected = Mirror(reflecting: entries)
        XCTAssertLessThanOrEqual(reflected.children.count, 2_048)
        for pair in reflected.children {
            let entry = Array(Mirror(reflecting: pair.value).children)[1].value
            let timestamps = Mirror(reflecting: entry).children.first { $0.label == "timestamps" }!.value
            XCTAssertLessThanOrEqual(Mirror(reflecting: timestamps).children.count, 11)
        }
        if case .allow = tracker.register(fingerprint: "repeating", now: start.addingTimeInterval(61)).action {} else {
            XCTFail("A quiet interval must reset loop suppression")
        }
    }
}
