import Foundation

// Capture APIs share the client ownership ledger; delivery remains in DebugBundleClient.
extension DebugBundleClient {
    public func beginOperation() -> DebugBundleOperationScope { evidence.operations.begin() }
    public func withOperationContext<T>(_ operation: () throws -> T) rethrows -> T { try evidence.operations.run(operation) }
    public func withOperationContext<T>(_ operation: () async throws -> T) async rethrows -> T { try await evidence.operations.run(operation) }

    func exceptionContextSnapshot() -> (breadcrumbs: [JSONValue], probes: [String: JSONValue]) {
        return lock.withLock {
            clearBreadcrumbsOnNextSuccess = true
            if config.probeFlushOnError {
                clearProbesOnNextSuccess = true
            }
            let breadcrumbPayload = breadcrumbs.map { JSONValue.object($0.payload) }
            let probePayload = (config.probeFlushOnError ? probes : [:]).reduce(into: [String: JSONValue]()) { result, entry in
                result[entry.key] = .array(entry.value)
            }
            return (breadcrumbPayload, probePayload)
        }
    }

    public func captureException(_ error: Error, context: [String: Any?] = [:]) {
        guard canAdmit(priority: 3, countTowardSession: false) else { return }
        let mergedContext = evidence.context(mergedContext(context))
        let snapshot = exceptionContextSnapshot()
        var payload: [String: JSONValue] = [
            "error": redactor.sanitizeJSON(.object(debugBundleSafeErrorPayload(error))),
            "stack": .string(Thread.callStackSymbols.joined(separator: "\n")),
            "context": .object(redactor.sanitizeDictionary(mergedContext)),
            "breadcrumbs": .array(snapshot.breadcrumbs)
        ]
        if config.probeFlushOnError { payload["probe_data"] = .object(snapshot.probes) }

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
        guard config.enabled, !config.projectToken.isEmpty, !label.isEmpty, redactor.sanitize(label) == .string(label), remoteProbeState.probesAreEnabled() else {
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
        guard let sanitized = DebugBundleBridgeJSON.object(event),
              let envelope = parseDebugBundleExternalEvent(
            sanitized,
            fallbackDevice: captureDevicePlaceholder
        ) else {
            return false
        }
        return capturePreparedEnvelope(envelope, needsDeviceContext: envelope.sdkName == reactNativeSDKName &&
            debugBundleMobileEventUsesDevice(envelope.eventType) &&
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

}
