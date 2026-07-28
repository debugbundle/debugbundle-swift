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
    private var buffer: [DebugBundleEventEnvelope] = []
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
    private var flushInFlight = false
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
            fileProtection: config.fileProtection
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
        self.buffer = self.queueStore.load(now: clock(), ttl: config.offlineQueueTtl)
        self.connectivityMonitor?.setUpdateHandler { [weak self] status in
            guard status == .connected else {
                return
            }
            Task { [weak self] in
                await self?.flush()
            }
        }
        if config.enabled, !config.projectToken.isEmpty {
            startPeriodicFlushLoop()
            Task {
                await self.refreshRemoteConfig(force: true)
            }
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
        await refreshRemoteConfig(force: true)
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

    private func refreshRemoteConfig(force: Bool) async {
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
            "error": redactor.sanitize(error),
            "stack": .string(Thread.callStackSymbols.joined(separator: "\n")),
            "context": .object(redactor.sanitizeDictionary(mergedContext)),
            "breadcrumbs": .array(snapshot.breadcrumbs),
            "probe_data": .object(snapshot.probes)
        ]

        enqueue(
            eventType: DebugBundleEventType.frontendException,
            payload: payload,
            traceId: debugBundleStringValue(from: mergedContext["trace_id"])
        )
    }

    public func captureError(_ error: Error, context: [String: Any?] = [:]) {
        captureException(error, context: context)
    }

    public func captureLog(_ message: String, level: DebugBundleLogLevel = .warning, context: [String: Any?] = [:]) {
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
        lock.withLock {
            persistentContext[key] = value
        }
    }

    public func probe(_ label: String, data: Any?, options: ProbeOptions = ProbeOptions()) {
        probe(label, options: options) { data }
    }

    public func probe(_ label: String, options: ProbeOptions = ProbeOptions(), producer: () -> Any?) {
        guard !label.isEmpty, remoteProbeState.probesAreEnabled() else {
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
            fallbackDevice: deviceContextProvider()
        ) else {
            return false
        }
        return capturePreparedEnvelope(envelope)
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
            device: deviceContextProvider()
        )
        return events.reduce(false) { captured, event in
            capturePreparedEnvelope(event) || captured
        }
    }

    public func recordBreadcrumb(breadcrumbType: String, route: String? = nil, data: [String: Any?] = [:]) {
        let sanitizedData = redactor.sanitizeDictionary(data)
        let breadcrumb = lock.withLock { () -> DebugBundleBreadcrumb? in
            guard shouldCapture(countTowardSession: true) else {
                return nil
            }
            let breadcrumb = DebugBundleBreadcrumb(
                occurredAt: debugBundleTimestamp(clock()),
                breadcrumbType: breadcrumbType,
                route: route,
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
        Task {
            await self.refreshRemoteConfig(force: false)
        }
    }

    public func recordAppBackground() {
        recordBreadcrumb(
            breadcrumbType: "app_background",
            route: lock.withLock { lastScreenName },
            data: [:]
        )
        Task {
            await self.flush()
        }
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

    public func flush() async {
        let now = clock()
        await refreshRemoteConfig(force: false)
        if connectivityMonitor?.currentStatus == .disconnected {
            lock.withLock {
                statusValue = .degraded
            }
            return
        }

        let canFlush = lock.withLock {
            guard let nextFlushAllowedAt else {
                return true
            }
            if now >= nextFlushAllowedAt {
                return true
            }
            statusValue = .degraded
            return false
        }
        guard canFlush else {
            return
        }

        let events = lock.withLock { () -> [DebugBundleEventEnvelope]? in
            guard !flushInFlight, !buffer.isEmpty else {
                return nil
            }
            flushInFlight = true
            return Array(buffer.prefix(config.batchSize))
        }
        guard let events else {
            return
        }

        do {
            let result = try await transport.send(events: events, config: config)
            handleTransportResult(result, sentEvents: events)
        } catch {
            lock.withLock {
                statusValue = .degraded
                scheduleRetryLocked(retryAfter: nil, now: now)
                flushInFlight = false
            }
        }
    }

    private func enqueue(
        eventType: String,
        payload: [String: JSONValue],
        traceId: String?
    ) {
        let now = clock()
        _ = capturePreparedEnvelope(
            makeEnvelope(
                eventType: eventType,
                payload: payload,
                traceId: traceId,
                occurredAt: now
            )
        )
    }

    private func capturePreparedEnvelope(_ authoredEvent: DebugBundleEventEnvelope) -> Bool {
        guard config.enabled, !config.projectToken.isEmpty else {
            return false
        }
        guard let event = applyDebugBundleBeforeSend(authoredEvent, hook: config.beforeSend) else {
            return false
        }
        let countTowardSession = debugBundleExternalEventCountsTowardSession(event.eventType)
        let allowed = lock.withLock {
            sessionSampledIn
                && shouldCapture(countTowardSession: countTowardSession)
                && shouldCaptureDebugBundleExternalEnvelope(
                    config: config,
                    policy: capturePolicy,
                    event: event
                )
        }
        guard allowed, random() <= config.sampleRate else {
            return false
        }

        let now = clock()
        let fingerprint = debugBundleFingerprint(
            eventType: event.eventType,
            payload: event.payload
        )
        let decision = suppressionTracker.register(fingerprint: fingerprint, now: now)
        switch decision.action {
        case .allow:
            return appendEnvelope(event, countTowardSession: countTowardSession)
        case let .suppress(suppressedCount, windowSeconds):
            guard suppressedCount > 0 else {
                return false
            }
            let aggregate = makeDebugBundleExternalSuppressionEvent(
                source: event,
                fingerprint: fingerprint,
                suppressedCount: suppressedCount,
                windowSeconds: windowSeconds,
                occurredAt: debugBundleTimestamp(now)
            )
            guard let preparedAggregate = applyDebugBundleBeforeSend(
                aggregate,
                hook: config.beforeSend
            ) else {
                return false
            }
            return appendEnvelope(preparedAggregate, countTowardSession: false)
        }
    }

    private func appendEnvelope(
        _ envelope: DebugBundleEventEnvelope,
        countTowardSession: Bool
    ) -> Bool {
        var shouldFlushImmediately = false
        let appended = lock.withLock { () -> Bool in
            guard shouldCapture(countTowardSession: countTowardSession) else {
                return false
            }
            buffer.append(envelope)
            trimBufferToConfiguredBoundsLocked()
            if countTowardSession {
                sessionEventCount += 1
            }
            queueStore.persist(buffer)
            shouldFlushImmediately = buffer.count >= config.batchSize
            return true
        }

        if appended, shouldFlushImmediately {
            Task { [weak self] in
                await self?.flush()
            }
        }
        return appended
    }

    private func makeEnvelope(
        eventType: String,
        payload: [String: JSONValue],
        traceId: String?,
        occurredAt: Date
    ) -> DebugBundleEventEnvelope {
        let occurredAtTimestamp = debugBundleTimestamp(occurredAt)
        let device = deviceContextProvider()
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
                flushInFlight = false
            } else {
                let droppedCount = min(sentEvents.count, buffer.count)
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
                flushInFlight = false
                buffer.removeFirst(droppedCount)
                queueStore.persist(buffer)
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
            flushInFlight = false

        case .legacyTransportSuccess:
            buffer.removeFirst(min(sentEvents.count, buffer.count))
            recordSuccessfulDeliveryLocked(
                accepted: sentEvents.count,
                acceptedFrontendException: sentEvents.contains {
                    $0.eventType == DebugBundleEventType.frontendException
                },
                probeDirectives: result.probeDirectives
            )

        case let .accounted(accepted, rejectedErrors, retryableIndices, acceptedFrontendException):
            let sentCount = min(sentEvents.count, buffer.count)
            let retainedEvents = buffer.prefix(sentCount).enumerated().compactMap { index, event in
                retryableIndices.contains(index) ? event : nil
            }
            buffer.replaceSubrange(0 ..< sentCount, with: retainedEvents)
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
            flushInFlight = false
            queueStore.persist(buffer)
        }
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
        flushInFlight = false
        latestInternalDiagnosticValue = nil
        remoteProbeState.applyPiggybackDirectives(probeDirectives, now: clock())
        if acceptedFrontendException {
            clearDeliveredExceptionContextLocked()
        }
        queueStore.persist(buffer)
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
        lock.withLock {
            persistentContext.merging(context) { _, new in new }
        }
    }

    private func trimBufferToConfiguredBoundsLocked() {
        if buffer.count > config.offlineQueueMaxEvents {
            buffer.removeFirst(buffer.count - config.offlineQueueMaxEvents)
        }

        let encoder = JSONEncoder()
        while !buffer.isEmpty {
            let encodedSize = (try? encoder.encode(buffer).count) ?? 0
            if encodedSize <= config.offlineQueueMaxBytes {
                return
            }
            buffer.removeFirst()
        }
    }

    private func startPeriodicFlushLoop() {
        periodicFlushTask?.cancel()
        periodicFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.sleep(self.config.flushInterval)
                guard !Task.isCancelled else {
                    return
                }
                await self.flush()
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
