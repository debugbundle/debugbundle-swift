import Foundation
public final class DebugBundleClient {
    private let config: DebugBundleConfig
    private let transport: DebugBundleTransporting
    private let queueStore: DebugBundleQueueStoring
    private let remoteConfigClient: DebugBundleRemoteConfigClienting
    private let connectivityMonitor: DebugBundleConnectivityMonitoring?
    private let clock: () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let random: () -> Double
    private let deviceContextProvider: () -> DebugBundleDeviceContext
    private let redactor: DebugBundleRedactor
    private let suppressionTracker = DebugBundleSuppressionTracker()
    private let remoteProbeState = DebugBundleRemoteProbeState()
    private let lock = NSLock()
    private var persistentContext: [String: Any?] = [:]
    private var delivery: DebugBundleDeliveryQueue!
    private var currentBatch: DebugBundleDeliveryQueue.Batch?
    private var flushSignal: DebugBundleCompletion?
    private var configSignal: DebugBundleCompletion?
    private var automaticFlushScheduled = false
    private var breadcrumbs: [DebugBundleBreadcrumb] = []
    private var probes: [String: [JSONValue]] = [:]
    private var capturePolicy = DebugBundleCapturePolicy.defaultWhenConfigFetchFails()
    private var remoteConfigETag: String?
    private var lastRemoteConfigRefreshAt: Date?
    private var remoteConfigRefreshInterval: TimeInterval = 30
    private var remoteConfigRefreshInFlight = false
    private var lastScreenName: String?
    private var statusValue: DebugBundleStatus
    private var lastEventValue: Date?
    private var latestInternalDiagnosticValue: DebugBundleInternalDiagnostic?
    private var nextFlushAllowedAt: Date?
    private var retryAttemptCount = 0
    private var sessionEventCount = 0
    private var sessionSampledIn: Bool
    private var clearBreadcrumbsOnNextSuccess = false
    private var clearProbesOnNextSuccess = false
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
        (self.queueStore as? DebugBundleFileQueueStore)?.installPrivacyTransformer {
            protectDebugBundleEvent($0, redactor: activeRedactor)
        }
        self.delivery = DebugBundleDeliveryQueue(
            config: config, store: self.queueStore, clock: clock,
            protect: { protectDebugBundleEvent($0, redactor: activeRedactor) },
            prepare: { [weak self] in self?.prepareOnWorker($0, capturedAt: $1, deferredError: $2, needsDeviceContext: $3) },
            pressureEvent: { [weak self] in self?.makePressureEvent($0) },
            onReady: { [weak self] in self?.scheduleAutomaticFlush() }
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
        periodicFlushTask?.cancel()
        connectivityMonitor?.setUpdateHandler(nil)
    }

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

