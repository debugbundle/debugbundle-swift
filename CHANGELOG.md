# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [3.1.2] - 2026-11-06

- Qualify immutable Git-tag delivery through SPM and CocoaPods without requiring a new Trunk catalogue entry. Trunk remains an explicit independent publishing channel; existing published pods stay available.

- Make local source-artifact manifests accept explicit current qualification receipts instead of hard-coded historical temporary logs.

- Preserve native SwiftLog Error/NSError underlying-cause evidence in error records through exception capture. Older metadata-only logger APIs retain their existing limitations.
- Existing event schemas remain compatible; complete exception inputs may create new future fingerprints. Consumer installations require an explicit upgrade.

## [3.1.1] - 2026-11-01

- Enforce native reply deadlines and caller cancellation without waiting for a delayed Foundation cancellation callback. Keep response byte/encoding bounds and cancel the losing read; body encoding shares the same request deadline. Regression tests include a native callback that deliberately ignores cancellation.
- Supersede the tagged 3.1.0 attempt whose CocoaPods publication was stopped by the older-simulator deadline regression. Existing tags remain immutable.

- Restore actual Swift5.10 compatibility in the logging adapter; retain the modern SwiftLog event overload on Swift6.2+ and declare its existing swift-log1.12.0 minimum explicitly.
- Add negotiated bounded NSError cause evidence, explicit recovery observations, operation scopes and complete canonical bridge preservation, retaining legacy stacks/grouping and capture signatures.
- Validate full owned hook candidates, apply privacy/final policy again and reduce optional evidence on proof loss without restoring pre-hook fields.
- Bound native response/request bytes and shared flush deadlines; retain sender/store snapshot ownership through partitioned delivery, partial ACK and retries.
- Protect native crash storage, preserve saved time/origin/identity and keep default replay until proven durable handoff; retain explicit legacy reporter callbacks.
- Include Objective-C implementations in the unchanged per-file coverage gate. See [3.1 guidance](MIGRATION-3.1.md).

## [3.0.1] - 2026-09-26

### Fixed

- Reject overflowing acknowledgement counts without trapping; honor retry hints after partial/malformed acknowledgements and accept HTTP-date headers.
- Reject nonfinite HTTP/custom retry hints and use finite fallback backoff, preserving retained events and recovery. Numeric hints remain capped at five minutes.
- Align the CocoaPods installation example with the published 3.x SDK family.

## [3.0.0] - 2026-09-25

### Changed

- **Major timing change:** capture admits privacy-safe bounded events and returns before `beforeSend` or disk access. A coalesced serial worker handles hooks, final policy/privacy, offline recovery and persistence. See [MIGRATION-3.0.md](MIGRATION-3.0.md).
- Count pending work, persistence snapshots and in-flight sends against one priority-aware event/byte limit. Full queues drop lower-priority/new events and emit bounded pressure summaries; active snapshots cannot be evicted.
- Bound flush/config waits without replacing a stuck sender, and cap suppression fingerprints and per-fingerprint timestamp history.
- Move device metadata/custom reference-error projection onto the same worker; never invoke arbitrary caller descriptions, reflection, custom value-error accessors or SwiftLog formatters. Preserve standard NSError, crash replay and Objective-C exception messages through primitive snapshots; unsupported custom details have explicit fallback text.

- Reconcile delivery acknowledgements using sent event identities so queue overflow during a send cannot delete newer unsent events or shift retryable acknowledgement indices.

- Reject logs below the effective local and remote level before context construction, privacy scanning, or invoking `beforeSend`. The hook is no longer called for logs rejected by policy.
- Gate CocoaPods publication on the iOS simulator test suite and iOS 15 deployment-target compilation, matching the existing CI lanes.

## [2.0.0] - 2026-09-21

### Security

- Enforce `telemetry-privacy-v1` before and after capture hooks, during file-queue recovery, and before buffered transport. Unsafe historical records are withheld while valid remote probe activation remains compatible.

## [1.3.0] - 2026-09-12

### Changed

- License first-party SDK code under Apache-2.0 and ship consistent package licensing metadata and license text.

## 1.2.0 - 2026-07-28

- Emit canonical closed mobile event envelopes through the direct `{events}` ingestion wrapper.
- Reconcile ingestion acknowledgements per event so retryable rejections remain queued, terminal rejections are removed deliberately, and rejected-only batches do not update delivery health.
- Added the universal `beforeSend` hook, canonical external-event capture for React Native, and object wrapping for scalar/list probe values.
- Added shared-schema wire-contract coverage plus clean SPM and CocoaPods consumer delivery smokes.
- Accept both whole-second and fractional-second ISO-8601 timestamps at connected event boundaries so standard JavaScript `Date.toISOString()` events are not rejected before queueing.
- Prepare the coordinated `1.2.0` source line and enforce at least 80% line coverage for every executable production source file.

## 1.1.0

- Added path-scoped immediate client-error promotion while retaining context-only handling for unpromoted client errors.

## 1.0.0

- Declared the Swift iOS package line stable.
