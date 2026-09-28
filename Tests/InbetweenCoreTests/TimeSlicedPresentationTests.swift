import Foundation
import Testing
@testable import InbetweenCore

struct TimeSlicedPresentationTests {
    @Test func reviewGroupingSeparatesPresenceAndGroupsEquivalentNoncontiguousSlices() throws {
        let session = reviewSession()
        let units = WaitPresentationSupport.pendingReviewUnits(from: [session])

        #expect(units.count == 3)
        let active = try #require(units.first { $0.presenceState == .active })
        let idle = try #require(units.first { $0.presenceState == .idle })
        let away = try #require(units.first { $0.presenceState == .away })
        #expect(active.sourceSliceIDs.count == 2)
        #expect(active.totalDuration == 30)
        #expect(active.activeDuration == 30)
        #expect(idle.totalDuration == 20)
        #expect(idle.idleDuration == 20)
        #expect(away.totalDuration == 10)
        #expect(away.awayDuration == 10)
        #expect(Set(units.map(\.label)) == ["chatgpt.com"])
        #expect(units.allSatisfy { $0.subtitle == "Understanding Swift actors" })
    }

    @Test func correctionsAndLeaveUnclassifiedAreScopedToSelectedPresenceUnit() throws {
        var tracker = WaitSessionTracker(sessions: [reviewSession()])
        let original = tracker.sessions[0]
        let units = WaitPresentationSupport.pendingReviewUnits(from: tracker.sessions)
        let active = try #require(units.first { $0.presenceState == .active })
        let idle = try #require(units.first { $0.presenceState == .idle })

        #expect(tracker.setManualClassificationOverride(
            .productive,
            forSliceIDs: Set(active.sourceSliceIDs),
            in: original.id
        ) == .updated(original.id))
        var slices = try #require(tracker.sessions[0].activityClassificationSlices)
        #expect(slices.filter { active.sourceSliceIDs.contains($0.id) }.allSatisfy {
            $0.effectiveClassification == .productive && $0.classificationReviewHandled
        })
        #expect(slices.filter { idle.sourceSliceIDs.contains($0.id) }.allSatisfy {
            $0.effectiveClassification == .unclassified && !$0.classificationReviewHandled
        })

        #expect(tracker.markClassificationReviewHandled(
            forSliceIDs: Set(idle.sourceSliceIDs),
            in: original.id
        ) == .updated(original.id))
        slices = try #require(tracker.sessions[0].activityClassificationSlices)
        #expect(slices.filter { idle.sourceSliceIDs.contains($0.id) }.allSatisfy {
            $0.effectiveClassification == .unclassified && $0.classificationReviewHandled
        })
        #expect(WaitPresentationSupport.pendingReviewUnits(from: tracker.sessions).map(\.presenceState) == [.away])

        #expect(tracker.setManualClassificationOverride(
            nil,
            forSliceIDs: Set(active.sourceSliceIDs),
            in: original.id
        ) == .updated(original.id))
        let pending = WaitPresentationSupport.pendingReviewUnits(from: tracker.sessions)
        #expect(Set(pending.map(\.presenceState)) == [.active, .away])
    }

    @Test func gapsNeverProduceReviewUnits() {
        let session = reviewSession(includeGap: true)
        let units = WaitPresentationSupport.pendingReviewUnits(from: [session])
        #expect(units.count == 3)
        #expect(units.flatMap(\.sourceSliceIDs).count == 4)
        #expect(units.allSatisfy { !$0.sourceSliceIDs.isEmpty })
    }

    @Test func mixedSliceDurationsDriveDashboardAndScopedCorrection() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = classifiedSession(start: start)
        var values = WaitHistoryInsights.classificationDurations(for: session)
        #expect(values.productive == 20)
        #expect(values.distracted == 15)
        #expect(values.unclassified == 25)
        #expect(values.total == 60)

        let insights = WaitHistoryInsights(
            sessions: [session],
            referenceDate: start.addingTimeInterval(60),
            calendar: utcCalendar()
        )
        #expect(insights.summary.productiveDuration == 20)
        #expect(insights.summary.distractedDuration == 15)
        #expect(insights.summary.unclassifiedDuration == 25)

        var tracker = WaitSessionTracker(sessions: [session])
        let unclassified = try #require(
            WaitPresentationSupport.pendingReviewUnits(from: tracker.sessions).first
        )
        _ = tracker.setManualClassificationOverride(
            .productive,
            forSliceIDs: Set(unclassified.sourceSliceIDs),
            in: session.id
        )
        values = WaitHistoryInsights.classificationDurations(for: tracker.sessions[0])
        #expect(values.productive == 30)
        #expect(values.distracted == 15)
        #expect(values.unclassified == 15) // unobserved gap remains unchanged
    }

    @Test func contributorsUseExactSliceUUIDAndEffectiveSliceDuration() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var session = classifiedSession(start: start)
        var slices = try #require(session.activityClassificationSlices)
        slices[0].manualClassificationOverride = .distracted
        session.activityClassificationSlices = slices
        let reference = start.addingTimeInterval(60)

        let distracted = WaitHistoryContributorAggregator.contributors(
            from: [session], classification: .distracted,
            referenceDate: reference, calendar: utcCalendar()
        )
        #expect(distracted.first { $0.label == "Xcode" }?.duration == 20)
        #expect(distracted.first { $0.label == "Steam" }?.duration == 15)
        #expect(distracted.reduce(0) { $0 + $1.duration } == 35)

        // A slice with no exact UUID match must become Other, even when another
        // segment has identical metadata and timestamps.
        let unmatched = ActivityClassificationSlice(
            sourceActivitySegmentID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(7),
            duration: 7,
            automaticClassificationResult: result(.productive)
        )
        session.activityClassificationSlices = [unmatched]
        let exactJoin = WaitHistoryContributorAggregator.contributors(
            from: [session], classification: .productive,
            referenceDate: reference, calendar: utcCalendar()
        )
        #expect(exactJoin == [.init(id: "other", label: "Other", duration: 7, isOther: true)])
    }

    @Test func historyBreakdownIsMixedWhileLegacyKeepsWholeWaitFallback() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sliced = classifiedSession(start: start)
        #expect(WaitPresentationSupport.historyDurationBreakdown(for: sliced)
            == "20s Productive · 15s Distracted · 25s Unclassified")

        let legacy = WaitSession(
            codexSessionID: "legacy", codexTurnID: "legacy",
            startTime: start, endTime: start.addingTimeInterval(60),
            duration: 60, state: .completed,
            classificationResult: result(.productive)
        )
        #expect(WaitPresentationSupport.historyDurationBreakdown(for: legacy) == nil)
        #expect(WaitHistoryInsights.classificationDurations(for: legacy).productive == 60)
        var tracker = WaitSessionTracker(sessions: [sliced, legacy])
        #expect(tracker.setManualClassificationOverride(.distracted, for: sliced.id) == .ignored)
        #expect(tracker.setManualClassificationOverride(.distracted, for: legacy.id) == .updated(legacy.id))
    }

    private func reviewSession(includeGap: Bool = false) -> WaitSession {
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        let contexts: [(UserPresenceState, TimeInterval, TimeInterval)] = [
            (.active, 0, 10), (.idle, 10, 30), (.active, 30, 50), (.away, 50, 60)
        ]
        let segments = contexts.map { presence, offset, end in
            ActivitySegment(
                waitSessionID: sessionID,
                context: ActivityContext(
                    applicationBundleIdentifier: "com.openai.chat",
                    applicationName: "ChatGPT",
                    browserDomain: "chatgpt.com",
                    browserPageTitle: "Understanding Swift actors",
                    presenceState: presence
                )!,
                startedAt: start.addingTimeInterval(offset),
                endedAt: start.addingTimeInterval(end),
                duration: end - offset
            )
        }
        var slices = segments.map { segment in
            ActivityClassificationSlice(
                sourceActivitySegmentID: segment.id,
                startedAt: segment.startedAt,
                endedAt: segment.endedAt!,
                duration: segment.duration!,
                automaticClassificationResult: result(
                    .unclassified,
                    reasons: segment.context.presenceState == .active
                        ? [.contextDependentActivity, .noStrongEvidence]
                        : [.meaningfulInactiveTime, .noStrongEvidence],
                    review: true
                )
            )
        }
        if includeGap {
            slices.append(ActivityClassificationSlice(
                sourceActivitySegmentID: nil,
                startedAt: start.addingTimeInterval(60),
                endedAt: start.addingTimeInterval(65),
                duration: 5,
                automaticClassificationResult: result(
                    .unclassified, reasons: [.unobservedGap], review: true
                )
            ))
        }
        let duration: TimeInterval = includeGap ? 65 : 60
        return WaitSession(
            id: sessionID, codexSessionID: "s", codexTurnID: "t",
            startTime: start, endTime: start.addingTimeInterval(duration),
            duration: duration, state: .completed,
            activitySegments: segments,
            classificationResult: result(.unclassified, reasons: [.mixedEvidence], review: true),
            activityClassificationSlices: slices
        )
    }

    private func classifiedSession(start: Date) -> WaitSession {
        let sessionID = UUID()
        let xcode = segment(sessionID, start, 0, 20, "com.apple.dt.Xcode", "Xcode", .active)
        let steam = segment(sessionID, start, 20, 35, "com.valvesoftware.steam", "Steam", .active)
        let idle = segment(sessionID, start, 35, 45, "com.openai.chat", "ChatGPT", .idle)
        let slices = [
            slice(xcode, .productive),
            slice(steam, .distracted),
            slice(idle, .unclassified, review: true),
            ActivityClassificationSlice(
                sourceActivitySegmentID: nil,
                startedAt: start.addingTimeInterval(45),
                endedAt: start.addingTimeInterval(60),
                duration: 15,
                automaticClassificationResult: result(.unclassified, reasons: [.unobservedGap])
            )
        ]
        return WaitSession(
            id: sessionID, codexSessionID: "mixed", codexTurnID: "mixed",
            startTime: start, endTime: start.addingTimeInterval(60), duration: 60,
            state: .completed, activitySegments: [xcode, steam, idle],
            classificationResult: result(.unclassified, reasons: [.mixedEvidence], review: true),
            activityClassificationSlices: slices
        )
    }

    private func segment(
        _ waitID: UUID, _ start: Date, _ from: TimeInterval, _ to: TimeInterval,
        _ bundle: String, _ app: String, _ presence: UserPresenceState
    ) -> ActivitySegment {
        ActivitySegment(
            waitSessionID: waitID,
            context: ActivityContext(
                applicationBundleIdentifier: bundle,
                applicationName: app,
                presenceState: presence
            )!,
            startedAt: start.addingTimeInterval(from),
            endedAt: start.addingTimeInterval(to),
            duration: to - from
        )
    }

    private func slice(
        _ segment: ActivitySegment,
        _ classification: WaitSessionClassification,
        review: Bool = false
    ) -> ActivityClassificationSlice {
        ActivityClassificationSlice(
            sourceActivitySegmentID: segment.id,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt!,
            duration: segment.duration!,
            automaticClassificationResult: result(
                classification,
                reasons: classification == .unclassified ? [.meaningfulInactiveTime] : [],
                review: review
            )
        )
    }

    private static func result(
        _ classification: WaitSessionClassification,
        reasons: [WaitSessionClassificationReason] = [],
        review: Bool = false
    ) -> WaitSessionClassificationResult {
        .init(classification: classification, reasonCodes: reasons, reviewSuggested: review)
    }

    private func result(
        _ classification: WaitSessionClassification,
        reasons: [WaitSessionClassificationReason] = [],
        review: Bool = false
    ) -> WaitSessionClassificationResult {
        Self.result(classification, reasons: reasons, review: review)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
