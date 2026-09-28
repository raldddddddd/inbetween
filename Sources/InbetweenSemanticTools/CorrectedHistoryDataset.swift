import Foundation
import InbetweenCore

/// Local-only, development-facing data made from contexts the user has
/// explicitly corrected. It intentionally contains no embeddings and no
/// inferred semantic category: Productive/Distracted/Unclassified is a user
/// productivity label, not a statement about the activity's semantic kind.
public struct CorrectedHistorySemanticDataset: Codable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let generatedAt: Date
    public let correctedSessionCount: Int
    public let correctedSliceCount: Int
    public let legacyWholeWaitCorrectionCount: Int
    public let exportedContextCount: Int
    public let skippedNonSemanticSegmentCount: Int
    public let examples: [CorrectedHistorySemanticExample]

    public init(
        generatedAt: Date,
        correctedSessionCount: Int,
        correctedSliceCount: Int,
        legacyWholeWaitCorrectionCount: Int,
        exportedContextCount: Int,
        skippedNonSemanticSegmentCount: Int,
        examples: [CorrectedHistorySemanticExample]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.correctedSessionCount = correctedSessionCount
        self.correctedSliceCount = correctedSliceCount
        self.legacyWholeWaitCorrectionCount = legacyWholeWaitCorrectionCount
        self.exportedContextCount = exportedContextCount
        self.skippedNonSemanticSegmentCount = skippedNonSemanticSegmentCount
        self.examples = examples
    }
}

public struct CorrectedHistorySemanticExample: Codable, Sendable {
    public let id: String
    public let semanticInput: String
    public let correctionScope: CorrectedHistoryCorrectionScope
    public let waitSessionID: UUID
    public let sourceSliceIDs: [UUID]
    public let sourceActivitySegmentIDs: [UUID]
    public let applicationName: String
    public let applicationBundleIdentifier: String
    public let browserDomain: String?
    public let browserPageTitle: String?
    public let windowTitle: String?
    public let resourceKind: String?
    public let resourceName: String?
    public let documentName: String?
    public let resourcePath: String?
    public let presenceState: String?
    public let contextDurationSeconds: TimeInterval
    public let contextShareOfSession: Double
    public let contextShareOfObservedActivity: Double
    public let sessionDurationSeconds: TimeInterval
    public let automaticClassification: String?
    public let automaticReasonCodes: [String]
    public let manualClassification: String
    public let effectiveClassification: String
    /// Always nil for history exports. Only the hand-authored corpus may
    /// provide this label, so productivity corrections cannot masquerade as
    /// semantic ground truth.
    public let semanticCategoryLabel: String?
    public let automaticAgreesWithManualCorrection: Bool
}

public enum CorrectedHistoryCorrectionScope: String, Codable, Sendable {
    case slice
    case legacyWholeWait
}

public enum CorrectedHistoryDatasetExporter {
    /// New sessions export only manually corrected slices. Legacy sessions keep
    /// their whole-wait correction scope explicit so context rows are not
    /// mistaken for independently labeled activity.
    public static func makeDataset(
        sessions: [WaitSession],
        generatedAt: Date = Date()
    ) -> CorrectedHistorySemanticDataset {
        let corrected = sessions
            .filter { session in
                guard session.state == .completed else { return false }
                if let slices = session.activityClassificationSlices {
                    return slices.contains { $0.manualClassificationOverride != nil }
                }
                return session.manualClassificationOverride != nil
            }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.startTime < rhs.startTime
            }

        var examples: [CorrectedHistorySemanticExample] = []
        var skipped = 0
        var correctedSliceCount = 0
        var legacyWholeWaitCorrectionCount = 0
        for session in corrected {
            guard let duration = session.duration, duration > 0 else { continue }
            let completeSegments = session.activitySegments.filter {
                $0.endedAt != nil && ($0.duration ?? 0) > 0
            }
            let observed = completeSegments.reduce(0) { $0 + max(0, $1.duration ?? 0) }
            let segmentByID = Dictionary(uniqueKeysWithValues: completeSegments.map { ($0.id, $0) })

            if let slices = session.activityClassificationSlices {
                let correctedSlices = slices.filter { $0.manualClassificationOverride != nil }
                correctedSliceCount += correctedSlices.count
                var groups: [ScopedContextKey: ScopedGroup] = [:]
                for slice in correctedSlices {
                    guard let sourceID = slice.sourceActivitySegmentID,
                          let segment = segmentByID[sourceID],
                          SemanticActivityDescription(context: segment.context) != nil,
                          let manual = slice.manualClassificationOverride
                    else { skipped += 1; continue }
                    let key = ScopedContextKey(
                        context: segment.context,
                        automatic: slice.automaticClassification,
                        reasons: slice.automaticClassificationResult.reasonCodes,
                        manual: manual
                    )
                    groups[key, default: ScopedGroup()].append(slice: slice, sourceID: sourceID)
                }
                appendExamples(
                    groups: groups, scope: .slice, session: session,
                    sessionDuration: duration,
                    observedDuration: slices.filter { !$0.isUnobservedGap }.reduce(0) { $0 + max(0, $1.duration) },
                    to: &examples
                )
            } else if let manual = session.manualClassificationOverride {
                legacyWholeWaitCorrectionCount += 1
                var groups: [ScopedContextKey: ScopedGroup] = [:]
                for segment in completeSegments {
                    guard SemanticActivityDescription(context: segment.context) != nil else {
                        skipped += 1; continue
                    }
                    let key = ScopedContextKey(
                        context: segment.context,
                        automatic: session.automaticClassification,
                        reasons: session.classificationResult?.reasonCodes ?? [],
                        manual: manual
                    )
                    groups[key, default: ScopedGroup()].append(segment: segment)
                }
                appendExamples(
                    groups: groups, scope: .legacyWholeWait, session: session,
                    sessionDuration: duration, observedDuration: observed, to: &examples
                )
            }
        }

