import DebugBundle
import Foundation

public struct DebugBundleBackgroundTaskToken: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public struct DebugBundleBackgroundFlushCoordinator {
    public typealias BeginTask = (@escaping @Sendable () -> Void) -> DebugBundleBackgroundTaskToken?
    public typealias EndTask = (DebugBundleBackgroundTaskToken) -> Void

    private final class State {
        private let lock = NSLock()
        private let endTask: EndTask
        private var token: DebugBundleBackgroundTaskToken?
        private var ended = false

        init(endTask: @escaping EndTask) {
            self.endTask = endTask
        }

        func setToken(_ token: DebugBundleBackgroundTaskToken) {
            let shouldEndImmediately = lock.withLock {
                self.token = token
                return ended
            }
            if shouldEndImmediately {
                endTask(token)
            }
        }

        func finish() {
            let tokenToEnd = lock.withLock { () -> DebugBundleBackgroundTaskToken? in
                if ended {
                    return nil
                }
                ended = true
                return token
            }
            guard let tokenToEnd else {
                return
            }
            endTask(tokenToEnd)
        }
    }

    private let beginTask: BeginTask
    private let flush: @Sendable () async -> Void
    private let endTask: EndTask

    public init(
        beginTask: @escaping BeginTask,
        endTask: @escaping EndTask,
        flush: @escaping @Sendable () async -> Void = {
            await DebugBundle.flush()
        }
    ) {
        self.beginTask = beginTask
        self.endTask = endTask
        self.flush = flush
    }

    public func performFlush() {
        let state = State(endTask: endTask)
        if let token = beginTask({
            state.finish()
        }) {
            state.setToken(token)
        }

        Task {
            await flush()
            state.finish()
        }
    }
}

public struct DebugBundleUIKitLifecycleRecorder {
    private let recordBreadcrumbImpl: (String, [String: Any?]?) -> Void
    private let recordScreenImpl: (String, String) -> Void
    private let recordAppForegroundImpl: () -> Void
    private let recordAppBackgroundImpl: () -> Void

    public init(
        recordBreadcrumb: @escaping (String, [String: Any?]?) -> Void = { name, data in
            DebugBundle.recordBreadcrumb(name, data: data ?? [:])
        },
        recordScreen: @escaping (String, String) -> Void = { screenName, source in
            DebugBundle.recordScreen(screenName, source: source)
        },
        recordAppForeground: @escaping () -> Void = {
            DebugBundle.recordAppForeground()
        },
        recordAppBackground: @escaping () -> Void = {
            DebugBundle.recordAppBackground()
        }
    ) {
        self.recordBreadcrumbImpl = recordBreadcrumb
        self.recordScreenImpl = recordScreen
        self.recordAppForegroundImpl = recordAppForeground
        self.recordAppBackgroundImpl = recordAppBackground
    }

    public func install(applicationStateRawValue: Int, isActive: Bool) {
        recordBreadcrumbImpl("app_install", ["application_state": applicationStateRawValue])
        if isActive {
            recordAppForegroundImpl()
        }
    }

    public func recordAppForeground() {
        recordAppForegroundImpl()
    }

    public func recordAppBackground() {
        recordAppBackgroundImpl()
    }

    public func recordSceneForeground(_ sceneName: String) {
        recordScreenImpl(sceneName, "uikit_scene")
        recordAppForegroundImpl()
    }

    public func recordSceneBackground(_ sceneName: String) {
        recordScreenImpl(sceneName, "uikit_scene")
        recordAppBackgroundImpl()
    }

    public func recordViewControllerAppearance(screenName: String, animated: Bool) {
        recordScreenImpl(
            screenName,
            animated ? "uikit_view_controller_animated" : "uikit_view_controller"
        )
    }

    public func recordNavigation(screenName: String, animated: Bool) {
        recordScreenImpl(
            screenName,
            animated ? "uikit_navigation_animated" : "uikit_navigation"
        )
    }
}

