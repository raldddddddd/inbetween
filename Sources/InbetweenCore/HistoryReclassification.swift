import Foundation

public struct HistoryReclassificationReport: Equatable, Sendable {
    public let inspectedSessionCount: Int
    public let reclassifiedSessionSummaryCount: Int
    public let reclassifiedSliceCount: Int
    public let productiveSliceCount: Int
    public let distractedSliceCount: Int
    public let finalProductiveSliceCount: Int
    public let finalDistractedSliceCount: Int
    public let finalProductiveSliceDuration: TimeInterval
    public let finalDistractedSliceDuration: TimeInterval
    public let finalProductiveSessionSummaryCount: Int
    public let finalDistractedSessionSummaryCount: Int
    public let preservedUnobservedGapCount: Int
    public let preservedManualOverrideCount: Int
    public let replacedManualUnclassifiedOverrideCount: Int
    public let remainingUnclassifiedSummaryCount: Int
    public let remainingUnclassifiedSliceCount: Int
    public let backupURL: URL?

    public var reclassifiedRecordCount: Int {
        reclassifiedSessionSummaryCount + reclassifiedSliceCount
    }

    fileprivate init(
        inspectedSessionCount: Int,
        reclassifiedSessionSummaryCount: Int,
        reclassifiedSliceCount: Int,
        productiveSliceCount: Int,
        distractedSliceCount: Int,
        finalProductiveSliceCount: Int,
        finalDistractedSliceCount: Int,
        finalProductiveSliceDuration: TimeInterval,
        finalDistractedSliceDuration: TimeInterval,
        finalProductiveSessionSummaryCount: Int,
        finalDistractedSessionSummaryCount: Int,
        preservedUnobservedGapCount: Int,
        preservedManualOverrideCount: Int,
        replacedManualUnclassifiedOverrideCount: Int,
        remainingUnclassifiedSummaryCount: Int,
        remainingUnclassifiedSliceCount: Int,
        backupURL: URL?
    ) {
        self.inspectedSessionCount = inspectedSessionCount
        self.reclassifiedSessionSummaryCount = reclassifiedSessionSummaryCount
        self.reclassifiedSliceCount = reclassifiedSliceCount
        self.productiveSliceCount = productiveSliceCount
        self.distractedSliceCount = distractedSliceCount
        self.finalProductiveSliceCount = finalProductiveSliceCount
        self.finalDistractedSliceCount = finalDistractedSliceCount
        self.finalProductiveSliceDuration = finalProductiveSliceDuration
        self.finalDistractedSliceDuration = finalDistractedSliceDuration
        self.finalProductiveSessionSummaryCount = finalProductiveSessionSummaryCount
        self.finalDistractedSessionSummaryCount = finalDistractedSessionSummaryCount
        self.preservedUnobservedGapCount = preservedUnobservedGapCount
        self.preservedManualOverrideCount = preservedManualOverrideCount
        self.replacedManualUnclassifiedOverrideCount = replacedManualUnclassifiedOverrideCount
        self.remainingUnclassifiedSummaryCount = remainingUnclassifiedSummaryCount
        self.remainingUnclassifiedSliceCount = remainingUnclassifiedSliceCount
        self.backupURL = backupURL
    }
}

public enum HistoryReclassificationError: Error, Equatable, LocalizedError {
    case confirmationRequired
    case backupVerificationFailed
    case transformationVerificationFailed
    case persistedVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Historical reclassification requires explicit confirmation."
        case .backupVerificationFailed:
            "The fresh backup did not reload with the original history; no history write was attempted."
        case .transformationVerificationFailed:
            "The proposed reclassification changed protected history fields; no history write was attempted."
        case .persistedVerificationFailed:
            "The saved history did not match the verified reclassification. No automatic rollback was performed."
        }
    }
}