        return CorrectedHistorySemanticDataset(
            generatedAt: generatedAt,
            correctedSessionCount: corrected.count,
            correctedSliceCount: correctedSliceCount,
            legacyWholeWaitCorrectionCount: legacyWholeWaitCorrectionCount,
            exportedContextCount: examples.count,
            skippedNonSemanticSegmentCount: skipped,
            examples: examples
        )
    }

    private static func appendExamples(
        groups: [ScopedContextKey: ScopedGroup],
        scope: CorrectedHistoryCorrectionScope,
        session: WaitSession,
        sessionDuration: TimeInterval,
        observedDuration: TimeInterval,
        to examples: inout [CorrectedHistorySemanticExample]
    ) {
        for key in groups.keys.sorted(by: { $0.context.semanticInput < $1.context.semanticInput }) {
            guard let group = groups[key] else { continue }
            examples.append(CorrectedHistorySemanticExample(
                id: "corrected-context-\(examples.count + 1)",
                semanticInput: key.context.semanticInput,
                correctionScope: scope,
                waitSessionID: session.id,
                sourceSliceIDs: group.sliceIDs.sorted { $0.uuidString < $1.uuidString },
                sourceActivitySegmentIDs: group.sourceActivitySegmentIDs.sorted { $0.uuidString < $1.uuidString },
                applicationName: key.context.applicationName,
                applicationBundleIdentifier: key.context.applicationBundleIdentifier,
                browserDomain: key.context.browserDomain,
                browserPageTitle: key.context.browserPageTitle,
                windowTitle: key.context.windowTitle,
                resourceKind: key.context.resourceKind,
                resourceName: key.context.resourceName,
                documentName: key.context.documentName,
                resourcePath: key.context.resourcePath,
                presenceState: key.context.presenceState,
                contextDurationSeconds: group.duration,
                contextShareOfSession: group.duration / sessionDuration,
                contextShareOfObservedActivity: observedDuration > 0 ? group.duration / observedDuration : 0,
                sessionDurationSeconds: sessionDuration,
                automaticClassification: key.automatic?.title,
                automaticReasonCodes: key.reasons,
                manualClassification: key.manual.title,
                effectiveClassification: key.manual.title,
                semanticCategoryLabel: nil,
                automaticAgreesWithManualCorrection: key.automatic == key.manual
            ))
        }
    }

    private static func reasonCode(_ reason: WaitSessionClassificationReason) -> String {
        // This deliberately follows the persisted code rather than a display
        // string, without adding production-only API just for development IO.
        guard let data = try? JSONEncoder().encode(reason),
              let code = try? JSONDecoder().decode(String.self, from: data) else {
            return String(describing: reason)
        }
        return code
    }

    private struct ContextKey: Hashable {
        let semanticInput: String
        let applicationName: String
        let applicationBundleIdentifier: String
        let browserDomain: String?
        let browserPageTitle: String?
        let windowTitle: String?
        let resourceKind: String?
        let resourceName: String?
        let documentName: String?
        let resourcePath: String?
        let presenceState: String?

        init(_ context: ActivityContext) {
            semanticInput = SemanticActivityDescription(context: context)?.text ?? ""
            applicationName = context.applicationName
            applicationBundleIdentifier = context.applicationBundleIdentifier
            browserDomain = context.browserDomain
            browserPageTitle = context.browserPageTitle
            windowTitle = context.windowTitle
            resourceKind = context.resourceKind?.rawValue
            resourceName = context.resourceName
            documentName = context.documentName
            resourcePath = context.resourcePath
            presenceState = context.presenceState?.rawValue
        }
    }

    private struct ScopedContextKey: Hashable {
        let context: ContextKey
        let automatic: WaitSessionClassification?
        let reasons: [String]
        let manual: WaitSessionClassification

        init(
            context: ActivityContext,
            automatic: WaitSessionClassification?,
            reasons: [WaitSessionClassificationReason],
            manual: WaitSessionClassification
        ) {
            self.context = ContextKey(context)
            self.automatic = automatic
            self.reasons = reasons.map(reasonCode)
            self.manual = manual
        }
    }

    private struct ScopedGroup {
        var duration: TimeInterval = 0
        var sliceIDs: Set<UUID> = []
        var sourceActivitySegmentIDs: Set<UUID> = []

        mutating func append(slice: ActivityClassificationSlice, sourceID: UUID) {
            duration += max(0, slice.duration)
            sliceIDs.insert(slice.id)
            sourceActivitySegmentIDs.insert(sourceID)
        }

        mutating func append(segment: ActivitySegment) {
            duration += max(0, segment.duration ?? 0)
            sourceActivitySegmentIDs.insert(segment.id)
        }
    }
}
