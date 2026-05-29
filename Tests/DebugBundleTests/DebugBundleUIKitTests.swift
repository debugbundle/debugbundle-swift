import XCTest
@testable import DebugBundleUIKit

#if canImport(UIKit)
import UIKit
#endif

final class DebugBundleUIKitTests: XCTestCase {
    func testLifecycleRecorderMapsUIKitLifecycleEvents() {
        var breadcrumbs: [(String, Int?)] = []
        var screens: [String] = []
        var foregroundCount = 0
        var backgroundCount = 0

        let recorder = DebugBundleUIKitLifecycleRecorder(
            recordBreadcrumb: { name, data in
                breadcrumbs.append((name, data?["application_state"] as? Int))
            },
            recordScreen: { screenName, source in
                screens.append("\(screenName):\(source)")
            },
            recordAppForeground: {
                foregroundCount += 1
            },
            recordAppBackground: {
                backgroundCount += 1
            }
        )

        recorder.install(applicationStateRawValue: 0, isActive: true)
        recorder.recordSceneForeground("CheckoutScene")
        recorder.recordSceneBackground("CheckoutScene")
        recorder.recordViewControllerAppearance(screenName: "CartViewController", animated: false)
        recorder.recordViewControllerAppearance(screenName: "PaymentViewController", animated: true)
        recorder.recordNavigation(screenName: "ReceiptViewController", animated: true)

        XCTAssertEqual(breadcrumbs.count, 1)
        XCTAssertEqual(breadcrumbs.first?.0, "app_install")
        XCTAssertEqual(breadcrumbs.first?.1, 0)
        XCTAssertEqual(foregroundCount, 2)
        XCTAssertEqual(backgroundCount, 1)
        XCTAssertEqual(screens, [
            "CheckoutScene:uikit_scene",
            "CheckoutScene:uikit_scene",
            "CartViewController:uikit_view_controller",
            "PaymentViewController:uikit_view_controller_animated",
            "ReceiptViewController:uikit_navigation_animated"
        ])
    }

    func testInstallDoesNotRecordForegroundWhenInactive() {
        var foregroundCount = 0
        let recorder = DebugBundleUIKitLifecycleRecorder(
            recordAppForeground: {
                foregroundCount += 1
            }
        )

        recorder.install(applicationStateRawValue: 1, isActive: false)

        XCTAssertEqual(foregroundCount, 0)
    }

    func testBackgroundFlushCoordinatorEndsTaskAfterFlush() async {
        let flushPerformed = expectation(description: "flush performed")
        var endedTokens: [Int] = []

        let coordinator = DebugBundleBackgroundFlushCoordinator(
            beginTask: { _ in
                DebugBundleBackgroundTaskToken(rawValue: 7)
            },
            endTask: { token in
                endedTokens.append(token.rawValue)
            },
            flush: {
                await Task.yield()
                flushPerformed.fulfill()
            }
        )

        coordinator.performFlush()

        await fulfillment(of: [flushPerformed], timeout: 1)
        XCTAssertEqual(endedTokens, [7])
    }

    func testBackgroundFlushCoordinatorFallsBackWithoutTaskToken() async {
        let flushPerformed = expectation(description: "flush performed")
        var endedTokens: [Int] = []

        let coordinator = DebugBundleBackgroundFlushCoordinator(
            beginTask: { _ in nil },
            endTask: { token in
                endedTokens.append(token.rawValue)
            },
            flush: {
                await Task.yield()
                flushPerformed.fulfill()
            }
        )

        coordinator.performFlush()

        await fulfillment(of: [flushPerformed], timeout: 1)
        XCTAssertTrue(endedTokens.isEmpty)
    }

#if canImport(UIKit)
    @MainActor
    func testApplicationDidEnterBackgroundWithUIApplicationFlushesOnSimulator() async {
        let flushPerformed = expectation(description: "flush performed")
        var backgroundCount = 0

        let recorder = DebugBundleUIKitLifecycleRecorder(
            recordAppBackground: {
                backgroundCount += 1
            }
        )

        DebugBundleUIKit.applicationDidEnterBackground(
            application: UIApplication.shared,
            recorder: recorder,
            flush: {
                flushPerformed.fulfill()
            }
        )

        await fulfillment(of: [flushPerformed], timeout: 1)
        XCTAssertEqual(backgroundCount, 1)
    }

    @MainActor
    func testRecordViewControllerAppearUsesUIViewControllerTypeName() {
        var screens: [String] = []
        let recorder = DebugBundleUIKitLifecycleRecorder(
            recordScreen: { screenName, source in
                screens.append("\(screenName):\(source)")
            }
        )

        DebugBundleUIKit.recordViewControllerAppear(
            UIViewController(),
            animated: true,
            recorder: recorder
        )

        XCTAssertEqual(screens, ["UIViewController:uikit_view_controller_animated"])
    }
#endif
}