import Foundation

public enum AIInsightEvidenceKind: String, Codable, Equatable, Sendable {
    case periodSummary = "period_summary"
    case daySummary = "day_summary"
    case focusBlock = "focus_block"
    case distractionCluster = "distraction_cluster"
    case contextSwitchCluster = "context_switch_cluster"
}

public enum ReflectionScope: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case today
    case lastSevenDays = "last_seven_days"

    public var id: Self { self }
    public var title: String { self == .today ? "Today" : "Last 7 Days" }
}

public enum ReflectionSuggestedQuestions {
    public static func forSnapshot(_ snapshot: AIInsightAnalysisSnapshot) -> [String] {
        guard snapshot.completedSessionCount > 0 else { return [] }

        // Use evidence blocks, which are built only from intervals with both
        // observed activity context and presence. Snapshot totals can also
        // include unobserved gaps, so they are not enough to ground a prompt.
        let observedEvidence = snapshot.evidence.filter {
            $0.durationSeconds > 0 && ($0.kind == .focusBlock || $0.kind == .distractionCluster)
        }
        let productive = observedEvidence.contains { $0.kind == .focusBlock }
        let distracted = observedEvidence.contains { $0.kind == .distractionCluster }
        let hasContext = snapshot.topContexts.contains { $0.durationSeconds > 0 }
            || observedEvidence.contains { $0.context != nil }
        guard !observedEvidence.isEmpty || hasContext else { return [] }

        let period = snapshot.scope == .today ? "today" : "this week"
        var questions: [String] = []
        if productive && distracted {
            questions.append("How did my recorded time divide between Productive and Distracted activity \(period)?")
        } else if productive {
            questions.append("What productive work took up the most recorded time \(period)?")
        } else if distracted {
            questions.append("Which activities made up my recorded Distracted time \(period)?")
        } else {
            questions.append("What activity context took up my recorded time \(period)?")
        }

        if snapshot.contextSwitchCount > 0 {
            questions.append("What was happening around my recorded context switches \(period)?")
        }

        var seen = Set<String>()
        return questions.filter {
            seen.insert($0.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")).inserted
        }.prefix(3).map { $0 }
    }
}

public struct AIInsightDurations: Codable, Equatable, Sendable {
    public let productiveSeconds: Int
    public let distractedSeconds: Int
    public let unclassifiedSeconds: Int
    public let notRecordedSeconds: Int
    public let activeSeconds: Int
    public let idleSeconds: Int
    public let awaySeconds: Int
    public let unobservedSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case productiveSeconds = "productive_seconds"
        case distractedSeconds = "distracted_seconds"
        case unclassifiedSeconds = "unclassified_seconds"
        case notRecordedSeconds = "not_recorded_seconds"
        case activeSeconds = "active_seconds"
        case idleSeconds = "idle_seconds"
        case awaySeconds = "away_seconds"
        case unobservedSeconds = "unobserved_seconds"
    }
}

public struct AIInsightEvidence: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: AIInsightEvidenceKind
    public let startedAt: String
    public let endedAt: String
    public let durationSeconds: Int
    public let classification: String?
    public let applicationName: String?
    public let context: String?
    public let switchCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, kind, classification, context
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case applicationName = "application_name"
        case switchCount = "switch_count"
    }
}

public struct AIInsightContextAggregate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let applicationName: String
    public let context: String?
    public let durationSeconds: Int
    public let evidenceIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id, context
        case applicationName = "application_name"
        case durationSeconds = "duration_seconds"
        case evidenceIDs = "evidence_ids"
    }
}

public struct AIInsightDailySummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let date: String
    public let completedSessionCount: Int
    public let durations: AIInsightDurations
    public let contextSwitchCount: Int
    public let focusBlockCount: Int
    public let distractionClusterCount: Int

    private enum CodingKeys: String, CodingKey {
        case id, date, durations
        case completedSessionCount = "completed_session_count"
        case contextSwitchCount = "context_switch_count"
        case focusBlockCount = "focus_block_count"
        case distractionClusterCount = "distraction_cluster_count"
    }
}

public struct AIInsightDayComparison: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(fromDate)-to-\(toDate)" }
    public let fromDate: String
    public let toDate: String
    public let productiveDeltaSeconds: Int
    public let distractedDeltaSeconds: Int
    public let unclassifiedDeltaSeconds: Int
    public let contextSwitchDelta: Int

    private enum CodingKeys: String, CodingKey {
        case fromDate = "from_date"
        case toDate = "to_date"
        case productiveDeltaSeconds = "productive_delta_seconds"
        case distractedDeltaSeconds = "distracted_delta_seconds"
        case unclassifiedDeltaSeconds = "unclassified_delta_seconds"
        case contextSwitchDelta = "context_switch_delta"
    }
}

