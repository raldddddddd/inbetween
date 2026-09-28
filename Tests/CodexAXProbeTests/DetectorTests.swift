import XCTest
@testable import CodexAXProbe

final class DetectorTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 100)
    func testAttachIdleDoesNotFinish() {
        var machine = Machine()
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start), [.idle])
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start.addingTimeInterval(3)), [])
    }
    func testCompletionConfirmedAndEmittedOnce() {
        var machine = Machine()
        XCTAssertEqual(machine.update(.working, identity: "a", at: start), [.working])
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start.addingTimeInterval(1)), [])
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start.addingTimeInterval(3)), [.finished, .idle])
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start.addingTimeInterval(4)), [])
        XCTAssertEqual(machine.update(.working, identity: "a", at: start.addingTimeInterval(5)), [.working])
    }
    func testUnknownAndWindowChangeInvalidateCompletion() {
        for changeIdentity in [false, true] {
            var machine = Machine()
            _ = machine.update(.working, identity: "a", at: start)
            if !changeIdentity { _ = machine.update(.unknown, identity: "a", at: start.addingTimeInterval(1)) }
            let result = machine.update(.idle, identity: changeIdentity ? "b" : "a", at: start.addingTimeInterval(4))
            XCTAssertFalse(result.contains(.finished))
        }
    }
    func testApprovalResumeAndTransientIdle() {
        var machine = Machine()
        _ = machine.update(.working, identity: "a", at: start)
        XCTAssertEqual(machine.update(.needsUser, identity: "a", at: start.addingTimeInterval(1)), [.needsUser])
        XCTAssertEqual(machine.update(.working, identity: "a", at: start.addingTimeInterval(2)), [.working])
        _ = machine.update(.idle, identity: "a", at: start.addingTimeInterval(3))
        XCTAssertEqual(machine.update(.working, identity: "a", at: start.addingTimeInterval(4)), [])
        _ = machine.update(.idle, identity: "a", at: start.addingTimeInterval(5))
        XCTAssertEqual(machine.update(.idle, identity: "a", at: start.addingTimeInterval(7)), [.finished, .idle])
    }
    func testClassificationRequiresScopeAndUnambiguousCompleteEvidence() {
        let scope = Signal(role: "AXWindow", attribute: "AXTitle", sha256: "scope")
        let working = Signal(role: "AXButton", attribute: "AXIdentifier", sha256: "work")
        let idle = Signal(role: "AXButton", attribute: "AXIdentifier", sha256: "idle")
        let rules = Rules(scope: [scope], idle: [idle], working: [working], needsUser: [])
        XCTAssertEqual(rules.classify([scope, working], complete: true).0, .working)
        XCTAssertEqual(rules.classify([working], complete: true).0, .unknown)
        XCTAssertEqual(rules.classify([scope, working, idle], complete: true).0, .unknown)
        XCTAssertEqual(rules.classify([scope, working], complete: false).0, .unknown)
    }
}
