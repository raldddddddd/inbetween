import Foundation

public enum DemoHistorySeederError: Error, Equatable, LocalizedError {
    case confirmationRequired
    case invalidReferenceDate
    case generatedOnOrAfterReferenceDate
    case migrationVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Demo history requires the explicit confirmation flag."
        case .invalidReferenceDate:
            "The reference date could not be resolved in the supplied calendar."
        case .generatedOnOrAfterReferenceDate:
            "Demo history may only be generated before the reference date."
        case .migrationVerificationFailed:
            "The synthetic Steam migration could not be verified. No automatic rollback was performed."
        }
    }
}

public struct DemoHistorySeedResult: Equatable, Sendable {
    public let backupURL: URL
    public let insertedSessionCount: Int
    public let preservedSessionCount: Int
}

public struct DemoHistoryMigrationResult: Equatable, Sendable {
    public let backupURL: URL
    public let migratedSessionCount: Int
}

/// Explicit development utility for deterministic screenshots and demos.
/// It never runs from the app; migrations are limited to exact dataset-owned identities.
public struct DemoHistorySeeder {
    public static let dataSetID = "inbetween-demo-history-2026-09-v1"

    private let store: WaitSessionStore
    private let calendar: Calendar
    private let now: () -> Date

    public init(
        store: WaitSessionStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    @discardableResult
    public func seed(referenceDate: Date, confirmed: Bool) throws -> DemoHistorySeedResult {
        guard confirmed else { throw DemoHistorySeederError.confirmationRequired }
        guard let referenceDay = calendar.dateInterval(of: .day, for: referenceDate)?.start else {
            throw DemoHistorySeederError.invalidReferenceDate
        }
        let generated = try makeSessions(referenceDay: referenceDay)
        guard generated.allSatisfy({
            calendar.startOfDay(for: WaitPresentationSupport.completionDate(for: $0)) < referenceDay
        }) else {
            throw DemoHistorySeederError.generatedOnOrAfterReferenceDate
        }

        let existing = try store.load()
        let existingIDs = Set(existing.map(\.id))
        let inserted = generated.filter { !existingIDs.contains($0.id) }
        let backupURL = try store.createTimestampedBackup(of: existing, at: now())
        try store.save(existing + inserted, expecting: existing)
        return DemoHistorySeedResult(
            backupURL: backupURL,
            insertedSessionCount: inserted.count,
            preservedSessionCount: existing.count
        )
    }

    /// Explicitly migrates only the two deterministic TV demo records.
    /// This is separate from normal seeding and never runs during app startup.
    @discardableResult
    public func migrateSyntheticTVToSteam(confirmed: Bool) throws -> DemoHistoryMigrationResult {
        try migrateSyntheticTVToSteam(confirmed: confirmed, postWriteValidation: { _, _, _ in true })
    }

    /// Internal validation seam lets tests exercise a failed post-write check
    /// without touching the user's store or relying on a filesystem race.
    @discardableResult
    func migrateSyntheticTVToSteam(
        confirmed: Bool,
        postWriteValidation: (_ original: [WaitSession], _ expected: [WaitSession], _ actual: [WaitSession]) -> Bool
    ) throws -> DemoHistoryMigrationResult {
        guard confirmed else { throw DemoHistorySeederError.confirmationRequired }
        let existing = try store.load()
        let templates = try makeSessions(referenceDay: calendar.startOfDay(for: now())).filter {
            $0.activitySegments.contains {
                $0.context.applicationBundleIdentifier == "com.valvesoftware.steam"
            }
        }
        let templatesByID = Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
        let candidates = existing.filter { session in
            session.syntheticDataSetID == Self.dataSetID
                && session.hookSource == "inbetween-demo-seeder"
                && templatesByID[session.id] != nil
                && session.activitySegments.contains {
                    $0.context.applicationBundleIdentifier == "com.apple.TV"
                }
        }
        guard Set(candidates.map(\.id)).count == candidates.count else {
            throw DemoHistorySeederError.migrationVerificationFailed
        }
        let migratedByID = Dictionary(uniqueKeysWithValues: candidates.compactMap { session -> (UUID, WaitSession)? in
            guard let template = templatesByID[session.id] else { return nil }
            return (session.id, replacingSyntheticTVActivity(in: session, with: template))
        })
        guard migratedByID.count == candidates.count else {
            throw DemoHistorySeederError.migrationVerificationFailed
        }
        let expected = existing.map { migratedByID[$0.id] ?? $0 }
        let backupURL = try store.createTimestampedBackup(of: existing, at: now())
        guard try WaitSessionStore(fileURL: backupURL).load() == existing else {
            throw DemoHistorySeederError.migrationVerificationFailed
        }

        try store.save(expected, expecting: existing)
        let actual = try store.load()
        guard actual == expected,
              actual.count == existing.count,
              postWriteValidation(existing, expected, actual),
              candidates.allSatisfy({ original in
                  guard let updated = actual.first(where: { $0.id == original.id }) else { return false }
                  return isVerifiedSteamReplacement(of: original, updated: updated)
              }),
              existing.filter({ migratedByID[$0.id] == nil }).allSatisfy({ original in
                  actual.first(where: { $0.id == original.id }) == original
              }) else {
            throw DemoHistorySeederError.migrationVerificationFailed
        }

        return DemoHistoryMigrationResult(
            backupURL: backupURL,
            migratedSessionCount: migratedByID.count
        )
    }

    public func makeSessions(referenceDay: Date) throws -> [WaitSession] {
        let plans: [(offset: Int, starts: [Int], durations: [Int], kinds: [Kind])] = [
            (-3, [9 * 3600 + 12 * 60, 13 * 3600 + 8 * 60, 16 * 3600 + 21 * 60], [945, 1_050, 540], [.development, .documentation, .steam]),
            (-2, [10 * 3600 + 4 * 60, 14 * 3600 + 36 * 60, 19 * 3600 + 10 * 60], [700, 805, 395], [.documentation, .ambiguous, .steam]),
            (-1, [8 * 3600 + 48 * 60, 12 * 3600 + 42 * 60, 17 * 3600 + 5 * 60, 20 * 3600 + 14 * 60], [1_080, 730, 960, 480], [.development, .documentation, .development, .ambiguous])
        ]
        var sequence = 1
        return try plans.flatMap { plan -> [WaitSession] in
            guard let day = calendar.date(byAdding: .day, value: plan.offset, to: referenceDay) else {
                throw DemoHistorySeederError.invalidReferenceDate
            }
            return try zip(zip(plan.starts, plan.durations), plan.kinds).map { pair, kind in
                defer { sequence += 1 }
                let start = day.addingTimeInterval(TimeInterval(pair.0))
                return try makeSession(index: sequence, start: start, duration: TimeInterval(pair.1), kind: kind)
            }
        }
    }

    private enum Kind { case development, documentation, steam, ambiguous }

    private func makeSession(index: Int, start: Date, duration: TimeInterval, kind: Kind) throws -> WaitSession {
        let sessionID = deterministicUUID(index: index, family: 1)
        let segmentID = deterministicUUID(index: index, family: 2)
        let sliceID = deterministicUUID(index: index, family: 3)
        let context: ActivityContext
        let classification: WaitSessionClassification
        let reason: WaitSessionClassificationReason
        switch kind {
        case .development:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode", applicationCategoryIdentifier: "public.app-category.developer-tools", windowTitle: "Inbetween · Reflection", resourceKind: .workspace, resourceName: "Inbetween", presenceState: .active, provenance: .syntheticDemo)!
            classification = .productive
            reason = .productiveApplicationCategory
        case .documentation:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "SwiftUI documentation", browserDomain: "developer.apple.com", browserPageTitle: "SwiftUI documentation", presenceState: .active, provenance: .syntheticDemo)!
            classification = .productive
            reason = .sustainedProductiveContext
        case .steam:
            context = ActivityContext(applicationBundleIdentifier: "com.valvesoftware.steam", applicationName: "Steam", presenceState: .active, provenance: .syntheticDemo)!
            classification = .distracted
            reason = .sustainedDistractingApplication
        case .ambiguous:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.Notes", applicationName: "Notes", windowTitle: "Weekend ideas", presenceState: index.isMultiple(of: 2) ? .idle : .away, provenance: .syntheticDemo)!
            classification = .unclassified
            reason = .meaningfulInactiveTime
        }
        let end = start.addingTimeInterval(duration)
        let segment = ActivitySegment(id: segmentID, waitSessionID: sessionID, context: context, startedAt: start, endedAt: end, duration: duration)
        let result = WaitSessionClassificationResult(classification: classification, reasonCodes: [reason], explanation: "Deterministic synthetic demo activity.", reviewSuggested: classification == .unclassified)
        let slice = ActivityClassificationSlice(id: sliceID, sourceActivitySegmentID: segmentID, startedAt: start, endedAt: end, duration: duration, automaticClassificationResult: result, classificationReviewHandled: classification == .unclassified)
        return WaitSession(
            id: sessionID,
            codexSessionID: "demo-session-\(index)",
            codexTurnID: "demo-turn-\(index)",
            startTime: start,
            endTime: end,
            duration: duration,
            state: .completed,
            hookSource: "inbetween-demo-seeder",
            activitySegments: [segment],
            classificationResult: result,
            activityClassificationSlices: [slice],
            classificationReviewHandled: classification == .unclassified,
            syntheticDataSetID: Self.dataSetID,
            recordOrigin: .synthetic
        )
    }

