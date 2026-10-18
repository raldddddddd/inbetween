import Foundation

public struct WaitClassificationReviewUnit: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceSliceIDs: [UUID]
    public let waitSessionID: UUID
    public let context: ActivityContext
    public let label: String
    public let subtitle: String?
    public let totalDuration: TimeInterval
    public let presenceState: UserPresenceState?
    public let activeDuration: TimeInterval
    public let idleDuration: TimeInterval
    public let awayDuration: TimeInterval
    public let automaticReason: String
    public let effectiveClassification: WaitSessionClassification?

    public init(
        id: String,
        sourceSliceIDs: [UUID],
        waitSessionID: UUID,
        context: ActivityContext,
        label: String,
        subtitle: String?,
        totalDuration: TimeInterval,
        presenceState: UserPresenceState?,
        activeDuration: TimeInterval,
        idleDuration: TimeInterval,
        awayDuration: TimeInterval,
        automaticReason: String,
        effectiveClassification: WaitSessionClassification?
    ) {
        self.id = id
        self.sourceSliceIDs = sourceSliceIDs
        self.waitSessionID = waitSessionID
        self.context = context
        self.label = label
        self.subtitle = subtitle
        self.totalDuration = totalDuration
        self.presenceState = presenceState
        self.activeDuration = activeDuration
        self.idleDuration = idleDuration
        self.awayDuration = awayDuration
        self.automaticReason = automaticReason
        self.effectiveClassification = effectiveClassification
    }
}

public struct WaitReviewActivityContext: Equatable, Sendable {
    public let applicationName: String
    public let contextTitle: String
    public let startedAt: Date
    public let endedAt: Date
    public let duration: TimeInterval

    public init(
        applicationName: String,
        contextTitle: String,
        startedAt: Date,
        endedAt: Date,
        duration: TimeInterval
    ) {
        self.applicationName = applicationName
        self.contextTitle = contextTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
    }
}

public enum WaitReviewItemSource: Equatable, Sendable {
    case sliced(WaitClassificationReviewUnit)
    case legacy(sessionID: UUID)
}

/// A read-only projection of one unresolved review choice. It deliberately
/// keeps navigation and display metadata separate from persisted classification.
public struct WaitReviewItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let source: WaitReviewItemSource
    public let waitSessionID: UUID
    public let applicationName: String
    public let contextTitle: String
    public let contextLocation: String?
    public let startedAt: Date
    public let endedAt: Date
    public let duration: TimeInterval
    public let explanation: String
    public let before: WaitReviewActivityContext?
    public let after: WaitReviewActivityContext?

    public var effectiveLocalClassification: WaitSessionClassification {
        switch source {
        case let .sliced(unit): unit.effectiveClassification ?? .unclassified
        case .legacy: .unclassified
        }
    }
}

public enum WaitReviewNavigation {
    public enum Direction: Sendable {
        case previous
        case next
    }

    public static func resolvedSelectionID(
        preferredID: String?,
        in items: [WaitReviewItem]
    ) -> String? {
        guard !items.isEmpty else { return nil }
        if let preferredID, items.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        return items[0].id
    }

    public static func adjacentSelectionID(
        from selectedID: String?,
        direction: Direction,
        in items: [WaitReviewItem]
    ) -> String? {
        guard let resolved = resolvedSelectionID(preferredID: selectedID, in: items),
              let index = items.firstIndex(where: { $0.id == resolved })
        else { return nil }
        switch direction {
        case .previous:
            return index > items.startIndex ? items[items.index(before: index)].id : resolved
        case .next:
            return index < items.index(before: items.endIndex)
                ? items[items.index(after: index)].id
                : resolved
        }
    }

