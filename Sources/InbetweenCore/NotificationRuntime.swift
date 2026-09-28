import Foundation

public enum NotificationRuntime {
    public static func supportsUserNotifications(
        bundleURL: URL,
        bundleIdentifier: String?
    ) -> Bool {
        bundleURL.pathExtension == "app"
            && !(bundleIdentifier?.isEmpty ?? true)
    }
}

/// Keeps notification emission tied to reliable state transitions rather than
/// merely observing a lifecycle event. In particular, a permission boundary is
/// recorded immediately but is not a notification-worthy state by itself.
public enum WaitSessionNotificationPolicy {
    /// Terminal session completion is the only notification produced directly
    /// by an accepted lifecycle/session update. The explicit event check makes
    /// it impossible for a `PermissionRequest` to submit a notification through
    /// this path, even if a future session update changes its notification API.
    public static func notification(
        forAcceptedSessionUpdate update: WaitSessionUpdate,
        event: LifecycleEvent
    ) -> WaitSessionNotification? {
        guard event.name != .permissionRequest else { return nil }
        return update.notification
    }

    /// Permission-attention notifications are intentionally disabled for this
    /// development cycle. The delayed tracker may still promote its UI state,
    /// but no macOS notification is dispatched from that transition.
    public static func dispatch(
        forDelayedPermissionUpdate update: DelayedPermissionAttentionUpdate
    ) -> NotificationDispatch? {
        _ = update
        return nil
    }
}

public struct NotificationDispatch: Equatable, Sendable {
    public let notification: WaitSessionNotification
    public let event: LifecycleEvent

    public init(notification: WaitSessionNotification, event: LifecycleEvent) {
        self.notification = notification
        self.event = event
    }
}
