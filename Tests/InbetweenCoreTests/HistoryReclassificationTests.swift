import Foundation
import Testing
@testable import InbetweenCore

struct HistoryReclassificationTests {
    @Test func reclassifiesHistoricalObservedResultsAndPreservesIdentityOverridesAndGaps() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-history-reclassification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let start = Date(timeIntervalSince1970: 20_000)
        let codingContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserPageTitle: "Editing parser.py",
            presenceState: .active
        ))
        let ambiguousContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserDomain: "example.net",
            browserPageTitle: "Welcome",
            presenceState: .active
        ))
        let codingSegment = segment(waitID: UUID(), context: codingContext, start: start)
        let ambiguousSegment = segment(waitID: UUID(), context: ambiguousContext, start: start)
        let codingSlice = slice(
            segmentID: codingSegment.id,
            start: start,
            manualOverride: .distracted,
            reviewHandled: true
        )
        let codingSession = WaitSession(
            codexSessionID: "historic-coding",
            codexTurnID: "turn-1",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            duration: 60,
            state: .completed,
            activitySegments: [codingSegment],
            classificationResult: .init(classification: .unclassified, reasonCodes: [.noStrongEvidence]),
            activityClassificationSlices: [codingSlice],
            manualClassificationOverride: .productive,
            classificationReviewHandled: true
        )
        let ambiguousSlice = slice(segmentID: ambiguousSegment.id, start: start, reviewHandled: true)
        let ambiguousSession = WaitSession(
            codexSessionID: "historic-ambiguous",
            codexTurnID: "turn-2",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            duration: 60,
            state: .completed,
            activitySegments: [ambiguousSegment],
            classificationResult: .init(classification: .unclassified, reasonCodes: [.noStrongEvidence]),
            activityClassificationSlices: [ambiguousSlice],
            classificationReviewHandled: true
        )
        let manualUnknownSegment = segment(waitID: UUID(), context: ambiguousContext, start: start)
        let explicitManualUnknown = WaitSession(
            codexSessionID: "historic-manual-unknown",
            codexTurnID: "turn-3",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            duration: 60,
            state: .completed,
            activitySegments: [manualUnknownSegment],
            classificationResult: .init(classification: .unclassified, reasonCodes: [.noStrongEvidence]),
            activityClassificationSlices: [slice(
                segmentID: manualUnknownSegment.id,
                start: start,
                manualOverride: .unclassified,
                reviewHandled: true
            )],
            manualClassificationOverride: .unclassified,
            classificationReviewHandled: true
        )
        let gapSession = WaitSession(
            codexSessionID: "historic-gap",
            codexTurnID: "turn-4",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            duration: 60,
            state: .completed,
            classificationResult: .init(classification: .unclassified, reasonCodes: [.unobservedGap]),
            activityClassificationSlices: [ActivityClassificationSlice(
                sourceActivitySegmentID: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(60),
                duration: 60,
                automaticClassificationResult: .init(
                    classification: .unclassified,
                    reasonCodes: [.unobservedGap, .insufficientActivityData]
                ),
                classificationReviewHandled: true
            )]
        )
        let original = [codingSession, ambiguousSession, explicitManualUnknown, gapSession]
        try store.save(original)

        let report = try WaitSessionHistoryReclassifier().apply(to: store, confirmed: true)

        let reloaded = try store.load()
        let reloadedByID = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.id, $0) })
        #expect(reloaded.map(\.id) == original.map(\.id))
        #expect(report.inspectedSessionCount == original.count)
        #expect(report.reclassifiedSessionSummaryCount == 4)
        #expect(report.reclassifiedSliceCount == 4)
        #expect(report.productiveSliceCount == 1)
        #expect(report.distractedSliceCount == 3)
        #expect(report.finalProductiveSliceCount == 0)
        #expect(report.finalDistractedSliceCount == 4)
        #expect(report.finalProductiveSliceDuration == 0)
        #expect(report.finalDistractedSliceDuration == 240)
        #expect(report.finalProductiveSessionSummaryCount == 1)
        #expect(report.finalDistractedSessionSummaryCount == 3)
        #expect(report.preservedUnobservedGapCount == 1)
        #expect(report.preservedManualOverrideCount == 2)
        #expect(report.replacedManualUnclassifiedOverrideCount == 2)
        #expect(report.remainingUnclassifiedSummaryCount == 0)
        #expect(report.remainingUnclassifiedSliceCount == 0)
        #expect(report.backupURL != nil)

        for old in original {
            let updated = try #require(reloadedByID[old.id])
            #expect(updated.startTime == old.startTime)
            #expect(updated.endTime == old.endTime)
            #expect(updated.duration == old.duration)
            #expect(updated.state == old.state)
            #expect(updated.activitySegments == old.activitySegments)
            #expect(updated.manualClassificationOverride == (old.manualClassificationOverride == .unclassified ? nil : old.manualClassificationOverride))
            #expect(updated.classificationReviewHandled == old.classificationReviewHandled)
            let oldSlices = old.activityClassificationSlices ?? []
            let newSlices = updated.activityClassificationSlices ?? []
            #expect(newSlices.map(\.id) == oldSlices.map(\.id))
            #expect(newSlices.map(\.startedAt) == oldSlices.map(\.startedAt))
            #expect(newSlices.map(\.endedAt) == oldSlices.map(\.endedAt))
            #expect(newSlices.map(\.duration) == oldSlices.map(\.duration))
            #expect(newSlices.map(\.sourceActivitySegmentID) == oldSlices.map(\.sourceActivitySegmentID))
            #expect(newSlices.map(\.manualClassificationOverride) == oldSlices.map { $0.manualClassificationOverride == .unclassified ? nil : $0.manualClassificationOverride })
            #expect(newSlices.map(\.classificationReviewHandled) == oldSlices.map(\.classificationReviewHandled))
        }

        let updatedCoding = try #require(reloadedByID[codingSession.id])
        #expect(updatedCoding.classificationResult?.classification == .productive)
        #expect(updatedCoding.activityClassificationSlices?.first?.automaticClassification == .productive)
        #expect(updatedCoding.activityClassificationSlices?.first?.effectiveClassification == .distracted)
        let updatedAmbiguous = try #require(reloadedByID[ambiguousSession.id])
        #expect(updatedAmbiguous.classificationResult?.classification == .distracted)
        #expect(updatedAmbiguous.activityClassificationSlices?.first?.automaticClassification == .distracted)
        let updatedManualUnknown = try #require(reloadedByID[explicitManualUnknown.id])
        #expect(updatedManualUnknown.manualClassificationOverride == nil)
        #expect(updatedManualUnknown.activityClassificationSlices?.first?.manualClassificationOverride == nil)
        #expect(updatedManualUnknown.activityClassificationSlices?.first?.automaticClassification == .distracted)
        let updatedGap = try #require(reloadedByID[gapSession.id])
        #expect(updatedGap.activityClassificationSlices?.first?.isUnobservedGap == true)
        #expect(updatedGap.activityClassificationSlices?.first?.automaticClassification == .distracted)
        #expect(updatedGap.activityClassificationSlices?.first?.effectiveClassification == .distracted)
        #expect(try WaitSessionStore(fileURL: try #require(report.backupURL)).load() == original)
    }

    @Test func classificationFallbackAlwaysReturnsOneOfTwoCategoriesForObservedContext() throws {
        let classifier = WaitSessionClassifier()
        let cases = [
            try #require(ActivityContext(
                applicationBundleIdentifier: "com.google.Chrome",
                applicationName: "Google Chrome",
                browserDomain: "example.net",
                browserPageTitle: "Welcome",
                presenceState: .active
            )),
            try #require(ActivityContext(
                applicationBundleIdentifier: "com.apple.dt.Xcode",
                applicationName: "Xcode",
                browserPageTitle: "Minecraft gameplay video",
                presenceState: .active
            )),
            try #require(ActivityContext(
                applicationBundleIdentifier: "com.apple.Terminal",
                applicationName: "Terminal",
                presenceState: .away
            ))
        ]
        for context in cases {
            let result = classifier.classify(context: context)
            #expect(result.classification == .productive || result.classification == .distracted)
        }
    }

    private func slice(
        segmentID: UUID,
        start: Date,
        manualOverride: WaitSessionClassification? = nil,
        reviewHandled: Bool
    ) -> ActivityClassificationSlice {
        ActivityClassificationSlice(
            sourceActivitySegmentID: segmentID,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            duration: 60,
            automaticClassificationResult: .init(
                classification: .unclassified,
                reasonCodes: [.contextDependentActivity, .noStrongEvidence]
            ),
            manualClassificationOverride: manualOverride,
            classificationReviewHandled: reviewHandled
        )
    }

    private func segment(waitID: UUID, context: ActivityContext, start: Date) -> ActivitySegment {
        ActivitySegment(
            waitSessionID: waitID,
            context: context,
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            duration: 60,
            lastObservedAt: start.addingTimeInterval(60)
        )
    }
}
