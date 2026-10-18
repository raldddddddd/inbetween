import Foundation

/// Derived, local-only summaries of completed wait sessions.
///
/// This type intentionally does not persist analytics. It summarizes the same
/// wait-session history that is already stored by `WaitSessionStore`.
public struct WaitHistoryInsights: Equatable, Sendable {
    public struct ClassificationDurations: Equatable, Sendable {
        public var productive: TimeInterval = 0
        public var distracted: TimeInterval = 0
        public var unclassified: TimeInterval = 0
        public var notRecorded: TimeInterval = 0

        public var total: TimeInterval {
            productive + distracted + unclassified + notRecorded
        }

        public var nonzeroClassificationCount: Int {
            [productive, distracted, unclassified].filter { $0 > 0 }.count
        }

        public init(
            productive: TimeInterval = 0,
            distracted: TimeInterval = 0,
            unclassified: TimeInterval = 0,
            notRecorded: TimeInterval = 0
        ) {
            self.productive = productive
            self.distracted = distracted
            self.unclassified = unclassified
            self.notRecorded = notRecorded
        }
    }
    public struct Summary: Equatable, Sendable {
        public let completedSessionCount: Int
        public let totalCompletedDuration: TimeInterval
        public let productiveDuration: TimeInterval
        public let distractedDuration: TimeInterval
        public let unclassifiedDuration: TimeInterval
        public let notRecordedDuration: TimeInterval

        public init(
            completedSessionCount: Int,
            totalCompletedDuration: TimeInterval,
            productiveDuration: TimeInterval,
            distractedDuration: TimeInterval,
            unclassifiedDuration: TimeInterval,
            notRecordedDuration: TimeInterval
        ) {
            self.completedSessionCount = completedSessionCount
            self.totalCompletedDuration = totalCompletedDuration
            self.productiveDuration = productiveDuration
            self.distractedDuration = distractedDuration
            self.unclassifiedDuration = unclassifiedDuration
            self.notRecordedDuration = notRecordedDuration
        }
    }

    public struct Period: Identifiable, Equatable, Sendable {
        public let startDate: Date
        public let endDate: Date
        public let summary: Summary

        public var id: Date { startDate }

        public init(startDate: Date, endDate: Date, summary: Summary) {
            self.startDate = startDate
            self.endDate = endDate
            self.summary = summary
        }
    }

    public let summary: Summary
    public let recentDays: [Period]
    public let recentWeeks: [Period]

    /// Seven consecutive day buckets in chronological order for a time-series view.
    /// `recentDays` remains newest first for textual lists.
    public var lastSevenDays: [Period] {
        Array(recentDays.prefix(7).reversed())
    }

    public var lastSevenDaysSummary: Summary {
        lastSevenDays.reduce(
            Summary(
                completedSessionCount: 0,
                totalCompletedDuration: 0,
                productiveDuration: 0,
                distractedDuration: 0,
                unclassifiedDuration: 0,
                notRecordedDuration: 0
            )
        ) { partial, period in
            Summary(
                completedSessionCount: partial.completedSessionCount + period.summary.completedSessionCount,
                totalCompletedDuration: partial.totalCompletedDuration + period.summary.totalCompletedDuration,
                productiveDuration: partial.productiveDuration + period.summary.productiveDuration,
                distractedDuration: partial.distractedDuration + period.summary.distractedDuration,
                unclassifiedDuration: partial.unclassifiedDuration + period.summary.unclassifiedDuration,
                notRecordedDuration: partial.notRecordedDuration + period.summary.notRecordedDuration
            )
        }
    }

    public init(
        sessions: [WaitSession],
        referenceDate: Date = .now,
        calendar: Calendar = .current,
        recentDayCount: Int = 7,
        recentWeekCount: Int = 4
    ) {
        let completed = sessions.filter { $0.state == .completed }
        summary = Self.makeSummary(from: completed)
        recentDays = Self.makePeriods(
            from: completed,
            referenceDate: referenceDate,
            calendar: calendar,
            count: max(0, recentDayCount),
            component: .day
        )
        recentWeeks = Self.makePeriods(
            from: completed,
            referenceDate: referenceDate,
            calendar: calendar,
            count: max(0, recentWeekCount),
            component: .weekOfYear
        )
    }

    private static func makePeriods(
        from sessions: [WaitSession],
        referenceDate: Date,
        calendar: Calendar,
        count: Int,
        component: Calendar.Component
    ) -> [Period] {
        guard count > 0,
              let currentStart = calendar.dateInterval(of: component, for: referenceDate)?.start
        else {
            return []
        }

        return (0..<count).compactMap { offset in
            guard let start = calendar.date(byAdding: component, value: -offset, to: currentStart),
                  let interval = calendar.dateInterval(of: component, for: start)
            else {
                return nil
            }
            let completedInPeriod = sessions.filter { session in
                guard let completionDate = completionDate(for: session) else { return false }
                return completionDate >= interval.start && completionDate < interval.end
            }
            let overlapping = sessions.filter { overlaps($0, interval: interval) }
            return Period(
                startDate: interval.start,
                endDate: interval.end,
                summary: makeSummary(
                    from: overlapping,
                    overlapping: interval,
                    completedSessionCount: completedInPeriod.count
                )
            )
        }
    }

