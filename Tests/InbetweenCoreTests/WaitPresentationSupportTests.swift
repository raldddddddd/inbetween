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

    @Test func reviewItemsOrderNewestWaitFirstAndActivitiesChronologically() throws {
        let older = slicedReviewSession(start: 1_000, titles: ["First", "Second"])
        let newer = slicedReviewSession(start: 2_000, titles: ["Third"])

        let items = WaitPresentationSupport.pendingReviewItems(from: [older, newer])

        #expect(items.map(\.contextTitle) == ["Third", "First", "Second"])
        #expect(items.map(\.waitSessionID) == [newer.id, older.id, older.id])
    }

    @Test func navigationBrowsesWithoutClassifyingOrMutatingSessions() throws {
        let session = slicedReviewSession(start: 1_000, titles: ["One", "Two", "Three"])
        let items = WaitPresentationSupport.pendingReviewItems(from: [session])
        let original = session

        let secondID = WaitReviewNavigation.adjacentSelectionID(
            from: items[0].id,
            direction: .next,
            in: items
        )
        let firstID = WaitReviewNavigation.adjacentSelectionID(
            from: secondID,
            direction: .previous,
            in: items
        )

        #expect(secondID == items[1].id)
        #expect(firstID == items[0].id)
        #expect(session == original)
        #expect(WaitReviewNavigation.position(of: secondID, in: items)?.current == 2)
        #expect(WaitReviewNavigation.position(of: secondID, in: items)?.total == 3)
    }

    @Test func navigationKeepsPositionAfterCurrentItemIsRemoved() {
        let session = slicedReviewSession(start: 1_000, titles: ["One", "Two", "Three"])
        let items = WaitPresentationSupport.pendingReviewItems(from: [session])

        #expect(WaitReviewNavigation.selectionIDAfterRemoving(items[1].id, from: items) == items[2].id)
        #expect(WaitReviewNavigation.selectionIDAfterRemoving(items[2].id, from: items) == items[1].id)
        #expect(WaitReviewNavigation.selectionIDAfterRemoving(items[0].id, from: [items[0]]) == nil)
    }

    @Test func selectedPositionRemainsStableAfterClassificationRemovesItem() throws {
        let session = slicedReviewSession(start: 1_000, titles: ["One", "Two", "Three"])
        var tracker = WaitSessionTracker(sessions: [session])
        let before = WaitPresentationSupport.pendingReviewItems(from: tracker.sessions)
        let selected = before[1]
        let desiredID = try #require(
            WaitReviewNavigation.selectionIDAfterRemoving(selected.id, from: before)
        )
        guard case let .sliced(unit) = selected.source else {
            Issue.record("Expected a sliced review item")
            return
        }

        _ = tracker.setManualClassificationOverride(
            .productive,
            forSliceIDs: Set(unit.sourceSliceIDs),
            in: unit.waitSessionID
        )
        let after = WaitPresentationSupport.pendingReviewItems(from: tracker.sessions)

        #expect(after.map(\.contextTitle) == ["One", "Three"])
        #expect(WaitReviewNavigation.resolvedSelectionID(preferredID: desiredID, in: after) == after[1].id)
        #expect(WaitReviewNavigation.position(of: desiredID, in: after)?.current == 2)
    }

    @Test func finalReviewHidesPresentationBeforeApplyingResolution() {
        var events: [String] = []

        WaitReviewResolutionOrder.perform(
            isFinalItem: true,
            hidePresentation: { events.append("hide") },
            applyResolution: { events.append("resolve") }
        )

        #expect(events == ["hide", "resolve"])
    }

    @Test func nonfinalReviewAdvancesWithoutHidingPresentation() {
        var events: [String] = []

        WaitReviewResolutionOrder.perform(
            isFinalItem: false,
            hidePresentation: { events.append("hide") },
            applyResolution: { events.append("resolve") }
        )

        #expect(events == ["resolve"])
    }

    @Test func reviewPresentationIncludesCapturedTitleTimesAndAdjacentActivity() throws {
        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        let before = reviewSegment(
            sessionID: sessionID, start: start, offset: 0, duration: 10,
            app: "Xcode", title: "Inbetween"
        )
        let current = reviewSegment(
            sessionID: sessionID, start: start, offset: 10, duration: 20,
            app: "Safari", title: "Swift concurrency – YouTube", domain: "youtube.com",
            pageTitle: "Swift concurrency – YouTube"
        )
        let after = reviewSegment(
            sessionID: sessionID, start: start, offset: 30, duration: 15,
            app: "Notes", title: "Ideas"
        )
        let slices = [
            reviewSlice(before, classification: .productive),
            reviewSlice(current, classification: .unclassified, review: true),
            reviewSlice(after, classification: .productive)
        ]
        let session = WaitSession(
            id: sessionID, codexSessionID: "s", codexTurnID: "t",
            startTime: start, endTime: start.addingTimeInterval(45), duration: 45,
            state: .completed, activitySegments: [before, current, after],
            classificationResult: .init(classification: .unclassified, reasonCodes: [.mixedEvidence], reviewSuggested: true),
            activityClassificationSlices: slices
        )

        let item = try #require(WaitPresentationSupport.pendingReviewItems(from: [session]).first)

        #expect(item.applicationName == "Safari")
        #expect(item.contextTitle == "Swift concurrency – YouTube")
        #expect(item.contextLocation == "youtube.com")
        #expect(item.startedAt == start.addingTimeInterval(10))
        #expect(item.endedAt == start.addingTimeInterval(30))
        #expect(item.duration == 20)
        #expect(item.before?.applicationName == "Xcode")
        #expect(item.before?.contextTitle == "Inbetween")
        #expect(item.after?.applicationName == "Notes")
        #expect(item.after?.contextTitle == "Ideas")
    }

    @Test func reviewPresentationUsesNeutralFallbackForMissingContext() throws {
        var value = session(end: 1_100, classification: .unclassified, review: true)
        value.activitySegments = [segment(
            id: value.id, start: 980, duration: 120,
            app: "Mystery App", bundle: "example.mystery"
        )]

        let item = try #require(WaitPresentationSupport.pendingReviewItems(from: [value]).first)

        #expect(item.applicationName == "Mystery App")
        #expect(item.contextTitle == "Context unavailable")
    }

    @Test func historyCanExplicitlySetUnclassified() {
        let value = session(end: 1_100, classification: .productive)
        var tracker = WaitSessionTracker(sessions: [value])

        _ = tracker.setManualClassificationOverride(.unclassified, for: value.id)

        #expect(tracker.sessions[0].manualClassificationOverride == .unclassified)
        #expect(tracker.sessions[0].effectiveClassification == .unclassified)
    }

    @Test func historyBreakdownOmitsCategoriesThatDisplayAsZeroSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        let value = WaitSession(
            codexSessionID: "session",
            codexTurnID: "turn",
            startTime: start,
            endTime: start.addingTimeInterval(10.8),
            duration: 10.8,
            state: .completed,
            activityClassificationSlices: [
                ActivityClassificationSlice(
                    sourceActivitySegmentID: nil,
                    startedAt: start,
                    endedAt: start.addingTimeInterval(10),
                    duration: 10,
                    automaticClassificationResult: .init(
                        classification: .productive,
                        reasonCodes: []
                    )
                ),
                ActivityClassificationSlice(
                    sourceActivitySegmentID: nil,
                    startedAt: start.addingTimeInterval(10),
                    endedAt: start.addingTimeInterval(10.8),
                    duration: 0.8,
                    automaticClassificationResult: .init(
                        classification: .unclassified,
                        reasonCodes: [.insufficientActivityData]
                    )
                )
            ]
        )

        #expect(WaitPresentationSupport.historyDurationBreakdown(for: value) == "10s Productive")
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

    private func slicedReviewSession(start: TimeInterval, titles: [String]) -> WaitSession {
        let sessionID = UUID()
        let date = Date(timeIntervalSince1970: start)
        let segments = titles.enumerated().map { index, title in
            reviewSegment(
                sessionID: sessionID,
                start: date,
                offset: TimeInterval(index * 10),
                duration: 10,
                app: "Safari",
                title: title,
                domain: "example.com",
                pageTitle: title
            )
        }
        let slices = segments.map { reviewSlice($0, classification: .unclassified, review: true) }
        return WaitSession(
            id: sessionID,
            codexSessionID: "session",
            codexTurnID: UUID().uuidString,
            startTime: date,
            endTime: date.addingTimeInterval(TimeInterval(titles.count * 10)),
            duration: TimeInterval(titles.count * 10),
            state: .completed,
            activitySegments: segments,
            classificationResult: .init(
                classification: .unclassified,
                reasonCodes: [.contextDependentActivity],
                reviewSuggested: true
            ),
            activityClassificationSlices: slices
        )
    }

    private func reviewSegment(
        sessionID: UUID,
        start: Date,
        offset: TimeInterval,
        duration: TimeInterval,
        app: String,
        title: String?,
        domain: String? = nil,
        pageTitle: String? = nil
    ) -> ActivitySegment {
        ActivitySegment(
            waitSessionID: sessionID,
            context: ActivityContext(
                applicationBundleIdentifier: "test.\(app.lowercased())",
                applicationName: app,
                windowTitle: title,
                browserDomain: domain,
                browserPageTitle: pageTitle,
                presenceState: .active
            )!,
            startedAt: start.addingTimeInterval(offset),
            endedAt: start.addingTimeInterval(offset + duration),
            duration: duration
        )
    }

    private func reviewSlice(
        _ segment: ActivitySegment,
        classification: WaitSessionClassification,
        review: Bool = false
    ) -> ActivityClassificationSlice {
        ActivityClassificationSlice(
            sourceActivitySegmentID: segment.id,
            startedAt: segment.startedAt,
            endedAt: segment.endedAt!,
            duration: segment.duration!,
            automaticClassificationResult: .init(
                classification: classification,
                reasonCodes: classification == .unclassified ? [.contextDependentActivity] : [],
                reviewSuggested: review
            )
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
