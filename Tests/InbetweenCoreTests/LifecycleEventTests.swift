import Foundation
import Testing
@testable import InbetweenCore

struct LifecycleEventTests {
    private let parser = LifecycleEventParser()

    @Test func parsesOnlySupportedMetadata() throws {
        let data = Data(#"""
        {
            "hook_event_name":"PermissionRequest",
            "session_id":"session-1",
            "turn_id":"turn-1",
            "observedAt":1000,
            "permission_mode":"default",
            "prompt":"must be ignored",
            "tool_input":{"command":"must be ignored"}
        }
        """#.utf8)

        let event = try parser.parse(data)

        #expect(event.name == .permissionRequest)
        #expect(event.sessionID == "session-1")
        #expect(event.turnID == "turn-1")
        #expect(event.permissionMode == .default)
    }

    @Test func rejectsUnknownEventsAndInvalidIdentifiers() {
        let unknown = Data(#"{"hook_event_name":"Transcript","session_id":"s","turn_id":"t","observedAt":1}"#.utf8)
        let invalidID = Data(#"{"hook_event_name":"Stop","session_id":"s","turn_id":"bad id","observedAt":1}"#.utf8)

        #expect(throws: LifecycleEventParseError.malformed) { try parser.parse(unknown) }
        #expect(throws: LifecycleEventParseError.invalidIdentifier) { try parser.parse(invalidID) }
    }

    @Test func parsesPrivacySafeBridgeTimingMetadata() throws {
        let data = Data(#"""
        {
            "hook_event_name":"Stop",
            "session_id":"session-1",
            "turn_id":"turn-1",
            "observedAt":1000,
            "hookInvokedAt":1000,
            "hookInvokedMonotonicNanoseconds":2000,
            "bridgeSentAt":1000.001,
            "bridgeSentMonotonicNanoseconds":3000,
            "prompt":"ignored"
        }
        """#.utf8)

        let event = try parser.parse(data)

        #expect(event.hookInvokedAt == 1000)
        #expect(event.hookInvokedMonotonicNanoseconds == 2000)
        #expect(event.bridgeSentAt == 1000.001)
        #expect(event.bridgeSentMonotonicNanoseconds == 3000)
    }
}
