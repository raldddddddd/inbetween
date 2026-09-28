import ServiceManagement

@MainActor
final class LaunchAtLoginController {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var isEnabled: Bool {
        service.status == .enabled
    }

    var statusText: String {
        switch service.status {
        case .enabled:
            return "Launch at Login enabled"
        case .requiresApproval:
            return "Launch at Login requires approval in System Settings"
        case .notRegistered:
            return "Launch at Login disabled"
        case .notFound:
            return "Launch at Login is available from the bundled app"
        @unknown default:
            return "Launch at Login status unavailable"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
