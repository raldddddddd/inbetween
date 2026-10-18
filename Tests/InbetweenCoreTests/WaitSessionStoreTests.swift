import Foundation
import Testing
@testable import InbetweenCore

struct WaitSessionStoreTests {
    @Test func concurrentStaleSnapshotsCannotDiscardSessionsOrManualDecisions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-concurrent-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sessions.json")
        let initialStore = WaitSessionStore(fileURL: fileURL)
        let firstWriter = WaitSessionStore(fileURL: fileURL)
        let secondWriter = WaitSessionStore(fileURL: fileURL)
        let start = Date(timeIntervalSince1970: 20_000)
        let originalID = UUID()
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.example.editor",
            applicationName: "Editor",
            windowTitle: "Project.swift",
            resourceKind: .project,
            resourceName: "Example project"
        ))
        let originalSegment = ActivitySegment(
            waitSessionID: originalID,
            context: context,
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            duration: 120,
            lastObservedAt: start.addingTimeInterval(120)
        )
        let slice = ActivityClassificationSlice(
            sourceActivitySegmentID: originalSegment.id,
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            duration: 120,
            automaticClassificationResult: .init(
                classification: .distracted,
                reasonCodes: [.sustainedDistractingApplication]
            ),
            manualClassificationOverride: .productive,
            classificationReviewHandled: true
        )
        let original = WaitSession(
            id: originalID,
            codexSessionID: "session-original",
            codexTurnID: "turn-original",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            duration: 120,
            state: .completed,
            activitySegments: [originalSegment],
            classificationResult: .init(
                classification: .distracted,
                reasonCodes: [.sustainedDistractingApplication]
            ),
            activityClassificationSlices: [slice],
            manualClassificationOverride: .productive,
            classificationReviewHandled: true,
            syntheticDataSetID: "test-dataset",
            recordOrigin: .synthetic
        )
        try initialStore.save([original])

        let firstBase = try firstWriter.load()
        let secondBase = try secondWriter.load()
        #expect(firstBase == secondBase)
        let firstCandidate = firstBase + [WaitSession(
            codexSessionID: "session-first",
            codexTurnID: "turn-first",
            startTime: start.addingTimeInterval(200),
            duration: 30,
            state: .completed
        )]
        let secondCandidate = secondBase + [WaitSession(
            codexSessionID: "session-second",
            codexTurnID: "turn-second",
            startTime: start.addingTimeInterval(300),
            duration: 45,
            state: .completed
        )]

        let gate = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()
        let outcomes = ConcurrentStoreSaveOutcomes()
        workers.enter()
        DispatchQueue.global().async {
            gate.wait()
            defer { workers.leave() }
            do {
                try firstWriter.save(firstCandidate, expecting: firstBase)
                outcomes.append(.saved)
            } catch WaitSessionStoreError.staleSnapshot {
                outcomes.append(.stale)
            } catch {
                outcomes.append(.failed(String(describing: error)))
            }
        }
        workers.enter()
        DispatchQueue.global().async {
            gate.wait()
            defer { workers.leave() }
            do {
                try secondWriter.save(secondCandidate, expecting: secondBase)
                outcomes.append(.saved)
            } catch WaitSessionStoreError.staleSnapshot {
                outcomes.append(.stale)
            } catch {
                outcomes.append(.failed(String(describing: error)))
            }
        }
        gate.signal()
        gate.signal()
        workers.wait()

        let results = outcomes.values
        #expect(results.filter { $0 == .saved }.count == 1)
        #expect(results.filter { $0 == .stale }.count == 1)
        #expect(results.allSatisfy {
            switch $0 {
            case .saved, .stale: true
            case .failed: false
            }
        })

        let reloaded = try initialStore.load()
        #expect(reloaded.count == 2)
        #expect(reloaded.first == original)
        #expect(reloaded.first?.id == originalID)
        #expect(reloaded.first?.startTime == start)
        #expect(reloaded.first?.endTime == start.addingTimeInterval(120))
        #expect(reloaded.first?.duration == 120)
        #expect(reloaded.first?.activitySegments == [originalSegment])
        #expect(reloaded.first?.activityClassificationSlices == [slice])
        #expect(reloaded.first?.recordOrigin == .synthetic)
        #expect(reloaded.first?.syntheticDataSetID == "test-dataset")
        #expect(reloaded.first?.manualClassificationOverride == .productive)
        #expect(reloaded.first?.classificationReviewHandled == true)
        #expect(reloaded.first?.activityClassificationSlices?.first?.manualClassificationOverride == .productive)
        #expect(reloaded.first?.activityClassificationSlices?.first?.classificationReviewHandled == true)
        let sessionIDs = Set(reloaded.map(\.codexSessionID))
        let firstCandidateWon = sessionIDs.contains(firstCandidate[1].codexSessionID)
        let secondCandidateWon = sessionIDs.contains(secondCandidate[1].codexSessionID)
        #expect(firstCandidateWon != secondCandidateWon)
        #expect(sessionIDs.contains("session-original"))
    }

    @Test func staleWholeStoreSnapshotCannotOverwriteNewerHistoryOrReviewDecisions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-stale-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("sessions.json")
        let firstWriter = WaitSessionStore(fileURL: fileURL)
        let staleWriter = WaitSessionStore(fileURL: fileURL)
        let start = Date(timeIntervalSince1970: 10_000)
        let originalID = UUID()
        let original = WaitSession(
            id: originalID,
            codexSessionID: "session-original",
            codexTurnID: "turn-original",
            startTime: start,
            endTime: start.addingTimeInterval(90),
            duration: 90,
            state: .completed,
            activityClassificationSlices: [ActivityClassificationSlice(
                sourceActivitySegmentID: UUID(),
                startedAt: start,
                endedAt: start.addingTimeInterval(90),
                duration: 90,
                automaticClassificationResult: .init(
                    classification: .unclassified,
                    reasonCodes: [.insufficientActivityData]
                )
            )]
        )
        try firstWriter.save([original])
        let staleSnapshot = try staleWriter.load()

        let added = WaitSession(
            codexSessionID: "session-added",
            codexTurnID: "turn-added",
            startTime: start.addingTimeInterval(200),
            endTime: start.addingTimeInterval(260),
            duration: 60,
            state: .completed
        )
        var updatedOriginal = original
        updatedOriginal.manualClassificationOverride = .distracted
        updatedOriginal.classificationReviewHandled = true
        var updatedSlices = updatedOriginal.activityClassificationSlices ?? []
        updatedSlices[0].manualClassificationOverride = .productive
        updatedSlices[0].classificationReviewHandled = true
        updatedOriginal.activityClassificationSlices = updatedSlices
        let newerSnapshot = [updatedOriginal, added]
        try firstWriter.save(newerSnapshot, expecting: staleSnapshot)
        let bytesAfterNewerWrite = try Data(contentsOf: fileURL)

        #expect(throws: WaitSessionStoreError.staleSnapshot) {
            try staleWriter.save(staleSnapshot, expecting: staleSnapshot)
        }

        let reloaded = try staleWriter.load()
        #expect(try Data(contentsOf: fileURL) == bytesAfterNewerWrite)
        #expect(reloaded == newerSnapshot)
        #expect(Set(reloaded.map(\.id)) == Set([originalID, added.id]))
        #expect(reloaded[0].manualClassificationOverride == .distracted)
        #expect(reloaded[0].classificationReviewHandled == true)
        #expect(reloaded[0].activityClassificationSlices?.first?.manualClassificationOverride == .productive)
        #expect(reloaded[0].activityClassificationSlices?.first?.classificationReviewHandled == true)
    }

    @Test func completedHistorySurvivesStoreReload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let session = WaitSession(
            codexSessionID: "session-1",
            codexTurnID: "turn-1",
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_008),
            duration: 8,
            state: .completed,
            attentionEvents: [
                WaitSessionAttentionEvent(
                    timestamp: Date(timeIntervalSince1970: 1_004),
                    permissionMode: .acceptEdits
                )
            ]
        )

        try store.save([session])
        let loaded = try store.load()

        #expect(loaded == [session])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    @Test func missingStoreLoadsAsEmptyHistory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-missing-\(UUID().uuidString)/sessions.json")
        let store = WaitSessionStore(fileURL: url)

        #expect(try store.load().isEmpty)
    }

    @Test func selectedAndOtherIntentionsSurvivePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-intention-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let selected = try #require(WaitSessionIntention(kind: .learn))
        let other = try #require(
            WaitSessionIntention(kind: .other, customLabel: "Sketch release notes")
        )
        let sessions = [
            WaitSession(
                codexSessionID: "session-1",
                codexTurnID: "turn-1",
                startTime: Date(timeIntervalSince1970: 1_000),
                endTime: Date(timeIntervalSince1970: 1_010),
                duration: 10,
                state: .completed,
                intention: selected
            ),
            WaitSession(
                codexSessionID: "session-2",
                codexTurnID: "turn-2",
                startTime: Date(timeIntervalSince1970: 2_000),
                intention: other,
                intentionPromptHandled: true
            )
        ]

        try store.save(sessions)
        let loaded = try store.load()

        #expect(loaded == sessions)
        #expect(loaded[0].intention?.displayName == "Learn")
        #expect(loaded[1].intention?.displayName == "Sketch release notes")
        #expect(loaded[1].intentionPromptHandled == true)
    }

    @Test func legacyIntentionCategoriesMigrateAndReencodeAsNewCategories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-legacy-intention-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyKinds = ["learn", "read", "admin", "plan", "move", "custom"]
        let sessions = legacyKinds.enumerated().map { index, kind in
            let label = kind == "custom" ? #", "customLabel": "Preserved label""# : ""
            return #"""
            {
              "id":"00000000-0000-0000-0000-00000000000\#(index + 1)",
              "codexSessionID":"session-\#(index)",
              "codexTurnID":"turn-\#(index)",
              "startTime":1000000,
              "state":"completed",
              "hookSource":"codex-lifecycle-hooks",
              "hookVersion":1,
              "attentionEvents":[],
              "intention":{"kind":"\#(kind)"\#(label)},
              "intentionPromptHandled":true
            }
            """#
        }
        let legacyData = try #require("[\(sessions.joined(separator: ","))]".data(using: .utf8))
        try legacyData.write(to: store.fileURL)

        let loaded = try store.load()

        #expect(loaded.map(\.intention?.kind) == [
            .learn, .learn, .focus, .focus, .move, .other
        ])
        #expect(loaded.last?.intention?.customLabel == "Preserved label")

        try store.save(loaded)
        let reencoded = try String(contentsOf: store.fileURL, encoding: .utf8)
        for legacyKind in ["read", "admin", "plan", "custom"] {
            #expect(!reencoded.contains(#""kind" : "\#(legacyKind)""#))
        }
        #expect(reencoded.contains(#""kind" : "other""#))
        #expect(reencoded.contains("Preserved label"))
    }

    @Test func classificationResultSurvivesPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-classification-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let result = WaitSessionClassificationResult(
            classification: .productive,
            reasonCodes: [.sustainedProductiveApplication],
            explanation: "Deterministic local explanation."
        )
        let session = WaitSession(
            codexSessionID: "session-1",
            codexTurnID: "turn-1",
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_120),
            duration: 120,
            state: .completed,
            classificationResult: result
        )

        try store.save([session])
        let loaded = try store.load()

        #expect(loaded == [session])
        #expect(loaded[0].classificationResult == result)
    }

    @Test func semanticDiagnosticAndManualOverrideSurvivePersistenceSeparately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-semantic-diagnostic-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let start = Date(timeIntervalSince1970: 1_000)
        let segmentID = UUID()
        let slice = ActivityClassificationSlice(
            sourceActivitySegmentID: segmentID,
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            duration: 120,
            automaticClassificationResult: .init(
                classification: .unclassified,
                reasonCodes: [.contextDependentActivity, .noStrongEvidence, .insufficientSemanticConfidence],
                explanation: "The local semantic match did not meet its confidence threshold.",
                reviewSuggested: true
            ),
            manualClassificationOverride: .distracted,
            classificationReviewHandled: true
        )
        let session = WaitSession(
            codexSessionID: "classification-session",
            codexTurnID: "classification-turn",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            duration: 120,
            state: .completed,
            activityClassificationSlices: [slice]
        )

        try store.save([session])
        let loaded = try #require(store.load().first)
        let persistedSlice = try #require(loaded.activityClassificationSlices?.first)

        #expect(persistedSlice.automaticClassification == .unclassified)
        #expect(persistedSlice.automaticClassificationResult.reasonCodes.contains(.insufficientSemanticConfidence))
        #expect(persistedSlice.effectiveClassification == .distracted)
        #expect(persistedSlice.classificationReviewHandled)
    }

    @Test func legacyClassificationShapesDecodeWithoutHistoricalReclassification() throws {
        let json = #"""
        [
          {
            "id":"00000000-0000-0000-0000-000000000001",
            "codexSessionID":"legacy-recovered","codexTurnID":"turn-1",
            "startTime":1000000,"endTime":1120000,"duration":120,
            "state":"completed","hookSource":"h","hookVersion":1,
            "classificationResult":{"classification":"recovered","reasonCodes":["intentionSelected"]},
            "manualClassificationOverride":"distracted","classificationReviewHandled":true
          },
          {
            "id":"00000000-0000-0000-0000-000000000002",
            "codexSessionID":"legacy-not-recorded","codexTurnID":"turn-2",
            "startTime":2000000,"endTime":2060000,"duration":60,
            "state":"completed","hookSource":"h","hookVersion":1
          }
        ]
        """#
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-legacy-classification-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()

        #expect(loaded[0].activityClassificationSlices == nil)
        #expect(loaded[0].automaticClassification == .productive)
        #expect(loaded[0].classificationResult?.reasonCodes == [.legacyIntentionSignal])
        #expect(loaded[0].manualClassificationOverride == .distracted)
        #expect(loaded[0].effectiveClassification == .distracted)
        #expect(loaded[1].activityClassificationSlices == nil)
        #expect(loaded[1].automaticClassification == nil)
        #expect(WaitHistoryInsights.classificationDurations(for: loaded[1]).notRecorded == 60)
    }

    @Test func legacyUnclassifiedActivityWithoutReviewFlagAppearsInManualReview() throws {
        let json = #"""
        [{
          "id":"00000000-0000-0000-0000-000000000003",
          "codexSessionID":"legacy-unclassified","codexTurnID":"turn-3",
          "startTime":3000000,"endTime":3060000,"duration":60,
          "state":"completed","hookSource":"h","hookVersion":1,
          "activitySegments":[{
            "id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "waitSessionID":"00000000-0000-0000-0000-000000000003",
            "context":{"applicationBundleIdentifier":"com.example.legacy","applicationName":"Legacy App","windowTitle":"Captured activity"},
            "startedAt":3000000,"endedAt":3060000,"duration":60
          }],
          "classificationResult":{"classification":"unclassified","reasonCodes":["insufficientActivityData"]}
        }]
        """#
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-legacy-review-eligibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        try Data(json.utf8).write(to: store.fileURL)

        let loaded = try store.load()
        let session = try #require(loaded.first)
        let reviews = WaitPresentationSupport.pendingReviewItems(from: loaded)

        #expect(session.classificationResult?.reviewSuggested == false)
        #expect(session.shouldRequestClassificationReview)
        #expect(reviews.count == 1)
        #expect(reviews[0].contextTitle == "Captured activity")
    }

    @Test func slicedSessionRoundTripPreservesExactSegmentReferenceAndCorrections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-sliced-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let waitID = UUID()
        let segmentID = UUID()
        let sliceID = UUID()
        let start = Date(timeIntervalSince1970: 4_000)
        let xcode = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            presenceState: .active
        ))
        let segment = ActivitySegment(
            id: segmentID, waitSessionID: waitID,
            context: xcode,
            startedAt: start, endedAt: start.addingTimeInterval(45), duration: 45
        )
        let automatic = WaitSessionClassificationResult(
            classification: .productive,
            reasonCodes: [.sustainedProductiveApplication]
        )
        let slice = ActivityClassificationSlice(
            id: sliceID, sourceActivitySegmentID: segmentID,
            startedAt: start, endedAt: start.addingTimeInterval(45), duration: 45,
            automaticClassificationResult: automatic,
            manualClassificationOverride: .distracted, classificationReviewHandled: true
        )
        let session = WaitSession(
            id: waitID, codexSessionID: "new", codexTurnID: "turn",
            startTime: start, endTime: start.addingTimeInterval(45), duration: 45,
            state: .completed, activitySegments: [segment],
            classificationResult: automatic, activityClassificationSlices: [slice]
        )

        try store.save([session])
        let loaded = try #require(store.load().first)

        #expect(loaded.activitySegments.first?.id == segmentID)
        #expect(loaded.activityClassificationSlices?.first?.id == sliceID)
        #expect(loaded.activityClassificationSlices?.first?.sourceActivitySegmentID == segmentID)
        #expect(loaded.activityClassificationSlices?.first?.automaticClassification == .productive)
        #expect(loaded.activityClassificationSlices?.first?.effectiveClassification == .distracted)
        #expect(loaded.activityClassificationSlices?.first?.classificationReviewHandled == true)
        #expect(WaitPresentationSupport.pendingReviewItems(from: [loaded]).isEmpty)
    }
}

private final class ConcurrentStoreSaveOutcomes: @unchecked Sendable {
    enum Value: Equatable {
        case saved
        case stale
        case failed(String)
    }

    private let lock = NSLock()
    private var storedValues: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        storedValues.append(value)
    }
}