public struct AIInsightAnalysisSnapshot: Codable, Equatable, Sendable {
    public let scope: ReflectionScope
    public let periodStart: String
    public let periodEnd: String
    public let completedSessionCount: Int
    public let durations: AIInsightDurations
    public let contextSwitchCount: Int
    public let evidence: [AIInsightEvidence]
    public let topContexts: [AIInsightContextAggregate]
    public let days: [AIInsightDailySummary]
    public let dayComparisons: [AIInsightDayComparison]

    private enum CodingKeys: String, CodingKey {
        case scope, durations, evidence, days
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case completedSessionCount = "completed_session_count"
        case contextSwitchCount = "context_switch_count"
        case topContexts = "top_contexts"
        case dayComparisons = "day_comparisons"
    }
}

/// Local navigation metadata is deliberately excluded from the encoded AI snapshot.
public struct AIInsightEvidenceLink: Equatable, Sendable {
    /// Sessions are ordered by the first contributing activity interval.
    public let evidenceID: String
    public let waitSessionIDs: [UUID]
    public let sourceSliceIDs: [UUID]
    public let startedAt: Date
    public let endedAt: Date

    public func resolvedSessionIDs(availableSessionIDs: Set<UUID>) -> [UUID] {
        waitSessionIDs.reduce(into: []) { resolved, id in
            if availableSessionIDs.contains(id), !resolved.contains(id) { resolved.append(id) }
        }
    }
}

public enum AIInsightEvidenceNavigation {
    public static func controlLabel(evidence: AIInsightEvidence, link: AIInsightEvidenceLink) -> String {
        if evidence.kind == .daySummary {
            let date = String(evidence.id.dropFirst("day-".count))
            return link.waitSessionIDs.count > 1
                ? "Day · \(link.waitSessionIDs.count) sessions · \(date)"
                : "Day · \(date)"
        }
        let kind: String
        switch evidence.kind {
        case .periodSummary: kind = "Period summary"
        case .daySummary: kind = "Day"
        case .focusBlock: kind = "Focus"
        case .distractionCluster: kind = "Distraction"
        case .contextSwitchCluster: kind = "Context switches"
        }
        return "\(kind) · \(link.startedAt.formatted(date: .omitted, time: .shortened))"
    }
}

public struct AIInsightPreparedSnapshot: Equatable, Sendable {
    public let payload: AIInsightAnalysisSnapshot
    public let fingerprint: String
    public let evidenceLinks: [String: AIInsightEvidenceLink]
}

public enum AIInsightSnapshotBuilder {
    private struct Interval {
        let sessionID: UUID
        let sliceID: UUID?
        let sourceSegmentID: UUID?
        let startedAt: Date
        let endedAt: Date
        let duration: TimeInterval
        let classification: WaitSessionClassification?
        let context: ActivityContext?
        let presence: UserPresenceState?
    }

    private struct MutableBlock {
        var intervals: [Interval]
        var startedAt: Date { intervals[0].startedAt }
        var endedAt: Date { intervals[intervals.count - 1].endedAt }
        var duration: TimeInterval { intervals.reduce(0) { $0 + $1.duration } }
    }