/// Re-evaluates stored Unclassified results without replacing session or slice
/// identities, intervals, captured contexts, or review state. Explicit manual
/// Unclassified decisions are cleared; manual Productive/Distracted decisions
/// remain intact.
public struct WaitSessionHistoryReclassifier: Sendable {
    public let classifier: WaitSessionClassifier

    public init(classifier: WaitSessionClassifier = WaitSessionClassifier()) {
        self.classifier = classifier
    }

    public func reclassify(_ sessions: [WaitSession]) -> [WaitSession] {
        sessions.map(reclassifiedSession)
    }

    /// Performs one explicit, backed-up compare-and-save. A failed post-write
    /// verification is reported without restoring an older snapshot.
    public func apply(to store: WaitSessionStore, confirmed: Bool) throws -> HistoryReclassificationReport {
        guard confirmed else { throw HistoryReclassificationError.confirmationRequired }
        let original = try store.load()
        let proposed = reclassify(original)
        guard preservesProtectedFields(from: original, to: proposed),
              reclassificationIsComplete(original: original, proposed: proposed) else {
            throw HistoryReclassificationError.transformationVerificationFailed
        }

        let backupURL = try store.createTimestampedBackup(of: original)
        guard try WaitSessionStore(fileURL: backupURL).load() == original else {
            throw HistoryReclassificationError.backupVerificationFailed
        }

        try store.save(proposed, expecting: original)
        let persisted = try store.load()
        guard persisted == proposed,
              preservesProtectedFields(from: original, to: persisted),
              reclassificationIsComplete(original: original, proposed: persisted) else {
            throw HistoryReclassificationError.persistedVerificationFailed
        }
        return report(before: original, after: persisted, backupURL: backupURL)
    }

    public func report(before: [WaitSession], after: [WaitSession], backupURL: URL? = nil) -> HistoryReclassificationReport {
        let oldByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        var summaryCount = 0
        var sliceCount = 0
        var productiveCount = 0
        var distractedCount = 0
        var gapCount = 0
        var manualOverrideCount = 0
        var replacedManualUnclassifiedCount = 0
        var remainingSummaryCount = 0
        var remainingSliceCount = 0
        var finalProductiveSliceCount = 0
        var finalDistractedSliceCount = 0
        var finalProductiveSliceDuration = 0.0
        var finalDistractedSliceDuration = 0.0
        var finalProductiveSessionCount = 0
        var finalDistractedSessionCount = 0

        for session in after {
            guard let old = oldByID[session.id] else { continue }
            if old.classificationResult?.classification == .unclassified,
               session.classificationResult?.classification != .unclassified {
                summaryCount += 1
            }
            if session.manualClassificationOverride != nil { manualOverrideCount += 1 }
            if old.manualClassificationOverride == .unclassified,
               session.manualClassificationOverride == nil { replacedManualUnclassifiedCount += 1 }
            if session.classificationResult?.classification == .unclassified { remainingSummaryCount += 1 }
            switch session.effectiveClassification {
            case .productive: finalProductiveSessionCount += 1
            case .distracted: finalDistractedSessionCount += 1
            case .unclassified, nil: break
            }

            let oldSlices = Dictionary(uniqueKeysWithValues: (old.activityClassificationSlices ?? []).map { ($0.id, $0) })
            for slice in session.activityClassificationSlices ?? [] {
                guard let previous = oldSlices[slice.id] else { continue }
                if previous.automaticClassification == .unclassified,
                   slice.automaticClassification != .unclassified {
                    sliceCount += 1
                    switch slice.automaticClassification {
                    case .productive: productiveCount += 1
                    case .distracted: distractedCount += 1
                    case .unclassified: break
                    }
                }
                if slice.isUnobservedGap { gapCount += 1 }
                if previous.manualClassificationOverride == .unclassified,
                   slice.manualClassificationOverride == nil { replacedManualUnclassifiedCount += 1 }
                if slice.effectiveClassification == .unclassified { remainingSliceCount += 1 }
                switch slice.effectiveClassification {
                case .productive:
                    finalProductiveSliceCount += 1
                    finalProductiveSliceDuration += slice.duration
                case .distracted:
                    finalDistractedSliceCount += 1
                    finalDistractedSliceDuration += slice.duration
                case .unclassified: break
                }
                if slice.manualClassificationOverride != nil { manualOverrideCount += 1 }
            }
        }

        return HistoryReclassificationReport(
            inspectedSessionCount: after.count,
            reclassifiedSessionSummaryCount: summaryCount,
            reclassifiedSliceCount: sliceCount,
            productiveSliceCount: productiveCount,
            distractedSliceCount: distractedCount,
            finalProductiveSliceCount: finalProductiveSliceCount,
            finalDistractedSliceCount: finalDistractedSliceCount,
            finalProductiveSliceDuration: finalProductiveSliceDuration,
            finalDistractedSliceDuration: finalDistractedSliceDuration,
            finalProductiveSessionSummaryCount: finalProductiveSessionCount,
            finalDistractedSessionSummaryCount: finalDistractedSessionCount,
            preservedUnobservedGapCount: gapCount,
            preservedManualOverrideCount: manualOverrideCount,
            replacedManualUnclassifiedOverrideCount: replacedManualUnclassifiedCount,
            remainingUnclassifiedSummaryCount: remainingSummaryCount,
            remainingUnclassifiedSliceCount: remainingSliceCount,
            backupURL: backupURL
        )
    }

