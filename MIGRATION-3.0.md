# Migrating to Swift SDK 3

Version 3.0.0 preserves the public capture signatures, event schema, telemetry privacy policy and file queue format while changing callback and durability timing. Keep a pinned 2.x installation available during rollout.

## Hook execution

`beforeSend` now runs on one serial background delivery worker. Capture first checks policy and queue admission, creates a privacy-safe bounded value, and returns. A hook receives that safe value; returning nil drops it, a valid replacement is used, and an invalid replacement falls back to the original. Final policy, size and mandatory privacy checks apply to the result and to suppression aggregates.

Remove assumptions that hook side effects finish before capture returns. Do not read or update UIKit/SwiftUI state directly from a hook. Snapshot any required application context before capture, and make callback state thread-safe. A blocked hook occupies one worker and one bounded queue slot; it cannot spawn more hook work or hold the capture lock. Capture methods and the native bridge's Boolean result report admission, not completed hook execution or delivery.

## Input projection and error details

Caller projection accepts bounded native JSON-shaped values and known Foundation class-cluster values. It never invokes custom `description`, `CustomReflectable`, custom object subclasses, or custom bridging code. Unsupported context/probe values become `[Unsupported value]`; projection has a 4,096-node budget. SwiftLog likewise formats only concrete standard values; custom `.stringConvertible` metadata uses that placeholder, and its error metadata reaches the core as an error value for safe projection.

Exact Foundation `NSError` instances preserve a bounded primitive `NSLocalizedDescriptionKey` from `userInfo`. Arbitrary value-type errors, including custom `LocalizedError` and `CustomNSError`, retain their type and capture stack but use `Error details unavailable (custom value type)`. Their computed accessors are not invoked and their raw graphs are not queued. If your app requires a custom message, explicitly construct an `NSError` with a trusted, bounded message before capture. `captureAsync` still rethrows the original error; `captureTask` still returns nil after reporting. This changes telemetry detail extraction.

Custom reference errors use a weak handle. The existing worker can obtain and protect their message while the original object remains alive; otherwise the event records `Error details unavailable (custom reference type)`. The SDK does not keep the error graph alive to obtain a message. Device-context providers also run on that same worker. Hooks see the enriched, re-protected snapshot.

Crash replay and Objective-C exception reporting pass standard `NSError` message snapshots to their report callback so those details remain available. `captureNSException` still throws the original `DebugBundleObjCExceptionError`. Fatal-crash persistence remains a separate exceptional path.

## Persistence and shutdown

File recovery, historical privacy scrubbing and coalesced writes now run on the same background worker. Custom `DebugBundleQueueStoring` implementations are called serially there, outside capture locks. A capture return no longer proves its event reached disk. Events can be lost if the process exits before persistence, including after a blocked hook or store; crash replay helpers retain their separate bounded fatal-evidence behavior.

`await flush()` waits for preparation, a delivery attempt and acknowledgement persistence within `requestTimeout`, capped at 60 seconds. It can return with work still pending. A timeout never acknowledges a batch, cancels ownership of a custom sender that has not returned, or starts a replacement sender. The lifecycle adapters use the same finite wait. Remote configuration has its own coalesced task and cannot prevent a ready batch from being sent.

## Capacity and priority

`offlineQueueMaxEvents` and `offlineQueueMaxBytes` now bound pending hook entries, ready entries, durable snapshots and in-flight entries together. Each event is limited to 256 KiB. Exceptions have highest priority, then ERROR/CRITICAL logs, failed requests and suppression records, then other request/breadcrumb/probe records, then lower-severity logs. Only strictly lower-priority entries without active snapshot ownership can be evicted. At full equal priority, the new event is dropped. A bounded count-only `error_suppressed` summary reports pressure when capacity becomes available, at most once per 30 seconds.

Queue TTL, offline replay, `Retry-After`, indexed partial acknowledgements, existing probe activation and final capture-policy enforcement remain in place. Duplicate suppression retains at most 2,048 hashed fingerprints and 11 recent timestamps per fingerprint. Per-session limits continue to exempt exception capture.

## Adoption

Keep installed v2 dependencies pinned until the v3 release is published and verified. After that release, update the SwiftPM requirement to `from: "3.0.0"` or the CocoaPods requirement to `~> 3.0`, review hook thread assumptions, and verify one normal event plus offline recovery in your application. No event schema or stored-queue migration is required.