        switch result {
        case let .loaded(configResponse, eTag):
            lock.withLock {
                remoteConfigETag = eTag
                capturePolicy = DebugBundleCapturePolicy.fromRemotePolicy(configResponse.capturePolicy)
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

    public func captureException(_ error: Error, context: [String: Any?] = [:]) {
        guard canAdmit(priority: 3, countTowardSession: false) else { return }
        let mergedContext = mergedContext(context)
        let snapshot = lock.withLock { () -> (breadcrumbs: [JSONValue], probes: [String: JSONValue]) in
            clearBreadcrumbsOnNextSuccess = true
            if config.probeFlushOnError {
                clearProbesOnNextSuccess = true
            }
            let breadcrumbPayload = breadcrumbs.map { JSONValue.object($0.payload) }
            let probePayload = probes.reduce(into: [String: JSONValue]()) { result, entry in
                result[entry.key] = .array(entry.value)
            }
            return (breadcrumbPayload, probePayload)
        }
        let payload: [String: JSONValue] = [
            "error": redactor.sanitizeJSON(.object(debugBundleSafeErrorPayload(error))),
            "stack": .string(Thread.callStackSymbols.joined(separator: "\n")),
            "context": .object(redactor.sanitizeDictionary(mergedContext)),
            "breadcrumbs": .array(snapshot.breadcrumbs),
            "probe_data": .object(snapshot.probes)
        ]

        enqueue(
            eventType: DebugBundleEventType.frontendException,
            payload: payload,
            traceId: debugBundleStringValue(from: mergedContext["trace_id"]),
            deferredError: DebugBundleDeferredError(error)
        )
    }

    public func captureError(_ error: Error, context: [String: Any?] = [:]) {
        captureException(error, context: context)
    }

    public func captureLog(_ message: String, level: DebugBundleLogLevel = .warning, context: [String: Any?] = [:]) {
        guard config.enabled, !config.projectToken.isEmpty else { return }
        let eligible = lock.withLock {
            capturePolicy.capturesLog(level, localEnabled: config.captureLogs, localThreshold: config.logLevel)
        }
        guard eligible, canAdmit(priority: level == .error || level == .critical ? 2 : 0) else { return }
        let mergedContext = mergedContext(context)
        let payload: [String: JSONValue] = [
            "level": .string(String(describing: level).lowercased()),
            "message": .string(message),
            "logged_at": .string(debugBundleTimestamp(clock())),
            "context": .object(redactor.sanitizeDictionary(mergedContext))
        ]
        enqueue(
            eventType: DebugBundleEventType.logEvent,
            payload: payload,
            traceId: debugBundleStringValue(from: mergedContext["trace_id"])
        )
    }

    public func captureRequest(_ request: DebugBundleRequestInfo, response: DebugBundleResponseInfo, context: [String: Any?] = [:]) {
        if config.captureNetwork {
            recordBreadcrumb(
                breadcrumbType: "network_request",
                route: request.routeTemplate,
                data: [
                    "method": request.method,
                    "url": request.url,
                    "status_code": response.statusCode,
                    "duration_ms": response.durationMillis as Any,
                    "trace_id": request.traceId as Any
                ]
            )
        }

        guard canAdmit(priority: response.statusCode >= 400 ? 2 : 1) else { return }
        let mergedContext = mergedContext(context)
        let payload: [String: JSONValue] = [
            "method": .string(request.method),
            "url": .string(request.url),
            "route_template": request.routeTemplate.map(JSONValue.string) ?? .null,
            "status_code": .number(Double(response.statusCode)),
            "duration_ms": response.durationMillis.map { .number(Double($0)) } ?? .null,
            "headers": .object(redactor.filterHeaders(request.headers, allowlist: config.headerAllowlist)),
            "response_headers": .object(redactor.filterHeaders(response.headers, allowlist: config.headerAllowlist)),
            "context": .object(redactor.sanitizeDictionary(mergedContext))
        ]

        let traceId = request.traceId ?? debugBundleStringValue(from: mergedContext["trace_id"])
        enqueue(
            eventType: DebugBundleEventType.requestEvent,
            payload: payload,
            traceId: traceId
        )
    }

    public func captureMessage(_ message: String, level: DebugBundleLogLevel = .warning, context: [String: Any?] = [:]) {
        captureLog(message, level: level, context: context)
    }

    public func setContext(_ key: String, value: Any?) {
        guard key.utf8.prefix(129).count <= 128 else { return }
        let safe = redactor.sanitizeDictionary([key: value])
        lock.withLock {
            guard persistentContext[key] != nil || persistentContext.count < 50 else { return }
            persistentContext[key] = safe[key]
        }
    }

    public func probe(_ label: String, data: Any?, options: ProbeOptions = ProbeOptions()) {
        probe(label, options: options) { data }
    }

    public func probe(_ label: String, options: ProbeOptions = ProbeOptions(), producer: () -> Any?) {
        guard !label.isEmpty, redactor.sanitize(label) == .string(label), remoteProbeState.probesAreEnabled() else {
            return
        }
        let matchingDirectives = remoteProbeState.matchingDirectives(
            label: label,
            service: config.service,
            environment: config.environment,
            now: clock()
        )
        guard !options.heavy || !matchingDirectives.isEmpty else {
            return
        }
        let value = redactor.sanitize(producer())
        lock.withLock {
            if probes[label] == nil, probes.count >= config.maxProbeLabels {
                return
            }
            var entries = probes[label] ?? []
            entries.append(value)
            if entries.count > config.maxProbeEntriesPerLabel {
                entries.removeFirst(entries.count - config.maxProbeEntriesPerLabel)
            }
            probes[label] = entries
        }

        guard !matchingDirectives.isEmpty else {
            return
        }

        for directive in matchingDirectives {
            let payload: [String: JSONValue] = [
                "label": .string(label),
                "data": value,
                "activation_id": .string(directive.effectiveActivationId),
                "probe_label_pattern": .string(directive.labelPattern)
            ]
            enqueue(
                eventType: DebugBundleEventType.probeEvent,
                payload: payload,
                traceId: nil
            )
        }
    }

    /**
     Additive bridge surface for a canonical event authored by another
     DebugBundle SDK, currently React Native.
     */
    public func captureExternalEvent(_ event: [String: Any?]) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty else {
            return false
        }
        let sanitized = redactor.sanitizeDictionary(event)
        guard let envelope = parseDebugBundleExternalEvent(
            sanitized,
            fallbackDevice: captureDevicePlaceholder
        ) else {
            return false
        }
        return capturePreparedEnvelope(envelope, needsDeviceContext:
            sanitized["device"] == nil && sanitized["payload"]?.objectValue?["device"] == nil)
    }

    public func isExternalProbeActive(_ label: String) -> Bool {
        !label.isEmpty
            && remoteProbeState.probesAreEnabled()
            && !remoteProbeState.matchingDirectives(
                label: label,
                service: config.service,
                environment: config.environment,
                now: clock()
            ).isEmpty
    }

    public func captureExternalProbe(
        sdkVersion: String,
        service: String,
        environment: String,
        label: String,
        data: Any?,
        occurredAt: String
    ) -> Bool {
        guard isExternalProbeActive(label) else {
            return false
        }
        let directives = remoteProbeState.matchingDirectives(
            label: label,
            service: service,
            environment: environment,
            now: clock()
        )
        let events = makeDebugBundleExternalProbeEvents(
            directives: directives,
            sdkVersion: sdkVersion.isEmpty ? config.sdkVersion : sdkVersion,
            service: service.isEmpty ? config.service : service,
            environment: environment.isEmpty ? config.environment : environment,
            label: label,
            data: redactor.sanitize(data),
            occurredAt: debugBundleParseTimestamp(occurredAt) == nil
                ? ISO8601DateFormatter().string(from: clock())
                : occurredAt,
            device: captureDevicePlaceholder
        )
        return events.reduce(false) { captured, event in
            capturePreparedEnvelope(event) || captured
        }
    }

    public func recordBreadcrumb(breadcrumbType: String, route: String? = nil, data: [String: Any?] = [:]) {
        let sanitizedData = redactor.sanitizeDictionary(data)
        guard case let .string(safeType) = redactor.sanitize(breadcrumbType) else { return }
        let safeRoute = route.flatMap { value -> String? in
            guard case let .string(cleaned) = redactor.sanitize(value) else { return nil }
            return cleaned
        }
        let breadcrumb = lock.withLock { () -> DebugBundleBreadcrumb? in
            guard shouldCapture(countTowardSession: true) else {
                return nil
            }
            let breadcrumb = DebugBundleBreadcrumb(
                occurredAt: debugBundleTimestamp(clock()),
                breadcrumbType: safeType,
                route: safeRoute,
                data: sanitizedData
            )
            breadcrumbs.append(breadcrumb)
            if breadcrumbs.count > config.maxBreadcrumbs {
                breadcrumbs.removeFirst(breadcrumbs.count - config.maxBreadcrumbs)
            }
            return breadcrumb
        }
        guard let breadcrumb else {
            return
        }
        enqueue(
            eventType: DebugBundleEventType.frontendBreadcrumb,
            payload: breadcrumb.payload,
            traceId: nil
        )
    }

    public func recordScreen(_ screenName: String, previousScreen: String? = nil, source: String = "manual") {
        guard config.captureScreens else {
            return
        }
        let resolvedPreviousScreen = previousScreen ?? lock.withLock { lastScreenName }
        lock.withLock {
            lastScreenName = screenName
        }
        recordBreadcrumb(
            breadcrumbType: "screen_transition",
            route: screenName,
            data: [
                "previous_screen": resolvedPreviousScreen as Any,
                "source": source
            ]
        )
    }

    public func recordAppForeground() {
        recordBreadcrumb(
            breadcrumbType: "app_foreground",
            route: lock.withLock { lastScreenName },
            data: [:]
        )
        _ = scheduleRemoteConfig(force: false)
    }

    public func recordAppBackground() {
        recordBreadcrumb(
            breadcrumbType: "app_background",
            route: lock.withLock { lastScreenName },
            data: [:]
        )
        scheduleAutomaticFlush(force: true)
    }

    public func recordAction(_ actionType: String, targetType: String, resourceName: String? = nil) {
        guard config.captureActions else {
            return
        }
        recordBreadcrumb(
            breadcrumbType: "user_action",
            route: lock.withLock { lastScreenName },
            data: [
                "action_type": actionType,
                "target_type": targetType,
                "resource_name": resourceName as Any
            ]
        )
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
            guard let batch = delivery.takeBatch() else { return nil }
            let signal = DebugBundleCompletion()
            currentBatch = batch
            flushSignal = signal
            // Only one sender owns a snapshot, even after a caller's deadline expires.
            Task { [self] in
                do {
                    let result = try await transport.send(events: batch.events, config: config)
                    handleTransportResult(result, sentEvents: batch.events)
                } catch {
                    lock.withLock {
                        retainCurrentBatchLocked()
                        statusValue = .degraded
                        scheduleRetryLocked(retryAfter: nil, now: clock())
                    }
                }
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

    private func scheduleAutomaticFlush(force: Bool = false) {
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

    private func scheduleRemoteConfig(force: Bool) -> DebugBundleCompletion {
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

    private func canAdmit(priority: Int, countTowardSession: Bool = true) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty,
              lock.withLock({ sessionSampledIn && shouldCapture(countTowardSession: countTowardSession) }) else { return false }
        return delivery.canAdmit(priority: priority)
    }

    private func enqueue(
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

    private func capturePreparedEnvelope(_ authoredEvent: DebugBundleEventEnvelope, deferredError: DebugBundleDeferredError? = nil, needsDeviceContext: Bool = true) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty,
              delivery.canAdmit(priority: DebugBundleDeliveryQueue.priority(authoredEvent)),
              let safe = protectDebugBundleEvent(authoredEvent, redactor: redactor) else { return false }
        // Retain only a bounded, privacy-safe value. Hooks never run on the caller.
        guard allowsFinalEvent(safe) else { return false }
        return delivery.admit(safe, deferredError: deferredError, needsDeviceContext: needsDeviceContext)
    }

    private func prepareOnWorker(_ captured: DebugBundleEventEnvelope, capturedAt: Date,
        deferredError: DebugBundleDeferredError?, needsDeviceContext: Bool) -> DebugBundleEventEnvelope? {
        var enriched = captured
        let device = needsDeviceContext ? deviceContextProvider() : captured.device
        if needsDeviceContext {
            enriched.device = device
            enriched.payload.removeValue(forKey: "device")
        }
        if let message = deferredError?.workerMessage() { enriched.payload["message"] = redactor.sanitize(message) }
        enriched.payload = canonicalizeSwiftEvent(eventType: enriched.eventType, payload: enriched.payload,
            device: device, occurredAt: enriched.occurredAt).payload
        guard let beforeHook = protectDebugBundleEvent(enriched, redactor: redactor),
              let hooked = applyDebugBundleBeforeSend(beforeHook, hook: config.beforeSend),
              let event = protectDebugBundleEvent(hooked, redactor: redactor),
              allowsFinalEvent(event), random() <= config.sampleRate else { return nil }
        let now = capturedAt
        let fingerprint = debugBundleFingerprint(eventType: event.eventType, payload: event.payload)
        switch suppressionTracker.register(fingerprint: fingerprint, now: now).action {
        case .allow:
            if debugBundleExternalEventCountsTowardSession(event.eventType) {
                lock.withLock { sessionEventCount += 1 }
            }
            return event
        case let .suppress(suppressedCount, windowSeconds):
            guard suppressedCount > 0 else { return nil }
            let aggregate = makeDebugBundleExternalSuppressionEvent(source: event, fingerprint: fingerprint,
                suppressedCount: suppressedCount, windowSeconds: windowSeconds, occurredAt: debugBundleTimestamp(now))
            guard let safe = protectDebugBundleEvent(aggregate, redactor: redactor),
                  let hooked = applyDebugBundleBeforeSend(safe, hook: config.beforeSend),
                  let final = protectDebugBundleEvent(hooked, redactor: redactor), allowsFinalEvent(final) else { return nil }
            return final
        }
    }

    private func allowsFinalEvent(_ event: DebugBundleEventEnvelope) -> Bool {
        lock.withLock {
            sessionSampledIn && shouldCapture(countTowardSession: debugBundleExternalEventCountsTowardSession(event.eventType))
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

    private var captureDevicePlaceholder: DebugBundleDeviceContext {
        DebugBundleDeviceContext(appVersion: config.appVersion, buildNumber: config.buildNumber, releaseChannel: config.releaseChannel)
    }

    private func makeEnvelope(
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
            scheduleRetryLocked(retryAfter: nil, now: now)
            retainCurrentBatchLocked()

        case .legacyTransportSuccess:
            reconcileSentEventsLocked(sentEvents)
            recordSuccessfulDeliveryLocked(
                accepted: sentEvents.count,
                acceptedFrontendException: sentEvents.contains {
                    $0.eventType == DebugBundleEventType.frontendException
                },
                probeDirectives: result.probeDirectives
            )

        case let .accounted(accepted, rejectedErrors, retryableIndices, acceptedFrontendException):
            reconcileSentEventsLocked(sentEvents, retryableIndices: retryableIndices)
            remoteProbeState.applyPiggybackDirectives(result.probeDirectives, now: now)
            if accepted > 0 {
                lastEventValue = now
            }
            let terminalErrors = rejectedErrors.filter { !retryableIndices.contains($0.index) }
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
            if acceptedFrontendException {
                clearDeliveredExceptionContextLocked()
            }
            if retryableIndices.isEmpty {
                statusValue = accepted > 0 ? .healthy : .disconnected
                nextFlushAllowedAt = nil
                retryAttemptCount = 0
            } else {
                statusValue = .degraded
                scheduleRetryLocked(retryAfter: nil, now: now)
            }
        }
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
        let resolvedDelay = retryAfter ?? fallbackDelay
        let boundedDelay = min(max(0, resolvedDelay), 300)
        nextFlushAllowedAt = now.addingTimeInterval(boundedDelay)
    }

    private func shouldCapture(countTowardSession: Bool) -> Bool {
        if !countTowardSession {
            return true
        }
        return sessionEventCount < config.maxEventsPerSession
    }

    private func mergedContext(_ context: [String: Any?]) -> [String: Any?] {
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