    public static func prepare(
        sessions: [WaitSession],
        referenceDate: Date = .now,
        calendar: Calendar = .current,
        scope: ReflectionScope = .today
    ) -> AIInsightPreparedSnapshot {
        guard let today = calendar.dateInterval(of: .day, for: referenceDate),
              let periodStart = scope == .today
                ? Optional(today.start)
                : calendar.date(byAdding: .day, value: -6, to: today.start)
        else {
            return empty(referenceDate: referenceDate, scope: scope)
        }
        let period = DateInterval(start: periodStart, end: today.end)
        let completed = sessions.filter { $0.state == .completed }
        // Duration follows the dates when it occurred, independent of the
        // session's completion date. Session counts remain completion-based.
        let completedInPeriod = completed.filter {
            let completion = WaitPresentationSupport.completionDate(for: $0)
            return completion >= period.start && completion < period.end
        }
        let intervals = completed
            .flatMap(makeIntervals)
            .compactMap { clipped($0, to: period) }
            .sorted(by: intervalStartsFirst)

        var productive: TimeInterval = 0
        var distracted: TimeInterval = 0
        var unclassified: TimeInterval = 0
        var notRecorded: TimeInterval = 0
        var active: TimeInterval = 0
        var idle: TimeInterval = 0
        var away: TimeInterval = 0
        var unobserved: TimeInterval = 0
        for interval in intervals {
            switch interval.classification {
            case .productive: productive += interval.duration
            case .distracted: distracted += interval.duration
            case .unclassified: unclassified += interval.duration
            case nil: notRecorded += interval.duration
            }
            switch interval.presence {
            case .active: active += interval.duration
            case .idle: idle += interval.duration
            case .away: away += interval.duration
            case nil: unobserved += interval.duration
            }
        }

        var links: [String: AIInsightEvidenceLink] = [:]
        var evidence: [AIInsightEvidence] = []
        evidence.append(AIInsightEvidence(
            id: "period-summary",
            kind: .periodSummary,
            startedAt: timestamp(period.start),
            endedAt: timestamp(period.end),
            durationSeconds: seconds(intervals.reduce(0) { $0 + $1.duration }),
            classification: nil,
            applicationName: nil,
            context: nil,
            switchCount: nil
        ))

        var daySummaries: [AIInsightDailySummary] = []
        let dayCount = scope == .today ? 1 : 7
        for offset in 0..<dayCount {
            guard let dayAnchor = calendar.date(byAdding: .day, value: offset, to: period.start),
                  let day = calendar.dateInterval(of: .day, for: dayAnchor) else { continue }
            let dayStart = day.start
            let dayEnd = day.end
            let dayIntervals = intervals.compactMap { clipped($0, to: day) }
            let daySessions = completedInPeriod.filter {
                let completion = WaitPresentationSupport.completionDate(for: $0)
                return completion >= dayStart && completion < dayEnd
            }
            let dayDurations = durations(for: dayIntervals)
            let dayFocusBlocks = blocks(in: dayIntervals) { $0.classification == .productive && $0.presence == .active }
            let dayDistractionBlocks = blocks(in: dayIntervals) { $0.classification == .distracted && $0.presence == .active }
            let daySwitches = contextSwitchClusters(in: dayIntervals).reduce(0) { $0 + $1.count }
            let stamp = dayStamp(dayStart, calendar: calendar)
            let dayID = "day-\(stamp)"
            daySummaries.append(AIInsightDailySummary(
                id: dayID,
                date: stamp,
                completedSessionCount: daySessions.count,
                durations: dayDurations,
                contextSwitchCount: daySwitches,
                focusBlockCount: dayFocusBlocks.count,
                distractionClusterCount: dayDistractionBlocks.count
            ))
            evidence.append(AIInsightEvidence(
                id: dayID,
                kind: .daySummary,
                startedAt: timestamp(dayStart),
                endedAt: timestamp(dayEnd),
                durationSeconds: seconds(dayIntervals.reduce(0) { $0 + $1.duration }),
                classification: nil,
                applicationName: nil,
                context: nil,
                switchCount: daySwitches
            ))
            if !dayIntervals.isEmpty {
                // A daily summary can combine multiple waits. Preserve each
                // source so History can highlight all of them.
                var sessionIDs: [UUID] = []
                for interval in dayIntervals where !sessionIDs.contains(interval.sessionID) {
                    sessionIDs.append(interval.sessionID)
                }
                links[dayID] = AIInsightEvidenceLink(
                    evidenceID: dayID,
                    waitSessionIDs: sessionIDs,
                    sourceSliceIDs: dayIntervals
                        .compactMap(\.sliceID),
                    startedAt: dayStart,
                    endedAt: dayEnd
                )
            }
        }

        for (kind, classification) in [
            (AIInsightEvidenceKind.focusBlock, WaitSessionClassification.productive),
            (.distractionCluster, .distracted)
        ] {
            let blocks = blocks(in: intervals) {
                $0.classification == classification && $0.presence == .active
            }
            for block in blocks.sorted(by: { $0.duration > $1.duration }).prefix(5) {
                appendEvidence(kind: kind, block: block, switchCount: nil, to: &evidence, links: &links)
            }
        }

        let switchClusters = contextSwitchClusters(in: intervals)
        for cluster in switchClusters.prefix(5) {
            appendEvidence(
                kind: .contextSwitchCluster,
                block: cluster.block,
                switchCount: cluster.count,
                to: &evidence,
                links: &links
            )
        }

        let topContexts = contextAggregates(from: intervals, links: links)
        let payload = AIInsightAnalysisSnapshot(
            scope: scope,
            periodStart: timestamp(period.start),
            periodEnd: timestamp(period.end),
            completedSessionCount: completedInPeriod.count,
            durations: AIInsightDurations(
                productiveSeconds: seconds(productive),
                distractedSeconds: seconds(distracted),
                unclassifiedSeconds: seconds(unclassified),
                notRecordedSeconds: seconds(notRecorded),
                activeSeconds: seconds(active),
                idleSeconds: seconds(idle),
                awaySeconds: seconds(away),
                unobservedSeconds: seconds(unobserved)
            ),
            contextSwitchCount: switchClusters.reduce(0) { $0 + $1.count },
            evidence: evidence,
            topContexts: topContexts,
            days: daySummaries,
            dayComparisons: zip(daySummaries, daySummaries.dropFirst()).map { previous, next in
                AIInsightDayComparison(
                    fromDate: previous.date,
                    toDate: next.date,
                    productiveDeltaSeconds: next.durations.productiveSeconds - previous.durations.productiveSeconds,
                    distractedDeltaSeconds: next.durations.distractedSeconds - previous.durations.distractedSeconds,
                    unclassifiedDeltaSeconds: next.durations.unclassifiedSeconds - previous.durations.unclassifiedSeconds,
                    contextSwitchDelta: next.contextSwitchCount - previous.contextSwitchCount
                )
            }
        )
        return AIInsightPreparedSnapshot(
            payload: payload,
            fingerprint: fingerprint(payload),
            evidenceLinks: links
        )
    }

