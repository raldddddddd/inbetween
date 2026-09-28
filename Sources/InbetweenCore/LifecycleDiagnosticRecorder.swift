import Foundation

/// Local, development-oriented trace entry for investigating lifecycle timing.
/// It deliberately contains only lifecycle identifiers and state transitions;
/// no prompt, activity, browser, or document content is recorded.
public struct LifecycleDiagnosticEntry: Codable, Equatable, Sendable {
    public let loggedAt: TimeInterval
    public let source: String
    public let lifecycleEvent: String
    public let eventObservedAt: TimeInterval?
    public let sessionID: String?
    public let turnID: String?
    public let boundaryID: String?
    public let lifecycleDisposition: String?
    public let sessionUpdate: String?
    public let permissionAttentionBefore: String
    public let permissionAttentionAfter: String
    public let timerAction: String
    public let enteredMayNeedAttention: Bool
    public let attentionNotificationSent: Bool

    public init(
        loggedAt: TimeInterval = Date().timeIntervalSince1970,
        source: String,
        lifecycleEvent: String,
        eventObservedAt: TimeInterval? = nil,
        sessionID: String? = nil,
        turnID: String? = nil,
        boundaryID: String? = nil,
        lifecycleDisposition: String? = nil,
        sessionUpdate: String? = nil,
        permissionAttentionBefore: DelayedPermissionAttentionState,
        permissionAttentionAfter: DelayedPermissionAttentionState,
        timerAction: String,
        enteredMayNeedAttention: Bool,
        attentionNotificationSent: Bool
    ) {
        self.loggedAt = loggedAt
        self.source = source
        self.lifecycleEvent = lifecycleEvent
        self.eventObservedAt = eventObservedAt
        self.sessionID = sessionID
        self.turnID = turnID
        self.boundaryID = boundaryID
        self.lifecycleDisposition = lifecycleDisposition
        self.sessionUpdate = sessionUpdate
        self.permissionAttentionBefore = String(describing: permissionAttentionBefore)
        self.permissionAttentionAfter = String(describing: permissionAttentionAfter)
        self.timerAction = timerAction
        self.enteredMayNeedAttention = enteredMayNeedAttention
        self.attentionNotificationSent = attentionNotificationSent
    }
}

/// Best-effort JSON-lines recorder. Diagnostics are local and must never affect
/// lifecycle handling, delayed attention, or notification delivery.
public final class LifecycleDiagnosticRecorder: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = LifecycleDiagnosticRecorder.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Inbetween", isDirectory: true)
            .appendingPathComponent("lifecycle-diagnostics.jsonl", isDirectory: false)
    }

    public func record(_ entry: LifecycleDiagnosticEntry) {
        guard var data = try? encodedLine(entry) else { return }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(
                    atPath: fileURL.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Diagnostics are intentionally non-fatal.
        }
    }

    private func encodedLine(_ entry: LifecycleDiagnosticEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(entry)
    }
}

public extension PermissionBoundaryID {
    var diagnosticIdentifier: String {
        "\(sessionID)/\(turnID)/\(String(format: "%.3f", observedAt))"
    }
}