    private func reclassifiedSession(_ original: WaitSession) -> WaitSession {
        guard original.state == .completed else { return original }
        var session = original
        if session.manualClassificationOverride == .unclassified {
            session.manualClassificationOverride = nil
        }
        let segmentsByID = Dictionary(uniqueKeysWithValues: original.activitySegments.map { ($0.id, $0) })

        if let oldSlices = original.activityClassificationSlices {
            let hasUnclassifiedHistory = original.classificationResult?.classification == .unclassified
                || oldSlices.contains {
                    $0.automaticClassification == .unclassified
                        || $0.manualClassificationOverride == .unclassified
                }
            let updatedSlices = oldSlices.map { slice -> ActivityClassificationSlice in
                let manualOverride = slice.manualClassificationOverride == .unclassified
                    ? nil : slice.manualClassificationOverride
                guard slice.automaticClassification == .unclassified else {
                    guard manualOverride != slice.manualClassificationOverride else { return slice }
                    return ActivityClassificationSlice(
                        id: slice.id,
                        sourceActivitySegmentID: slice.sourceActivitySegmentID,
                        startedAt: slice.startedAt,
                        endedAt: slice.endedAt,
                        duration: slice.duration,
                        automaticClassificationResult: slice.automaticClassificationResult,
                        manualClassificationOverride: manualOverride,
                        classificationReviewHandled: slice.classificationReviewHandled
                    )
                }
                let result: WaitSessionClassificationResult
                if slice.isUnobservedGap {
                    result = .init(
                        classification: .distracted,
                        reasonCodes: [.unobservedGap, .insufficientActivityData, .deterministicFallback],
                        explanation: "No activity was observed during this interval; Distracted was assigned as the deterministic fallback."
                    )
                } else if let sourceID = slice.sourceActivitySegmentID,
                          let segment = segmentsByID[sourceID] {
                    result = classifier.classify(context: segment.context)
                } else {
                    result = .init(
                        classification: .distracted,
                        reasonCodes: [.insufficientActivityData, .deterministicFallback],
                        explanation: "Stored activity context was unavailable; Distracted was assigned as the deterministic fallback."
                    )
                }
                return ActivityClassificationSlice(
                    id: slice.id,
                    sourceActivitySegmentID: slice.sourceActivitySegmentID,
                    startedAt: slice.startedAt,
                    endedAt: slice.endedAt,
                    duration: slice.duration,
                    automaticClassificationResult: result,
                    manualClassificationOverride: manualOverride,
                    classificationReviewHandled: slice.classificationReviewHandled
                )
            }
            session.activityClassificationSlices = updatedSlices
            if hasUnclassifiedHistory, let summary = classifier.summary(for: updatedSlices) {
                session.classificationResult = summary
            }
        } else if original.classificationResult?.classification == .unclassified
            || original.manualClassificationOverride == .unclassified {
            if original.activitySegments.isEmpty {
                session.classificationResult = .init(
                    classification: .distracted,
                    reasonCodes: [.insufficientActivityData, .deterministicFallback],
                    explanation: "No stored activity context was available; Distracted was chosen as the deterministic fallback."
                )
            } else {
                let classified = original.activitySegments.map { segment in
                    (segment.duration ?? 0, classifier.classify(context: segment.context))
                }
                let productiveDuration = classified
                    .filter { $0.1.classification == .productive }
                    .reduce(0) { $0 + $1.0 }
                let distractedDuration = classified
                    .filter { $0.1.classification == .distracted }
                    .reduce(0) { $0 + $1.0 }
                let result = productiveDuration > distractedDuration
                    ? WaitSessionClassification.productive
                    : .distracted
                session.classificationResult = .init(
                    classification: result,
                    reasonCodes: [.mixedEvidence, .deterministicFallback],
                    explanation: "Legacy activity contexts were summarized by observed duration; ties resolve to Distracted."
                )
            }
        }
        return session
    }

