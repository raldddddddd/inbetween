import AppKit

@MainActor
final class SystemLifecycleMonitor: NSObject {
    typealias Handler = @MainActor (Date) -> Void

    private let workspaceNotificationCenter: NotificationCenter
    private let onSleep: Handler
    private let onWake: Handler
    private let onTerminate: Handler

    init(
        workspace: NSWorkspace = .shared,
        onSleep: @escaping Handler,
        onWake: @escaping Handler,
        onTerminate: @escaping Handler
    ) {
        workspaceNotificationCenter = workspace.notificationCenter
        self.onSleep = onSleep
        self.onWake = onWake
        self.onTerminate = onTerminate
        super.init()

        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(willSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(didWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    isolated deinit {
        workspaceNotificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func willSleep(_ notification: Notification) {
        onSleep(Date())
    }

    @objc private func didWake(_ notification: Notification) {
        onWake(Date())
    }

    @objc private func willTerminate(_ notification: Notification) {
        onTerminate(Date())
    }
}
