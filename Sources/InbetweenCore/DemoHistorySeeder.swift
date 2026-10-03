import Foundation

public enum DemoHistorySeederError: Error, Equatable, LocalizedError {
    case confirmationRequired
    case invalidReferenceDate
    case generatedOnOrAfterReferenceDate

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            "Demo history requires the explicit confirmation flag."
        case .invalidReferenceDate:
            "The reference date could not be resolved in the supplied calendar."
        case .generatedOnOrAfterReferenceDate:
            "Demo history may only be generated before the reference date."
        }
    }
}

public struct DemoHistorySeedResult: Equatable, Sendable {
    public let backupURL: URL
    public let insertedSessionCount: Int
    public let preservedSessionCount: Int
}

/// Explicit development utility for deterministic screenshots and demos.
/// It never runs from the app and can only replace records carrying its own provenance marker.
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
        let targetDays = Set(generated.map {
            calendar.startOfDay(for: WaitPresentationSupport.completionDate(for: $0))
        })
        let preserved = existing.filter { session in
            session.syntheticDataSetID != Self.dataSetID
                || !targetDays.contains(calendar.startOfDay(
                    for: WaitPresentationSupport.completionDate(for: session)
                ))
        }
        let backupURL = try store.createTimestampedBackup(of: existing, at: now())
        try store.save((preserved + generated).sorted { $0.startTime < $1.startTime })
        return DemoHistorySeedResult(
            backupURL: backupURL,
            insertedSessionCount: generated.count,
            preservedSessionCount: preserved.count
        )
    }

    public func makeSessions(referenceDay: Date) throws -> [WaitSession] {
        let plans: [(offset: Int, starts: [Int], durations: [Int], kinds: [Kind])] = [
            (-3, [9 * 3600 + 12 * 60, 13 * 3600 + 8 * 60, 16 * 3600 + 21 * 60], [945, 1_050, 540], [.development, .documentation, .entertainment]),
            (-2, [10 * 3600 + 4 * 60, 14 * 3600 + 36 * 60, 19 * 3600 + 10 * 60], [700, 805, 395], [.documentation, .ambiguous, .entertainment]),
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

    private enum Kind { case development, documentation, entertainment, ambiguous }

    private func makeSession(index: Int, start: Date, duration: TimeInterval, kind: Kind) throws -> WaitSession {
        let sessionID = deterministicUUID(index: index, family: 1)
        let segmentID = deterministicUUID(index: index, family: 2)
        let sliceID = deterministicUUID(index: index, family: 3)
        let context: ActivityContext
        let classification: WaitSessionClassification
        let reason: WaitSessionClassificationReason
        switch kind {
        case .development:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.dt.Xcode", applicationName: "Xcode", applicationCategoryIdentifier: "public.app-category.developer-tools", windowTitle: "Inbetween · Reflection", resourceKind: .workspace, resourceName: "Inbetween", presenceState: .active)!
            classification = .productive
            reason = .productiveApplicationCategory
        case .documentation:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "SwiftUI documentation", browserDomain: "developer.apple.com", browserPageTitle: "SwiftUI documentation", presenceState: .active)!
            classification = .productive
            reason = .sustainedProductiveContext
        case .entertainment:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.TV", applicationName: "TV", applicationCategoryIdentifier: "public.app-category.entertainment", windowTitle: "Continue Watching", presenceState: .active)!
            classification = .distracted
            reason = .distractingApplicationCategory
        case .ambiguous:
            context = ActivityContext(applicationBundleIdentifier: "com.apple.Notes", applicationName: "Notes", windowTitle: "Weekend ideas", presenceState: index.isMultiple(of: 2) ? .idle : .away)!
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
            syntheticDataSetID: Self.dataSetID
        )
    }

    private func deterministicUUID(index: Int, family: Int) -> UUID {
        UUID(uuidString: String(format: "d3e00000-0000-4000-8%03x-%012x", family, index))!
    }
}
