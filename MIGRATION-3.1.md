# Swift 3.1 evidence compatibility

This is an unpublished additive candidate. Existing initializers, capture return
values, transport/store protocols and explicit crash-report callbacks remain
available. Continue to follow [the 3.0 timing migration](MIGRATION-3.0.md).

Swift5.10–6.1 uses the original SwiftLog `LogHandler` method with a compatible
swift-log release selected from1.6.0. The native `LogEvent` overload remains on
Swift6.2+ with swift-log1.12.0 or later, whose compiler requirement matches that
API. The modern dependency minimum now states the adapter's existing requirement;
older compiler consumers no longer fail on an unavailable `LogEvent` type.
Ordinary logging, redaction and recursion protection apply on both paths. Older
SwiftLog has no error-bearing event API; capture an error explicitly through
`captureException` when its structured evidence is needed.

Upgrade the accepting DebugBundle server/readers and every relay before enabling
new producers. Native HTTP uses existing config and ACK requests. Missing or
unknown capability proof emits compatible primary failures and disables standalone
recovery. A custom transport, opaque relay or offline reader requires an explicit
`DebugBundleEvidenceCapabilities(version: 1, features: [...])` pin covering every
hop. Never pin support based only on the mobile SDK version.

`withEvidenceOptions` enables bounded cause evidence by default for proven paths;
recovery is opt-in. Existing raw stacks, fingerprint inputs, original error
propagation, hook timing and queue limits remain authoritative. Exact NSError
underlying/multiple errors can supply causes while still alive; arbitrary Swift
Error values have no universal cause or throw-site trace. No raw error graph is
kept alive for later traversal, and no frame locals or reflection are collected.

Hooks may change all canonical fields, including identity and event type. Fully
valid replacements receive mandatory privacy and final policy/proof again.
Invalid replacements fall back to the protected original; exhausted validation or
unsafe/oversized valid replacements are withheld. Optional wire reduction retains
the latest accepted primary, not pre-hook sensitive data. Native HTTP bodies stay
within 256KiB including the wrapper; partitioned chunks share one flush deadline.

Use explicit operation/failure/attempt scopes for recovery. HTTP 200 and
`attempt_completed` are observations, not semantic recovery. See the
[README](README.md#explicit-recovery-and-operation-scope) for APIs, limits and
policy behaviour. Existing sessions and legacy same-named context fields are not
retroactively relabelled as structured evidence.

Default crash replay now retains its private record until positive queue-store or
canonical ingestion acknowledgement. Existing explicit `report:` callbacks keep
their caller-owned handoff semantics. Implement `DebugBundleAcknowledgingQueueStore`
if a custom store can positively confirm durable persistence. Previous-crash
reports keep their saved time/stable identity and do not consume launch probes or
run current-capture hooks. Existing v1 crash records remain readable with unknown
trace origin. Native reports retain at most eight frames and 4KiB combined added
evidence; hard-kill/OOM capture remains best effort.

Canonical React Native events retain structured evidence, nullable metadata and
all correlation fields through the native queue. Legacy bridge migration remains
available, while invalid new evidence cannot be stripped into a legacy success.
No browser passive collector or browser relay host is added to iOS.