    /// Keep the same numeric position when possible; when the final item is
    /// removed, select the new final item instead.
    public static func selectionIDAfterRemoving(
        _ selectedID: String,
        from items: [WaitReviewItem]
    ) -> String? {
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else {
            return resolvedSelectionID(preferredID: selectedID, in: items)
        }
        let remaining = items.filter { $0.id != selectedID }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)].id
    }

    public static func position(
        of selectedID: String?,
        in items: [WaitReviewItem]
    ) -> (current: Int, total: Int)? {
        guard let resolved = resolvedSelectionID(preferredID: selectedID, in: items),
              let index = items.firstIndex(where: { $0.id == resolved })
        else { return nil }
        return (index + 1, items.count)
    }
}

/// Keeps the menu-bar window at its current size while the final review action
/// is applied. Hiding first prevents SwiftUI from shrinking the visible window
/// away from its menu-bar anchor as the last review card disappears.
public enum WaitReviewResolutionOrder {
    public static func perform(
        isFinalItem: Bool,
        hidePresentation: () -> Void,
        applyResolution: () -> Void
    ) {
        if isFinalItem {
            hidePresentation()
        }
        applyResolution()
    }
}

/// Small, derived presentation helpers for completed wait history.
///
/// Nothing in this file is persisted and no historical session is reclassified.
public enum WaitPresentationSupport {
    public static func completedHistory(from sessions: [WaitSession]) -> [WaitSession] {
        sessions
            .filter { $0.state == .completed }
            .sorted(by: newestCompletedFirst)
    }

    public static func pendingReviews(from sessions: [WaitSession]) -> [WaitSession] {
        sessions
            .filter { $0.activityClassificationSlices == nil && $0.shouldRequestClassificationReview }
            .sorted(by: newestCompletedFirst)
    }

    public static func pendingReviewUnits(
        from sessions: [WaitSession]
    ) -> [WaitClassificationReviewUnit] {
        completedHistory(from: sessions).flatMap { classificationUnits(for: $0, pendingOnly: true) }
    }

    public static func pendingReviewItems(from sessions: [WaitSession]) -> [WaitReviewItem] {
        completedHistory(from: sessions).flatMap { session in
            if session.activityClassificationSlices != nil {
                return classificationUnits(for: session, pendingOnly: true).map {
                    reviewItem(for: $0, in: session)
                }
            }
            guard session.shouldRequestClassificationReview else { return [] }
            return [legacyReviewItem(for: session)]
        }
    }

    /// Derived from persisted slices and their exact source-segment UUIDs. The
    /// identity deliberately includes presence, so Active/Idle/Away never merge.
    public static func classificationUnits(
        for session: WaitSession,
        pendingOnly: Bool = false
    ) -> [WaitClassificationReviewUnit] {
        guard let slices = session.activityClassificationSlices else { return [] }
        let segmentsByID = Dictionary(uniqueKeysWithValues: session.activitySegments.map { ($0.id, $0) })
        var order: [ReviewIdentity] = []
        var groups: [ReviewIdentity: MutableReviewUnit] = [:]

        for slice in slices.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard !slice.isUnobservedGap,
                  let sourceID = slice.sourceActivitySegmentID,
                  let segment = segmentsByID[sourceID]
            else { continue }
            let presence = segment.context.presenceState
            if pendingOnly {
                guard slice.effectiveClassification == .unclassified,
                      slice.manualClassificationOverride == nil,
                      !slice.classificationReviewHandled
                else { continue }
            }
            let identity = ReviewIdentity(context: segment.context, presence: presence)
            if groups[identity] == nil {
                order.append(identity)
                groups[identity] = MutableReviewUnit(
                    sessionID: session.id,
                    context: segment.context,
                    presence: presence
                )
            }
            groups[identity]?.append(slice)
        }

