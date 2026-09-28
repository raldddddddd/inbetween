import Foundation

/// The conservative, user-facing interpretation of a recorded permission boundary.
///
/// This state is intentionally separate from `ApplicationLifecycleState`. The
/// lifecycle state machine retains its exact event semantics while this tracker
/// requires a short period without supported continuation evidence before the UI
/// suggests that Codex may need the user.
public enum DelayedPermissionAttentionState: Equatable, Sendable {
    case inactive
    case pending
    case mayNeedAttention
}

/// Stable identity for one recorded permission boundary.
public struct PermissionBoundaryID: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let observedAt: TimeInterval

    public init(sessionID: String, turnID: String, observedAt: TimeInterval) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
    }

    init(event: LifecycleEvent) {
        self.init(
            sessionID: event.sessionID,
            turnID: event.turnID,
            observedAt: event.observedAt
        )
    }
}

/// A one-shot transition emitted while tracking a permission boundary.
public enum DelayedPermissionAttentionUpdate: Equatable, Sendable {
    case unchanged
    case pending(boundaryID: PermissionBoundaryID, deadline: Date)
    case cleared
    case becamePersistent(boundaryID: PermissionBoundaryID, event: LifecycleEvent)
}

/// Tracks whether a permission boundary has persisted without a supported
/// lifecycle continuation event.
///
/// Time is supplied by the caller so tests never need to sleep. This type does
/// not schedule work itself; the application can schedule a single cancellable
/// wake-up for the deadline returned by `.pending`.
public struct DelayedPermissionAttentionTracker: Sendable {
    public static let permissionPersistenceThreshold: TimeInterval = 8

    public private(set) var state: DelayedPermissionAttentionState = .inactive
    public private(set) var currentBoundaryID: PermissionBoundaryID?
    public private(set) var deadline: Date?

    private let threshold: TimeInterval
    private var currentEvent: LifecycleEvent?

    public init(
        threshold: TimeInterval = DelayedPermissionAttentionTracker
            .permissionPersistenceThreshold
    ) {
        precondition(threshold >= 0 && threshold.isFinite)
        self.threshold = threshold
    }

    /// Observes an event only after the lifecycle/session pipeline has accepted it.
    ///
    /// A distinct `PermissionRequest` starts a new boundary. `UserPromptSubmit`
    /// is the supported nonterminal continuation event in the current hook model;
    /// terminal events clear the boundary as well. A later permission request is
    /// itself evidence that execution passed the previous boundary, then begins a
    /// separate boundary with its own delay.
    @discardableResult
    public mutating func observeAcceptedLifecycleEvent(
        _ event: LifecycleEvent,
        receivedAt: Date
    ) -> DelayedPermissionAttentionUpdate {
        switch event.name {
        case .permissionRequest:
            let boundaryID = PermissionBoundaryID(event: event)
            guard boundaryID != currentBoundaryID else { return .unchanged }

            let deadline = receivedAt.addingTimeInterval(threshold)
            currentBoundaryID = boundaryID
            currentEvent = event
            self.deadline = deadline
            state = .pending
            return .pending(boundaryID: boundaryID, deadline: deadline)

        case .userPromptSubmit, .stop, .interrupt:
            return clear()
        }
    }

    /// Promotes only the expected boundary, and only once, after its deadline.
    /// Supplying the boundary identity prevents a canceled wake-up for an older
    /// request from promoting a newer one.
    @discardableResult
    public mutating func evaluate(
        boundaryID expectedBoundaryID: PermissionBoundaryID,
        at now: Date
    ) -> DelayedPermissionAttentionUpdate {
        guard state == .pending,
              currentBoundaryID == expectedBoundaryID,
              let deadline,
              now >= deadline,
              let currentEvent
        else {
            return .unchanged
        }

        state = .mayNeedAttention
        return .becamePersistent(boundaryID: expectedBoundaryID, event: currentEvent)
    }

    /// Clears ephemeral presentation state. Callers use this for supported
    /// continuation/terminal events and before sleep or termination. A fresh
    /// tracker deliberately does not reconstruct stale attention from history.
    @discardableResult
    public mutating func clear() -> DelayedPermissionAttentionUpdate {
        guard state != .inactive || currentBoundaryID != nil else { return .unchanged }
        state = .inactive
        currentBoundaryID = nil
        currentEvent = nil
        deadline = nil
        return .cleared
    }
}
