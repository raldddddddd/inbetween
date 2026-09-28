import Foundation
import Testing
@testable import InbetweenCore

struct LifecycleDiagnosticRecorderTests {
    @Test func writesPrivacyScopedLifecycleTraceAsJSONLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("lifecycle-diagnostics.jsonl")
        let recorder = LifecycleDiagnosticRecorder(fileURL: fileURL)

        recorder.record(LifecycleDiagnosticEntry(
            loggedAt: 2_000.123,
            source: "lifecycle_event",
            lifecycleEvent: LifecycleEventName.permissionRequest.rawValue,
            eventObservedAt: 1_999.875,
            sessionID: "session-1",
            turnID: "turn-1",
            boundaryID: "session-1/turn-1/1999.875",
            lifecycleDisposition: "accepted",
            sessionUpdate: "attentionRecorded",
            permissionAttentionBefore: .inactive,
            permissionAttentionAfter: .pending,
            timerAction: "started",
            enteredMayNeedAttention: false,
            attentionNotificationSent: false
        ))

        let line = try String(contentsOf: fileURL, encoding: .utf8)
        let entry = try JSONDecoder().decode(
            LifecycleDiagnosticEntry.self,
            from: try #require(line.data(using: .utf8))
        )
        #expect(entry.loggedAt == 2_000.123)
        #expect(entry.lifecycleEvent == "PermissionRequest")
        #expect(entry.permissionAttentionBefore == "inactive")
        #expect(entry.permissionAttentionAfter == "pending")
        #expect(entry.timerAction == "started")
        #expect(!entry.attentionNotificationSent)
        #expect(!line.contains("prompt"))
    }
}