        return order.compactMap { groups[$0]?.value }
    }

    public static func historyDurationBreakdown(for session: WaitSession) -> String? {
        guard session.activityClassificationSlices != nil else { return nil }
        let values = WaitHistoryInsights.classificationDurations(for: session)
        var parts: [String] = []
        if values.productive >= 1 { parts.append("\(WaitDurationFormat.compact(values.productive)) Productive") }
        if values.distracted >= 1 { parts.append("\(WaitDurationFormat.compact(values.distracted)) Distracted") }
        if values.unclassified >= 1 { parts.append("\(WaitDurationFormat.compact(values.unclassified)) Unclassified") }
        return parts.joined(separator: " · ")
    }

    /// Duration explicitly represented by nil-source classification slices.
    /// Nil means the session uses the older model and has no persisted gap map.
    public static func unobservedDuration(for session: WaitSession) -> TimeInterval? {
        guard let slices = session.activityClassificationSlices else { return nil }
        return slices.filter(\.isUnobservedGap).reduce(0) { $0 + max(0, $1.duration) }
    }

    public static func completionDate(for session: WaitSession) -> Date {
        session.endTime
            ?? session.duration.map { session.startTime.addingTimeInterval($0) }
            ?? session.startTime
    }

    public static func strongestContextLabel(for session: WaitSession) -> String? {
        WaitHistoryContributorAggregator.contributors(for: session)
            .first(where: { !$0.isOther })?
            .label
    }

    public static func reviewExplanation(for session: WaitSession) -> String {
        let reasons = session.classificationResult?.reasonCodes ?? []
        if reasons.contains(.deterministicFallback) {
            if reasons.contains(.mixedEvidence),
               let classification = session.classificationResult?.classification {
                return "Mixed activity was summarized as \(classification.title) by observed duration; ties resolve to Distracted."
            }
            return "The available activity context did not establish Productive activity, so Distracted was chosen as the deterministic fallback."
        }
        if reasons.contains(.mixedEvidence) {
            return "Activity was split between productive and distracting evidence."
        }

        if reasons.contains(.meaningfulInactiveTime) {
            let away = session.activitySegments.reduce(0) { partial, segment in
                guard segment.context.presenceState == .away else { return partial }
                return partial + max(0, segment.duration ?? 0)
            }
            let total = max(0, session.duration ?? 0)
            if away > 0, total > 0, away >= total / 2 {
                return "Most of this wait was spent away from the Mac."
            }
            if away > 0 {
                return "Activity included \(WaitDurationFormat.compact(away)) away from the Mac."
            }
        }

        if reasons.contains(.semanticEmbeddingUnavailable) {
            return "The local sentence embedding could not score this activity."
        }
        if reasons.contains(.insufficientSemanticConfidence) {
            return "The local semantic match did not meet its confidence threshold."
        }
        if reasons.contains(.neutralSemanticCandidate) {
            return "The strongest local semantic candidate was neutral."
        }
        if reasons.contains(.semanticContextUnavailable) {
            return "No meaningful local activity metadata were available for semantic classification."
        }

        if reasons.contains(.contextDependentActivity) {
            if let domain = strongestDomain(in: session) {
                return "Browser activity on \(domain) did not contain enough context for a confident classification."
            }
            if let context = strongestContextLabel(for: session) {
                return "Activity in \(context) did not contain enough context for a confident classification."
            }
        }

        if reasons.contains(.insufficientActivityData) {
            return "Not enough activity context was recorded for a confident classification."
        }

        return session.classificationResult?.explanation
            ?? "Inbetween could not confidently classify this wait from the recorded activity context."
    }

    public static func contextTitle(for context: ActivityContext) -> String {
        let isBrowserContext = context.browserPageTitle != nil
            || context.browserDomain != nil
            || context.browserURL != nil
        let candidates = isBrowserContext
            ? [
                context.browserPageTitle,
                context.windowTitle,
                context.documentName,
                context.resourceName,
                context.browserDomain,
                context.browserURL
            ]
            : [
                context.resourceName,
                context.documentName,
                context.windowTitle,
                context.resourcePath
            ]
        return candidates.compactMap { $0 }.first ?? "Context unavailable"
    }

    private static func reviewItem(
        for unit: WaitClassificationReviewUnit,
        in session: WaitSession
    ) -> WaitReviewItem {
        let slices = (session.activityClassificationSlices ?? []).filter {
            unit.sourceSliceIDs.contains($0.id)
        }
        let startedAt = slices.map(\.startedAt).min() ?? session.startTime
        let endedAt = slices.map(\.endedAt).max()
            ?? startedAt.addingTimeInterval(unit.totalDuration)
        let surrounding = surroundingActivity(
            sourceSegmentIDs: Set(slices.compactMap(\.sourceActivitySegmentID)),
            in: session.activitySegments
        )
        return WaitReviewItem(
            id: "slice:\(unit.id)",
            source: .sliced(unit),
            waitSessionID: session.id,
            applicationName: unit.context.applicationName,
            contextTitle: contextTitle(for: unit.context),
            contextLocation: contextLocation(for: unit.context),
            startedAt: startedAt,
            endedAt: endedAt,
            duration: unit.totalDuration,
            explanation: unit.automaticReason,
            before: surrounding.before,
            after: surrounding.after
        )
    }

    private static func legacyReviewItem(for session: WaitSession) -> WaitReviewItem {
        let ordered = session.activitySegments.sorted(by: activityStartsFirst)
        let representative = ordered.enumerated().max { lhs, rhs in
            let left = max(0, lhs.element.duration ?? 0)
            let right = max(0, rhs.element.duration ?? 0)
            if left != right { return left < right }
            return lhs.offset > rhs.offset
        }
        let context = representative?.element.context
        let before = representative.flatMap { value in
            value.offset > ordered.startIndex ? activityContext(ordered[value.offset - 1]) : nil
        }
        let after = representative.flatMap { value in
            value.offset < ordered.count - 1 ? activityContext(ordered[value.offset + 1]) : nil
        }
        let endedAt = session.endTime
            ?? session.duration.map { session.startTime.addingTimeInterval($0) }
            ?? session.startTime
        return WaitReviewItem(
            id: "legacy:\(session.id.uuidString)",
            source: .legacy(sessionID: session.id),
            waitSessionID: session.id,
            applicationName: context?.applicationName ?? "Activity unavailable",
            contextTitle: context.map(contextTitle(for:)) ?? "Context unavailable",
            contextLocation: context.flatMap(contextLocation(for:)),
            startedAt: session.startTime,
            endedAt: endedAt,
            duration: max(0, session.duration ?? endedAt.timeIntervalSince(session.startTime)),
            explanation: reviewExplanation(for: session),
            before: before,
            after: after
        )
    }

    private static func surroundingActivity(
        sourceSegmentIDs: Set<UUID>,
        in segments: [ActivitySegment]
    ) -> (before: WaitReviewActivityContext?, after: WaitReviewActivityContext?) {
        let ordered = segments.sorted(by: activityStartsFirst)
        let indices = ordered.indices.filter { sourceSegmentIDs.contains(ordered[$0].id) }
        guard let first = indices.first, let last = indices.last else { return (nil, nil) }
        let before = first > ordered.startIndex ? activityContext(ordered[first - 1]) : nil
        let after = last < ordered.count - 1 ? activityContext(ordered[last + 1]) : nil
        return (before, after)
    }

    private static func activityContext(_ segment: ActivitySegment) -> WaitReviewActivityContext {
        let endedAt = segment.endedAt
            ?? segment.duration.map { segment.startedAt.addingTimeInterval($0) }
            ?? segment.startedAt
        return WaitReviewActivityContext(
            applicationName: segment.context.applicationName,
            contextTitle: contextTitle(for: segment.context),
            startedAt: segment.startedAt,
            endedAt: endedAt,
            duration: max(0, segment.duration ?? endedAt.timeIntervalSince(segment.startedAt))
        )
    }

    private static func activityStartsFirst(_ lhs: ActivitySegment, _ rhs: ActivitySegment) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func contextLocation(for context: ActivityContext) -> String? {
        let title = contextTitle(for: context)
        return [context.browserDomain, context.resourceName, context.documentName]
            .compactMap { $0 }
            .first { $0.caseInsensitiveCompare(title) != .orderedSame }
    }

    private static func newestCompletedFirst(_ lhs: WaitSession, _ rhs: WaitSession) -> Bool {
        let lhsDate = completionDate(for: lhs)
        let rhsDate = completionDate(for: rhs)
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        if lhs.startTime != rhs.startTime { return lhs.startTime > rhs.startTime }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func strongestDomain(in session: WaitSession) -> String? {
        var durations: [String: TimeInterval] = [:]
        for segment in session.activitySegments {
            guard let domain = segment.context.browserDomain else { continue }
            let normalized = WaitHistoryContributorAggregator.normalizedDomain(domain)
            durations[normalized, default: 0] += max(0, segment.duration ?? 0)
        }
        return durations.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }.first?.key
    }

    private struct ReviewIdentity: Hashable {
        let bundle: String
        let applicationName: String
        let windowTitle: String?
        let domain: String?
        let pageTitle: String?
        let browserURL: String?
        let resourceKind: String?
        let resourceName: String?
        let documentName: String?
        let resourcePath: String?
        let presence: UserPresenceState?

        init(context: ActivityContext, presence: UserPresenceState?) {
            bundle = BuiltInActivityEvidencePolicy.canonicalBundleIdentifier(
                context.applicationBundleIdentifier
            )
            applicationName = context.applicationName
            windowTitle = context.windowTitle
            domain = context.browserDomain.map(WaitHistoryContributorAggregator.normalizedDomain)
            pageTitle = context.browserPageTitle
            browserURL = Self.meaningfulBrowserLocation(context.browserURL)
            resourceKind = context.resourceKind?.rawValue
            resourceName = context.resourceName
            documentName = context.documentName
            resourcePath = context.resourcePath
            self.presence = presence
        }

        private static func meaningfulBrowserLocation(_ value: String?) -> String? {
            guard let value, var components = URLComponents(string: value) else { return nil }
            components.query = nil
            components.fragment = nil
            return components.string
        }
    }

    private struct MutableReviewUnit {
        let sessionID: UUID
        let context: ActivityContext
        let presence: UserPresenceState?
        var slices: [ActivityClassificationSlice] = []

        mutating func append(_ slice: ActivityClassificationSlice) { slices.append(slice) }

        var value: WaitClassificationReviewUnit {
            let ids = slices.map(\.id)
            let duration = slices.reduce(0) { $0 + max(0, $1.duration) }
            let effective = Set(slices.map(\.effectiveClassification))
            return WaitClassificationReviewUnit(
                id: "\(sessionID.uuidString):\(presence?.rawValue ?? "unknown"):\(ids.map(\.uuidString).joined(separator: ","))",
                sourceSliceIDs: ids,
                waitSessionID: sessionID,
                context: context,
                label: Self.label(for: context),
                subtitle: Self.subtitle(for: context),
                totalDuration: duration,
                presenceState: presence,
                activeDuration: presence == .active ? duration : 0,
                idleDuration: presence == .idle ? duration : 0,
                awayDuration: presence == .away ? duration : 0,
                automaticReason: reason,
                effectiveClassification: effective.count == 1 ? effective.first : nil
            )
        }

        private static func subtitle(for context: ActivityContext) -> String? {
            let candidates = [
                context.browserPageTitle,
                context.documentName,
                context.windowTitle,
                context.resourcePath,
                context.applicationName
            ]
            return candidates.compactMap { $0 }.first {
                $0.caseInsensitiveCompare(label(for: context)) != .orderedSame
            }
        }

        private static func label(for context: ActivityContext) -> String {
            if let resourceName = context.resourceName { return resourceName }
            if let domain = context.browserDomain {
                return WaitHistoryContributorAggregator.normalizedDomain(domain)
            }
            if let documentName = context.documentName { return documentName }
            return context.applicationName
        }

        private var reason: String {
            let reasons = slices.flatMap(\.automaticClassificationResult.reasonCodes)
            if reasons.contains(.deterministicFallback) {
                return "The available activity context did not establish Productive activity, so Distracted was chosen as the deterministic fallback."
            }
            if reasons.contains(.meaningfulInactiveTime) {
                let state = presence?.rawValue ?? "unknown-presence"
                return "Foreground context cannot classify \(state) time."
            }
            if reasons.contains(.semanticEmbeddingUnavailable) {
                return "The local sentence embedding could not score this activity."
            }
            if reasons.contains(.insufficientSemanticConfidence) {
                return "The local semantic match did not meet its confidence threshold."
            }
            if reasons.contains(.neutralSemanticCandidate) {
                return "The strongest local semantic candidate was neutral."
            }
            if reasons.contains(.semanticContextUnavailable) {
                return "No meaningful local activity metadata were available for semantic classification."
            }
            if reasons.contains(.contextDependentActivity) {
                return "The recorded context is genuinely context-dependent."
            }
            if reasons.contains(.mixedEvidence) {
                return "The automatic evidence was mixed."
            }
            return slices.first?.automaticClassificationResult.explanation
                ?? "The available context was not strong enough to classify."
        }
    }
}

