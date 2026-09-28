import Foundation
import Testing
@testable import InbetweenCore

struct WaitSessionStoreTests {
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
    }
}
