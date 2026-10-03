import Foundation

public struct WaitSessionStore {
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([WaitSession].self, from: data)
    }

    public func save(_ sessions: [WaitSession]) throws {
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
