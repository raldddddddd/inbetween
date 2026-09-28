import Foundation

public enum StopLatencyStage: String, Codable, Sendable {
    case appReceived = "app_received"
    case waitSessionCompleted = "wait_session_completed"
    case notificationAddStarted = "notification_add_started"
    case notificationAddCompleted = "notification_add_completed"
    case notificationAddFailed = "notification_add_failed"
    case notificationWillPresent = "notification_will_present"
    case notificationObserved = "notification_observed"
}

public final class StopLatencyRecorder: @unchecked Sendable {
    public static let defaultFileURL = URL(
        fileURLWithPath: "/tmp/inbetween-stop-latency.jsonl",
        isDirectory: false
    )

    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = StopLatencyRecorder.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func record(
        _ stage: StopLatencyStage,
        sessionID: String,
        turnID: String,
        wallTime: TimeInterval = Date().timeIntervalSince1970,
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        outcome: String? = nil,
        delivered: Bool? = nil,
        pending: Bool? = nil
    ) {
        let entry = Entry(
            stage: stage,
            wallTime: wallTime,
            monotonicNanoseconds: monotonicNanoseconds,
            sessionID: sessionID,
            turnID: turnID,
            outcome: outcome,
            delivered: delivered,
            pending: pending
        )
        guard let data = try? encodedLine(entry) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            let fileManager = FileManager.default
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
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Diagnostics must never affect lifecycle handling or notifications.
        }
    }

    private func encodedLine(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    private struct Entry: Codable {
        let stage: StopLatencyStage
        let wallTime: TimeInterval
        let monotonicNanoseconds: UInt64
        let sessionID: String
        let turnID: String
        let outcome: String?
        let delivered: Bool?
        let pending: Bool?
    }
}
