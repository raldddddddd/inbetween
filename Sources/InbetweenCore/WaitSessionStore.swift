import Foundation
import Darwin

public enum WaitSessionStoreError: Error, Equatable, LocalizedError {
    case staleSnapshot

    public var errorDescription: String? {
        switch self {
        case .staleSnapshot:
            "Saved history changed since it was loaded. The newer store was preserved; restart Inbetween to load it before saving again."
        }
    }
}

public struct WaitSessionStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Inbetween", isDirectory: true)
            .appendingPathComponent("wait-sessions.json", isDirectory: false)
    }

    public func load() throws -> [WaitSession] {
        try loadFromDisk()
    }

    /// Unconditionally writes a complete snapshot. Keep this internal for
    /// isolated fixtures and new backup files; production history updates must
    /// use the compare-and-save overload below.
    func save(_ sessions: [WaitSession]) throws {
        try withExclusiveWriteLock {
            try writeToDisk(sessions)
        }
    }

    /// Saves only when the on-disk snapshot still matches the caller's base.
    /// The sidecar lock keeps the compare and atomic replacement together for
    /// all cooperating Inbetween writers.
    public func save(_ sessions: [WaitSession], expecting expectedSessions: [WaitSession]) throws {
        try withExclusiveWriteLock {
            let current = try loadFromDisk()
            guard current == expectedSessions else {
                throw WaitSessionStoreError.staleSnapshot
            }
            try writeToDisk(sessions)
        }
    }

    private func loadFromDisk() throws -> [WaitSession] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([WaitSession].self, from: data)
    }

    private func writeToDisk(_ sessions: [WaitSession]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private func withExclusiveWriteLock<T>(_ operation: () throws -> T) throws -> T {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    public func createTimestampedBackup(
        of sessions: [WaitSession],
        at date: Date = .now
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = "backup-\(formatter.string(from: date))"
        var backupURL = fileURL.deletingPathExtension().appendingPathExtension("\(stem).json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = fileURL.deletingPathExtension()
                .appendingPathExtension("\(stem)-\(suffix).json")
            suffix += 1
        }
        let backupStore = WaitSessionStore(fileURL: backupURL)
        try backupStore.save(sessions)
        return backupURL
    }
}