    private static func empty(referenceDate: Date, scope: ReflectionScope) -> AIInsightPreparedSnapshot {
        let value = timestamp(referenceDate)
        let payload = AIInsightAnalysisSnapshot(
            scope: scope,
            periodStart: value,
            periodEnd: value,
            completedSessionCount: 0,
            durations: .init(
                productiveSeconds: 0, distractedSeconds: 0, unclassifiedSeconds: 0,
                notRecordedSeconds: 0, activeSeconds: 0, idleSeconds: 0,
                awaySeconds: 0, unobservedSeconds: 0
            ),
            contextSwitchCount: 0,
            evidence: [],
            topContexts: [],
            days: [],
            dayComparisons: []
        )
        return .init(payload: payload, fingerprint: fingerprint(payload), evidenceLinks: [:])
    }

    private static func durations(for intervals: [Interval]) -> AIInsightDurations {
        var productive = 0.0, distracted = 0.0, unclassified = 0.0, notRecorded = 0.0
        var active = 0.0, idle = 0.0, away = 0.0, unobserved = 0.0
        for interval in intervals {
            switch interval.classification {
            case .productive: productive += interval.duration
            case .distracted: distracted += interval.duration
            case .unclassified: unclassified += interval.duration
            case nil: notRecorded += interval.duration
            }
            switch interval.presence {
            case .active: active += interval.duration
            case .idle: idle += interval.duration
            case .away: away += interval.duration
            case nil: unobserved += interval.duration
            }
        }
        return AIInsightDurations(
            productiveSeconds: seconds(productive), distractedSeconds: seconds(distracted),
            unclassifiedSeconds: seconds(unclassified), notRecordedSeconds: seconds(notRecorded),
            activeSeconds: seconds(active), idleSeconds: seconds(idle), awaySeconds: seconds(away),
            unobservedSeconds: seconds(unobserved)
        )
    }

    private static func clipped(_ interval: Interval, to boundary: DateInterval) -> Interval? {
        let start = max(interval.startedAt, boundary.start)
        let end = min(interval.endedAt, boundary.end)
        guard end > start else { return nil }
        return Interval(
            sessionID: interval.sessionID,
            sliceID: interval.sliceID,
            sourceSegmentID: interval.sourceSegmentID,
            startedAt: start,
            endedAt: end,
            duration: end.timeIntervalSince(start),
            classification: interval.classification,
            context: interval.context,
            presence: interval.presence
        )
    }

