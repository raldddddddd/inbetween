import Foundation
import Testing
@testable import InbetweenCore

struct AIInsightsTests {
    @Test func snapshotCalculatesAuthoritativeDurationsPresenceSwitchesAndStableEvidence() throws {
        let fixture = try makeSession()
        let calendar = utcCalendar()
        let reference = fixture.startTime.addingTimeInterval(3_600)

        let first = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: reference, calendar: calendar
        )
        let second = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: reference, calendar: calendar
        )

        #expect(first.fingerprint == second.fingerprint)
        #expect(first.payload.evidence.map(\.id) == second.payload.evidence.map(\.id))
        #expect(first.payload.completedSessionCount == 1)
        #expect(first.payload.durations.productiveSeconds == 120)
        #expect(first.payload.durations.distractedSeconds == 60)
        #expect(first.payload.durations.unclassifiedSeconds == 60)
        #expect(first.payload.durations.activeSeconds == 180)
        #expect(first.payload.durations.idleSeconds == 60)
        #expect(first.payload.durations.awaySeconds == 0)
        #expect(first.payload.contextSwitchCount == 2)
        #expect(first.payload.evidence.contains { $0.kind == .focusBlock && $0.durationSeconds == 120 })
        #expect(first.payload.evidence.contains { $0.kind == .distractionCluster && $0.durationSeconds == 60 })
    }

    @Test func snapshotSanitizesProviderPayloadAndKeepsLocalNavigationPrivate() throws {
        let fixture = try makeSession(
            browserTitle: "Plan https://example.com/private?q=secret person@example.com /Users/alice/Hidden.txt"
        )
        let prepared = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: fixture.startTime, calendar: utcCalendar()
        )
        let encoded = try #require(String(
            data: JSONEncoder().encode(prepared.payload), encoding: .utf8
        ))

        #expect(!encoded.contains("q=secret"))
        #expect(!encoded.contains("person@example.com"))
        #expect(!encoded.contains("/Users/alice"))
        #expect(!encoded.contains(fixture.id.uuidString))
        #expect(encoded.contains("[redacted]"))
        #expect(!prepared.evidenceLinks.isEmpty)
    }

    @Test func insightValidationAcceptsKnownEvidenceAndRejectsUnknownOrInventedClaims() throws {
        let fixture = try makeSession()
        let snapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: fixture.startTime, calendar: utcCalendar()
        ).payload
        let evidenceID = try #require(snapshot.evidence.first { $0.kind == .focusBlock }?.id)
        let valid = try responseData(evidenceID: evidenceID)
        let insights = try FeatherlessInsightProvider.validate(valid, snapshot: snapshot)
        #expect(insights.count == 3)
        #expect(insights.allSatisfy { $0.evidenceIDs == [evidenceID] })

        let unknown = try responseData(evidenceID: "ev-not-supplied")
        #expect(throws: AIInsightError.invalidInsight("unknown_evidence")) {
            try FeatherlessInsightProvider.validate(unknown, snapshot: snapshot)
        }

        let invented = try responseData(
            evidenceID: evidenceID,
            observation: "This block lasted 47 minutes."
        )
        #expect(throws: AIInsightError.invalidInsight("invented_metric_or_range")) {
            try FeatherlessInsightProvider.validate(invented, snapshot: snapshot)
        }
    }

    @Test func providerFailureLeavesDeterministicSnapshotAndEvidenceMappingAvailable() async throws {
        let fixture = try makeSession()
        let prepared = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: fixture.startTime, calendar: utcCalendar()
        )
        let coordinator = AIInsightCoordinator(provider: FailingInsightProvider())

        await #expect(throws: AIInsightError.networkUnavailable) {
            try await coordinator.insights(for: prepared)
        }
        #expect(prepared.payload.durations.productiveSeconds == 120)
        #expect(!prepared.evidenceLinks.isEmpty)
    }

    @Test func evidenceLinkMapsBackToExactTimelineSessionAndSlices() throws {
        let fixture = try makeSession()
        let prepared = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: fixture.startTime, calendar: utcCalendar()
        )
        let evidence = try #require(prepared.payload.evidence.first { $0.kind == .focusBlock })
        let link = try #require(prepared.evidenceLinks[evidence.id])
        let productiveSliceIDs = Set(try #require(fixture.activityClassificationSlices).filter {
            $0.effectiveClassification == .productive
        }.map(\.id))

        #expect(link.waitSessionIDs == [fixture.id])
        #expect(AIInsightEvidenceNavigation.controlLabel(evidence: evidence, link: link).hasPrefix("Focus · "))
        #expect(Set(link.sourceSliceIDs) == productiveSliceIDs)
        #expect(link.startedAt == fixture.startTime)
        #expect(link.endedAt == fixture.startTime.addingTimeInterval(120))
    }

    @Test func legacyPartialCoverageHistoryAndReflectionAttributeTheSameElapsedTime() throws {
        let calendar = utcCalendar()
        let start = Date(timeIntervalSince1970: 1_704_758_340) // 2024-01-08 23:59 UTC
        let sessionID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let partialSegment = try segment(
            id: "dddddddd-dddd-dddd-dddd-dddddddddddd",
            sessionID: sessionID,
            start: start,
            from: 30,
            to: 60,
            bundle: "com.apple.dt.Xcode",
            app: "Xcode",
            resourceKind: .workspace,
            presence: .active
        )
        let session = WaitSession(
            id: sessionID,
            codexSessionID: "legacy-partial",
            codexTurnID: "legacy-partial",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            duration: 120,
            state: .completed,
            activitySegments: [partialSegment],
            classificationResult: .init(
                classification: .productive, reasonCodes: [], reviewSuggested: false
            )
        )
        let reference = start.addingTimeInterval(120)

        let history = WaitHistoryInsights(
            sessions: [session], referenceDate: reference, calendar: calendar
        )
        let reflection = AIInsightSnapshotBuilder.prepare(
            sessions: [session], referenceDate: reference, calendar: calendar, scope: .lastSevenDays
        )
        let priorDay = try #require(history.recentDays.first { $0.startDate == calendar.startOfDay(for: start) })
        let today = try #require(history.recentDays.first { $0.startDate == calendar.startOfDay(for: reference) })
        let reflectionPriorDay = try #require(reflection.payload.days.first { $0.date == "2024-01-08" })
        let reflectionToday = try #require(reflection.payload.days.first { $0.date == "2024-01-09" })

        #expect(priorDay.summary.productiveDuration == 60)
        #expect(today.summary.productiveDuration == 60)
        #expect(reflectionPriorDay.durations.productiveSeconds == 60)
        #expect(reflectionToday.durations.productiveSeconds == 60)
        #expect(priorDay.summary.completedSessionCount == 0)
        #expect(today.summary.completedSessionCount == 1)
        #expect(history.lastSevenDaysSummary.totalCompletedDuration == 120)
    }

    @Test func historyAndReflectionStayInParityAfterManualSliceCorrectionAndReview() throws {
        let fixture = try makeSession()
        let calendar = utcCalendar()
        let reference = fixture.startTime.addingTimeInterval(3_600)

        func values(_ session: WaitSession) throws -> (WaitHistoryInsights.Summary, AIInsightDurations) {
            let history = WaitHistoryInsights(
                sessions: [session], referenceDate: reference, calendar: calendar
            ).lastSevenDaysSummary
            let reflection = AIInsightSnapshotBuilder.prepare(
                sessions: [session], referenceDate: reference, calendar: calendar, scope: .lastSevenDays
            ).payload.durations
            #expect(Int(history.productiveDuration) == reflection.productiveSeconds)
            #expect(Int(history.distractedDuration) == reflection.distractedSeconds)
            #expect(Int(history.unclassifiedDuration) == reflection.unclassifiedSeconds)
            #expect(Int(history.notRecordedDuration) == reflection.notRecordedSeconds)
            #expect(Int(history.totalCompletedDuration) == reflection.productiveSeconds
                + reflection.distractedSeconds + reflection.unclassifiedSeconds + reflection.notRecordedSeconds)
            return (history, reflection)
        }

        let originalValues = try values(fixture)
        var corrected = fixture
        var slices = try #require(corrected.activityClassificationSlices)
        slices[0].manualClassificationOverride = .distracted
        slices[0].classificationReviewHandled = true
        corrected.activityClassificationSlices = slices
        let correctedValues = try values(corrected)
        #expect(correctedValues.0.distractedDuration == originalValues.0.distractedDuration + 120)
        #expect(correctedValues.0.productiveDuration == originalValues.0.productiveDuration - 120)

        for index in slices.indices { slices[index].classificationReviewHandled = true }
        corrected.activityClassificationSlices = slices
        let handledValues = try values(corrected)
        #expect(handledValues == correctedValues)
    }

    @Test func todayClipsCrossMidnightIntervalsAndCountsSessionsByCompletionDate() throws {
        let calendar = manilaCalendar()
        let today = date("2026-03-04 12:00", calendar: calendar)
        let startedYesterday = try durationSession(
            id: "11111111-1111-1111-1111-111111111111",
            start: date("2026-03-03 23:59", calendar: calendar), duration: 120
        )
        let endsTomorrow = try durationSession(
            id: "22222222-2222-2222-2222-222222222222",
            start: date("2026-03-04 23:59", calendar: calendar), duration: 120
        )

        let snapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [startedYesterday, endsTomorrow],
            referenceDate: today,
            calendar: calendar
        )

        #expect(snapshot.payload.durations.productiveSeconds == 120)
        #expect(snapshot.payload.evidence.first { $0.id == "period-summary" }?.durationSeconds == 120)
        #expect(snapshot.payload.days.first?.durations.productiveSeconds == 120)
        // Session counts describe waits completed during the day, not waits
        // whose duration merely overlaps the day.
        #expect(snapshot.payload.completedSessionCount == 1)
        #expect(snapshot.payload.days.first?.completedSessionCount == 1)
    }

    @Test func sevenDaySnapshotClipsBothPeriodBoundariesAndKeepsEmptyDays() throws {
        let calendar = manilaCalendar()
        let reference = date("2026-03-10 12:00", calendar: calendar)
        let crossesStart = try durationSession(
            id: "33333333-3333-3333-3333-333333333333",
            start: date("2026-03-03 23:59", calendar: calendar), duration: 120
        )
        let crossesEnd = try durationSession(
            id: "44444444-4444-4444-4444-444444444444",
            start: date("2026-03-10 23:59", calendar: calendar), duration: 120
        )

        let snapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [crossesStart, crossesEnd],
            referenceDate: reference,
            calendar: calendar,
            scope: .lastSevenDays
        )

        #expect(snapshot.payload.days.map(\.date) == [
            "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07",
            "2026-03-08", "2026-03-09", "2026-03-10"
        ])
        #expect(snapshot.payload.durations.productiveSeconds == 120)
        #expect(snapshot.payload.completedSessionCount == 1)
        #expect(snapshot.payload.days.map(\.durations.productiveSeconds) == [60, 0, 0, 0, 0, 0, 60])
        #expect(snapshot.payload.days.map(\.completedSessionCount) == [1, 0, 0, 0, 0, 0, 0])
        #expect(snapshot.payload.days.filter { $0.durations.productiveSeconds == 0 }.count == 5)
    }

    @Test func dailyEvidenceLinksAndNavigatesToAllContributingWaitsAndSlices() throws {
        let calendar = manilaCalendar()
        let day = date("2026-03-04 12:00", calendar: calendar)
        let first = try slicedSession(
            sessionID: "55555555-5555-5555-5555-555555555555",
            segmentID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            sliceID: "00000000-0000-0000-0000-000000000001",
            start: date("2026-03-04 09:00", calendar: calendar), duration: 60
        )
        let second = try slicedSession(
            sessionID: "66666666-6666-6666-6666-666666666666",
            segmentID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            sliceID: "00000000-0000-0000-0000-000000000002",
            start: date("2026-03-04 10:00", calendar: calendar), duration: 60
        )

        let prepared = AIInsightSnapshotBuilder.prepare(
            sessions: [second, first], referenceDate: day, calendar: calendar
        )
        let summary = try #require(prepared.payload.evidence.first { $0.id == "day-2026-03-04" })
        let link = try #require(prepared.evidenceLinks[summary.id])

        #expect(summary.durationSeconds == 120)
        #expect(link.waitSessionIDs == [first.id, second.id])
        #expect(Set(link.sourceSliceIDs) == Set([
            try #require(first.activityClassificationSlices?.first?.id),
            try #require(second.activityClassificationSlices?.first?.id)
        ]))
        #expect(link.resolvedSessionIDs(availableSessionIDs: [first.id, second.id]) == [first.id, second.id])
        #expect(link.resolvedSessionIDs(availableSessionIDs: [second.id]) == [second.id])
        #expect(link.resolvedSessionIDs(availableSessionIDs: []) == [])
        #expect(AIInsightEvidenceNavigation.controlLabel(evidence: summary, link: link) == "Day · 2 sessions · 2026-03-04")
    }

    @Test func partialCoverageRemainsNotRecordedAndDailyTotalsReconcile() throws {
        let calendar = manilaCalendar()
        let start = date("2026-03-04 09:00", calendar: calendar)
        let id = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let activity = try segment(
            id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
            sessionID: id,
            start: start,
            from: 0,
            to: 60,
            bundle: "com.apple.dt.Xcode",
            app: "Xcode",
            resourceKind: .workspace,
            presence: .active
        )
        let slice = ActivityClassificationSlice(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            sourceActivitySegmentID: activity.id,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt!,
            duration: 60,
            automaticClassificationResult: .init(
                classification: .productive, reasonCodes: [], reviewSuggested: false
            )
        )
        let session = WaitSession(
            id: id,
            codexSessionID: "partial",
            codexTurnID: "partial",
            startTime: start,
            endTime: start.addingTimeInterval(120),
            duration: 120,
            state: .completed,
            activitySegments: [activity],
            activityClassificationSlices: [slice]
        )

        let snapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [session], referenceDate: start, calendar: calendar
        )
        let day = try #require(snapshot.payload.days.first)

        #expect(snapshot.payload.durations.productiveSeconds == 60)
        #expect(snapshot.payload.durations.notRecordedSeconds == 60)
        #expect(snapshot.payload.evidence.first { $0.id == "period-summary" }?.durationSeconds == 120)
        #expect(day.durations.productiveSeconds + day.durations.notRecordedSeconds == 120)
        #expect(snapshot.payload.evidence.first { $0.id == day.id }?.durationSeconds == 120)
    }

    @Test func localCalendarDayUsesDaylightSavingBoundaries() throws {
        let calendar = newYorkCalendar()
        let reference = date("2026-03-08 12:00", calendar: calendar)
        let wait = try durationSession(
            id: "77777777-7777-7777-7777-777777777777",
            start: date("2026-03-08 01:30", calendar: calendar), duration: 3_600
        )

        let snapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [wait], referenceDate: reference, calendar: calendar
        )
        let start = try #require(calendar.dateInterval(of: .day, for: reference)?.start)
        let end = try #require(calendar.dateInterval(of: .day, for: reference)?.end)

        #expect(end.timeIntervalSince(start) == 23 * 60 * 60)
        #expect(snapshot.payload.periodStart == ISO8601DateFormatter().string(from: start))
        #expect(snapshot.payload.periodEnd == ISO8601DateFormatter().string(from: end))
        #expect(snapshot.payload.durations.productiveSeconds == 3_600)
        #expect(snapshot.payload.days.first?.durations.productiveSeconds == 3_600)
    }

    @Test func coordinatorReportsFreshAndCachedInsightGenerations() async throws {
        let fixture = try makeSession()
        let prepared = AIInsightSnapshotBuilder.prepare(
            sessions: [fixture], referenceDate: fixture.startTime, calendar: utcCalendar()
        )
        let provider = SuccessfulInsightProvider()
        let coordinator = AIInsightCoordinator(provider: provider)

        let first = try await coordinator.generation(for: prepared)
        let cached = try await coordinator.generation(for: prepared)
        let refreshed = try await coordinator.generation(for: prepared, forceRefresh: true)

        #expect(first.source == .fresh)
        #expect(cached.source == .cache)
        #expect(refreshed.source == .fresh)
        #expect(await provider.callCount() == 2)
    }

    private func responseData(
        evidenceID: String,
        observation: String = "The focused work block is the clearest sustained pattern."
    ) throws -> Data {
        let types = [
            AIInsightType.strongestFocusBlock,
            .productiveContextSwitch,
            .notableWithinPeriodChange
        ]
        let values: [[String: Any]] = types.map { type in
            [
                "insight_id": "\(type.rawValue)-\(evidenceID)",
                "type": type.rawValue,
                "title": "Evidence-backed pattern",
                "observation": observation,
                "evidence_ids": [evidenceID],
                "confidence": 0.8
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["insights": values])
    }

    private func makeSession(
        browserTitle: String = "Swift concurrency documentation"
    ) throws -> WaitSession {
        let start = Date(timeIntervalSince1970: 1_704_715_200)
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let xcode = try segment(
            id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", sessionID: sessionID,
            start: start, from: 0, to: 120, bundle: "com.apple.dt.Xcode", app: "Xcode",
            resourceKind: .workspace, presence: .active
        )
        let video = try segment(
            id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", sessionID: sessionID,
            start: start, from: 120, to: 180, bundle: "com.google.Chrome", app: "Chrome",
            domain: "youtube.com", title: browserTitle, presence: .active
        )
        let idle = try segment(
            id: "cccccccc-cccc-cccc-cccc-cccccccccccc", sessionID: sessionID,
            start: start, from: 180, to: 240, bundle: "com.openai.chat", app: "ChatGPT",
            presence: .idle
        )
        let classifications: [(ActivitySegment, WaitSessionClassification)] = [
            (xcode, .productive), (video, .distracted), (idle, .unclassified)
        ]
        let slices = classifications.enumerated().map { index, value in
            ActivityClassificationSlice(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                sourceActivitySegmentID: value.0.id,
                startedAt: value.0.startedAt,
                endedAt: value.0.endedAt!,
                duration: value.0.duration!,
                automaticClassificationResult: .init(
                    classification: value.1,
                    reasonCodes: value.1 == .unclassified ? [.meaningfulInactiveTime] : [],
                    reviewSuggested: value.1 == .unclassified
                )
            )
        }
        return WaitSession(
            id: sessionID,
            codexSessionID: "session",
            codexTurnID: "turn",
            startTime: start,
            endTime: start.addingTimeInterval(240),
            duration: 240,
            state: .completed,
            activitySegments: [xcode, video, idle],
            classificationResult: .init(
                classification: .unclassified,
                reasonCodes: [.mixedEvidence],
                reviewSuggested: true
            ),
            activityClassificationSlices: slices
        )
    }

    private func durationSession(id: String, start: Date, duration: TimeInterval) throws -> WaitSession {
        WaitSession(
            id: UUID(uuidString: id)!,
            codexSessionID: id,
            codexTurnID: id,
            startTime: start,
            endTime: start.addingTimeInterval(duration),
            duration: duration,
            state: .completed,
            classificationResult: .init(classification: .productive, reasonCodes: [], reviewSuggested: false)
        )
    }

    private func slicedSession(
        sessionID: String,
        segmentID: String,
        sliceID: String,
        start: Date,
        duration: TimeInterval
    ) throws -> WaitSession {
        let id = UUID(uuidString: sessionID)!
        let activity = try segment(
            id: segmentID,
            sessionID: id,
            start: start,
            from: 0,
            to: duration,
            bundle: "com.apple.dt.Xcode",
            app: "Xcode",
            resourceKind: .workspace,
            presence: .active
        )
        let slice = ActivityClassificationSlice(
            id: UUID(uuidString: sliceID)!,
            sourceActivitySegmentID: activity.id,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt!,
            duration: duration,
            automaticClassificationResult: .init(
                classification: .productive,
                reasonCodes: [],
                reviewSuggested: false
            )
        )
        return WaitSession(
            id: id,
            codexSessionID: sessionID,
            codexTurnID: sessionID,
            startTime: start,
            endTime: start.addingTimeInterval(duration),
            duration: duration,
            state: .completed,
            activitySegments: [activity],
            activityClassificationSlices: [slice]
        )
    }

    private func segment(
        id: String,
        sessionID: UUID,
        start: Date,
        from: TimeInterval,
        to: TimeInterval,
        bundle: String,
        app: String,
        domain: String? = nil,
        title: String? = nil,
        resourceKind: ActivityResourceKind? = nil,
        presence: UserPresenceState
    ) throws -> ActivitySegment {
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: bundle,
            applicationName: app,
            browserDomain: domain,
            browserPageTitle: title,
            resourceKind: resourceKind,
            resourceName: resourceKind == nil ? nil : "/Users/alice/SecretProject",
            presenceState: presence
        ))
        return ActivitySegment(
            id: UUID(uuidString: id)!,
            waitSessionID: sessionID,
            context: context,
            startedAt: start.addingTimeInterval(from),
            endedAt: start.addingTimeInterval(to),
            duration: to - from
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func manilaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        return calendar
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ value: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }
}

private struct FailingInsightProvider: AIInsightProviding {
    func insights(for snapshot: AIInsightAnalysisSnapshot) async throws -> [AIInsight] {
        throw AIInsightError.networkUnavailable
    }
}

private actor SuccessfulInsightProvider: AIInsightProviding {
    private var calls = 0

    func insights(for snapshot: AIInsightAnalysisSnapshot) async throws -> [AIInsight] {
        calls += 1
        let evidenceID = try #require(snapshot.evidence.first { $0.id != "period-summary" }?.id)
        return [
            .strongestFocusBlock,
            .productiveContextSwitch,
            .notableWithinPeriodChange
        ].map { type in
            AIInsight(
                id: "\(type.rawValue)-\(evidenceID)",
                type: type,
                title: "Observed pattern",
                observation: "The linked evidence supports this concise observation.",
                evidenceIDs: [evidenceID],
                suggestion: nil,
                confidence: 0.8
            )
        }
    }

    func callCount() -> Int { calls }
}
