import Foundation
public final class DebugBundleClient {
    let evidence: DebugBundleEvidenceController
    let config: DebugBundleConfig
    private let transport: DebugBundleTransporting
    private let queueStore: DebugBundleQueueStoring
    private let remoteConfigClient: DebugBundleRemoteConfigClienting
    private let connectivityMonitor: DebugBundleConnectivityMonitoring?
    let clock: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let random: () -> Double
    private let deviceContextProvider: () -> DebugBundleDeviceContext
    let redactor: DebugBundleRedactor
    private let suppressionTracker = DebugBundleSuppressionTracker()
    let remoteProbeState = DebugBundleRemoteProbeState()
    let lock = NSLock()
    var persistentContext: [String: Any?] = [:]
    private var delivery: DebugBundleDeliveryQueue!
    private var currentBatch: DebugBundleDeliveryQueue.Batch?
    private var flushSignal: DebugBundleCompletion?
    private var configSignal: DebugBundleCompletion?
    private var automaticFlushScheduled = false
    var breadcrumbs: [DebugBundleBreadcrumb] = []
    var probes: [String: [JSONValue]] = [:]
    var capturePolicy = DebugBundleCapturePolicy.defaultWhenConfigFetchFails()
    private var capturePolicyKnown = false
    private var remoteConfigETag: String?
    private var lastRemoteConfigRefreshAt: Date?
    private var remoteConfigRefreshInterval: TimeInterval = 30
    private var remoteConfigRefreshInFlight = false
    var lastScreenName: String?
    private var statusValue: DebugBundleStatus
    private var lastEventValue: Date?
    private var latestInternalDiagnosticValue: DebugBundleInternalDiagnostic?
    private var nextFlushAllowedAt: Date?
    private var retryAttemptCount = 0
    private var sessionEventCount = 0
    private var sessionSampledIn: Bool
    var clearBreadcrumbsOnNextSuccess = false
    var clearProbesOnNextSuccess = false
    private var periodicFlushTask: Task<Void, Never>?
    public init(
        config: DebugBundleConfig,
        transport: DebugBundleTransporting? = nil,
        queueStore: DebugBundleQueueStoring? = nil,
        remoteConfigClient: DebugBundleRemoteConfigClienting? = nil,
        connectivityMonitor: DebugBundleConnectivityMonitoring? = nil,
        clock: @escaping () -> Date = Date.init,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        random: @escaping () -> Double = { Double.random(in: 0...1) },
        deviceContextProvider: (() -> DebugBundleDeviceContext)? = nil
    ) {
        self.evidence = DebugBundleEvidenceController(config.evidenceOptions)
        self.config = config
        self.transport = transport ?? DebugBundleHTTPTransport()
        self.queueStore = queueStore ?? DebugBundleFileQueueStore(
            fileURL: debugBundleDefaultQueueURL(for: config),
            fileProtection: config.fileProtection,
            maxReadBytes: config.offlineQueueMaxBytes > Int.max - 64 * 1024
                ? Int.max : config.offlineQueueMaxBytes + 64 * 1024
        )
        self.remoteConfigClient = remoteConfigClient ?? DebugBundleHTTPRemoteConfigClient()
        self.connectivityMonitor = connectivityMonitor ?? debugBundleDefaultConnectivityMonitor()
        self.clock = clock
        self.sleep = sleep ?? debugBundleDefaultSleep
        self.random = random
        self.deviceContextProvider = deviceContextProvider ?? {
            let processInfo = ProcessInfo.processInfo
            let locale = Locale.current.identifier
            let timezone = TimeZone.current.identifier
            return DebugBundleDeviceContext(
                appVersion: config.appVersion,
                buildNumber: config.buildNumber,
                releaseChannel: config.releaseChannel,
                osName: processInfo.operatingSystemVersionString.isEmpty ? nil : "iOS",
                osVersion: processInfo.operatingSystemVersionString,
                locale: locale,
                timezone: timezone,
                freeMemoryBytes: processInfo.physicalMemory > Int64.max ? Int64.max : Int64(processInfo.physicalMemory)
            )
        }
        self.redactor = DebugBundleRedactor(sensitiveKeys: config.redactFields)
        self.statusValue = config.enabled && !config.projectToken.isEmpty ? .healthy : .disconnected
        self.sessionSampledIn = config.enabled && !config.projectToken.isEmpty && (config.sessionSampleRate >= 1 || random() <= config.sessionSampleRate)
        let activeRedactor = self.redactor
        let activeEvidence = self.evidence
        (self.queueStore as? DebugBundleFileQueueStore)?.installPrivacyTransformer {
            protectDebugBundleEvent($0, redactor: activeRedactor)
        }
        self.delivery = DebugBundleDeliveryQueue(
            config: config, store: self.queueStore, clock: clock,
            protect: { protectDebugBundleEvent($0, redactor: activeRedactor) },
            prepare: { [weak self] in self?.prepareOnWorker($0, capturedAt: $1, deferredError: $2, needsDeviceContext: $3, runBeforeSend: $4) },
            pressureEvent: { [weak self] in self?.makePressureEvent($0) },
            onReady: { [weak self] in self?.scheduleAutomaticFlush() },
            onPrepared: { activeEvidence.prepared($0) },
            onDropped: { if $0.eventType == "diagnostic_context" { activeEvidence.budget.release($0.eventId) } },
            onRestored: { activeEvidence.budget.restore($0) },
            retainRestored: { $0.eventType != "diagnostic_context" || activeEvidence.canHold($0) },
            onPersisted: { activeEvidence.budget.synchronize($0) }
        )
        self.delivery.start()
        self.connectivityMonitor?.setUpdateHandler { [weak self] status in
            if status == .connected { self?.scheduleAutomaticFlush(force: true) }
        }
        if config.enabled, !config.projectToken.isEmpty {
            startPeriodicFlushLoop()
            _ = scheduleRemoteConfig(force: true)
        }
    }

