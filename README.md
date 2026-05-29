# DebugBundle Swift

Swift Package Manager SDK for DebugBundle.

This repository is the native Apple-platform client SDK surface. The current implementation establishes the core universal API, fail-open client behavior, redaction, duplicate suppression, offline delivery, capture-policy enforcement, remote probes, and first-party Apple-platform adapters.

## Current Scope

- Universal Swift facade and instance client
- No-throw capture APIs
- Explicit `captureAsync` wrapper for async operations that captures and rethrows application errors
- No-throw `captureTask` helper for spawned async task boundaries
- Canonical event envelope builder
- Sensitive-field redaction before buffering or transport
- Durable file-backed offline queue with TTL and byte/event bounds
- Configurable queue file protection with iOS-family application support
- Connectivity-aware deferred delivery through an injectable `NWPathMonitor`-backed monitor
- Bounded retry windows for `429`, transient `5xx`, and transport errors with `Retry-After` support
- Automatic flush triggers on `batchSize`, `flushInterval`, and lifecycle background
- UIKit helper for bounded background flush execution time via `UIApplication.beginBackgroundTask`
- Bounded remote-config refresh on init, explicit flush, and foreground resume using `poll_interval_ms` when available
- Transport sends capped to `batchSize`, plus internal diagnostics for dropped non-`429` `4xx` queue batches
- HTTP transport with bounded `Retry-After` handling
- Duplicate suppression and `error_suppressed` aggregate emission
- Session sampling and max-events-per-session enforcement
- Breadcrumb ring buffer attached to exception events
- Always-on probe buffering with error attachment
- Bundle and runtime configuration resolution helpers with `Bundle.main.debugBundleProjectToken` support
- Remote config fetch with local capture-policy enforcement and probe directives
- URLSession request instrumentation helpers, explicit instrumented session capture, and configuration-backed URLProtocol instrumentation
- Optional Alamofire adapter target with trace injection and request-event capture
- UIKit app, scene, view-controller, and composed navigation helpers plus SwiftUI screen, scene-phase, navigation, and action breadcrumb modifiers
- SwiftLog `LogHandler` adapter target
- Crash-reporter target with bounded fatal-crash evidence persistence, next-launch replay helpers, and explicit Objective-C exception bridging
- Test support with a recording transport, localhost mock ingestion server, decoded batch fixtures, and queue inspection helpers

## Build And Verification

```sh
make test
make test-ios-simulator
make build
```

`make test-ios-simulator` auto-resolves a usable iPhone simulator from the locally installed runtimes.

Override the simulator destination when needed:

```sh
make test-ios-simulator IOS_SIMULATOR_DESTINATION="platform=iOS Simulator,name=iPhone 17,OS=latest"
```

## Support Labels

- Minimum compatibility target: iOS 15 and iPadOS 15 through Swift Package Manager
- Current package development lane: Swift 5.10 toolchain with Swift 6-compatible concurrency patterns where practical
- Installed-base validation in this repo: SwiftPM package tests on macOS plus iOS simulator package tests through `xcodebuild`, including UIKit and SwiftUI lifecycle coverage

## Configuration Notes

- Configuration precedence is programmatic `DebugBundleConfig`, then injected runtime configuration, then Info.plist or Xcode-provided values, then SDK defaults.
- Capture-policy fields are server-owned and are not accepted from local SDK configuration.
- Use platform-specific service names such as `checkout-ios` and `checkout-android` when multiple mobile surfaces share one DebugBundle project.
- All DebugBundle Swift package products should be consumed from the same package version. Optional products like `DebugBundleAlamofire`, `DebugBundleSwiftLog`, and `DebugBundleCrashReporter` are intended to stay aligned with the core `DebugBundle` package tag.

## Safe Startup

When `enabled` is true but the SDK has no usable project token or endpoint, it fails open: capture calls stay silent, the host app keeps running, and `DebugBundle.status` reports a degraded or disconnected state instead of pretending capture is healthy.

## First Event Verification

```swift
import DebugBundle

DebugBundle.initialize(
	DebugBundleConfig(
		projectToken: Bundle.main.debugBundleProjectToken,
		service: "checkout-ios",
		environment: "staging",
		endpoint: "http://127.0.0.1:9001/v1/events"
	)
)

DebugBundle.captureMessage("swift-sdk-smoke", level: .error)

Task {
	await DebugBundle.flush()
}
```

Point `endpoint` at the local mock ingestion server from `DebugBundleTestSupport` or another staging ingestion endpoint, send one explicit message or exception, flush, and confirm the mock or staging project received an event with the expected `service`, `environment`, and SDK metadata.

Remaining slices still include deeper crash evidence handling and iOS-safe background delivery hooks beyond lifecycle-triggered flush.

## CI

This repo now includes a GitHub Actions workflow that runs both the host SwiftPM lane and the iOS simulator lane from the Makefile so local and CI verification stay aligned.

## Optional Alamofire Adapter

```swift
import Alamofire
import DebugBundleAlamofire

let session = Session.debugBundleInstrumented(
	tracePropagationTargets: ["https://api.example.com"]
)

let response = await session.request("https://api.example.com/checkout").serializingData().response
```

The adapter only injects `X-DebugBundle-Trace-Id` for explicitly allowed targets and records Alamofire request summaries through the same `request_event` path as the URLSession integration.

UIKit integration helpers are explicit forwarding helpers. Use `DebugBundleUIKit.install(application:)` in `UIApplicationDelegate`, forward app and scene lifecycle callbacks through `DebugBundleUIKit`, call `recordViewControllerAppear(_:screenName:animated:)` from `viewDidAppear` when you need explicit screen naming, and wrap existing navigation delegates with `DebugBundleNavigationDelegate(existing:)` so navigation breadcrumbs compose with existing delegate behavior.

When the app delegate has access to `UIApplication`, prefer the bounded background-flush overload so iOS grants a short execution window for delivery attempts:

```swift
func applicationDidEnterBackground(_ application: UIApplication) {
	DebugBundleUIKit.applicationDidEnterBackground(application: application)
}
```

This helper still respects iOS background limits. It improves the chance of a flush completing during suspension, but does not guarantee delivery and does not replace a larger background URLSession or `BGTaskScheduler` strategy.