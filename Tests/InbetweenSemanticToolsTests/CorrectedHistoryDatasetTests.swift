import Foundation
import Testing
@testable import InbetweenSemanticTools
import InbetweenCore

struct CorrectedHistoryDatasetTests {
    @Test func exportsOnlyCorrectedSlicesAndAggregatesEquivalentScopedContexts() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let sessionID = UUID()
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserDomain: "developer.apple.com",
            browserPageTitle: "Swift concurrency documentation",
            presenceState: .active
        ))
        let repeated = ActivitySegment(waitSessionID: sessionID, context: context, startedAt: start, endedAt: start.addingTimeInterval(30), duration: 30)
        let second = ActivitySegment(waitSessionID: sessionID, context: context, startedAt: start.addingTimeInterval(35), endedAt: start.addingTimeInterval(65), duration: 30)
        let result = WaitSessionClassificationResult(
            classification: .unclassified,
            reasonCodes: [.contextDependentActivity, .noStrongEvidence]
        )
        let slices = [repeated, second].map { segment in
            ActivityClassificationSlice(
                sourceActivitySegmentID: segment.id,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt!,
                duration: segment.duration!,
                automaticClassificationResult: result,
                manualClassificationOverride: .productive,
                classificationReviewHandled: true
            )
        }
        let completed = WaitSession(
            id: sessionID, codexSessionID: "session", codexTurnID: "turn", startTime: start,
            endTime: start.addingTimeInterval(120), duration: 120, state: .completed,
            activitySegments: [repeated, second], classificationResult: result,
            activityClassificationSlices: slices
        )
        let active = WaitSession(codexSessionID: "active", codexTurnID: "turn", startTime: start, state: .active, activitySegments: [repeated], manualClassificationOverride: .distracted)

        let dataset = CorrectedHistoryDatasetExporter.makeDataset(
            sessions: [active, completed], generatedAt: start
        )

        #expect(dataset.correctedSessionCount == 1)
        #expect(dataset.correctedSliceCount == 2)
        #expect(dataset.legacyWholeWaitCorrectionCount == 0)
        #expect(dataset.exportedContextCount == 1)
        let example = try #require(dataset.examples.first)
        #expect(example.correctionScope == .slice)
        #expect(Set(example.sourceSliceIDs) == Set(slices.map(\.id)))
        #expect(Set(example.sourceActivitySegmentIDs) == Set([repeated.id, second.id]))
        #expect(example.semanticInput == "Page: Swift concurrency documentation | Domain: developer.apple.com")
        #expect(example.contextDurationSeconds == 60)
        #expect(example.contextShareOfSession == 0.5)
        #expect(example.contextShareOfObservedActivity == 1)
        #expect(example.manualClassification == "Productive")
        #expect(example.effectiveClassification == "Productive")
        #expect(example.automaticClassification == "Unclassified")
        #expect(example.automaticReasonCodes == ["contextDependentActivity", "noStrongEvidence"])
        #expect(example.automaticAgreesWithManualCorrection == false)
        #expect(example.semanticCategoryLabel == nil)
    }

    @Test func keepsPresenceTransitionsSeparateAndSkipsAppOnlySegments() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let sessionID = UUID()
        let active = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode",
            windowTitle: "WaitSession.swift", presenceState: .active
        ))
        let away = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode",
            windowTitle: "WaitSession.swift", presenceState: .away
        ))
        let appOnly = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.finder", applicationName: "Finder", presenceState: .idle
        ))
        let session = WaitSession(
            id: sessionID, codexSessionID: "session", codexTurnID: "turn", startTime: start,
            endTime: start.addingTimeInterval(100), duration: 100, state: .completed,
            activitySegments: [
                .init(waitSessionID: sessionID, context: active, startedAt: start, endedAt: start.addingTimeInterval(20), duration: 20),
                .init(waitSessionID: sessionID, context: away, startedAt: start.addingTimeInterval(20), endedAt: start.addingTimeInterval(50), duration: 30),
                .init(waitSessionID: sessionID, context: appOnly, startedAt: start.addingTimeInterval(50), endedAt: start.addingTimeInterval(80), duration: 30),
            ], manualClassificationOverride: .unclassified
        )

        let dataset = CorrectedHistoryDatasetExporter.makeDataset(sessions: [session], generatedAt: start)

        #expect(dataset.examples.count == 2)
        #expect(dataset.correctedSliceCount == 0)
        #expect(dataset.legacyWholeWaitCorrectionCount == 1)
        #expect(dataset.examples.allSatisfy { $0.correctionScope == .legacyWholeWait })
        #expect(dataset.examples.allSatisfy { $0.sourceSliceIDs.isEmpty })
        #expect(Set(dataset.examples.compactMap(\.presenceState)) == ["active", "away"])
        #expect(dataset.skippedNonSemanticSegmentCount == 1)
    }

    @Test func sliceCorrectionDoesNotLabelUncorrectedSiblingContext() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        let sessionID = UUID()
        let correctedContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome",
            browserDomain: "developer.apple.com", browserPageTitle: "Swift documentation",
            presenceState: .active
        ))
        let siblingContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome", applicationName: "Google Chrome",
            browserDomain: "youtube.com", browserPageTitle: "Unrelated video",
            presenceState: .active
        ))
        let correctedSegment = ActivitySegment(
            waitSessionID: sessionID, context: correctedContext, startedAt: start,
            endedAt: start.addingTimeInterval(30), duration: 30
        )
        let siblingSegment = ActivitySegment(
            waitSessionID: sessionID, context: siblingContext, startedAt: start.addingTimeInterval(30),
            endedAt: start.addingTimeInterval(60), duration: 30
        )
        let automatic = WaitSessionClassificationResult(
            classification: .unclassified, reasonCodes: [.noStrongEvidence]
        )
        let session = WaitSession(
            id: sessionID, codexSessionID: "session", codexTurnID: "turn", startTime: start,
            endTime: start.addingTimeInterval(60), duration: 60, state: .completed,
            activitySegments: [correctedSegment, siblingSegment],
            activityClassificationSlices: [
                .init(
                    sourceActivitySegmentID: correctedSegment.id, startedAt: start,
                    endedAt: start.addingTimeInterval(30), duration: 30,
                    automaticClassificationResult: automatic,
                    manualClassificationOverride: .productive, classificationReviewHandled: true
                ),
                .init(
                    sourceActivitySegmentID: siblingSegment.id, startedAt: start.addingTimeInterval(30),
                    endedAt: start.addingTimeInterval(60), duration: 30,
                    automaticClassificationResult: automatic
                )
            ]
        )

        let dataset = CorrectedHistoryDatasetExporter.makeDataset(sessions: [session])

        #expect(dataset.examples.count == 1)
        #expect(dataset.examples[0].browserDomain == "developer.apple.com")
        #expect(dataset.examples[0].contextDurationSeconds == 30)
    }
}
