import Foundation

public enum LifecycleEventName: String, Codable, CaseIterable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case permissionRequest = "PermissionRequest"
    case interrupt = "Interrupt"
}

public enum PermissionMode: String, Codable, Sendable {
    case `default`
    case acceptEdits
    case plan
    case dontAsk
    case bypassPermissions
}

public struct LifecycleEvent: Codable, Equatable, Sendable {
    public let name: LifecycleEventName
    public let sessionID: String
    public let turnID: String
    public let observedAt: TimeInterval
    public let permissionMode: PermissionMode?
    public let stopHookActive: Bool?
    public let hookInvokedAt: TimeInterval?
    public let hookInvokedMonotonicNanoseconds: UInt64?
    public let bridgeSentAt: TimeInterval?
    public let bridgeSentMonotonicNanoseconds: UInt64?

    public init(
        name: LifecycleEventName,
        sessionID: String,
        turnID: String,
        observedAt: TimeInterval,
        permissionMode: PermissionMode? = nil,
        stopHookActive: Bool? = nil,
        hookInvokedAt: TimeInterval? = nil,
        hookInvokedMonotonicNanoseconds: UInt64? = nil,
        bridgeSentAt: TimeInterval? = nil,
        bridgeSentMonotonicNanoseconds: UInt64? = nil
    ) {
        self.name = name
        self.sessionID = sessionID
        self.turnID = turnID
        self.observedAt = observedAt
        self.permissionMode = permissionMode
        self.stopHookActive = stopHookActive
        self.hookInvokedAt = hookInvokedAt
        self.hookInvokedMonotonicNanoseconds = hookInvokedMonotonicNanoseconds
        self.bridgeSentAt = bridgeSentAt
        self.bridgeSentMonotonicNanoseconds = bridgeSentMonotonicNanoseconds
    }

    public var date: Date { Date(timeIntervalSince1970: observedAt) }

    private enum CodingKeys: String, CodingKey {
        case name = "hook_event_name"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case observedAt
        case permissionMode = "permission_mode"
        case stopHookActive = "stop_hook_active"
        case hookInvokedAt
        case hookInvokedMonotonicNanoseconds
        case bridgeSentAt
        case bridgeSentMonotonicNanoseconds
    }
}

public enum LifecycleEventParseError: Error, Equatable {
    case malformed
    case invalidIdentifier
    case invalidTimestamp
}

public struct LifecycleEventParser: Sendable {
    private let decoder = JSONDecoder()

    public init() {}

    public func parse(_ data: Data) throws -> LifecycleEvent {
        let event: LifecycleEvent
        do {
            event = try decoder.decode(LifecycleEvent.self, from: data)
        } catch {
            throw LifecycleEventParseError.malformed
        }

        guard isValidIdentifier(event.sessionID), isValidIdentifier(event.turnID) else {
            throw LifecycleEventParseError.invalidIdentifier
        }
        guard event.observedAt.isFinite, event.observedAt > 0 else {
            throw LifecycleEventParseError.invalidTimestamp
        }
        return event
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0) &&
                    !CharacterSet.controlCharacters.contains($0)
            }
    }
}
