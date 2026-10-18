import Foundation
import InbetweenCore

let arguments = CommandLine.arguments
if arguments.contains("--migrate-synthetic-tv-to-steam") {
    guard arguments.contains("--confirm") else {
        FileHandle.standardError.write(Data("TV-to-Steam migration requires --confirm.\n".utf8))
        exit(2)
    }
    do {
        let result = try DemoHistorySeeder(store: WaitSessionStore()).migrateSyntheticTVToSteam(
            confirmed: true
        )
        print("Migrated and verified \(result.migratedSessionCount) synthetic TV sessions.")
        print("Verified backup: \(result.backupURL.path)")
    } catch {
        FileHandle.standardError.write(Data("Demo migration failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

guard let referenceIndex = arguments.firstIndex(of: "--reference-date"),
      arguments.indices.contains(referenceIndex + 1),
      arguments.contains("--confirm")
else {
    FileHandle.standardError.write(Data("Usage: inbetween-demo-history-seeder --reference-date YYYY-MM-DD --confirm | --migrate-synthetic-tv-to-steam --confirm\n".utf8))
    exit(2)
}

let formatter = DateFormatter()
formatter.locale = Locale(identifier: "en_US_POSIX")
formatter.calendar = Calendar(identifier: .gregorian)
formatter.timeZone = .current
formatter.dateFormat = "yyyy-MM-dd"

guard let referenceDate = formatter.date(from: arguments[referenceIndex + 1]) else {
    FileHandle.standardError.write(Data("Invalid --reference-date. Use YYYY-MM-DD.\n".utf8))
    exit(2)
}

do {
    let result = try DemoHistorySeeder(store: WaitSessionStore()).seed(
        referenceDate: referenceDate,
        confirmed: true
    )
    print("Added \(result.insertedSessionCount) demo sessions; preserved \(result.preservedSessionCount).")
    print("Backup: \(result.backupURL.path)")
} catch {
    FileHandle.standardError.write(Data("Demo seeding failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