    private static func makeIntervals(_ session: WaitSession) -> [Interval] {
        let total = max(0, session.duration ?? session.endTime?.timeIntervalSince(session.startTime) ?? 0)
        let sessionEnd = session.startTime.addingTimeInterval(total)
        guard let slices = session.activityClassificationSlices else {
            var values: [Interval] = []
            var cursor = session.startTime
            for segment in session.activitySegments.sorted(by: {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                let segmentEnd = segment.endedAt
                    ?? segment.duration.map { segment.startedAt.addingTimeInterval($0) }
                    ?? segment.startedAt
                let start = max(cursor, segment.startedAt)
                let end = min(min(segmentEnd, segment.duration.map {
                    segment.startedAt.addingTimeInterval(max(0, $0))
                } ?? segmentEnd), sessionEnd)
                guard end > start else { continue }
                if start > cursor {
                    values.append(Interval(
                        sessionID: session.id, sliceID: nil, sourceSegmentID: nil,
                        startedAt: cursor, endedAt: start, duration: start.timeIntervalSince(cursor),
                        classification: session.effectiveClassification, context: nil, presence: nil
                    ))
                }
                values.append(Interval(
                    sessionID: session.id,
                    sliceID: nil,
                    sourceSegmentID: segment.id,
                    startedAt: start,
                    endedAt: end,
                    duration: end.timeIntervalSince(start),
                    classification: session.effectiveClassification,
                    context: segment.context,
                    presence: segment.context.presenceState
                ))
                cursor = end
            }
            if cursor < sessionEnd {
                values.append(Interval(
                    sessionID: session.id, sliceID: nil, sourceSegmentID: nil,
                    startedAt: cursor, endedAt: sessionEnd,
                    duration: sessionEnd.timeIntervalSince(cursor), classification: session.effectiveClassification,
                    context: nil, presence: nil
                ))
            }
            return values
        }
        let segments = Dictionary(uniqueKeysWithValues: session.activitySegments.map { ($0.id, $0) })
        var remaining = total
        var values: [Interval] = []
        for slice in slices.sorted(by: { $0.startedAt < $1.startedAt }) where remaining > 0 {
            let duration = min(remaining, max(0, slice.duration))
            guard duration > 0 else { continue }
            let segment = slice.sourceActivitySegmentID.flatMap { segments[$0] }
            values.append(Interval(
                sessionID: session.id,
                sliceID: slice.id,
                sourceSegmentID: slice.sourceActivitySegmentID,
                startedAt: slice.startedAt,
                endedAt: min(slice.endedAt, slice.startedAt.addingTimeInterval(duration)),
                duration: duration,
                classification: slice.effectiveClassification,
                context: segment?.context,
                presence: segment?.context.presenceState
            ))
            remaining -= duration
        }
        if remaining > 0 {
            let start = values.last?.endedAt ?? session.startTime
            values.append(Interval(
                sessionID: session.id, sliceID: nil, sourceSegmentID: nil,
                startedAt: start, endedAt: min(sessionEnd, start.addingTimeInterval(remaining)),
                duration: remaining, classification: nil, context: nil, presence: nil
            ))
        }
        return values
    }

    private static func blocks(
        in intervals: [Interval],
        matching predicate: (Interval) -> Bool
    ) -> [MutableBlock] {
        var result: [MutableBlock] = []
        for interval in intervals where predicate(interval) {
            if let last = result.indices.last,
               result[last].intervals.last?.sessionID == interval.sessionID,
               interval.startedAt.timeIntervalSince(result[last].endedAt) <= 1 {
                result[last].intervals.append(interval)
            } else {
                result.append(MutableBlock(intervals: [interval]))
            }
        }
        return result
    }

    private static func contextSwitchClusters(
        in intervals: [Interval]
    ) -> [(block: MutableBlock, count: Int)] {
        let observed = intervals.filter { $0.presence != nil && $0.context != nil }
        var switches: [(Interval, Interval)] = []
        for pair in zip(observed, observed.dropFirst()) where pair.0.sessionID == pair.1.sessionID {
            if contextIdentity(pair.0.context!) != contextIdentity(pair.1.context!) {
                switches.append(pair)
            }
        }
        var clusters: [(MutableBlock, Int)] = []
        for pair in switches {
            if let last = clusters.indices.last,
               clusters[last].0.intervals.last?.sessionID == pair.1.sessionID,
               pair.0.startedAt.timeIntervalSince(clusters[last].0.endedAt) <= 300 {
                clusters[last].0.intervals.append(pair.1)
                clusters[last].1 += 1
            } else {
                clusters.append((MutableBlock(intervals: [pair.0, pair.1]), 1))
            }
        }
        return clusters.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.startedAt < $1.0.startedAt
        }
    }

