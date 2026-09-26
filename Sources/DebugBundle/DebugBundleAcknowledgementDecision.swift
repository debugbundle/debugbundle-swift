enum DebugBundleAcknowledgementDecision {
    case legacyTransportSuccess
    case protocolFailure
    case accounted(
        accepted: Int,
        rejectedErrors: [DebugBundleIngestionError],
        retryableIndices: Set<Int>,
        acceptedFrontendException: Bool
    )
}

func decideDebugBundleAcknowledgement(
    result: DebugBundleTransportResult,
    events: [DebugBundleEventEnvelope]
) -> DebugBundleAcknowledgementDecision {
    guard let acknowledgement = result.acknowledgement else {
        return result.acknowledgementRequired ? .protocolFailure : .legacyTransportSuccess
    }

    let rejectedIndices = acknowledgement.errors.map(\.index)
    let isConsistent = acknowledgement.accepted >= 0
        && acknowledgement.rejected >= 0
        && acknowledgement.accepted <= events.count
        && acknowledgement.rejected == events.count - acknowledgement.accepted
        && acknowledgement.errors.count == acknowledgement.rejected
        && Set(rejectedIndices).count == rejectedIndices.count
        && rejectedIndices.allSatisfy(events.indices.contains)
        && acknowledgement.errors.allSatisfy { !$0.reason.isEmpty }
    guard isConsistent else {
        return .protocolFailure
    }

    let rejectedIndexSet = Set(rejectedIndices)
    let acceptedFrontendException = events.indices.contains { index in
        !rejectedIndexSet.contains(index)
            && events[index].eventType == DebugBundleEventType.frontendException
    }
    let retryableIndices = Set(
        acknowledgement.errors
            .filter { retryableIngestionRejectionReasons.contains($0.reason) }
            .map(\.index)
    )
    return .accounted(
        accepted: acknowledgement.accepted,
        rejectedErrors: acknowledgement.errors,
        retryableIndices: retryableIndices,
        acceptedFrontendException: acceptedFrontendException
    )
}

private let retryableIngestionRejectionReasons: Set<String> = [
    "rate_limited",
    "monthly_quota_exceeded",
    "analytics_quota_exceeded"
]
