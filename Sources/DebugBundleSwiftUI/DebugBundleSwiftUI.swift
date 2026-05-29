import DebugBundle

#if canImport(SwiftUI)
import SwiftUI

public struct DebugBundleSwiftUILifecycleRecorder {
    private let recordScreenImpl: (String, String) -> Void
    private let recordForegroundImpl: (String?) -> Void
    private let recordBackgroundImpl: (String?) -> Void
    private let recordActionImpl: (String, String, String?) -> Void

    public init(
        recordScreen: @escaping (String, String) -> Void = { screenName, source in
            DebugBundle.recordScreen(screenName, source: source)
        },
        recordForeground: @escaping (String?) -> Void = { _ in
            DebugBundle.recordAppForeground()
        },
        recordBackground: @escaping (String?) -> Void = { _ in
            DebugBundle.recordAppBackground()
        },
        recordAction: @escaping (String, String, String?) -> Void = { actionType, targetType, resourceName in
            DebugBundle.recordAction(actionType, targetType: targetType, resourceName: resourceName)
        }
    ) {
        self.recordScreenImpl = recordScreen
        self.recordForegroundImpl = recordForeground
        self.recordBackgroundImpl = recordBackground
        self.recordActionImpl = recordAction
    }

    public func recordScreen(_ screenName: String, source: String) {
        recordScreenImpl(screenName, source)
    }

    public func recordScenePhase(_ scenePhase: ScenePhase, screenName: String?) {
        switch scenePhase {
        case .active:
            recordForegroundImpl(screenName)
        case .background:
            recordBackgroundImpl(screenName)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    public func recordAction(actionType: String, targetType: String, resourceName: String?) {
        recordActionImpl(actionType, targetType, resourceName)
    }
}

public struct DebugBundleScreenModifier: ViewModifier {
    private let screenName: String
    private let source: String
    @Environment(\.scenePhase) private var scenePhase
    private let recorder: DebugBundleSwiftUILifecycleRecorder

    public init(
        screenName: String,
        source: String = "swiftui",
        recorder: DebugBundleSwiftUILifecycleRecorder = DebugBundleSwiftUILifecycleRecorder()
    ) {
        self.screenName = screenName
        self.source = source
        self.recorder = recorder
    }

    public func body(content: Content) -> some View {
        content
            .onAppear {
                recorder.recordScreen(screenName, source: source)
            }
            .onChange(of: scenePhase) { newPhase in
                recorder.recordScenePhase(newPhase, screenName: screenName)
            }
    }
}

public struct DebugBundleActionModifier: ViewModifier {
    private let actionType: String
    private let targetType: String
    private let resourceName: String?
    private let recorder: DebugBundleSwiftUILifecycleRecorder

    public init(
        actionType: String = "tap",
        targetType: String,
        resourceName: String? = nil,
        recorder: DebugBundleSwiftUILifecycleRecorder = DebugBundleSwiftUILifecycleRecorder()
    ) {
        self.actionType = actionType
        self.targetType = targetType
        self.resourceName = resourceName
        self.recorder = recorder
    }

    public func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture().onEnded {
                recorder.recordAction(actionType: actionType, targetType: targetType, resourceName: resourceName)
            }
        )
    }
}

public extension View {
    func debugBundleScreen(_ screenName: String) -> some View {
        modifier(DebugBundleScreenModifier(screenName: screenName))
    }

    func debugBundleNavigationScreen(_ screenName: String) -> some View {
        modifier(DebugBundleScreenModifier(screenName: screenName, source: "swiftui_navigation"))
    }

    func debugBundleAction(
        _ actionType: String = "tap",
        targetType: String,
        resourceName: String? = nil
    ) -> some View {
        modifier(
            DebugBundleActionModifier(
                actionType: actionType,
                targetType: targetType,
                resourceName: resourceName
            )
        )
    }
}
#endif