    private func replacingSyntheticTVActivity(
        in existing: WaitSession,
        with generated: WaitSession
    ) -> WaitSession {
        guard let replacementSegment = generated.activitySegments.first else { return existing }
        var updated = existing
        let replacedSegmentIDs = Set(existing.activitySegments.compactMap { segment -> UUID? in
            segment.context.applicationBundleIdentifier == "com.apple.TV" ? segment.id : nil
        })
        updated.activitySegments = existing.activitySegments.map { segment in
            guard replacedSegmentIDs.contains(segment.id) else { return segment }
            return ActivitySegment(
                id: segment.id,
                waitSessionID: segment.waitSessionID,
                context: replacementSegment.context,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt,
                duration: segment.duration,
                lastObservedAt: segment.lastObservedAt
            )
        }
        updated.classificationResult = generated.classificationResult
        if let slices = existing.activityClassificationSlices,
           let replacementResult = generated.activityClassificationSlices?.first?.automaticClassificationResult {
            updated.activityClassificationSlices = slices.map { slice in
                guard let sourceID = slice.sourceActivitySegmentID,
                      replacedSegmentIDs.contains(sourceID) else { return slice }
                return ActivityClassificationSlice(
                    id: slice.id,
                    sourceActivitySegmentID: slice.sourceActivitySegmentID,
                    startedAt: slice.startedAt,
                    endedAt: slice.endedAt,
                    duration: slice.duration,
                    automaticClassificationResult: replacementResult,
                    manualClassificationOverride: slice.manualClassificationOverride,
                    classificationReviewHandled: slice.classificationReviewHandled
                )
            }
        }
        return updated
    }