    deinit {
        evidence.close()
        periodicFlushTask?.cancel()
        connectivityMonitor?.setUpdateHandler(nil)
    }

    public var evidenceCapabilities: DebugBundleEvidenceCapabilities { evidence.capabilities(lock.withLock { capturePolicy.diagnosticsAllowed }) }

    public var status: DebugBundleStatus {
        lock.withLock { statusValue }
    }

    public var lastEventAt: Date? {
        lock.withLock { lastEventValue }
    }

    var latestInternalDiagnostic: DebugBundleInternalDiagnostic? {
        lock.withLock { latestInternalDiagnosticValue }
    }

    public func refreshRemoteConfig() async {
        let deadline = ProcessInfo.processInfo.systemUptime + flushTimeout
        if let pending = lock.withLock({ configSignal }) {
            guard await pending.wait(timeout: deadline - ProcessInfo.processInfo.systemUptime) else { return }
        }
        let signal = scheduleRemoteConfig(force: true)
        _ = await signal.wait(timeout: deadline - ProcessInfo.processInfo.systemUptime)
    }

    public func captureAsync<T>(context: [String: Any?] = [:], operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            captureError(error, context: context)
            throw error
        }
    }

    @discardableResult
    public func captureTask<T: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) -> Task<T?, Never> {
        Task(priority: priority) { [weak self] in
            do {
                return try await operation()
            } catch {
                self?.captureError(error)
                return nil
            }
        }
    }

    private func performRemoteConfigRefresh(force: Bool) async {
        guard config.enabled, !config.projectToken.isEmpty else {
            return
        }

        let now = clock()
        let requestContext = lock.withLock { () -> (shouldFetch: Bool, eTag: String?) in
            if remoteConfigRefreshInFlight {
                return (false, nil)
            }
            if !force,
               let lastRemoteConfigRefreshAt,
               now.timeIntervalSince(lastRemoteConfigRefreshAt) < remoteConfigRefreshInterval {
                return (false, nil)
            }
            remoteConfigRefreshInFlight = true
            return (true, remoteConfigETag)
        }

        guard requestContext.shouldFetch else {
            return
        }

        let result = await remoteConfigClient.fetch(
            request: DebugBundleRemoteConfigRequest(
                projectToken: config.projectToken,
                endpoint: config.endpoint,
                timeout: config.requestTimeout,
                eTag: requestContext.eTag
            )
        )

        if transport is DebugBundleHTTPTransport, remoteConfigClient is DebugBundleHTTPRemoteConfigClient,
           DebugBundleEvidenceController.matchingConfigPath(config.endpoint) {
            switch result {
            case let .loaded(response, _): evidence.observe(response.evidenceCapabilities)
            case .failed: evidence.observe(nil)
            case .notModified: break
            }
        }
        switch result {
        case let .loaded(configResponse, eTag):
            lock.withLock {
                remoteConfigETag = eTag
                capturePolicy = DebugBundleCapturePolicy.fromRemotePolicy(configResponse.capturePolicy)
                capturePolicyKnown = true
                lastRemoteConfigRefreshAt = now
                remoteConfigRefreshInterval = debugBundleRemoteConfigRefreshInterval(configResponse.pollIntervalMillis)
                remoteConfigRefreshInFlight = false
            }
            remoteProbeState.applyConfig(
                probesEnabled: configResponse.probesEnabled,
                remoteProbesEnabled: configResponse.remoteProbesEnabled,
                directives: configResponse.activeProbes,
                triggerTokenKey: configResponse.triggerTokenKey,
                now: clock()
            )
        case let .notModified(eTag):
            lock.withLock {
                remoteConfigETag = eTag ?? remoteConfigETag
                lastRemoteConfigRefreshAt = now
                remoteConfigRefreshInFlight = false
            }
        case .failed:
            lock.withLock {
                capturePolicy = DebugBundleCapturePolicy.defaultWhenConfigFetchFails()
                lastRemoteConfigRefreshAt = now
                remoteConfigRefreshInFlight = false
            }
        }
    }

    public func activateProbeTriggerToken(_ token: String) -> Bool {
        guard let directive = DebugBundleProbeTriggerTokenValidator.validate(
            token: token,
            triggerTokenKey: remoteProbeState.tokenKey(),
            now: clock()
        ) else {
            return false
        }
        remoteProbeState.activateTrigger(directive)
        return true
    }

    private var flushTimeout: TimeInterval { min(max(config.requestTimeout, 0.001), 60) }

    public func flush() async {
        let deadline = ProcessInfo.processInfo.systemUptime + flushTimeout
        let configuration = scheduleRemoteConfig(force: false)
        guard await delivery.waitUntilIdle(timeout: deadline - ProcessInfo.processInfo.systemUptime) else { return }
        let signal = lock.withLock { () -> DebugBundleCompletion? in
            if let flushSignal { return flushSignal }
            if connectivityMonitor?.currentStatus == .disconnected {
                statusValue = .degraded
                return nil
            }
            if let nextFlushAllowedAt, clock() < nextFlushAllowedAt {
                statusValue = .degraded
                return nil
            }
            guard let batch = delivery.takeBatch(includeDiagnostics: capturePolicyKnown) else { return nil }
            let signal = DebugBundleCompletion()
            currentBatch = batch
            delivery.retainSnapshot(batch)
            flushSignal = signal
            // Only one sender owns a snapshot, even after a caller's deadline expires.
            Task { [self] in
                do {
                    try await sendOwnedBatch(batch, deadline: deadline)
                } catch {
                    if transport is DebugBundleHTTPTransport { evidence.observe(nil) }
                    lock.withLock {
                        retainCurrentBatchLocked()
                        statusValue = .degraded
                        scheduleRetryLocked(retryAfter: nil, now: clock())
                    }
                }
                delivery.releaseSnapshot(batch)
                lock.withLock { flushSignal = nil }
                signal.finish()
            }
            return signal
        }
        if let signal { _ = await signal.wait(timeout: deadline - ProcessInfo.processInfo.systemUptime) }
        _ = await delivery.waitUntilIdle(timeout: deadline - ProcessInfo.processInfo.systemUptime)
        _ = await configuration.wait(timeout: deadline - ProcessInfo.processInfo.systemUptime)
    }

    var pendingCaptureCount: Int { delivery.retainedCount }
    var pendingCaptureBytes: Int { delivery.byteCount }

    func waitForPendingCapture() async {
        _ = await delivery.waitUntilIdle(timeout: flushTimeout)
    }

    private func finalizeBatch(_ batch: DebugBundleDeliveryQueue.Batch, native: Bool) -> DebugBundleDeliveryQueue.Batch? {
        delivery.refineBatch(batch) { original in
            guard let safe = protectDebugBundleEvent(original, redactor: redactor) else { return nil }
            let policy = lock.withLock { capturePolicy }
            guard let filtered = evidence.filter(safe, diagnosticsAllowed: policy.diagnosticsAllowed),
                  shouldCaptureDebugBundleExternalEnvelope(config: config, policy: policy, event: filtered) else { return nil }
            return native ? DebugBundleIngestionWire.fit(filtered) : filtered
        }
    }

    private func sendOwnedBatch(_ batch: DebugBundleDeliveryQueue.Batch, deadline: TimeInterval) async throws {
        guard transport is DebugBundleHTTPTransport else {
            let active = finalizeBatch(batch, native: false)
            lock.withLock { currentBatch = active }
            if let active { handleTransportResult(try await transport.send(events: active.events, config: config), sentEvents: active.events) }
            return
        }
        var remaining: DebugBundleDeliveryQueue.Batch? = batch
        // Unsent tails retain their leases/bytes through every native call and are requeued on exit.
        defer { if let remaining { delivery.finishBatch(remaining, retryableIndices: Set(remaining.events.indices)) } }
        while let candidate = remaining {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                lock.withLock { currentBatch = nil }
                return
            }
            let active = finalizeBatch(candidate, native: true)
            remaining = nil
            lock.withLock { currentBatch = active }
            guard let active else { return }
            let count = DebugBundleIngestionWire.prefixCount(active.events)
            guard count > 0 else { throw URLError(.dataLengthExceedsMaximum) }
            let sending = DebugBundleDeliveryQueue.Batch(ids: Array(active.ids.prefix(count)), events: Array(active.events.prefix(count)))
            if count < active.events.count {
                remaining = DebugBundleDeliveryQueue.Batch(ids: Array(active.ids.dropFirst(count)), events: Array(active.events.dropFirst(count)))
            }
            lock.withLock { currentBatch = sending }
            let duration = deadline - ProcessInfo.processInfo.systemUptime
            guard duration > 0 else { lock.withLock { retainCurrentBatchLocked() }; return }
            var attemptConfig = config
            attemptConfig.requestTimeout = duration
            let result = try await transport.send(events: sending.events, config: attemptConfig)
            handleTransportResult(result, sentEvents: sending.events)
            guard (200..<300).contains(result.statusCode),
                  case let .accounted(accepted, _, retryable, _) = decideDebugBundleAcknowledgement(result: result, events: sending.events),
                  accepted == sending.events.count, retryable.isEmpty else { return }
        }
    }

    func scheduleAutomaticFlush(force: Bool = false) {
        guard force || delivery.readyCount >= config.batchSize else { return }
        let start = lock.withLock { () -> Bool in
            guard !automaticFlushScheduled, flushSignal == nil else { return false }
            automaticFlushScheduled = true
            return true
        }
        if start {
            Task { [weak self] in
                guard let self else { return }
                await self.flush()
                self.lock.withLock { self.automaticFlushScheduled = false }
            }
        }
    }

    func scheduleRemoteConfig(force: Bool) -> DebugBundleCompletion {
        lock.withLock {
            if let configSignal { return configSignal }
            let signal = DebugBundleCompletion()
            configSignal = signal
            Task { [weak self] in
                guard let self else { signal.finish(); return }
                await self.performRemoteConfigRefresh(force: force)
                self.lock.withLock { self.configSignal = nil }
                signal.finish()
            }
            return signal
        }
    }

    func canAdmit(priority: Int, countTowardSession: Bool = true) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty,
              lock.withLock({ (priority == 3 || sessionSampledIn) && shouldCapture(countTowardSession: countTowardSession) }) else { return false }
        return delivery.canAdmit(priority: priority)
    }

    func enqueue(
        eventType: String,
        payload: [String: JSONValue],
        traceId: String?,
        deferredError: DebugBundleDeferredError? = nil
    ) {
        let now = clock()
        _ = capturePreparedEnvelope(
            makeEnvelope(
                eventType: eventType,
                payload: payload,
                traceId: traceId,
                occurredAt: now
            ), deferredError: deferredError
        )
    }

    func capturePreparedEnvelope(_ authoredEvent: DebugBundleEventEnvelope, deferredError: DebugBundleDeferredError? = nil, needsDeviceContext: Bool = true, runBeforeSend: Bool = true, onRetained: (() -> Void)? = nil) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty,
              delivery.canAdmit(priority: DebugBundleDeliveryQueue.priority(authoredEvent)),
              let safe = protectDebugBundleEvent(authoredEvent, redactor: redactor) else { return false }
        // Retain only a bounded, privacy-safe value. Hooks never run on the caller.
        guard allowsFinalEvent(safe) else { return false }
        if safe.eventType == "diagnostic_context" {
            guard isValidBeforeSendEvent(safe), evidence.budget.reserve(safe) else { return false }
        }
        return delivery.admit(safe, deferredError: deferredError, needsDeviceContext: needsDeviceContext, runBeforeSend: runBeforeSend, onRetained: onRetained)
    }

    private func prepareOnWorker(_ captured: DebugBundleEventEnvelope, capturedAt: Date,
        deferredError: DebugBundleDeferredError?, needsDeviceContext: Bool, runBeforeSend: Bool) -> DebugBundleEventEnvelope? {
        func finish(_ candidate: DebugBundleEventEnvelope?) -> DebugBundleEventEnvelope? {
            let final = evidence.reconcile(captured, candidate, diagnosticsAllowed: lock.withLock { capturePolicy.diagnosticsAllowed })
            if let final, debugBundleExternalEventCountsTowardSession(final.eventType) { lock.withLock { sessionEventCount += 1 } }
            return final
        }
        var enriched = captured
        let wasCanonical = isValidBeforeSendEvent(enriched)
        let device = needsDeviceContext ? deviceContextProvider() : captured.device
        if needsDeviceContext {
            enriched.device = device
            if wasCanonical && debugBundleMobileEventUsesDevice(enriched.eventType) {
                enriched.payload["device"] = .object(canonicalSwiftDevice(device, payload: [:]))
            } else {
                enriched.payload.removeValue(forKey: "device")
            }
        }
        if let message = deferredError?.workerMessage() { enriched.payload["message"] = redactor.sanitize(message) }
        if !isValidBeforeSendEvent(enriched) {
            enriched.payload = canonicalizeSwiftEvent(eventType: enriched.eventType, payload: enriched.payload,
                device: device, occurredAt: enriched.occurredAt).payload
        }
        if evidence.canCaptureExceptions, let deferredError {
            enriched.payload["exception_evidence"] = deferredError.workerEvidence(
                name: enriched.payload["name"]?.stringValue ?? "Error",
                message: enriched.payload["message"]?.stringValue ?? "Unavailable",
                stack: enriched.payload["stack"]?.stringValue ?? "", redactor: redactor, context: enriched.context)
        }
        guard let beforeHook = protectDebugBundleEvent(enriched, redactor: redactor),
              let hooked = applyDebugBundleBeforeSend(beforeHook, hook: runBeforeSend ? config.beforeSend : nil),
              let event = protectDebugBundleEvent(hooked, redactor: redactor), (!wasCanonical || isValidBeforeSendEvent(event)),
              allowsFinalEvent(event), random() <= config.sampleRate else { return finish(nil) }
        if event.eventType == "diagnostic_context" || !runBeforeSend { return finish(event) }
        let fingerprint = debugBundleFingerprint(eventType: event.eventType, payload: event.payload)
        switch suppressionTracker.register(fingerprint: fingerprint, now: capturedAt).action {
        case .allow: return finish(event)
        case let .suppress(suppressedCount, windowSeconds):
            guard suppressedCount > 0 else { return finish(nil) }
            let aggregate = makeDebugBundleExternalSuppressionEvent(source: event, fingerprint: fingerprint,
                suppressedCount: suppressedCount, windowSeconds: windowSeconds, occurredAt: debugBundleTimestamp(capturedAt))
            guard let safe = protectDebugBundleEvent(aggregate, redactor: redactor),
                  let hooked = applyDebugBundleBeforeSend(safe, hook: runBeforeSend ? config.beforeSend : nil),
                  let final = protectDebugBundleEvent(hooked, redactor: redactor), allowsFinalEvent(final) else { return finish(nil) }
            return finish(final)
        }
    }

    private func allowsFinalEvent(_ event: DebugBundleEventEnvelope) -> Bool {
        lock.withLock {
            (debugBundleIsException(event.eventType) || event.eventType == DebugBundleEventType.errorSuppressed || sessionSampledIn)
                && shouldCapture(countTowardSession: debugBundleExternalEventCountsTowardSession(event.eventType))
                && shouldCaptureDebugBundleExternalEnvelope(config: config, policy: capturePolicy, event: event)
        }
    }

    private func makePressureEvent(_ pressure: DebugBundleDeliveryQueue.Pressure) -> DebugBundleEventEnvelope? {
        let event = makeEnvelope(eventType: DebugBundleEventType.errorSuppressed, payload: [
            "fingerprint": .string("swift-queue-pressure"), "suppressed_count": .number(Double(pressure.count)),
            "window_seconds": .number(max(1, ceil(pressure.last.timeIntervalSince(pressure.first)))),
            "first_seen": .string(debugBundleTimestamp(pressure.first)), "last_seen": .string(debugBundleTimestamp(pressure.last))
        ], traceId: nil, occurredAt: clock())
        return protectDebugBundleEvent(event, redactor: redactor)
    }

    var captureDevicePlaceholder: DebugBundleDeviceContext {
        DebugBundleDeviceContext(appVersion: config.appVersion, buildNumber: config.buildNumber, releaseChannel: config.releaseChannel)
    }

    func makeEnvelope(
        eventType: String,
        payload: [String: JSONValue],
        traceId: String?,
        occurredAt: Date
    ) -> DebugBundleEventEnvelope {
        let occurredAtTimestamp = debugBundleTimestamp(occurredAt)
        let device = captureDevicePlaceholder
        let canonical = canonicalizeSwiftEvent(
            eventType: eventType,
            payload: payload,
            device: device,
            occurredAt: occurredAtTimestamp
        )
        return DebugBundleEventEnvelope(
            sdkName: "@debugbundle/sdk-swift",
            sdkVersion: config.sdkVersion,
            service: config.service,
            environment: config.environment,
            eventType: eventType,
            occurredAt: occurredAtTimestamp,
            correlation: traceId.map { DebugBundleCorrelation(traceId: $0) },
            payload: canonical.payload,
            device: device,
            releaseChannel: config.releaseChannel,
            appVersion: config.appVersion,
            buildNumber: config.buildNumber,
            context: canonical.context
        )
    }

    private func handleTransportResult(
        _ result: DebugBundleTransportResult,
        sentEvents: [DebugBundleEventEnvelope]
    ) {
        let now = clock()
        if transport is DebugBundleHTTPTransport {
            let complete: Bool
            if case .protocolFailure = decideDebugBundleAcknowledgement(result: result, events: sentEvents) { complete = false }
            else { complete = (200 ..< 300).contains(result.statusCode) }
            evidence.observe(complete ? result.evidenceCapabilities : nil)
        }
        if (200..<300).contains(result.statusCode),
           case let .accounted(_, rejectedErrors, _, _) = decideDebugBundleAcknowledgement(result: result, events: sentEvents),
           let batch = lock.withLock({ currentBatch }) {
            let rejected = Set(rejectedErrors.map(\.index))
            delivery.acknowledgeRetained(batch, acceptedIndices: Set(sentEvents.indices).subtracting(rejected))
        }
        lock.withLock {
            if (200 ..< 300).contains(result.statusCode) {
                handleSuccessfulTransportResultLocked(result, sentEvents: sentEvents, now: now)
                return
            }
            if result.statusCode == 429 || (500 ... 599).contains(result.statusCode) {
                statusValue = .degraded
                scheduleRetryLocked(retryAfter: result.retryAfter, now: now)
                retainCurrentBatchLocked()
            } else {
                reconcileSentEventsLocked(sentEvents)
                let droppedCount = sentEvents.count
                latestInternalDiagnosticValue = DebugBundleInternalDiagnostic(
                    category: "transport_drop",
                    message: "Dropped queued events after terminal client response",
                    metadata: [
                        "status_code": .number(Double(result.statusCode)),
                        "dropped_event_count": .number(Double(droppedCount))
                    ],
                    recordedAt: now
                )
                statusValue = .disconnected
                nextFlushAllowedAt = nil
                retryAttemptCount = 0
            }
        }
    }

    private func handleSuccessfulTransportResultLocked(
        _ result: DebugBundleTransportResult,
        sentEvents: [DebugBundleEventEnvelope],
        now: Date
    ) {
        switch decideDebugBundleAcknowledgement(result: result, events: sentEvents) {
        case .protocolFailure:
            latestInternalDiagnosticValue = DebugBundleInternalDiagnostic(
                category: "ingestion_acknowledgement_protocol",
                message: "Retained queued events after a malformed ingestion acknowledgement",
                metadata: ["event_count": .number(Double(sentEvents.count))],
                recordedAt: now
            )
            statusValue = .degraded
            scheduleRetryLocked(retryAfter: result.retryAfter, now: now)
            retainCurrentBatchLocked()

        case .legacyTransportSuccess:
            let ownsContext = currentBatch.map { delivery.acceptedCurrentContext($0, acceptedIndices: Set(sentEvents.indices)) } ?? false
            reconcileSentEventsLocked(sentEvents)
            recordSuccessfulDeliveryLocked(
                accepted: sentEvents.count,
                acceptedFrontendException: ownsContext,
                probeDirectives: result.probeDirectives
            )

        case let .accounted(accepted, rejectedErrors, retryableIndices, acceptedFrontendException):
            let acceptedIndices = Set(sentEvents.indices).subtracting(rejectedErrors.map(\.index))
            let ownsContext = acceptedFrontendException && (currentBatch.map { delivery.acceptedCurrentContext($0, acceptedIndices: acceptedIndices) } ?? false)
            let retainedIndices = retryableIndices.union(compatibleRejectionsLocked(rejectedErrors, sentEvents: sentEvents))
            reconcileSentEventsLocked(sentEvents, retryableIndices: retainedIndices)
            remoteProbeState.applyPiggybackDirectives(result.probeDirectives, now: now)
            if accepted > 0 {
                lastEventValue = now
            }
            let terminalErrors = rejectedErrors.filter { !retainedIndices.contains($0.index) }
            if !terminalErrors.isEmpty {
                latestInternalDiagnosticValue = DebugBundleInternalDiagnostic(
                    category: "ingestion_event_rejected",
                    message: "Removed terminally rejected events after indexed ingestion acknowledgement",
                    metadata: [
                        "rejected_event_count": .number(Double(terminalErrors.count)),
                        "first_reason": .string(terminalErrors[0].reason)
                    ],
                    recordedAt: now
                )
            } else {
                latestInternalDiagnosticValue = nil
            }
            if ownsContext {
                clearDeliveredExceptionContextLocked()
            }
            if retainedIndices.isEmpty {
                statusValue = accepted > 0 ? .healthy : .disconnected
                nextFlushAllowedAt = nil
                retryAttemptCount = 0
            } else {
                statusValue = .degraded
                scheduleRetryLocked(retryAfter: result.retryAfter, now: now)
            }
        }
    }

    private func compatibleRejectionsLocked(_ errors: [DebugBundleIngestionError], sentEvents: [DebugBundleEventEnvelope]) -> Set<Int> {
        guard transport is DebugBundleHTTPTransport, let batch = currentBatch else { return [] }
        var replacements: [Int: DebugBundleEventEnvelope] = [:]
        for error in errors where error.reason == "invalid_event" {
            let event = sentEvents[error.index]
            guard debugBundleIsException(event.eventType),
                  evidence.filter(event, diagnosticsAllowed: capturePolicy.diagnosticsAllowed, owned: false) != event else { continue }
            let compatible = DebugBundleIngestionWire.withoutEvidence(event)
            if compatible != event, isValidBeforeSendEvent(compatible) { replacements[error.index] = compatible }
        }
        guard !replacements.isEmpty else { return [] }
        let (rewritten, indices) = delivery.rewriteForRetry(batch, replacements: replacements)
        currentBatch = rewritten
        return indices
    }

    private func reconcileSentEventsLocked(
        _ sentEvents: [DebugBundleEventEnvelope],
        retryableIndices: Set<Int> = []
    ) {
        guard let batch = currentBatch else { return }
        delivery.finishBatch(batch, retryableIndices: retryableIndices)
        currentBatch = nil
    }

    private func retainCurrentBatchLocked() {
        guard let batch = currentBatch else { return }
        delivery.finishBatch(batch, retryableIndices: Set(batch.events.indices))
        currentBatch = nil
    }

    private func recordSuccessfulDeliveryLocked(
        accepted: Int,
        acceptedFrontendException: Bool,
        probeDirectives: [DebugBundleRemoteProbeDirective]?
    ) {
        statusValue = .healthy
        if accepted > 0 {
            lastEventValue = clock()
        }
        nextFlushAllowedAt = nil
        retryAttemptCount = 0
        latestInternalDiagnosticValue = nil
        remoteProbeState.applyPiggybackDirectives(probeDirectives, now: clock())
        if acceptedFrontendException {
            clearDeliveredExceptionContextLocked()
        }
    }

    private func clearDeliveredExceptionContextLocked() {
        if clearBreadcrumbsOnNextSuccess {
            breadcrumbs.removeAll(keepingCapacity: true)
            clearBreadcrumbsOnNextSuccess = false
        }
        if clearProbesOnNextSuccess {
            probes.removeAll(keepingCapacity: true)
            clearProbesOnNextSuccess = false
        }
    }

    private func scheduleRetryLocked(retryAfter: TimeInterval?, now: Date) {
        retryAttemptCount += 1
        let fallbackDelay = min(pow(2, Double(max(0, retryAttemptCount - 1))), 300)
        let resolvedDelay = retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? fallbackDelay
        let boundedDelay = min(max(0, resolvedDelay), 300)
        nextFlushAllowedAt = now.addingTimeInterval(boundedDelay)
    }

    func shouldCapture(countTowardSession: Bool) -> Bool {
        if !countTowardSession {
            return true
        }
        return sessionEventCount < config.maxEventsPerSession
    }

    func mergedContext(_ context: [String: Any?]) -> [String: Any?] {
        guard context.count <= 50 else { return ["_redacted": "[REDACTED]"] }
        return lock.withLock {
            persistentContext.merging(context) { _, new in new }
        }
    }

    private func startPeriodicFlushLoop() {
        periodicFlushTask?.cancel()
        let sleeper = sleep
        let interval = config.flushInterval
        periodicFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                await sleeper(interval)
                guard !Task.isCancelled else {
                    return
                }
                await self?.flush()
            }
        }
    }

}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
