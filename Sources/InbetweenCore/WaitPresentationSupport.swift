import Foundation

public struct WaitClassificationReviewUnit: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceSliceIDs: [UUID]
    public let waitSessionID: UUID
    public let context: ActivityContext
    public let label: String
    public let subtitle: String?
    public let totalDuration: TimeInterval
    public let presenceState: UserPresenceState
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
        presenceState: UserPresenceState,
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
                  let segment = segmentsByID[sourceID],
                  let presence = segment.context.presenceState
            else { continue }
            if pendingOnly {
                guard slice.effectiveClassification == .unclassified,
                      slice.automaticClassificationResult.reviewSuggested,
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
        if values.productive > 0 { parts.append("\(WaitDurationFormat.compact(values.productive)) Productive") }
        if values.distracted > 0 { parts.append("\(WaitDurationFormat.compact(values.distracted)) Distracted") }
        if values.unclassified > 0 { parts.append("\(WaitDurationFormat.compact(values.unclassified)) Unclassified") }
        return parts.joined(separator: " · ")
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
        let presence: UserPresenceState

        init(context: ActivityContext, presence: UserPresenceState) {
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
        let presence: UserPresenceState
        var slices: [ActivityClassificationSlice] = []

        mutating func append(_ slice: ActivityClassificationSlice) { slices.append(slice) }

        var value: WaitClassificationReviewUnit {
            let ids = slices.map(\.id)
            let duration = slices.reduce(0) { $0 + max(0, $1.duration) }
            let effective = Set(slices.map(\.effectiveClassification))
            return WaitClassificationReviewUnit(
                id: "\(sessionID.uuidString):\(presence.rawValue):\(ids.map(\.uuidString).joined(separator: ","))",
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
            if reasons.contains(.meaningfulInactiveTime) {
                return "Foreground context cannot classify \(presence.rawValue) time."
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
        guard let today = calendar.dateInterval(of: .day, for: referenceDate)?.start,
              let start = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today)
        else { return [] }

        let matching = sessions.filter { session in
            guard session.state == .completed,
                  session.activityClassificationSlices != nil
                    || session.effectiveClassification == classification
            else { return false }
            let completion = WaitPresentationSupport.completionDate(for: session)
            return completion >= start && completion < end
        }

        return aggregate(matching, classification: classification)
    }

    public static func contributors(for session: WaitSession) -> [WaitHistoryContribution] {
        aggregate([session], classification: nil)
    }

    static func normalizedDomain(_ domain: String) -> String {
        let value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    private static func aggregate(
        _ sessions: [WaitSession],
        classification: WaitSessionClassification?
    ) -> [WaitHistoryContribution] {
        var totals: [ContributorIdentity: TimeInterval] = [:]

        for session in sessions {
            if let slices = session.activityClassificationSlices {
                let segmentsByID = Dictionary(
                    uniqueKeysWithValues: session.activitySegments.map { ($0.id, $0) }
                )
                for slice in slices {
                    guard classification == nil || slice.effectiveClassification == classification else {
                        continue
                    }
                    let duration = max(0, slice.duration)
                    guard duration > 0 else { continue }
                    if let sourceID = slice.sourceActivitySegmentID,
                       let segment = segmentsByID[sourceID] {
                        totals[identity(for: segment.context), default: 0] += duration
                    } else {
                        totals[.other, default: 0] += duration
                    }
                }
                continue
            }
            let sessionDuration = max(
                0,
                session.duration
                    ?? session.endTime?.timeIntervalSince(session.startTime)
                    ?? 0
            )
            var remaining = sessionDuration

            for segment in session.activitySegments.sorted(by: { $0.startedAt < $1.startedAt }) {
                guard remaining > 0 else { break }
                let duration = min(remaining, max(0, segment.duration ?? 0))
                guard duration > 0 else { continue }
                totals[identity(for: segment.context), default: 0] += duration
                remaining -= duration
            }

            if remaining > 0 {
                totals[.other, default: 0] += remaining
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
