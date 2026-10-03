import Foundation
import Testing
@testable import InbetweenCore

struct DemoHistorySeederTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Manila")!
        return value
    }

    @Test func mergesOnlySaturdayThroughMondayAndPreservesEveryRealSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-seed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("wait-sessions.json"))
        let saturdayReal = realSession(id: "10000000-0000-0000-0000-000000000001", date: date("2026-09-26 07:00"))
        let fridayReal = realSession(id: "10000000-0000-0000-0000-000000000002", date: date("2026-09-25 07:00"))
        let tuesdayReal = realSession(id: "10000000-0000-0000-0000-000000000003", date: date("2026-09-29 07:00"))
        let futureReal = realSession(id: "10000000-0000-0000-0000-000000000004", date: date("2026-09-30 07:00"))
        let protectedTaggedTuesday = WaitSession(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            codexSessionID: "protected-tagged", codexTurnID: "tuesday",
            startTime: date("2026-09-29 08:00"), endTime: date("2026-09-29 08:01"),
            duration: 60, state: .completed,
            syntheticDataSetID: DemoHistorySeeder.dataSetID
        )
        try store.save([saturdayReal, fridayReal, tuesdayReal, futureReal, protectedTaggedTuesday])
        let seeder = DemoHistorySeeder(store: store, calendar: calendar, now: { self.date("2026-09-29 12:00") })

        let result = try seeder.seed(referenceDate: date("2026-09-29 09:00"), confirmed: true)
        let loaded = try store.load()
        let referenceDay = calendar.startOfDay(for: date("2026-09-29 09:00"))
        let synthetic = loaded.filter {
            $0.syntheticDataSetID == DemoHistorySeeder.dataSetID
                && calendar.startOfDay(for: $0.endTime!) < referenceDay
        }

        #expect(FileManager.default.fileExists(atPath: result.backupURL.path))
        #expect(Set(loaded.filter { $0.syntheticDataSetID == nil }.map(\.id)) == Set([saturdayReal.id, fridayReal.id, tuesdayReal.id, futureReal.id]))
        #expect(loaded.first { $0.id == protectedTaggedTuesday.id } == protectedTaggedTuesday)
        #expect(Set(synthetic.map { dayString($0.endTime!) }) == ["2026-09-26", "2026-09-27", "2026-09-28"])
        #expect(synthetic.allSatisfy { calendar.startOfDay(for: $0.endTime!) < referenceDay })

        let totals = Dictionary(grouping: synthetic, by: { dayString($0.endTime!) }).mapValues { $0.reduce(0) { $0 + ($1.duration ?? 0) } }
        #expect(totals["2026-09-26"] == 2_535)
        #expect(totals["2026-09-27"] == 1_900)
        #expect(totals["2026-09-28"] == 3_250)
        #expect(totals.values.allSatisfy { $0 < 3_600 })
        #expect(synthetic.flatMap { $0.activityClassificationSlices ?? [] }.filter { $0.effectiveClassification == .unclassified }.allSatisfy { $0.classificationReviewHandled })
    }

    @Test func rerunReplacesOnlyOwnDeterministicRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-seed-idempotent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("wait-sessions.json"))
        let real = realSession(id: "20000000-0000-0000-0000-000000000001", date: date("2026-09-28 06:00"))
        try store.save([real])
        let seeder = DemoHistorySeeder(store: store, calendar: calendar, now: { self.date() })
        _ = try seeder.seed(referenceDate: date("2026-09-29 00:00"), confirmed: true)
        let first = try store.load()
        _ = try seeder.seed(referenceDate: date("2026-09-29 00:00"), confirmed: true)
        let second = try store.load()
        #expect(first == second)
        #expect(second.filter { $0.id == real.id } == [real])
    }

    @Test func requiresExplicitConfirmation() throws {
        let store = WaitSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        #expect(throws: DemoHistorySeederError.confirmationRequired) {
            try DemoHistorySeeder(store: store, calendar: calendar).seed(referenceDate: date("2026-09-29 00:00"), confirmed: false)
        }
    }

    private func realSession(id: String, date: Date) -> WaitSession {
        WaitSession(id: UUID(uuidString: id)!, codexSessionID: "real", codexTurnID: id, startTime: date, endTime: date.addingTimeInterval(60), duration: 60, state: .completed)
    }

    private func date(_ value: String = "2026-09-29 12:00") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
