/// The conservative status Inbetween may present to the user.
///
/// Lifecycle events can retain internal detail that is useful for local history
/// without proving that Codex is blocked. In particular, `PermissionRequest`
/// remains Working unless a separate delayed tracker observes that the boundary
/// persisted without a supported continuation event.
public enum UserFacingWaitStatus: Equatable, Sendable {
    case listening
    case working
    case mayNeedAttention
    case ready

    public init(
        lifecycleState: ApplicationLifecycleState,
        hasActiveWait: Bool,
        permissionAttentionState: DelayedPermissionAttentionState = .inactive
    ) {
        if hasActiveWait {
            self = permissionAttentionState == .mayNeedAttention
                ? .mayNeedAttention
                : .working
            return
        }

        switch lifecycleState {
        case .ready:
            self = .ready
        case .idle, .active, .attention:
            self = .listening
        }
    }
}
