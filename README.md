# DebugBundle Swift

![SwiftPM](https://img.shields.io/badge/swiftpm-v3.1.0--candidate-orange)
![CI](https://img.shields.io/github/actions/workflow/status/debugbundle/debugbundle-swift/ci.yml?branch=main&label=ci)
![License](https://img.shields.io/badge/license-Apache--2.0-blue)

Native DebugBundle SDK for iOS and iPadOS apps, with SwiftUI and UIKit lifecycle capture, URLSession trace injection, offline queueing, SwiftLog support, crash replay helpers, and probes.

Version **3.0.0** changes hook and persistence timing. Review [the v3 migration](MIGRATION-3.0.md) before upgrading from 2.x.

Swift is a mobile client SDK, not a browser relay host. It sends mobile events to the configured ingestion endpoint and uses explicit first-party URLSession or Alamofire instrumentation for trace correlation; browser relay settings such as `transportMode`, `allowedOrigins`, and CORS preflight handling belong to the Browser SDK plus a backend/server SDK relay.

The Swift SDK is published through Swift Package Manager from `https://github.com/debugbundle/debugbundle-swift` and CocoaPods as `DebugBundle`.

## Unpublished 3.1.0 evidence candidate

The current working candidate adds `withEvidenceOptions(DebugBundleEvidenceOptions(...))` without changing existing configuration initializers. Structured exception evidence defaults on only for a proven complete delivery path; standalone recovery defaults off. Custom transports and opaque relays require an explicit complete-path `DebugBundleEvidenceCapabilities` pin. Native HTTP/config discovers support through the existing requests, with bounded identity/UTF-8 responses and a total request deadline. Missing or unknown proof downgrades optional evidence on retries while preserving the protected primary failure.

Native cause collection runs on the existing delivery worker and keeps only weak error references across admission. Exact Foundation `NSError` values support `NSUnderlyingErrorKey` and `NSMultipleUnderlyingErrorsKey`, under eight-node/four-depth/five-child and 32KiB addition bounds. Root `Thread.callStackSymbols` locations are capture-time evidence. Underlying errors do not acquire fabricated throw-site stacks; arbitrary Swift value errors and unsafe custom native accessors report unavailable details. No Mirror, frame-local inspection or symbolication is added. A collected or deallocated error cannot be recovered retrospectively. Native/runtime, packaged-artifact and complete parity qualification remain in progress; this candidate is not published. See [3.1 compatibility and evidence guidance](MIGRATION-3.1.md).

### Explicit recovery and operation scope

Opt in with `config.withEvidenceOptions(.init(captureRecoveryObservations: true))`.
The existing config/ACK lifecycle must prove support through the complete path.
`client.evidenceCapabilities` and the equivalent facade property expose the
intersection of that proof, local options and the current diagnostic policy.

```swift
let scope = client.beginOperation()
defer { scope.close() }
let failureRef = UUID().uuidString.lowercased()
client.captureException(error, context: DebugBundleEvidenceContext.forFailure(
    failureRef, scope: scope.evidenceScope))
client.captureRecovery(.init(
    failureRef: failureRef, attemptId: UUID().uuidString.lowercased(),
    state: "attempt_completed", scope: scope.evidenceScope, statusCode: 200))
```

Manual scopes are synchronous and thread local. Use `withOperationContext { ... }`
(or its async overload) across suspension points; ended parent scopes cannot be
reused by outliving child tasks. Reuse a fresh attempt ID for observations of the
same attempt. States are `attempt_started`, `attempt_completed`, `attempt_failed`,
`recovery_observed` and `failure_persisted`. Report semantic recovery only when the
application actually observes it. HTTP 200 and completion alone leave recovery
unknown. Explicit context uses the existing queue, policy, sampling, quotas and
metering; it is independent of remote probes. It is bounded to 50 failure windows,
five attempts and 20 observations per failure, five minutes and 64KiB of combined
metadata/pending data. Offline retention cannot renew an expired window.

### Crash and queue handoff

`DebugBundleCrashReporter` keeps small, private, protected runtime reports with
original capture time and stable identity. The no-reporter
`replayPendingCrash(store:)` and `replayPendingCrash(store:client:)` overloads keep
the record until acknowledged durable local persistence or a canonical ingestion
ACK. The optional `DebugBundleAcknowledgingQueueStore` protocol lets a custom
store explicitly confirm persistence; legacy `Void` stores cannot provide that
proof. Explicit legacy `report:` callbacks retain their caller-owned immediate
handoff behaviour. A previous crash never consumes current-launch probes or
breadcrumbs. Supplied native fatal frames are bounded to eight frames and 4KiB
of combined evidence; an unavailable throw trace is never replaced with a
capture trace labelled as the original. Default persisted trace origin is unknown;
use the explicit `traceOrigin:` overload when the reporter knows it.

Caught Objective-C exceptions retain supported native frames via
`DebugBundleObjCExceptionBridge`; unsafe custom getters are not inspected. Native
fatal storage is best effort and avoids waiting for another SDK store operation.
It does not promise recovery from hard kill, OOM, signal-handler restrictions or
unavailable storage. It adds no signal handler or third-party crash backend.

## Installation

### Swift Package Manager

Add the package to your app target:

```swift
// Package.swift
.dependencies: [
	.package(url: "https://github.com/debugbundle/debugbundle-swift", from: "3.0.1")
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

In Xcode, you can also use File -> Add Package Dependencies... with `https://github.com/debugbundle/debugbundle-swift` and select `3.0.1` or a compatible SemVer range.

### CocoaPods

Add the pod to your iOS app target:

```ruby
target "CheckoutApp" do
	pod "DebugBundle", "~> 3.0"
end
```

Then run:

```sh
pod install
```

The CocoaPods package currently publishes the core `DebugBundle` native client used by React Native and brownfield pod-based iOS apps. Use Swift Package Manager when you need the optional Swift package products listed below.

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
| `flushInterval` | `3` seconds | Background flush interval; delivery also depends on worker and transport availability. |
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
| `offlineQueueMaxEvents` | `500` | Shared cap across pending hooks, ready events, persistence snapshots and in-flight sends. |
| `offlineQueueMaxBytes` | `5 MB` | Shared serialized-byte cap across all retained queue states; each event is also capped at 256 KiB. |
| `offlineQueueTtl` | `72` hours | Drop queued events older than this on delivery attempt. |
| `fileProtection` | `.completeUntilFirstUserAuthentication` | Queue file protection class for app-private storage. |
| `offlineQueueURL` | SDK-managed Application Support path | Override queue storage location for tests or advanced setups. |
| `maxProbeLabels` | `50` | Maximum distinct probe labels buffered in memory. |
| `maxProbeEntriesPerLabel` | `10` | Ring-buffer size per probe label. |
| `probeFlushOnError` | `true` | Attach buffered probes to captured exceptions. |
| `redactFields` | built-in sensitive field set | Additional field names; the mandatory credential baseline remains active even when this set is empty. |
| `headerAllowlist` | built-in safe header set | Headers allowed into captured network metadata. |
| `sdkVersion` | `3.1.0` candidate | SDK version stamped into outgoing event metadata. |

Logs rejected by the effective local and remote level, and events rejected by full-queue priority admission, return before hook work. Capture retains a bounded privacy-safe snapshot, then returns; one serial worker runs accepted `beforeSend` hooks, final policy/privacy checks, queue recovery and coalesced persistence. Hooks cannot rely on the caller thread or synchronous side effects. Device metadata and weakly held custom reference-error details use that worker too; unsupported custom value/error accessors are withheld as described in the v3 migration.

`await flush()` waits at most `requestTimeout` (capped at 60 seconds), including preparation and persistence. It does not acknowledge events on timeout or free a stuck sender's ownership. Remote config runs separately. A stalled hook, store or transport causes bounded best-effort loss instead of additional workers or unbounded tasks. Use short, thread-safe hooks, and see [v3 migration](MIGRATION-3.0.md) for shutdown and custom-store implications.

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

Swift 5.10–6.1 uses the original SwiftLog `LogHandler` interface. Swift 6.2+
retains the error-bearing `LogEvent` overload and requires swift-log 1.12.0+.
SwiftPM selects compatible dependency versions for the active compiler; see
[3.1 compatibility guidance](MIGRATION-3.1.md) for the older logging fallback.

| Label | Runtime / platform |
| --- | --- |
| Minimum app compatibility target | iOS 15 and iPadOS 15 |
| Host development lane | Swift 5.10 toolchain on macOS with Swift 6-compatible concurrency patterns where practical |
| Published package baseline | `v3.0.1`; local unpublished candidate `3.1.0` |
| Installed-base validation lane | SwiftPM package tests on macOS plus iOS simulator coverage through `xcodebuild` |
| Primary supported app surfaces | SwiftUI, UIKit, URLSession, Alamofire, SwiftLog |
| Out of scope for V1 | macOS app runtime capture, watchOS, tvOS, visionOS, widgets, App Clips, server-side Swift |

## CocoaPods Release

Validate the podspec before release:

```sh
make pod-lint
```

Publish from an authenticated CocoaPods trunk session:

```sh
make pod-publish
```

GitHub Actions publishes the pod automatically for `v*` tags when the repository has a `COCOAPODS_TRUNK_TOKEN` secret. The tag must match `DebugBundle.podspec` exactly, for example `v3.0.1` for podspec version `3.0.1`.

## Dependency Alignment

Keep all DebugBundle Swift products on the same package tag. Optional products like `DebugBundleAlamofire`, `DebugBundleSwiftLog`, and `DebugBundleCrashReporter` are intended to stay aligned with the core `DebugBundle` version.

If you use Alamofire or SwiftLog integration, stay within the package-declared dependency lanes resolved by Swift Package Manager for the selected SDK tag instead of mixing snippets from different tags.

## Current Scope

- Universal Swift facade and instance client
- No-throw capture APIs plus explicit `captureAsync` and `captureTask` helpers
- Sensitive-field redaction before queue persistence or transport
- Durable file-backed offline queue with TTL and byte and event bounds
- Connectivity-aware deferred delivery with bounded retry windows and `Retry-After` handling
- HTTP and custom retry hints must be finite; invalid hints use safe fallback backoff and valid numeric hints are capped at five minutes.
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
- `telemetry-privacy-v1` protects credential fields/text before capture hooks and again before queue persistence or transport. Older file queue records are bounded, projected, and atomically rewritten by the background startup worker before replay; corrupt/oversized records are withheld. The policy cannot infer every arbitrary confidential value, so keep capture allowlists and customer field configuration narrow.
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
The CocoaPods publication workflow runs this simulator gate and compiles the iOS 15 deployment target before pushing a podspec.

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

Apache-2.0

### Ingestion retry hints

Retryable partial acknowledgements, malformed acknowledgements and server failures honor bounded `Retry-After` hints, including HTTP-date headers. Delays are capped at five minutes and measured from response receipt. Existing fallback backoff remains in effect when no hint is supplied.

## Probe checkpoint guidance

Application instrumentation supplies probe labels and bounded data. Deploy a new
checkpoint before activating it. Remote activation affects future matching calls
when policy permits; it does not inject code or recover unretained measurements.
Built-in runtime/error/device collectors keep their documented SDK settings.

Use fixed labels and allowlisted technical states: `media.preview.checkpoint`
(stage/input kind/attempt), `auth.session.checkpoint` (observed session presence
and result), `job.dependency.checkpoint` (named dependency/attempt/result), or
`cache.preview.checkpoint` (hit/miss/coarse age bucket). Omit customer identifiers,
tokens/cookies, cache keys, URLs and raw payloads. HTTP 200 or attempt completion
alone does not establish semantic recovery.

Empty probe data means no matching retained observation for the selected sample
window. It does not confirm activation delivery to every SDK or execution of a
label. Check the deployed SDK/wrapper version, instrumentation, scope, expiry,
policy, sampling and delivery receipts. See the [probe recipes](https://debugbundle.com/docs/probes#bounded-checkpoint-recipes).

`make evidence-performance` runs the native release-build comparison for 20 identical
NSError/cause and explicit recovery pairs, disabled/enabled and under empty/full queue
pressure. It reports caller and deferred flush time, Darwin allocator live byte/block
deltas and retained queue bytes, with one warm-up and three reported repetitions.
Live allocator deltas include process activity; they are not cumulative allocation
churn or peak RSS. The Make target isolates the four lanes in separate test processes;
allocator high-water values include initialization and the warm-up. Signed deltas may
include deferred cleanup. Caller timing includes temporary autorelease cleanup.
Synthetic configuration, transport and held queue startup keep all
traffic local and setup outside capture measurements. The test checks native causes,
original error priority and existing diagnostic/count/byte ceilings. Use the existing
iOS simulator target with `XCODE_TEST_ARGS='-configuration Release ENABLE_TESTABILITY=YES -only-testing:DebugBundleTests/DebugBundleEvidencePerformanceTests'`
for the same comparison on the simulator; neither host nor simulator proves device costs.
