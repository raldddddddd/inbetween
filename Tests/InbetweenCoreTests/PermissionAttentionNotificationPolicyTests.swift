import Foundation
import Testing
@testable import InbetweenCore

struct PermissionAttentionNotificationPolicyTests {
    private let receivedAt = Date(timeIntervalSince1970: 2_000)

    @Test func permissionRequestIsWorkingAndDoesNotDispatchImmediately() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let request = event(.permissionRequest, time: 1_001)

        let update = tracker.observeAcceptedLifecycleEvent(request, receivedAt: receivedAt)

        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: update) == nil)
        #expect(WaitSessionNotificationPolicy.notification(
            forAcceptedSessionUpdate: .attentionRecorded(UUID()),
            event: request
        ) == nil)
        #expect(UserFacingWaitStatus(
            lifecycleState: .attention,
            hasActiveWait: true,
            permissionAttentionState: tracker.state
        ) == .working)
    }

    @Test func continuationBeforeThresholdDispatchesNothing() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001), receivedAt: receivedAt
        ))

        let continuation = tracker.observeAcceptedLifecycleEvent(
            event(.userPromptSubmit, time: 1_002), receivedAt: receivedAt.addingTimeInterval(2)
        )
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: continuation) == nil)
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: tracker.evaluate(
            boundaryID: boundaryID, at: receivedAt.addingTimeInterval(20)
        )) == nil)
    }

    @Test func persistentPermissionAttentionDoesNotDispatchNotification() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let request = event(.permissionRequest, time: 1_001)
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            request, receivedAt: receivedAt
        ))

        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: tracker.evaluate(
            boundaryID: boundaryID, at: receivedAt.addingTimeInterval(8)
        )) == nil)
        #expect(tracker.state == .mayNeedAttention)
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: tracker.evaluate(
            boundaryID: boundaryID, at: receivedAt.addingTimeInterval(20)
        )) == nil)
    }

    @Test func continuationAfterAttentionClearsWithoutAnotherNotification() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001), receivedAt: receivedAt
        ))
        _ = tracker.evaluate(boundaryID: boundaryID, at: receivedAt.addingTimeInterval(8))

        let continuation = tracker.observeAcceptedLifecycleEvent(
            event(.userPromptSubmit, time: 1_010), receivedAt: receivedAt.addingTimeInterval(9)
        )
        #expect(continuation == .cleared)
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: continuation) == nil)
        #expect(tracker.state == .inactive)
    }

    @Test func stopWhilePendingCancelsAttentionAndDispatchesOnlyReady() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let boundaryID = try pendingBoundary(tracker.observeAcceptedLifecycleEvent(
            event(.permissionRequest, time: 1_001), receivedAt: receivedAt
        ))
        let stop = event(.stop, time: 1_004)

        let clear = tracker.observeAcceptedLifecycleEvent(stop, receivedAt: receivedAt.addingTimeInterval(3))
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: clear) == nil)
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: tracker.evaluate(
            boundaryID: boundaryID, at: receivedAt.addingTimeInterval(20)
        )) == nil)
        #expect(WaitSessionNotificationPolicy.notification(
            forAcceptedSessionUpdate: .completed(UUID()), event: stop
        ) == .ready)
    }

    @Test func duplicatePermissionRequestDoesNotDispatchOrCreateAnotherDeadline() throws {
        var tracker = DelayedPermissionAttentionTracker()
        let request = event(.permissionRequest, time: 1_001)
        let first = tracker.observeAcceptedLifecycleEvent(request, receivedAt: receivedAt)
        let duplicate = tracker.observeAcceptedLifecycleEvent(request, receivedAt: receivedAt.addingTimeInterval(1))

        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: first) == nil)
        #expect(duplicate == .unchanged)
        #expect(WaitSessionNotificationPolicy.dispatch(forDelayedPermissionUpdate: duplicate) == nil)
    }

    private func pendingBoundary(_ update: DelayedPermissionAttentionUpdate) throws -> PermissionBoundaryID {
        guard case let .pending(boundaryID, _) = update else {
            Issue.record("Expected a pending permission boundary")
            throw PendingBoundaryError.missing
        }
        return boundaryID
    }

    private func event(_ name: LifecycleEventName, time: TimeInterval) -> LifecycleEvent {
        LifecycleEvent(name: name, sessionID: "session-1", turnID: "turn-1", observedAt: time)
    }

    private enum PendingBoundaryError: Error { case missing }
}
