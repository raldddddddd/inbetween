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

        let steamSessions = synthetic.filter {
            $0.activitySegments.contains { $0.context.applicationBundleIdentifier == "com.valvesoftware.steam" }
        }
        #expect(loaded.count == 15)
        #expect(synthetic.count == 10)
        #expect(steamSessions.count == 2)
        #expect(synthetic.allSatisfy { $0.syntheticDataSetID == DemoHistorySeeder.dataSetID && $0.hookSource == "inbetween-demo-seeder" })
        #expect(synthetic.allSatisfy { $0.recordOrigin == .synthetic })
        #expect(synthetic.flatMap(\.activitySegments).allSatisfy {
            $0.context.provenance.applicationIdentity == .syntheticDemo
        })
        #expect(synthetic.allSatisfy { !$0.activitySegments.contains { $0.context.applicationBundleIdentifier == "com.apple.TV" } })
        #expect(steamSessions.allSatisfy { $0.automaticClassification == .distracted })
        #expect(steamSessions.flatMap { $0.activityClassificationSlices ?? [] }.allSatisfy { $0.automaticClassification == .distracted })
        #expect(steamSessions.allSatisfy { $0.activitySegments.first?.context.applicationCategoryIdentifier == nil })
        #expect(Set(steamSessions.map { $0.duration ?? 0 }) == [540, 395])
        #expect(steamSessions.allSatisfy { session in
            guard let context = session.activitySegments.first?.context else { return false }
            return WaitSessionClassifier().classify(context: context).classification == .distracted
        })
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

    @Test func replacesOnlyTaggedTVSeedsAndPreservesTimelineAndManualOverrides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-seed-tv-migration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("wait-sessions.json"))
        let seeder = DemoHistorySeeder(store: store, calendar: calendar, now: { self.date("2026-09-29 12:00") })
        let generated = try seeder.makeSessions(referenceDay: calendar.startOfDay(for: date("2026-09-29 00:00")))

        let legacyTV = generated.filter { $0.activitySegments.first?.context.applicationBundleIdentifier == "com.valvesoftware.steam" }.map { session in
            makeLegacyTV(session)
        }
        let otherDemo = generated.first { $0.activitySegments.first?.context.applicationBundleIdentifier == "com.apple.dt.Xcode" }!
        var manuallyReviewedOtherDemo = otherDemo
        manuallyReviewedOtherDemo.manualClassificationOverride = .distracted
        var real = realSession(id: "30000000-0000-0000-0000-000000000001", date: date("2026-09-27 06:00"))
        real.manualClassificationOverride = .productive
        let seededWithLegacyTV = generated.map { session in
            legacyTV.first(where: { $0.id == session.id }) ?? (session.id == otherDemo.id ? manuallyReviewedOtherDemo : session)
        }
        try store.save(seededWithLegacyTV + [real])
        let before = try store.load()
        let oldTVByID = Dictionary(uniqueKeysWithValues: legacyTV.map { ($0.id, $0) })

        let seeded = try seeder.seed(referenceDate: date("2026-09-29 00:00"), confirmed: true)
        #expect(seeded.insertedSessionCount == 0)
        #expect(try store.load().filter { oldTVByID[$0.id] != nil } == legacyTV)
        let result = try seeder.migrateSyntheticTVToSteam(confirmed: true)
        let after = try store.load()
        let migrated = after.filter { oldTVByID[$0.id] != nil }

        #expect(FileManager.default.fileExists(atPath: result.backupURL.path))
        #expect(try WaitSessionStore(fileURL: result.backupURL).load() == before)
        #expect(result.migratedSessionCount == 2)
        #expect(after.count == before.count)
        #expect(migrated.count == 2)
        #expect(Set(migrated.map(\.id)) == Set(legacyTV.map(\.id)))
        #expect(migrated.allSatisfy { $0.syntheticDataSetID == DemoHistorySeeder.dataSetID && $0.hookSource == "inbetween-demo-seeder" })
        #expect(migrated.allSatisfy { $0.automaticClassification == .distracted })
        #expect(migrated.flatMap { $0.activitySegments }.allSatisfy { $0.context.applicationBundleIdentifier == "com.valvesoftware.steam" })
        #expect(migrated.allSatisfy { $0.activitySegments.first?.context.applicationName == "Steam" })
        #expect(migrated.allSatisfy { $0.activitySegments.first?.context.applicationCategoryIdentifier == nil })
        #expect(after.filter { $0.syntheticDataSetID == DemoHistorySeeder.dataSetID }.allSatisfy {
            !$0.activitySegments.contains { $0.context.applicationBundleIdentifier == "com.apple.TV" }
        })

        for old in legacyTV {
            let replacement = migrated.first { $0.id == old.id }!
            #expect(replacement.startTime == old.startTime)
            #expect(replacement.endTime == old.endTime)
            #expect(replacement.duration == old.duration)
            #expect(replacement.activitySegments.map(\.id) == old.activitySegments.map(\.id))
            #expect(replacement.activitySegments.map(\.startedAt) == old.activitySegments.map(\.startedAt))
            #expect(replacement.activitySegments.map(\.endedAt) == old.activitySegments.map(\.endedAt))
            #expect(replacement.activityClassificationSlices?.map(\.id) == old.activityClassificationSlices?.map(\.id))
            #expect(replacement.manualClassificationOverride == old.manualClassificationOverride)
            #expect(replacement.activityClassificationSlices?.map(\.manualClassificationOverride) == old.activityClassificationSlices?.map(\.manualClassificationOverride))
            #expect(replacement.classificationReviewHandled == old.classificationReviewHandled)
            #expect(replacement.activityClassificationSlices?.map(\.classificationReviewHandled) == old.activityClassificationSlices?.map(\.classificationReviewHandled))
        }
        #expect(after.first { $0.id == real.id } == real)
        #expect(after.first { $0.id == manuallyReviewedOtherDemo.id } == manuallyReviewedOtherDemo)

        let beforeTotals = Dictionary(grouping: before.filter { $0.syntheticDataSetID == DemoHistorySeeder.dataSetID }, by: { dayString($0.endTime!) })
            .mapValues { $0.reduce(0) { $0 + ($1.duration ?? 0) } }
        let afterTotals = Dictionary(grouping: after.filter { $0.syntheticDataSetID == DemoHistorySeeder.dataSetID }, by: { dayString($0.endTime!) })
            .mapValues { $0.reduce(0) { $0 + ($1.duration ?? 0) } }
        #expect(afterTotals == beforeTotals)
        #expect(afterTotals == ["2026-09-26": 2_535, "2026-09-27": 1_900, "2026-09-28": 3_250])

        let migratedSnapshot = after
        let secondMigration = try seeder.migrateSyntheticTVToSteam(confirmed: true)
        #expect(secondMigration.migratedSessionCount == 0)
        #expect(try store.load() == migratedSnapshot)
    }

    @Test func failedPostWriteMigrationVerificationDoesNotRestoreOriginalSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-seed-tv-migration-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("wait-sessions.json"))
        let seeder = DemoHistorySeeder(store: store, calendar: calendar, now: { self.date("2026-09-29 12:00") })
        let generated = try seeder.makeSessions(referenceDay: calendar.startOfDay(for: date("2026-09-29 00:00")))
        let tvRecords = generated
            .filter { $0.activitySegments.first?.context.applicationBundleIdentifier == "com.valvesoftware.steam" }
            .map(makeLegacyTV)
        var real = realSession(id: "40000000-0000-0000-0000-000000000001", date: date("2026-09-27 06:00"))
        real.manualClassificationOverride = .productive
        let before = tvRecords + [real]
        try store.save(before)

        var postWriteValidationWasCalled = false
        #expect(throws: DemoHistorySeederError.migrationVerificationFailed) {
            try seeder.migrateSyntheticTVToSteam(confirmed: true) { original, expected, actual in
                postWriteValidationWasCalled = true
                #expect(original == before)
                #expect(actual == expected)
                return false
            }
        }

        let persisted = try store.load()
        let targetIDs = Set(tvRecords.map(\.id))
        let persistedTargets = persisted.filter { targetIDs.contains($0.id) }
        #expect(postWriteValidationWasCalled)
        #expect(persisted.count == before.count)
        #expect(persisted != before)
        #expect(Set(persisted.map(\.id)) == Set(before.map(\.id)))
        #expect(persisted.first { $0.id == real.id } == real)
        #expect(persistedTargets.count == tvRecords.count)
        #expect(persistedTargets.allSatisfy { $0.automaticClassification == .distracted })
        #expect(persistedTargets.allSatisfy { $0.manualClassificationOverride == .productive })
        #expect(persistedTargets.flatMap(\.activitySegments).allSatisfy {
            $0.context.applicationBundleIdentifier == "com.valvesoftware.steam"
        })
        #expect(persisted.allSatisfy {
            !$0.activitySegments.contains { $0.context.applicationBundleIdentifier == "com.apple.TV" }
        })
    }

    @Test func requiresExplicitConfirmation() throws {
        let store = WaitSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID()).json"))
        #expect(throws: DemoHistorySeederError.confirmationRequired) {
            try DemoHistorySeeder(store: store, calendar: calendar).seed(referenceDate: date("2026-09-29 00:00"), confirmed: false)
        }
        #expect(throws: DemoHistorySeederError.confirmationRequired) {
            try DemoHistorySeeder(store: store, calendar: calendar).migrateSyntheticTVToSteam(confirmed: false)
        }
    }

    private func realSession(id: String, date: Date) -> WaitSession {
        WaitSession(id: UUID(uuidString: id)!, codexSessionID: "real", codexTurnID: id, startTime: date, endTime: date.addingTimeInterval(60), duration: 60, state: .completed)
    }

    private func makeLegacyTV(_ session: WaitSession) -> WaitSession {
        var legacy = session
        let legacyContext = ActivityContext(
            applicationBundleIdentifier: "com.apple.TV",
            applicationName: "TV",
            applicationCategoryIdentifier: "public.app-category.entertainment",
            windowTitle: "Continue Watching",
            presenceState: .active
        )!
        legacy.activitySegments = session.activitySegments.map { segment in
            ActivitySegment(
                id: segment.id,
                waitSessionID: segment.waitSessionID,
                context: legacyContext,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                duration: segment.duration,
                lastObservedAt: segment.lastObservedAt
            )
        }
        legacy.manualClassificationOverride = .productive
        if let slices = legacy.activityClassificationSlices {
            legacy.activityClassificationSlices = slices.map { slice in
                ActivityClassificationSlice(
                    id: slice.id,
                    sourceActivitySegmentID: slice.sourceActivitySegmentID,
                    startedAt: slice.startedAt,
                    endedAt: slice.endedAt,
                    duration: slice.duration,
                    automaticClassificationResult: slice.automaticClassificationResult,
                    manualClassificationOverride: .unclassified,
                    classificationReviewHandled: true
                )
            }
        }
        legacy.classificationReviewHandled = true
        return legacy
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
