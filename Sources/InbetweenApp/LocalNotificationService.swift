import InbetweenCore
import OSLog
import UserNotifications

@MainActor
final class LocalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let logger = Logger(
        subsystem: "com.inbetween.app",
        category: "notifications"
    )

    private let center: UNUserNotificationCenter?
    private let latencyRecorder: StopLatencyRecorder

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        latencyRecorder: StopLatencyRecorder = StopLatencyRecorder()
    ) {
        self.latencyRecorder = latencyRecorder
        guard NotificationRuntime.supportsUserNotifications(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier
        ) else {
            center = nil
            super.init()
            Self.logger.notice("Notifications disabled because this process is not an identified app bundle")
            return
        }

        center = UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self

        Task { [weak self] in
            await self?.prepareAuthorization()
        }
    }

    func send(_ notification: WaitSessionNotification, for event: LifecycleEvent? = nil) {
        switch notification {
        case .ready:
            submit(
                kind: "stop",
                title: "Codex is ready",
                body: "The active Codex turn stopped.",
                event: event,
                recordsStopLatency: true
            )
        case .permissionMayNeedAttention:
            submit(
                kind: "permission-attention",
                title: "Codex may need you",
                body: "A permission request may still be waiting for your response.",
                event: event,
                recordsStopLatency: false
            )
        }
    }

    func sendSmokeTest() {
        send(.ready)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let kind = notification.request.content.userInfo["inbetween_kind"] as? String ?? "unknown"
        if kind == "stop",
           let sessionID = notification.request.content.userInfo["session_id"] as? String,
           let turnID = notification.request.content.userInfo["turn_id"] as? String {
            latencyRecorder.record(
                .notificationWillPresent,
                sessionID: sessionID,
                turnID: turnID
            )
        }
        Self.logger.notice("Foreground notification will present; kind=\(kind, privacy: .public)")
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let kind = response.notification.request.content.userInfo["inbetween_kind"] as? String ?? "unknown"
        Self.logger.notice("Notification response received; kind=\(kind, privacy: .public)")
        completionHandler()
    }

    private func prepareAuthorization() async {
        guard let center else { return }
        await logSettings(label: "initial", center: center)

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Self.logger.notice("Notification authorization request completed; granted=\(granted, privacy: .public)")
        } catch {
            Self.logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
        }

        await logSettings(label: "current", center: center)
    }

    private func submit(
        kind: String,
        title: String,
        body: String,
        event: LifecycleEvent?,
        recordsStopLatency: Bool
    ) {
        guard let center else {
            if recordsStopLatency, let event {
                latencyRecorder.record(
                    .notificationAddFailed,
                    sessionID: event.sessionID,
                    turnID: event.turnID,
                    outcome: "no_app_bundle"
                )
            }
            Self.logger.notice("Notification not submitted outside an identified app bundle; kind=\(kind, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var userInfo = ["inbetween_kind": kind]
        if let event {
            userInfo["session_id"] = event.sessionID
            userInfo["turn_id"] = event.turnID
        }
        content.userInfo = userInfo

        let identifier = "inbetween-\(kind)-\(UUID().uuidString)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        Task {
            if recordsStopLatency, let event {
                latencyRecorder.record(
                    .notificationAddStarted,
                    sessionID: event.sessionID,
                    turnID: event.turnID
                )
            }
            do {
                try await center.add(request)
                if recordsStopLatency, let event {
                    latencyRecorder.record(
                        .notificationAddCompleted,
                        sessionID: event.sessionID,
                        turnID: event.turnID,
                        outcome: "submitted"
                    )
                }
                Self.logger.notice("Notification request submitted; kind=\(kind, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(500))
                let delivered = await center.deliveredNotifications()
                let pending = await center.pendingNotificationRequests()
                let isDelivered = delivered.contains { $0.request.identifier == identifier }
                let isPending = pending.contains { $0.identifier == identifier }
                if recordsStopLatency, let event {
                    latencyRecorder.record(
                        .notificationObserved,
                        sessionID: event.sessionID,
                        turnID: event.turnID,
                        delivered: isDelivered,
                        pending: isPending
                    )
                }
                Self.logger.notice(
                    "Notification request state; kind=\(kind, privacy: .public) delivered=\(isDelivered, privacy: .public) pending=\(isPending, privacy: .public)"
                )
            } catch {
                if recordsStopLatency, let event {
                    latencyRecorder.record(
                        .notificationAddFailed,
                        sessionID: event.sessionID,
                        turnID: event.turnID,
                        outcome: "add_error"
                    )
                }
                Self.logger.error(
                    "Notification request failed; kind=\(kind, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func logSettings(
        label: String,
        center: UNUserNotificationCenter
    ) async {
        let settings = await center.notificationSettings()
        Self.logger.notice(
            "Notification settings \(label, privacy: .public); authorization=\(settings.authorizationStatus.rawValue, privacy: .public) alerts=\(settings.alertSetting.rawValue, privacy: .public) sounds=\(settings.soundSetting.rawValue, privacy: .public) center=\(settings.notificationCenterSetting.rawValue, privacy: .public)"
        )
    }
}
