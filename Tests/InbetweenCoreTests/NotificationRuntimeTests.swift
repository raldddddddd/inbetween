import Foundation
import Testing
@testable import InbetweenCore

struct NotificationRuntimeTests {
    @Test func enablesNotificationsOnlyForIdentifiedAppBundle() {
        #expect(NotificationRuntime.supportsUserNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/Inbetween.app"),
            bundleIdentifier: "com.inbetween.app"
        ))
        #expect(!NotificationRuntime.supportsUserNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/Inbetween"),
            bundleIdentifier: "com.inbetween.app"
        ))
        #expect(!NotificationRuntime.supportsUserNotifications(
            bundleURL: URL(fileURLWithPath: "/tmp/Inbetween.app"),
            bundleIdentifier: nil
        ))
    }
}