#if canImport(UIKit)
import UIKit

public enum DebugBundleUIKit {
    public static func install(
        application: UIApplication,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.install(
            applicationStateRawValue: application.applicationState.rawValue,
            isActive: application.applicationState == .active
        )
    }

    public static func applicationDidBecomeActive(
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordAppForeground()
    }

    public static func applicationDidEnterBackground(
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordAppBackground()
    }

    public static func applicationDidEnterBackground(
        application: UIApplication,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder(),
        flush: @escaping @Sendable () async -> Void = {
            await DebugBundle.flush()
        }
    ) {
        recorder.recordAppBackground()
        DebugBundleBackgroundFlushCoordinator(
            beginTask: { expirationHandler in
                let identifier = application.beginBackgroundTask(
                    withName: "DebugBundleFlush",
                    expirationHandler: expirationHandler
                )
                guard identifier != .invalid else {
                    return nil
                }
                return DebugBundleBackgroundTaskToken(rawValue: identifier.rawValue)
            },
            endTask: { token in
                application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
            },
            flush: flush
        ).performFlush()
    }

    public static func recordSceneForeground(
        _ sceneName: String,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordSceneForeground(sceneName)
    }

    public static func recordSceneBackground(
        _ sceneName: String,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordSceneBackground(sceneName)
    }

    public static func sceneWillEnterForeground(
        _ scene: UIScene,
        sceneName: String? = nil,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordSceneForeground(resolvedSceneName(for: scene, explicit: sceneName))
    }

    public static func sceneDidEnterBackground(
        _ scene: UIScene,
        sceneName: String? = nil,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordSceneBackground(resolvedSceneName(for: scene, explicit: sceneName))
    }

    public static func recordViewControllerAppear(
        _ viewController: UIViewController,
        screenName: String? = nil,
        animated: Bool,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder()
    ) {
        recorder.recordViewControllerAppearance(
            screenName: resolvedViewControllerName(for: viewController, explicit: screenName),
            animated: animated
        )
    }

    private static func resolvedSceneName(for scene: UIScene, explicit: String?) -> String {
        if let explicit = sanitizedName(explicit) {
            return explicit
        }

        let configurationName = scene.session.configuration.name
        if let configurationName = sanitizedName(configurationName) {
            return configurationName
        }

        return String(describing: type(of: scene))
    }

    static func resolvedViewControllerName(for viewController: UIViewController, explicit: String?) -> String {
        sanitizedName(explicit) ?? String(describing: type(of: viewController))
    }

    private static func sanitizedName(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public final class DebugBundleNavigationDelegate: NSObject, UINavigationControllerDelegate {
    private let existingDelegate: UINavigationControllerDelegate?
    private let recorder: DebugBundleUIKitLifecycleRecorder
    private let screenNameProvider: ((UIViewController) -> String?)?

    public init(
        existing: UINavigationControllerDelegate? = nil,
        recorder: DebugBundleUIKitLifecycleRecorder = DebugBundleUIKitLifecycleRecorder(),
        screenNameProvider: ((UIViewController) -> String?)? = nil
    ) {
        self.existingDelegate = existing
        self.recorder = recorder
        self.screenNameProvider = screenNameProvider
    }

    public override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (existingDelegate?.responds(to: aSelector) ?? false)
    }

    public override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if existingDelegate?.responds(to: aSelector) == true {
            return existingDelegate
        }

        return super.forwardingTarget(for: aSelector)
    }

    public func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        recorder.recordNavigation(
            screenName: DebugBundleUIKit.resolvedViewControllerName(
                for: viewController,
                explicit: screenNameProvider?(viewController)
            ),
            animated: animated
        )
        existingDelegate?.navigationController?(navigationController, didShow: viewController, animated: animated)
    }
}
#else
public enum DebugBundleUIKit {}
public final class DebugBundleNavigationDelegate {
    public init(existing: Any? = nil) {}
}
#endif

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}