public struct WaitHistoryContribution: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let duration: TimeInterval
    public let isOther: Bool

    public init(id: String, label: String, duration: TimeInterval, isOther: Bool = false) {
        self.id = id
        self.label = label
        self.duration = duration
        self.isOther = isOther
    }
}

/// Aggregates stored activity context for the Last 7 Days drill-down.
public enum WaitHistoryContributorAggregator {
    public static func contributors(
        from sessions: [WaitSession],
        classification: WaitSessionClassification,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [WaitHistoryContribution] {
        guard let today = calendar.dateInterval(of: .day, for: referenceDate),
              let start = calendar.date(byAdding: .day, value: -6, to: today.start)
        else { return [] }
        let interval = DateInterval(start: start, end: today.end)

        let matching = sessions.filter {
            $0.state == .completed && sessionOverlaps($0, interval: interval)
        }

        return aggregate(matching, classification: classification, overlapping: interval)
    }

    public static func contributors(for session: WaitSession) -> [WaitHistoryContribution] {
        aggregate([session], classification: nil, overlapping: nil)
    }

    static func normalizedDomain(_ domain: String) -> String {
        let value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    private static func aggregate(
        _ sessions: [WaitSession],
        classification: WaitSessionClassification?,
        overlapping interval: DateInterval?
    ) -> [WaitHistoryContribution] {
        var totals: [ContributorIdentity: TimeInterval] = [:]

        for session in sessions {
            let total = max(0, session.duration ?? session.endTime?.timeIntervalSince(session.startTime) ?? 0)
            let sessionEnd = session.startTime.addingTimeInterval(total)
            if let slices = session.activityClassificationSlices {
                let segmentsByID = Dictionary(
                    uniqueKeysWithValues: session.activitySegments.map { ($0.id, $0) }
                )
                var remaining = total
                var lastEnd: Date?
                for slice in slices.sorted(by: {
                    if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }) where remaining > 0 {
                    let allocated = min(remaining, max(0, slice.duration))
                    guard allocated > 0 else { continue }
                    let end = min(slice.endedAt, slice.startedAt.addingTimeInterval(allocated))
                    let effective = slice.effectiveClassification
                    let duration = clippedDuration(
                        start: slice.startedAt,
                        end: end,
                        interval: interval
                    )
                    if duration > 0, classification == nil || effective == classification {
                        if let sourceID = slice.sourceActivitySegmentID,
                           let segment = segmentsByID[sourceID] {
                            totals[identity(for: segment.context), default: 0] += duration
                        } else {
                            totals[.other, default: 0] += duration
                        }
                    }
                    if end > slice.startedAt { lastEnd = end }
                    remaining -= allocated
                }
                if remaining > 0 {
                    let start = lastEnd ?? session.startTime
                    let end = min(sessionEnd, start.addingTimeInterval(remaining))
                    let duration = clippedDuration(start: start, end: end, interval: interval)
                    if duration > 0, classification == nil || classification == .unclassified {
                        totals[.other, default: 0] += duration
                    }
                }
                continue
            }
            guard classification == nil || session.effectiveClassification == classification else { continue }
            var cursor = session.startTime
            for segment in session.activitySegments.sorted(by: {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }) {
                let rawEnd = segment.endedAt
                    ?? segment.duration.map { segment.startedAt.addingTimeInterval($0) }
                    ?? segment.startedAt
                let start = max(cursor, segment.startedAt)
                let end = min(min(rawEnd, segment.duration.map {
                    segment.startedAt.addingTimeInterval(max(0, $0))
                } ?? rawEnd), sessionEnd)
                guard end > start else { continue }
                if start > cursor {
                    let gapDuration = clippedDuration(start: cursor, end: start, interval: interval)
                    if gapDuration > 0 { totals[.other, default: 0] += gapDuration }
                }
                let duration = clippedDuration(start: start, end: end, interval: interval)
                if duration > 0 { totals[identity(for: segment.context), default: 0] += duration }
                cursor = end
            }

            if cursor < sessionEnd {
                let duration = clippedDuration(start: cursor, end: sessionEnd, interval: interval)
                if duration > 0 { totals[.other, default: 0] += duration }
            }
        }

        return totals.map { identity, duration in
            WaitHistoryContribution(
                id: identity.key,
                label: identity.label,
                duration: duration,
                isOther: identity == .other
            )
        }.sorted {
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func sessionOverlaps(_ session: WaitSession, interval: DateInterval) -> Bool {
        let end = session.startTime.addingTimeInterval(
            max(0, session.duration ?? session.endTime?.timeIntervalSince(session.startTime) ?? 0)
        )
        return end > interval.start && session.startTime < interval.end
    }

    private static func clippedDuration(
        start: Date,
        end: Date,
        interval: DateInterval?
    ) -> TimeInterval {
        guard end > start else { return 0 }
        guard let interval else { return end.timeIntervalSince(start) }
        return max(0, min(end, interval.end).timeIntervalSince(max(start, interval.start)))
    }

    private static func identity(for context: ActivityContext) -> ContributorIdentity {
        if let kind = context.resourceKind,
           kind == .project || kind == .workspace || kind == .terminal || kind == .folder,
           let label = context.resourceName ?? context.resourcePath.map(shortPathLabel) {
            let canonical = context.resourcePath ?? "\(kind.rawValue):\(label.lowercased())"
            return .value(key: "resource:\(canonical.lowercased())", label: label)
        }

        if let domain = context.browserDomain {
            let normalized = normalizedDomain(domain)
            return .value(key: "domain:\(normalized)", label: normalized)
        }

        if let label = context.documentName ?? context.resourceName {
            let canonical = context.resourcePath ?? label.lowercased()
            return .value(key: "document:\(canonical.lowercased())", label: label)
        }

        let canonicalBundle = BuiltInActivityEvidencePolicy.canonicalBundleIdentifier(
            context.applicationBundleIdentifier
        )
        let label = canonicalBundle == "com.valvesoftware.steam"
            ? "Steam"
            : context.applicationName
        return .value(key: "application:\(canonicalBundle.lowercased())", label: label)
    }

    private static func shortPathLabel(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? (path as NSString).abbreviatingWithTildeInPath : last
    }

    private enum ContributorIdentity: Hashable {
        case value(key: String, label: String)
        case other

        var key: String {
            switch self {
            case let .value(key, _): key
            case .other: "other"
            }
        }

        var label: String {
            switch self {
            case let .value(_, label): label
            case .other: "Other"
            }
        }
    }
}

public enum WaitDurationFormat {
    public static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3_600 {
            let minutes = total / 60
            let remainingSeconds = total % 60
            return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
        }

        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    public static func spoken(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if hours == 0, remainingSeconds > 0 {
            parts.append("\(remainingSeconds) \(remainingSeconds == 1 ? "second" : "seconds")")
        }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}