    private static func makeSummary(from sessions: [WaitSession]) -> Summary {
        var productive: TimeInterval = 0
        var distracted: TimeInterval = 0
        var unclassified: TimeInterval = 0
        var notRecorded: TimeInterval = 0

        for session in sessions {
            let durations = classificationDurations(for: session)
            productive += durations.productive
            distracted += durations.distracted
            unclassified += durations.unclassified
            notRecorded += durations.notRecorded
        }

        return Summary(
            completedSessionCount: sessions.count,
            totalCompletedDuration: sessions.reduce(0) { $0 + completedDuration(for: $1) },
            productiveDuration: productive,
            distractedDuration: distracted,
            unclassifiedDuration: unclassified,
            notRecordedDuration: notRecorded
        )
    }

    private static func makeSummary(
        from sessions: [WaitSession],
        overlapping interval: DateInterval,
        completedSessionCount: Int
    ) -> Summary {
        var total: TimeInterval = 0
        var productive: TimeInterval = 0
        var distracted: TimeInterval = 0
        var unclassified: TimeInterval = 0
        var notRecorded: TimeInterval = 0

        for session in sessions {
            total += overlapDuration(for: session, with: interval)
            let durations = classificationDurations(for: session, overlapping: interval)
            productive += durations.productive
            distracted += durations.distracted
            unclassified += durations.unclassified
            notRecorded += durations.notRecorded
        }

        return Summary(
            completedSessionCount: completedSessionCount,
            totalCompletedDuration: total,
            productiveDuration: productive,
            distractedDuration: distracted,
            unclassifiedDuration: unclassified,
            notRecordedDuration: notRecorded
        )
    }

    private static func overlaps(_ session: WaitSession, interval: DateInterval) -> Bool {
        let end = session.startTime.addingTimeInterval(completedDuration(for: session))
        return end > interval.start && session.startTime < interval.end
    }

    private static func overlapDuration(for session: WaitSession, with interval: DateInterval) -> TimeInterval {
        let end = session.startTime.addingTimeInterval(completedDuration(for: session))
        let start = max(session.startTime, interval.start)
        let clippedEnd = min(end, interval.end)
        return max(0, clippedEnd.timeIntervalSince(start))
    }

    private static func completionDate(for session: WaitSession) -> Date? {
        session.endTime ?? session.duration.map { session.startTime.addingTimeInterval($0) }
    }

    private static func completedDuration(for session: WaitSession) -> TimeInterval {
        max(0, session.duration ?? session.endTime?.timeIntervalSince(session.startTime) ?? 0)
    }

    /// New sessions aggregate exact effective slice durations. Legacy sessions
    /// continue to contribute their complete wait to the whole-wait result.
    public static func classificationDurations(
        for session: WaitSession
    ) -> ClassificationDurations {
        let total = completedDuration(for: session)
        guard let slices = session.activityClassificationSlices else {
            switch session.effectiveClassification {
            case .productive: return .init(productive: total)
            case .distracted: return .init(distracted: total)
            case .unclassified: return .init(unclassified: total)
            case nil: return .init(notRecorded: total)
            }
        }

        var result = ClassificationDurations()
        var remaining = total
        for slice in slices.sorted(by: {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }) where remaining > 0 {
            let duration = min(remaining, max(0, slice.duration))
            switch slice.effectiveClassification {
            case .productive: result.productive += duration
            case .distracted: result.distracted += duration
            case .unclassified: result.unclassified += duration
            }
            remaining -= duration
        }
        // Missing slice coverage has no classification record. Keep it separate
        // from observed activity instead of manufacturing an Unclassified slice.
        result.notRecorded += max(0, remaining)
        return result
    }

    /// Date-bucketed classification follows occurrence time. Legacy whole-wait
    /// decisions apply to the entire wait interval, including uncovered time;
    /// sliced records use their exact intervals and report missing coverage as
    /// Not recorded.
    public static func classificationDurations(
        for session: WaitSession,
        overlapping interval: DateInterval
    ) -> ClassificationDurations {
        let total = completedDuration(for: session)
        guard let slices = session.activityClassificationSlices else {
            let duration = overlapDuration(for: session, with: interval)
            switch session.effectiveClassification {
            case .productive: return .init(productive: duration)
            case .distracted: return .init(distracted: duration)
            case .unclassified: return .init(unclassified: duration)
            case nil: return .init(notRecorded: duration)
            }
        }

        var result = ClassificationDurations()
        var remaining = total
        var lastEnd: Date?
        func add(classification: WaitSessionClassification, start: Date, end: Date) {
            let clippedStart = max(start, interval.start)
            let clippedEnd = min(end, interval.end)
            let overlap = max(0, clippedEnd.timeIntervalSince(clippedStart))
            switch classification {
            case .productive: result.productive += overlap
            case .distracted: result.distracted += overlap
            case .unclassified: result.unclassified += overlap
            }
        }

        for slice in slices.sorted(by: {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }) where remaining > 0 {
            let allocated = min(remaining, max(0, slice.duration))
            guard allocated > 0 else { continue }
            let start = slice.startedAt
            let end = min(slice.endedAt, start.addingTimeInterval(allocated))
            if end > start {
                add(
                    classification: slice.effectiveClassification,
                    start: start,
                    end: end
                )
                lastEnd = end
            }
            remaining -= allocated
        }
        if remaining > 0 {
            let start = lastEnd ?? session.startTime
            let end = min(
                session.startTime.addingTimeInterval(total),
                start.addingTimeInterval(remaining)
            )
            if end > start {
                let clippedStart = max(start, interval.start)
                let clippedEnd = min(end, interval.end)
                result.notRecorded += max(0, clippedEnd.timeIntervalSince(clippedStart))
            }
        }
        return result
    }
}
