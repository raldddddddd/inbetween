import Foundation
import Testing
@testable import InbetweenCore

struct UserFacingWaitStatusTests {
    @Test func permissionRequestKeepsAnActiveWaitWorking() {
        var machine = LifecycleStateMachine()
        let now = Date(timeIntervalSince1970: 1_100)

        #expect(machine.apply(event(.userPromptSubmit, time: 1_000), now: now) == .accepted)
        #expect(machine.apply(event(.permissionRequest, time: 1_001), now: now) == .accepted)
        #expect(machine.snapshot.state == .attention)
        #expect(
            UserFacingWaitStatus(
                lifecycleState: machine.snapshot.state,
                hasActiveWait: machine.snapshot.activeTurn != nil,
                permissionAttentionState: .pending
            ) == .working
        )
    }

    @Test func onlyPersistentPermissionAttentionSurfacesMayNeedAttention() {
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: .inactive
        ) == .working)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: .pending
        ) == .working)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: .mayNeedAttention
        ) == .mayNeedAttention)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: false,
            permissionAttentionState: .mayNeedAttention
        ) == .listening)
    }

    @Test func readyLifecycleStateIsPresentedAsReady() {
        #expect(UserFacingWaitStatus(lifecycleState: .idle, hasActiveWait: false) == .listening)
        #expect(UserFacingWaitStatus(lifecycleState: .attention, hasActiveWait: false) == .listening)
        #expect(UserFacingWaitStatus(lifecycleState: .ready, hasActiveWait: false) == .ready)
    }

    private func event(
        _ name: LifecycleEventName,
        time: TimeInterval
    ) -> LifecycleEvent {
        LifecycleEvent(name: name, sessionID: "session-1", turnID: "turn-1", observedAt: time)
    }
}