    private static func appendEvidence(
        kind: AIInsightEvidenceKind,
        block: MutableBlock,
        switchCount: Int?,
        to evidence: inout [AIInsightEvidence],
        links: inout [String: AIInsightEvidenceLink]
    ) {
        guard let first = block.intervals.first else { return }
        let rawID = ([kind.rawValue, first.sessionID.uuidString]
            + block.intervals.compactMap { $0.sliceID?.uuidString }).joined(separator: ":")
        let id = "ev-\(stableHash(Data(rawID.utf8)))"
        let representative = block.intervals
            .filter { $0.context != nil }
            .max { $0.duration < $1.duration }
        let app = representative?.context.map { sanitizedApplication($0) }
        let context = representative?.context.flatMap { sanitizedContext($0) }
        evidence.append(AIInsightEvidence(
            id: id,
            kind: kind,
            startedAt: timestamp(block.startedAt),
            endedAt: timestamp(block.endedAt),
            durationSeconds: seconds(block.duration),
            classification: first.classification?.title,
            applicationName: app,
            context: context,
            switchCount: switchCount
        ))
        links[id] = AIInsightEvidenceLink(
            evidenceID: id,
            waitSessionIDs: Array(Set(block.intervals.map(\.sessionID))).sorted { lhs, rhs in
                let left = block.intervals.first(where: { $0.sessionID == lhs })?.startedAt ?? .distantFuture
                let right = block.intervals.first(where: { $0.sessionID == rhs })?.startedAt ?? .distantFuture
                return left == right ? lhs.uuidString < rhs.uuidString : left < right
            },
            sourceSliceIDs: block.intervals.compactMap(\.sliceID),
            startedAt: block.startedAt,
            endedAt: block.endedAt
        )
    }

    private static func contextAggregates(
        from intervals: [Interval],
        links: [String: AIInsightEvidenceLink]
    ) -> [AIInsightContextAggregate] {
        struct Aggregate { var app: String; var context: String?; var duration: TimeInterval = 0; var ids: Set<String> = [] }
        var values: [String: Aggregate] = [:]
        for interval in intervals where interval.context != nil && interval.duration > 0 {
            let app = sanitizedApplication(interval.context!)
            let context = sanitizedContext(interval.context!)
            let key = app.lowercased() + "|" + (context?.lowercased() ?? "")
            var value = values[key] ?? Aggregate(app: app, context: context)
            value.duration += interval.duration
            value.ids.formUnion(links.values.filter {
                $0.waitSessionIDs.contains(interval.sessionID)
                    && interval.sliceID.map($0.sourceSliceIDs.contains) == true
            }.map(\.evidenceID))
            values[key] = value
        }
        return values.map { key, value in
            AIInsightContextAggregate(
                id: "ctx-\(stableHash(Data(key.utf8)))",
                applicationName: value.app,
                context: value.context,
                durationSeconds: seconds(value.duration),
                evidenceIDs: value.ids.sorted()
            )
        }.sorted {
            if $0.durationSeconds != $1.durationSeconds { return $0.durationSeconds > $1.durationSeconds }
            return $0.id < $1.id
        }.prefix(5).map { $0 }
    }

    private static func sanitizedApplication(_ context: ActivityContext) -> String {
        AITextSanitizer.sanitize(context.applicationName, maximumLength: 60)
    }

    private static func sanitizedContext(_ context: ActivityContext) -> String? {
        let value: String?
        if let domain = context.browserDomain {
            let title = context.browserPageTitle ?? context.windowTitle
            value = [domain, title].compactMap { $0 }.joined(separator: " · ")
        } else if let kind = context.resourceKind {
            value = kind.rawValue.capitalized
        } else {
            value = nil
        }
        return value.map { AITextSanitizer.sanitize($0, maximumLength: 100) }
    }

    private static func contextIdentity(_ context: ActivityContext) -> String {
        [context.applicationBundleIdentifier, context.browserDomain, context.browserPageTitle,
         context.resourceKind?.rawValue, context.resourceName, context.documentName, context.windowTitle]
            .compactMap { $0?.lowercased() }.joined(separator: "|")
    }

    private static func intervalStartsFirst(_ lhs: Interval, _ rhs: Interval) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return (lhs.sliceID?.uuidString ?? "") < (rhs.sliceID?.uuidString ?? "")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return formatter.string(from: date)
    }

    private static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func seconds(_ value: TimeInterval) -> Int { Int(max(0, value).rounded()) }

    private static func fingerprint(_ payload: AIInsightAnalysisSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return stableHash((try? encoder.encode(payload)) ?? Data())
    }

    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

