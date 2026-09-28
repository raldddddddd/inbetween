import Foundation
import Testing
@testable import InbetweenCore

struct WaitPresentationSupportTests {
    @Test func historyAndPendingReviewsAreNewestFirst() {
        let older = session(end: 1_100, classification: .unclassified, review: true)
        let newer = session(end: 1_300, classification: .unclassified, review: true)

        #expect(WaitPresentationSupport.completedHistory(from: [newer, older]).map(\.id) == [newer.id, older.id])
        #expect(WaitPresentationSupport.pendingReviews(from: [older, newer]).map(\.id) == [newer.id, older.id])
    }

    @Test func handledReviewDisappearsAndNextReviewAdvances() throws {
        let older = session(end: 1_100, classification: .unclassified, review: true)
        let newer = session(end: 1_300, classification: .unclassified, review: true)
        var tracker = WaitSessionTracker(sessions: [older, newer])

        #expect(WaitPresentationSupport.pendingReviews(from: tracker.sessions).first?.id == newer.id)
        #expect(tracker.markClassificationReviewHandled(for: newer.id) == .updated(newer.id))

        let pending = WaitPresentationSupport.pendingReviews(from: tracker.sessions)
        #expect(pending.count == 1)
        #expect(pending.first?.id == older.id)
    }

    @Test func leavingUnclassifiedKeepsClassificationAndPreventsRepeatReview() {
        let value = session(end: 1_100, classification: .unclassified, review: true)
        var tracker = WaitSessionTracker(sessions: [value])

        _ = tracker.markClassificationReviewHandled(for: value.id)

        #expect(tracker.sessions[0].effectiveClassification == .unclassified)
        #expect(WaitPresentationSupport.pendingReviews(from: tracker.sessions).isEmpty)
    }

    @Test func historyCanExplicitlySetUnclassified() {
        let value = session(end: 1_100, classification: .productive)
        var tracker = WaitSessionTracker(sessions: [value])

        _ = tracker.setManualClassificationOverride(.unclassified, for: value.id)

        #expect(tracker.sessions[0].manualClassificationOverride == .unclassified)
        #expect(tracker.sessions[0].effectiveClassification == .unclassified)
    }

    @Test func contributorAggregationGroupsDomainsAndSortsByDuration() throws {
        let id = UUID()
        var value = session(end: 1_700_000_000, duration: 180, classification: .distracted)
        value.activitySegments = [
            segment(id: id, start: 1_699_999_820, duration: 50, domain: "www.youtube.com", title: "Video one"),
            segment(id: id, start: 1_699_999_870, duration: 40, domain: "youtube.com", title: "Video two"),
            segment(id: id, start: 1_699_999_910, duration: 30, app: "Discord", bundle: "com.discord")
        ]

        let values = WaitHistoryContributorAggregator.contributors(
            from: [value],
            classification: .distracted,
            referenceDate: Date(timeIntervalSince1970: 1_700_000_000),
            calendar: utcCalendar()
        )

        #expect(values.map(\.label) == ["youtube.com", "Other", "Discord"])
        #expect(values.map(\.duration) == [90, 60, 30])
    }

    @Test func correctionMovesContributorsToEffectiveCategory() {
        var value = session(end: 1_700_000_000, duration: 120, classification: .unclassified)
        value.activitySegments = [segment(id: value.id, start: 1_699_999_880, duration: 120, app: "Xcode", bundle: "com.apple.dt.Xcode")]
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = utcCalendar()

        #expect(WaitHistoryContributorAggregator.contributors(from: [value], classification: .productive, referenceDate: reference, calendar: calendar).isEmpty)
        value.manualClassificationOverride = .productive
        #expect(WaitHistoryContributorAggregator.contributors(from: [value], classification: .productive, referenceDate: reference, calendar: calendar).first?.label == "Xcode")
        #expect(WaitHistoryContributorAggregator.contributors(from: [value], classification: .unclassified, referenceDate: reference, calendar: calendar).isEmpty)
    }

    @Test func contributorLabelsPreferProjectDocumentAndApplicationFallbacks() throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let contexts = [
            ActivityContext(applicationBundleIdentifier: "xcode", applicationName: "Xcode", resourceKind: .project, resourceName: "Inbetween", resourcePath: "/tmp/Inbetween.xcodeproj")!,
            ActivityContext(applicationBundleIdentifier: "preview", applicationName: "Preview", documentName: "Roadmap.pdf")!,
            ActivityContext(applicationBundleIdentifier: "messages", applicationName: "Messages")!
        ]
        let value = WaitSession(
            codexSessionID: "s",
            codexTurnID: "t",
            startTime: base,
            endTime: base.addingTimeInterval(60),
            duration: 60,
            state: .completed,
            activitySegments: contexts.enumerated().map { index, context in
                ActivitySegment(waitSessionID: UUID(), context: context, startedAt: base.addingTimeInterval(Double(index * 20)), endedAt: base.addingTimeInterval(Double((index + 1) * 20)), duration: 20)
            },
            classificationResult: .init(classification: .productive, reasonCodes: [])
        )

        #expect(Set(WaitHistoryContributorAggregator.contributors(for: value).map(\.label)) == ["Inbetween", "Roadmap.pdf", "Messages"])
    }

    @Test func reviewExplanationsUseStoredEvidenceConservatively() {
        let mixed = session(end: 1_100, classification: .unclassified, review: true, reasons: [.mixedEvidence])
        let sparse = session(end: 1_100, classification: .unclassified, review: true, reasons: [.insufficientActivityData])

        #expect(WaitPresentationSupport.reviewExplanation(for: mixed) == "Activity was split between productive and distracting evidence.")
        #expect(WaitPresentationSupport.reviewExplanation(for: sparse) == "Not enough activity context was recorded for a confident classification.")
    }

    @Test func compactDurationFormattingIsHumanReadable() {
        #expect(WaitDurationFormat.compact(41) == "41s")
        #expect(WaitDurationFormat.compact(294) == "4m 54s")
        #expect(WaitDurationFormat.compact(4_320) == "1h 12m")
    }

    private func session(
        end: TimeInterval,
        duration: TimeInterval = 120,
        classification: WaitSessionClassification?,
        review: Bool = false,
        reasons: [WaitSessionClassificationReason] = []
    ) -> WaitSession {
        WaitSession(
            codexSessionID: "session",
            codexTurnID: UUID().uuidString,
            startTime: Date(timeIntervalSince1970: end - duration),
            endTime: Date(timeIntervalSince1970: end),
            duration: duration,
            state: .completed,
            classificationResult: classification.map {
                .init(classification: $0, reasonCodes: reasons, reviewSuggested: review)
            }
        )
    }

    private func segment(
        id: UUID,
        start: TimeInterval,
        duration: TimeInterval,
        domain: String? = nil,
        title: String? = nil,
        app: String = "Google Chrome",
        bundle: String = "com.google.Chrome"
    ) -> ActivitySegment {
        let date = Date(timeIntervalSince1970: start)
        let context = ActivityContext(
            applicationBundleIdentifier: bundle,
            applicationName: app,
            browserDomain: domain,
            browserPageTitle: title
        )!
        return ActivitySegment(
            waitSessionID: id,
            context: context,
            startedAt: date,
            endedAt: date.addingTimeInterval(duration),
            duration: duration
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