    private func isVerifiedSteamReplacement(of original: WaitSession, updated: WaitSession) -> Bool {
        guard original.id == updated.id,
              original.syntheticDataSetID == updated.syntheticDataSetID,
              original.hookSource == updated.hookSource,
              original.startTime == updated.startTime,
              original.endTime == updated.endTime,
              original.duration == updated.duration,
              original.manualClassificationOverride == updated.manualClassificationOverride,
              updated.automaticClassification == .distracted,
              original.activitySegments.count == updated.activitySegments.count,
              original.activityClassificationSlices?.count == updated.activityClassificationSlices?.count
        else { return false }

        let segmentPairs = zip(original.activitySegments, updated.activitySegments)
        guard segmentPairs.allSatisfy({ before, after in
            before.id == after.id
                && before.startedAt == after.startedAt
                && before.endedAt == after.endedAt
                && before.duration == after.duration
                && (before.context.applicationBundleIdentifier == "com.apple.TV"
                    ? after.context.applicationBundleIdentifier == "com.valvesoftware.steam"
                    : before == after)
        }) else { return false }
        return original.activitySegments.contains {
            $0.context.applicationBundleIdentifier == "com.apple.TV"
        } && updated.activitySegments.contains {
            $0.context.applicationBundleIdentifier == "com.valvesoftware.steam"
        } && (updated.activityClassificationSlices ?? []).allSatisfy {
            $0.automaticClassification == .distracted
        }
    }

    private func deterministicUUID(index: Int, family: Int) -> UUID {
        UUID(uuidString: String(format: "d3e00000-0000-4000-8%03x-%012x", family, index))!
    }
}