public enum AIInsightType: String, Codable, CaseIterable, Equatable, Sendable {
    case strongestFocusBlock = "strongest_focus_block"
    case fragmentedWorkPeriod = "fragmented_work_period"
    case distractionCluster = "distraction_cluster"
    case productiveContextSwitch = "productive_context_switch"
    case usageActiveMismatch = "usage_active_mismatch"
    case notableWithinPeriodChange = "notable_within_period_change"
}

public struct AIInsight: Equatable, Identifiable, Sendable {
    public let id: String
    public let type: AIInsightType
    public let title: String
    public let observation: String
    public let evidenceIDs: [String]
    public let suggestion: String?
    public let confidence: Double?
}

public enum AIInsightGenerationSource: String, Equatable, Sendable {
    case fresh
    case cache

    public var title: String {
        switch self {
        case .fresh: "Fresh request"
        case .cache: "Cache"
        }
    }
}

public struct AIInsightGeneration: Equatable, Sendable {
    public let insights: [AIInsight]
    public let source: AIInsightGenerationSource
}

public protocol AIInsightProviding: Sendable {
    func insights(for snapshot: AIInsightAnalysisSnapshot) async throws -> [AIInsight]
}

public enum AIInsightError: Error, Equatable, LocalizedError, Sendable {
    case timeout
    case networkUnavailable
    case rateLimited
    case providerUnavailable(statusCode: Int)
    case malformedResponse
    case invalidInsight(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "Featherless timed out. Local metrics remain available."
        case .networkUnavailable: "Featherless could not be reached. Local metrics remain available."
        case .rateLimited: "Featherless is rate limiting requests. Try again later."
        case let .providerUnavailable(code): "Featherless or the model is unavailable (HTTP \(code))."
        case .malformedResponse: "Featherless returned an invalid insights response."
        case let .invalidInsight(category): "Featherless insight validation failed (\(category))."
        }
    }
}

/// The only model-facing reflection instructions.
public enum AIInsightPromptTemplate {
    public static let systemInstructions = """
    Interpret the supplied deterministic productivity snapshot. Return 3 to 5 concise, evidence-backed observations and no generic encouragement. Never calculate or state numbers, durations, counts, percentages, or time ranges; the app displays authoritative local metrics separately. Use only supplied evidence IDs, and include at least one ev- evidence range (not only period-summary) for every insight. Supported types: strongest_focus_block, fragmented_work_period, distraction_cluster, productive_context_switch, usage_active_mismatch, notable_within_period_change. Each insight_id must be TYPE-EVIDENCE_ID using its first evidence ID. Return only JSON: {"insights":[{"insight_id":"type-ev-id","type":"supported_type","title":"short title","observation":"concise observation without numbers","evidence_ids":["ev-id"],"suggestion":"optional action","confidence":0.0}]}. No markdown or extra keys.
    """

    public static func userContent(for snapshot: AIInsightAnalysisSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let string = String(data: try encoder.encode(snapshot), encoding: .utf8) else {
            throw AIInsightError.malformedResponse
        }
        return string
    }
}

public struct FeatherlessInsightProvider: AIInsightProviding {
    private let configuration: FeatherlessConfiguration
    private let transport: any FeatherlessHTTPTransport

