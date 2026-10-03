import Foundation
import InbetweenCore

let arguments = CommandLine.arguments
guard let referenceIndex = arguments.firstIndex(of: "--reference-date"),
      arguments.indices.contains(referenceIndex + 1),
      arguments.contains("--confirm")
else {
    FileHandle.standardError.write(Data("Usage: inbetween-demo-history-seeder --reference-date YYYY-MM-DD --confirm\n".utf8))
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
