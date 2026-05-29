# DebugBundle Swift

![SwiftPM](https://img.shields.io/badge/swiftpm-v0.1.1-orange)
![CI](https://img.shields.io/github/actions/workflow/status/debugbundle/debugbundle-swift/ci.yml?branch=main&label=ci)
![License](https://img.shields.io/badge/license-AGPL--3.0--only-blue)

Native DebugBundle SDK for iOS and iPadOS apps, with SwiftUI and UIKit lifecycle capture, URLSession trace injection, offline queueing, SwiftLog support, crash replay helpers, and probes.

Swift is a mobile client SDK, not a browser relay host. It sends mobile events to the configured ingestion endpoint and uses explicit first-party URLSession or Alamofire instrumentation for trace correlation; browser relay settings such as `transportMode`, `allowedOrigins`, and CORS preflight handling belong to the Browser SDK plus a backend/server SDK relay.

The Swift SDK is published through Swift Package Manager from `https://github.com/debugbundle/debugbundle-swift`.

## Installation

Add the package to your app target:

```swift
// Package.swift
.dependencies: [
	.package(url: "https://github.com/debugbundle/debugbundle-swift", from: "0.1.1")
],
.targets: [
	.target(
		name: "CheckoutApp",
		dependencies: [
			.product(name: "DebugBundle", package: "debugbundle-swift"),
			.product(name: "DebugBundleURLSession", package: "debugbundle-swift"),
			.product(name: "DebugBundleUIKit", package: "debugbundle-swift"),
			.product(name: "DebugBundleSwiftUI", package: "debugbundle-swift"),
			.product(name: "DebugBundleSwiftLog", package: "debugbundle-swift")
		]
	)
]
```

In Xcode, you can also use File -> Add Package Dependencies... with `https://github.com/debugbundle/debugbundle-swift` and select `0.1.1` or a compatible SemVer range.

Available products:

| Product | Purpose |
| --- | --- |
| `DebugBundle` | Core client, facade, queueing, transport, redaction, capture policy, and probes |
| `DebugBundleURLSession` | URLSession instrumentation, trace propagation, and request capture |
| `DebugBundleAlamofire` | Alamofire adapter for trace injection and request capture |
| `DebugBundleUIKit` | UIApplication, UIScene, view-controller, and navigation helpers |
| `DebugBundleSwiftUI` | SwiftUI screen, scene-phase, navigation, and action breadcrumbs |
| `DebugBundleCrashReporter` | Next-launch crash evidence replay and Objective-C exception bridging |
| `DebugBundleSwiftLog` | SwiftLog `LogHandler` integration |
| `DebugBundleTestSupport` | Fake transports, queue inspection helpers, and mock ingestion support |

## Quick Start

### SwiftUI

```swift
import DebugBundle
import DebugBundleSwiftUI

@main
struct CheckoutApp: App {
	init() {
		DebugBundle.initialize(
			DebugBundleConfig(
				projectToken: Bundle.main.debugBundleProjectToken,
				service: "checkout-ios",
				environment: "production",
				releaseChannel: "app-store"
			)
		)
	}

	var body: some Scene {
		WindowGroup {
			CheckoutRootView()
				.debugBundleScreen("CheckoutRoot")
		}
	}
}
```

### UIKit

```swift
import DebugBundle
import DebugBundleUIKit
import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		DebugBundle.initialize(
			DebugBundleConfig(
				projectToken: Bundle.main.debugBundleProjectToken,
				service: "checkout-ios",
				environment: "production"
			)
		)

		DebugBundleUIKit.install(application: application)
		return true
	}
}
```

Capture explicit messages, logs, errors, and probes:

```swift
import DebugBundle

DebugBundle.captureMessage("checkout_started")
DebugBundle.captureLog("payment retry", level: .warning, context: ["attempt": attempt])
DebugBundle.setContext("tenant", value: tenantID)
DebugBundle.probe("checkout.cart", data: ["items": itemCount])

Task {
	do {
		try await DebugBundle.captureAsync(context: ["screen": "Checkout"]) {
			try await checkout()
		}
	} catch {
		DebugBundle.captureException(error, context: ["flow": "checkout"])
	}

	await DebugBundle.flush()
}
```

## Configuration Reference

Configuration sources and precedence:

1. Explicit `DebugBundleConfig(...)` fields always win.
2. Runtime configuration and `Bundle` helpers fill values when you use the bundle-backed config path.
3. SDK defaults apply for anything you leave unset.

Capture-policy fields are server-owned and are not accepted in local SDK configuration. The SDK learns capture policy and probe directives through remote config and applies them locally before transport.

| Field | Default | Purpose |
| --- | --- | --- |
| `projectToken` | empty | Write-only DebugBundle project token. Missing or blank tokens leave connected delivery disabled. |
| `enabled` | `true` | Global kill switch. |
| `environment` | `production` | Environment label such as `production`, `staging`, or `development`. |
| `service` | `ios-app` | Service name shown on incidents and bundles. |
| `endpoint` | `https://api.debugbundle.com/v1/events` | Ingestion endpoint for cloud or self-hosted delivery. |
| `batchSize` | `10` | Events per flush batch. |
| `flushInterval` | `3` seconds | Maximum delay before a background flush. |
| `sampleRate` | `1.0` | Per-event sample rate. |
| `sessionSampleRate` | `1.0` | Session-level sampling decision for the whole app session. |
| `requestTimeout` | `5` seconds | HTTP timeout for delivery and remote config fetches. |
| `releaseChannel` | `production` | App release lane such as `app-store`, `testflight`, or `internal`. |
| `appVersion` | app metadata when supplied | Human-readable app version attached to event metadata. |
| `buildNumber` | app metadata when supplied | Build number attached to event metadata. |
| `maxEventsPerSession` | `100` | Hard cap after which only exception capture continues. |
| `maxBreadcrumbs` | `20` | Ring-buffer size for screen, action, network, and log breadcrumbs. |
| `captureScreens` | `true` | Enable screen breadcrumbs. |
| `captureActions` | `false` | Enable manual action breadcrumbs. |
| `captureNetwork` | `true` | Enable first-party request capture. |
| `captureLogs` | `true` | Enable log-event capture. |
| `logLevel` | `.warning` | Minimum captured log severity. |
| `tracePropagationTargets` | `[]` | Allowed first-party targets for `X-DebugBundle-Trace-Id` injection. |
| `offlineQueueMaxEvents` | `500` | Maximum queued events persisted on device. |
| `offlineQueueMaxBytes` | `5 MB` | Maximum queue size on disk. |
| `offlineQueueTtl` | `72` hours | Drop queued events older than this on delivery attempt. |
| `fileProtection` | `.completeUntilFirstUserAuthentication` | Queue file protection class for app-private storage. |
| `offlineQueueURL` | SDK-managed Application Support path | Override queue storage location for tests or advanced setups. |
| `maxProbeLabels` | `50` | Maximum distinct probe labels buffered in memory. |
| `maxProbeEntriesPerLabel` | `10` | Ring-buffer size per probe label. |
| `probeFlushOnError` | `true` | Attach buffered probes to captured exceptions. |
| `redactFields` | built-in sensitive field set | Additional field names to redact before persistence or transport. |
| `headerAllowlist` | built-in safe header set | Headers allowed into captured network metadata. |
| `sdkVersion` | `0.1.1` | SDK version stamped into outgoing event metadata. |

## Install Examples By Mode

### URLSession

```swift
import DebugBundleURLSession

let configuration = URLSessionConfiguration.default
configuration.debugBundleInstrumented(
	tracePropagationTargets: ["https://api.example.com"]
)

let session = URLSession(configuration: configuration)
```

If you want an instrumented request wrapper that also records request summaries, use `DebugBundleInstrumentedURLSession`.

### Alamofire

```swift
import Alamofire
import DebugBundleAlamofire

let session = Session.debugBundleInstrumented(
	tracePropagationTargets: ["https://api.example.com"]
)
```

### SwiftLog

```swift
import DebugBundleSwiftLog
import Logging

LoggingSystem.bootstrap { label in
	DebugBundleLogHandler(label: label)
}
```

### UIKit screen naming

```swift
override func viewDidAppear(_ animated: Bool) {
	super.viewDidAppear(animated)
	DebugBundleUIKit.recordViewControllerAppear(self, screenName: "Checkout", animated: animated)
}
```

### SwiftUI screen and action breadcrumbs

```swift
CheckoutView()
	.debugBundleScreen("Checkout")
	.debugBundleAction("tap", targetType: "button", resourceName: "place-order")
```

## Runtime And Platform Support

| Label | Runtime / platform |
| --- | --- |
| Minimum app compatibility target | iOS 15 and iPadOS 15 |
| Host development lane | Swift 5.10 toolchain on macOS with Swift 6-compatible concurrency patterns where practical |
| Current package release | `v0.1.1` |
| Installed-base validation lane | SwiftPM package tests on macOS plus iOS simulator coverage through `xcodebuild` |
| Primary supported app surfaces | SwiftUI, UIKit, URLSession, Alamofire, SwiftLog |
| Out of scope for V1 | macOS app runtime capture, watchOS, tvOS, visionOS, widgets, App Clips, server-side Swift |

## Dependency Alignment

Keep all DebugBundle Swift products on the same package tag. Optional products like `DebugBundleAlamofire`, `DebugBundleSwiftLog`, and `DebugBundleCrashReporter` are intended to stay aligned with the core `DebugBundle` version.

If you use Alamofire or SwiftLog integration, stay within the package-declared dependency lanes resolved by Swift Package Manager for the selected SDK tag instead of mixing snippets from different tags.

## Current Scope

- Universal Swift facade and instance client
- No-throw capture APIs plus explicit `captureAsync` and `captureTask` helpers
- Sensitive-field redaction before queue persistence or transport
- Durable file-backed offline queue with TTL and byte and event bounds
- Connectivity-aware deferred delivery with bounded retry windows and `Retry-After` handling
- Automatic flush triggers on batch size, interval, foreground and background lifecycle, and explicit flush
- Duplicate suppression and `error_suppressed` aggregate emission
- Session sampling, per-session caps, breadcrumb buffering, and always-on probes
- Bundle and runtime configuration resolution helpers with `Bundle.main.debugBundleProjectToken` support
- Remote config fetch with local capture-policy enforcement and probe directives
- URLSession instrumentation, explicit instrumented session helpers, and configuration-backed URLProtocol instrumentation
- Optional Alamofire adapter target with trace injection and request-event capture
- UIKit app, scene, view-controller, and navigation helpers plus SwiftUI screen, scene-phase, navigation, and action modifiers
- SwiftLog adapter target
- Crash-reporter target with bounded fatal-crash evidence persistence, next-launch replay helpers, and Objective-C exception bridging
- Test support with recording transports, mock ingestion, decoded batch fixtures, and queue inspection helpers

## Safety Defaults

- SDK failures are fail-open and do not crash the host app.
- Missing or blank connected credentials leave the SDK in a degraded or disconnected no-op state instead of pretending delivery is healthy.
- Request and response bodies are disabled by default.
- Header capture is allowlist-based.
- Sensitive fields are redacted before queue persistence or transport.
- Screenshots, text fields, clipboard, contacts, keychain values, photos, precise location, IDFV, and advertising IDs are not captured by default.
- Duplicate storms are suppressed locally before transport.

## Service Naming

- Use one stable service name per shipped app surface, such as `checkout-ios` or `consumer-ios`.
- When one DebugBundle project receives mobile and backend traffic, keep service names distinct, for example `checkout-ios`, `checkout-api`, and `checkout-worker`.
- Reuse the same environment label across related surfaces so incident correlation stays readable.

## Safe Startup And Status

`DebugBundle.initialize(...)` is fail-open. If the project token or endpoint is missing or invalid, the SDK degrades to a no-op capture path instead of crashing the host app.

Normal status values:

- `healthy` when the last flush succeeded or the SDK is idle
- `degraded` when delivery is rate-limited or temporarily failing and buffered events are being retained for retry
- `disconnected` when the SDK is not initialized with a usable config or repeated failures have exhausted the current connection path

`DebugBundle.lastEventAt` returns the timestamp of the last successful delivery, or `nil` before the first success.

## First Event Verification

Point the SDK at a mock, staging, or self-hosted ingestion endpoint that the simulator or device can actually reach:

```swift
import Foundation
import DebugBundle

DebugBundle.initialize(
	DebugBundleConfig(
		projectToken: Bundle.main.debugBundleProjectToken,
		service: "checkout-ios",
		environment: "staging",
		endpoint: URL(string: "http://127.0.0.1:9001/v1/events")!
	)
)

DebugBundle.captureMessage("swift-sdk-smoke", level: .error)

Task {
	await DebugBundle.flush()
}
```

Then confirm the mock or staging project received the event with the expected `service`, `environment`, and SDK metadata.

## Validation

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

## Documentation

Full docs: `https://debugbundle.com/docs/sdks/swift`

See also:

- `https://debugbundle.com/docs/quickstart`
- `https://debugbundle.com/docs/installation`
- `https://debugbundle.com/docs/sdks/universal-interface`

## License

AGPL-3.0-only