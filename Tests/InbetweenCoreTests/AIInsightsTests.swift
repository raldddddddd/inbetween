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

        #expect(link.waitSessionID == fixture.id)
        #expect(Set(link.sourceSliceIDs) == productiveSliceIDs)
        #expect(link.startedAt == fixture.startTime)
        #expect(link.endedAt == fixture.startTime.addingTimeInterval(120))
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