    public init(
        configuration: FeatherlessConfiguration,
        transport: any FeatherlessHTTPTransport = URLSessionFeatherlessHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func insights(for snapshot: AIInsightAnalysisSnapshot) async throws -> [AIInsight] {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Inbetween", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(Request(
            model: configuration.model,
            messages: [
                .init(role: "system", content: AIInsightPromptTemplate.systemInstructions),
                .init(role: "user", content: try AIInsightPromptTemplate.userContent(for: snapshot))
            ],
            temperature: 0,
            maxTokens: 700
        ))
        let response: FeatherlessHTTPResponse
        do { response = try await transport.send(request) }
        catch FeatherlessTransportError.timeout { throw AIInsightError.timeout }
        catch FeatherlessTransportError.networkUnavailable { throw AIInsightError.networkUnavailable }
        catch { throw AIInsightError.networkUnavailable }
        switch response.statusCode {
        case 200..<300: break
        case 429: throw AIInsightError.rateLimited
        default: throw AIInsightError.providerUnavailable(statusCode: response.statusCode)
        }
        guard let completion = try? JSONDecoder().decode(Response.self, from: response.data),
              let content = completion.choices.first?.message.content,
              let contentData = content.data(using: .utf8)
        else { throw AIInsightError.malformedResponse }
        return try Self.validate(contentData, snapshot: snapshot)
    }

    public static func validate(
        _ data: Data,
        snapshot: AIInsightAnalysisSnapshot
    ) throws -> [AIInsight] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["insights"],
              let raw = root["insights"] as? [[String: Any]],
              (3...5).contains(raw.count)
        else { throw AIInsightError.malformedResponse }
        let allowedKeys: Set<String> = [
            "insight_id", "type", "title", "observation", "evidence_ids", "suggestion", "confidence"
        ]
        let evidenceIDs = Set(snapshot.evidence.map(\.id))
        var seen: Set<String> = []
        return try raw.map { value in
            guard Set(value.keys).isSubset(of: allowedKeys),
                  let id = value["insight_id"] as? String,
                  let rawType = value["type"] as? String,
                  let type = AIInsightType(rawValue: rawType),
                  let title = value["title"] as? String,
                  let observation = value["observation"] as? String,
                  let references = value["evidence_ids"] as? [String],
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !references.isEmpty
            else { throw AIInsightError.invalidInsight("malformed_fields") }
            guard references.allSatisfy(evidenceIDs.contains) else {
                throw AIInsightError.invalidInsight("unknown_evidence")
            }
            guard references.contains(where: { $0 != "period-summary" }) else {
                throw AIInsightError.invalidInsight("non_navigable_evidence")
            }
            guard id == "\(type.rawValue)-\(references[0])", seen.insert(id).inserted else {
                throw AIInsightError.invalidInsight("unstable_or_duplicate_id")
            }
            let suggestion = value["suggestion"] as? String
            guard [title, observation, suggestion].compactMap({ $0 }).allSatisfy({ !containsDigit($0) }) else {
                throw AIInsightError.invalidInsight("invented_metric_or_range")
            }
            let confidence = value["confidence"] as? Double
            guard confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                throw AIInsightError.invalidInsight("invalid_confidence")
            }
            return AIInsight(
                id: id,
                type: type,
                title: AITextSanitizer.sanitize(title, maximumLength: 80),
                observation: AITextSanitizer.sanitize(observation, maximumLength: 240),
                evidenceIDs: references,
                suggestion: suggestion.map { AITextSanitizer.sanitize($0, maximumLength: 160) },
                confidence: confidence
            )
        }
    }

    private static func containsDigit(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private struct Message: Codable { let role: String; let content: String }
    private struct Request: Encodable {
        let model: String; let messages: [Message]; let temperature: Double; let maxTokens: Int
        enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens" }
    }
    private struct Response: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
    }
}

public actor AIInsightCoordinator {
    private let provider: any AIInsightProviding
    private var cachedFingerprint: String?
    private var cachedInsights: [AIInsight] = []

    public init(provider: any AIInsightProviding) { self.provider = provider }

    public func insights(
        for prepared: AIInsightPreparedSnapshot,
        forceRefresh: Bool = false
    ) async throws -> [AIInsight] {
        try await generation(for: prepared, forceRefresh: forceRefresh).insights
    }

    public func generation(
        for prepared: AIInsightPreparedSnapshot,
        forceRefresh: Bool = false
    ) async throws -> AIInsightGeneration {
        if !forceRefresh, cachedFingerprint == prepared.fingerprint {
            return AIInsightGeneration(insights: cachedInsights, source: .cache)
        }
        let values = try await provider.insights(for: prepared.payload)
        let knownEvidence = Set(prepared.payload.evidence.map(\.id))
        var seen: Set<String> = []
        guard (3...5).contains(values.count), values.allSatisfy({ value in
            !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !value.evidenceIDs.isEmpty
                && value.evidenceIDs.allSatisfy(knownEvidence.contains)
                && value.evidenceIDs.contains(where: { $0 != "period-summary" })
                && value.id == "\(value.type.rawValue)-\(value.evidenceIDs[0])"
                && seen.insert(value.id).inserted
                && value.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true
        }) else {
            throw AIInsightError.malformedResponse
        }
        cachedFingerprint = prepared.fingerprint
        cachedInsights = values
        return AIInsightGeneration(insights: values, source: .fresh)
    }
}
