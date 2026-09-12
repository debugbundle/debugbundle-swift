# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-09-12

### Changed

- License first-party SDK code under Apache-2.0 and ship consistent package licensing metadata and license text.

## Unreleased

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