    private func preservesProtectedFields(from original: [WaitSession], to proposed: [WaitSession]) -> Bool {
        guard original.map(\.id) == proposed.map(\.id) else { return false }
        let proposedByID = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
        for old in original {
            guard var new = proposedByID[old.id] else { return false }
            let expectedSessionOverride = old.manualClassificationOverride == .unclassified
                && old.state == .completed ? nil : old.manualClassificationOverride
            guard expectedSessionOverride == new.manualClassificationOverride,
                  old.classificationReviewHandled == new.classificationReviewHandled else { return false }
            let oldSlices = old.activityClassificationSlices
            let newSlices = new.activityClassificationSlices
            if let oldValues = oldSlices, let newValues = newSlices {
                guard oldValues.map(\.id) == newValues.map(\.id) else { return false }
                for index in oldValues.indices {
                    let expectedSliceOverride = oldValues[index].manualClassificationOverride == .unclassified
                        && old.state == .completed ? nil : oldValues[index].manualClassificationOverride
                    guard oldValues[index].startedAt == newValues[index].startedAt,
                          oldValues[index].endedAt == newValues[index].endedAt,
                          oldValues[index].duration == newValues[index].duration,
                          oldValues[index].sourceActivitySegmentID == newValues[index].sourceActivitySegmentID,
                          expectedSliceOverride == newValues[index].manualClassificationOverride,
                          oldValues[index].classificationReviewHandled == newValues[index].classificationReviewHandled else { return false }
                }
            } else if oldSlices != nil || newSlices != nil {
                return false
            }
            new.classificationResult = old.classificationResult
            new.activityClassificationSlices = old.activityClassificationSlices
            new.manualClassificationOverride = old.manualClassificationOverride
            guard old == new else { return false }
        }
        return true
    }

    private func reclassificationIsComplete(original: [WaitSession], proposed: [WaitSession]) -> Bool {
        let proposedByID = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
        for session in original where session.state == .completed {
            guard let updated = proposedByID[session.id] else { return false }
            if session.classificationResult?.classification == .unclassified,
               updated.classificationResult?.classification == .unclassified {
                return false
            }
            let updatedSlices = Dictionary(uniqueKeysWithValues: (updated.activityClassificationSlices ?? []).map { ($0.id, $0) })
            for slice in session.activityClassificationSlices ?? [] {
                guard let newSlice = updatedSlices[slice.id] else { return false }
                if newSlice.effectiveClassification == .unclassified {
                    return false
                }
            }
        }
        return true
    }
}
