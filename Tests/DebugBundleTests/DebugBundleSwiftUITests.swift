import XCTest

#if canImport(SwiftUI)
import DebugBundle
import SwiftUI
@testable import DebugBundleSwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class DebugBundleSwiftUITests: XCTestCase {
    @MainActor
    @available(iOS 16.0, macOS 13.0, *)
    func testDefaultRecorderAndViewModifiersRenderSafely() {
        DebugBundle.initialize(
            DebugBundleConfig(projectToken: "", enabled: false, service: "disabled")
        )
        let recorder = DebugBundleSwiftUILifecycleRecorder()
        recorder.recordScreen("Checkout", source: "swiftui")
        recorder.recordScenePhase(.active, screenName: "Checkout")
        recorder.recordScenePhase(.background, screenName: "Checkout")
        recorder.recordAction(actionType: "tap", targetType: "button", resourceName: "pay_now")

        let view = Text("Checkout")
            .debugBundleScreen("Checkout")
            .debugBundleNavigationScreen("Payment")
            .debugBundleAction("submit", targetType: "button", resourceName: "pay_now")
            .modifier(DebugBundleScreenModifier(screenName: "Receipt", recorder: recorder))
            .modifier(
                DebugBundleActionModifier(
                    targetType: "link",
                    resourceName: "receipt",
                    recorder: recorder
                )
            )
        let renderer = ImageRenderer(content: view)

#if canImport(UIKit)
        XCTAssertNotNil(renderer.uiImage)
#elseif canImport(AppKit)
        XCTAssertNotNil(renderer.nsImage)
#endif
    }

    func testLifecycleRecorderMapsScenePhasesAndActions() {
        var events: [String] = []
        let recorder = DebugBundleSwiftUILifecycleRecorder(
            recordScreen: { screenName, source in
                events.append("screen:\(screenName):\(source)")
            },
            recordForeground: { screenName in
                events.append("foreground:\(screenName ?? "nil")")
            },
            recordBackground: { screenName in
                events.append("background:\(screenName ?? "nil")")
            },
            recordAction: { actionType, targetType, resourceName in
                events.append("action:\(actionType):\(targetType):\(resourceName ?? "nil")")
            }
        )

        recorder.recordScreen("Checkout", source: "swiftui")
        recorder.recordScenePhase(.active, screenName: "Checkout")
        recorder.recordScenePhase(.inactive, screenName: "Checkout")
        recorder.recordScenePhase(.background, screenName: "Checkout")
        recorder.recordAction(actionType: "tap", targetType: "button", resourceName: "pay_now")
        recorder.recordScreen("Payment", source: "swiftui_navigation")

        XCTAssertEqual(events, [
            "screen:Checkout:swiftui",
            "foreground:Checkout",
            "background:Checkout",
            "action:tap:button:pay_now",
            "screen:Payment:swiftui_navigation"
        ])
    }

#if canImport(UIKit)
    @MainActor
    func testScreenModifierRecordsOnAppearWhenHosted() async {
        let screenRecorded = expectation(description: "screen recorded")
        var events: [String] = []

        let recorder = DebugBundleSwiftUILifecycleRecorder(
            recordScreen: { screenName, source in
                events.append("screen:\(screenName):\(source)")
                screenRecorded.fulfill()
            }
        )

        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIHostingController(
            rootView: Text("Checkout")
                .modifier(DebugBundleScreenModifier(screenName: "Checkout", recorder: recorder))
        )

        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

        await fulfillment(of: [screenRecorded], timeout: 1)
        XCTAssertEqual(events, ["screen:Checkout:swiftui"])
        XCTAssertFalse(window.isHidden)
    }
#endif
}
#endif
