import Foundation
import Testing
@testable import InbetweenCore

struct DelayedPermissionAttentionTests {
    private let receivedAt = Date(timeIntervalSince1970: 2_000)

    @Test func permissionInitiallyRemainsWorkingBeforeTheThreshold() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let request = event(.permissionRequest, time: 1_001)

        let update = tracker.observeAcceptedLifecycleEvent(request, receivedAt: receivedAt)
        guard case let .pending(boundaryID, deadline) = update else {
            Issue.record("Expected a pending permission boundary")
            return
        }

        #expect(deadline == receivedAt.addingTimeInterval(8))
        #expect(tracker.state == .pending)
        #expect(tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(7.999)
        ) == .unchanged)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: tracker.state
        ) == .working)
    }

    @Test func persistenceAtThresholdPromotesAndSignalsOnlyOnce() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let request = event(.permissionRequest, time: 1_001)
        let boundaryID = try pendingBoundary(
            tracker.observeAcceptedLifecycleEvent(request, receivedAt: receivedAt)
        )

        #expect(tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(8)
        ) == .becamePersistent(boundaryID: boundaryID, event: request))
        #expect(tracker.state == .mayNeedAttention)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: tracker.state
        ) == .mayNeedAttention)

        #expect(tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(60)
        ) == .unchanged)
    }

    @Test func continuationBeforeThresholdPreventsAttention() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001),
            receivedAt: receivedAt
        ))

        #expect(tracker.observeAcceptedLifecycleEvent(
            event(.userPromptSubmit, time: 1_002),
            receivedAt: receivedAt.addingTimeInterval(2)
        ) == .cleared)
        #expect(tracker.state == .inactive)
        #expect(tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(20)
        ) == .unchanged)
    }

    @Test func continuationAfterAttentionReturnsToWorking() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001),
            receivedAt: receivedAt
        ))
        tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(8)
        )

        #expect(tracker.observeAcceptedLifecycleEvent(
            event(.userPromptSubmit, time: 1_010),
            receivedAt: receivedAt.addingTimeInterval(9)
        ) == .cleared)
        #expect(UserFacingWaitStatus(
            lifecycleState: .active,
            hasActiveWait: true,
            permissionAttentionState: tracker.state
        ) == .working)
    }

    @Test func stopClearsPendingAttentionAndCannotPromoteLater() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001),
            receivedAt: receivedAt
        ))

        #expect(tracker.observeAcceptedLifecycleEvent(
            event(.stop, time: 1_004),
            receivedAt: receivedAt.addingTimeInterval(3)
        ) == .cleared)
        #expect(tracker.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(20)
        ) == .unchanged)
    }

    @Test func aLaterPermissionRequestIsASeparateBoundary() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let firstRequest = event(.permissionRequest, time: 1_001)
        let firstID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            firstRequest,
            receivedAt: receivedAt
        ))
        #expect(tracker.evaluate(
            boundaryID: firstID,
            at: receivedAt.addingTimeInterval(8)
        ) == .becamePersistent(boundaryID: firstID, event: firstRequest))

        let secondRequest = event(.permissionRequest, time: 1_020)
        let secondID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            secondRequest,
            receivedAt: receivedAt.addingTimeInterval(20)
        ))
        #expect(secondID != firstID)
        #expect(tracker.state == .pending)
        #expect(tracker.evaluate(
            boundaryID: firstID,
            at: receivedAt.addingTimeInterval(40)
        ) == .unchanged)
        #expect(tracker.evaluate(
            boundaryID: secondID,
            at: receivedAt.addingTimeInterval(28)
        ) == .becamePersistent(boundaryID: secondID, event: secondRequest))
    }

    @Test func clearingForSleepAndFreshRelaunchCannotReviveAStaleBoundary() throws {
        var beforeSleep = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(beforeSleep.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001),
            receivedAt: receivedAt
        ))

        #expect(beforeSleep.clear() == .cleared)
        #expect(beforeSleep.evaluate(
            boundaryID: boundaryID,
            at: receivedAt.addingTimeInterval(100)
        ) == .unchanged)

        let relaunched = DelayedPermissionAttentionTracker()
        #expect(relaunched.state == .inactive)
        #expect(relaunched.currentBoundaryID == nil)
        #expect(relaunched.deadline == nil)
    }

    private func pendingBoundary(
        _ update: DelayedPermissionAttentionUpdate
    ) throws -> PermissionBoundaryID {
        guard case let .pending(boundaryID, _) = update else {
            Issue.record("Expected a pending permission boundary")
            throw PendingBoundaryError.missing
        }
        return boundaryID
    }

    private func event(
        _ name: LifecycleEventName,
        time: TimeInterval
    ) -> LifecycleEvent {
        LifecycleEvent(
            name: name,
            sessionID: "session-1",
            turnID: "turn-1",
            observedAt: time
        )
    }

    private enum PendingBoundaryError: Error {
        case missing
    }
}
