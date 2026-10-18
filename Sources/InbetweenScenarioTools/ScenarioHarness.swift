import Foundation
import InbetweenCore

/// JSON fixture root for the headless, development-only scenario runner.
public struct ScenarioDocument: Codable, Sendable {
    public let schemaVersion: Int
    public let scenarios: [ScenarioFixture]
}

public struct ScenarioFixture: Codable, Sendable {
    public let name: String
    public let description: String
    public let referenceTime: TimeInterval
    public let sessions: [ScenarioSessionFixture]
    public let personalRules: [ScenarioRuleFixture]
    public let lifecycleEvents: [ScenarioLifecycleFixture]
    public let permissionChecks: [TimeInterval]
    public let expected: ScenarioExpectedOutcome?

    public init(
        name: String,
        description: String,
        referenceTime: TimeInterval,
        sessions: [ScenarioSessionFixture],
        personalRules: [ScenarioRuleFixture] = [],
        lifecycleEvents: [ScenarioLifecycleFixture] = [],
        permissionChecks: [TimeInterval] = [],
        expected: ScenarioExpectedOutcome? = nil
    ) {
        self.name = name; self.description = description; self.referenceTime = referenceTime
        self.sessions = sessions; self.personalRules = personalRules
        self.lifecycleEvents = lifecycleEvents; self.permissionChecks = permissionChecks; self.expected = expected
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, referenceTime, sessions, personalRules, lifecycleEvents, permissionChecks, expected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        referenceTime = try container.decode(TimeInterval.self, forKey: .referenceTime)
        sessions = try container.decode([ScenarioSessionFixture].self, forKey: .sessions)
        personalRules = try container.decodeIfPresent([ScenarioRuleFixture].self, forKey: .personalRules) ?? []
        lifecycleEvents = try container.decodeIfPresent([ScenarioLifecycleFixture].self, forKey: .lifecycleEvents) ?? []
        permissionChecks = try container.decodeIfPresent([TimeInterval].self, forKey: .permissionChecks) ?? []
        expected = try container.decodeIfPresent(ScenarioExpectedOutcome.self, forKey: .expected)
    }
}

public struct ScenarioSessionFixture: Codable, Sendable {
    public let id: String
    public let sessionID: String
    public let turnID: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let classificationMode: String?
    public let activities: [ScenarioActivityFixture]
    /// Values are applied in order; `null` means clear the override.
    public let manualOverrideSequence: [WaitSessionClassification?]
    public var sliceReviewActions: [ScenarioSliceReviewAction]?

    public init(
        id: String, sessionID: String, turnID: String,
        start: TimeInterval, end: TimeInterval, classificationMode: String?,
        activities: [ScenarioActivityFixture],
        manualOverrideSequence: [WaitSessionClassification?],
        sliceReviewActions: [ScenarioSliceReviewAction]? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.start = start
        self.end = end
        self.classificationMode = classificationMode
        self.activities = activities
        self.manualOverrideSequence = manualOverrideSequence
        self.sliceReviewActions = sliceReviewActions
    }
}

public struct ScenarioSliceReviewAction: Codable, Sendable {
    public let activityIndexes: [Int]
    public let action: String
}

public struct ScenarioActivityFixture: Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let app: String
    public let bundleID: String
    public let windowTitle: String?
    public let domain: String?
    public let url: String?
    public let pageTitle: String?
    public let resourceKind: ActivityResourceKind?
    public let resourceName: String?
    public let documentName: String?
    public let resourcePath: String?
    public let presence: UserPresenceState?
}

public struct ScenarioRuleFixture: Codable, Sendable {
    public let scope: ContextRuleScope
    public let pattern: String
    public let disposition: ContextRuleDisposition
}

public struct ScenarioLifecycleFixture: Codable, Sendable {
    public let name: LifecycleEventName
    public let sessionID: String
    public let turnID: String
    public let time: TimeInterval
    public let permissionMode: PermissionMode?
}

public struct ScenarioExpectedOutcome: Codable, Sendable {
    /// Whole-wait expectations are retained for explicit legacy fixtures only.
    public let automaticClassification: WaitSessionClassification?
    public let effectiveClassification: WaitSessionClassification?
    public let reviewRequested: Bool?
    public let automaticReasonCodes: [WaitSessionClassificationReason]?
    public let productiveSeconds: TimeInterval?
    public let distractedSeconds: TimeInterval?
    public let unclassifiedSeconds: TimeInterval?
    public let reviewUnitCount: Int?
    public let reviewUnits: [ScenarioReviewUnitExpectation]?
    public let permissionState: String?
    public let dashboard: ScenarioDashboardExpectation?

    public init(
        automaticClassification: WaitSessionClassification? = nil,
        effectiveClassification: WaitSessionClassification? = nil,
        reviewRequested: Bool? = nil,
        automaticReasonCodes: [WaitSessionClassificationReason]? = nil,
        productiveSeconds: TimeInterval? = nil,
        distractedSeconds: TimeInterval? = nil,
        unclassifiedSeconds: TimeInterval? = nil,
        reviewUnitCount: Int? = nil,
        reviewUnits: [ScenarioReviewUnitExpectation]? = nil,
        permissionState: String? = nil,
        dashboard: ScenarioDashboardExpectation? = nil
    ) {
        self.automaticClassification = automaticClassification
        self.effectiveClassification = effectiveClassification
        self.reviewRequested = reviewRequested
        self.automaticReasonCodes = automaticReasonCodes
        self.productiveSeconds = productiveSeconds
        self.distractedSeconds = distractedSeconds
        self.unclassifiedSeconds = unclassifiedSeconds
        self.reviewUnitCount = reviewUnitCount
        self.reviewUnits = reviewUnits
        self.permissionState = permissionState
        self.dashboard = dashboard
    }
}

public struct ScenarioReviewUnitExpectation: Codable, Sendable {
    public let presence: UserPresenceState
    public let totalSeconds: TimeInterval
    public let sourceSliceCount: Int?
}

public struct ScenarioDashboardExpectation: Codable, Sendable {
    public let productiveSeconds: TimeInterval?
    public let distractedSeconds: TimeInterval?
    public let unclassifiedSeconds: TimeInterval?
    public let notRecordedSeconds: TimeInterval?
    public let days: [ScenarioDayExpectation]?
}

public struct ScenarioDayExpectation: Codable, Sendable {
    /// Zero is the fixture reference day, negative values are earlier days.
    public let dayOffset: Int
    public let productiveSeconds: TimeInterval?
    public let distractedSeconds: TimeInterval?
    public let unclassifiedSeconds: TimeInterval?
    public let notRecordedSeconds: TimeInterval?
}

public struct ScenarioRunResult: Encodable, Sendable {
    public struct SessionResult: Encodable, Sendable {
        public let id: String
        public let automaticClassification: String?
        public let automaticReasonCodes: [String]
        public let effectiveClassification: String?
        public let reviewRequested: Bool
        public let classificationDurations: ClassificationDurationResult
        public let reviewUnits: [ReviewUnitResult]
        public let activity: ActivityBreakdown
        public let semanticContexts: [SemanticResult]
    }
    public struct ClassificationDurationResult: Encodable, Sendable {
        public let productiveSeconds: TimeInterval
        public let distractedSeconds: TimeInterval
        public let unclassifiedSeconds: TimeInterval
        public let notRecordedSeconds: TimeInterval
    }
    public struct ReviewUnitResult: Encodable, Sendable {
        public let label: String
        public let presence: String
        public let totalSeconds: TimeInterval
        public let sourceSliceCount: Int
    }
    public struct ActivityBreakdown: Encodable, Sendable {
        public let totalSeconds: TimeInterval
        public let activeSeconds: TimeInterval
        public let idleSeconds: TimeInterval
        public let awaySeconds: TimeInterval
    }
    public struct SemanticResult: Encodable, Sendable {
        public let input: String
        public let category: String?
        public let similarity: Double?
        public let runnerUp: String?
        public let margin: Double?
        public let evidence: String
    }
    public struct DashboardResult: Encodable, Sendable {
        public let productiveSeconds: TimeInterval
        public let distractedSeconds: TimeInterval
        public let unclassifiedSeconds: TimeInterval
        public let notRecordedSeconds: TimeInterval
        public let days: [DashboardDay]
    }
    public struct DashboardDay: Encodable, Sendable {
        public let dayOffset: Int
        public let productiveSeconds: TimeInterval
        public let distractedSeconds: TimeInterval
        public let unclassifiedSeconds: TimeInterval
        public let notRecordedSeconds: TimeInterval
    }

    public let name: String
    public let sessions: [SessionResult]
    public let lifecycleState: String
    public let permissionState: String
    public let permissionUpdates: [String]
    public let dashboard: DashboardResult
    public let assertionFailures: [String]

    public var passed: Bool { assertionFailures.isEmpty }
}

public enum ScenarioHarnessError: LocalizedError {
    case invalidFixture(String)
    public var errorDescription: String? {
        switch self { case let .invalidFixture(message): return message }
    }
}

/// Runs fixtures strictly in memory. It never constructs a store, monitor,
/// notification runtime, permission request, browser, or hook configuration.
public enum ScenarioHarness {
    public static func run(_ fixture: ScenarioFixture) throws -> ScenarioRunResult {
        let rules = try fixture.personalRules.enumerated().map { index, rule in
            guard let value = PersonalContextRule(
                id: deterministicUUID(UInt64(index)), scope: rule.scope, pattern: rule.pattern,
                disposition: rule.disposition
            ) else { throw ScenarioHarnessError.invalidFixture("Invalid personal rule: \(rule.pattern)") }
            return value
        }
        let classifier = WaitSessionClassifier(
            rules: WaitSessionClassificationRules(personalContextRules: rules)
        )
        let analyzer = classifier.semanticAnalyzer
        let sessions = try fixture.sessions.map { try makeSession($0, classifier: classifier) }
        var lifecycle = LifecycleStateMachine(maximumEventAge: .greatestFiniteMagnitude, futureTolerance: .greatestFiniteMagnitude)
        var permission = DelayedPermissionAttentionTracker()
        var permissionUpdates: [String] = []
        let events = fixture.lifecycleEvents.sorted(by: { $0.time < $1.time })
        let checks = fixture.permissionChecks.sorted()
        var eventIndex = 0; var checkIndex = 0
        // Advance time deterministically, so a check before a later continuation
        // can promote attention and that continuation can subsequently clear it.
        while eventIndex < events.count || checkIndex < checks.count {
            let eventTime = eventIndex < events.count ? events[eventIndex].time : .greatestFiniteMagnitude
            let checkTime = checkIndex < checks.count ? checks[checkIndex] : .greatestFiniteMagnitude
            if eventTime <= checkTime {
                let eventFixture = events[eventIndex]; eventIndex += 1
                let event = LifecycleEvent(name: eventFixture.name, sessionID: eventFixture.sessionID, turnID: eventFixture.turnID, observedAt: eventFixture.time, permissionMode: eventFixture.permissionMode)
                if lifecycle.apply(event, now: event.date) == .accepted {
                    permissionUpdates.append(describe(permission.observeAcceptedLifecycleEvent(event, receivedAt: event.date)))
                }
            } else {
                let time = checks[checkIndex]; checkIndex += 1
                if let boundary = permission.currentBoundaryID {
                    permissionUpdates.append(describe(permission.evaluate(boundaryID: boundary, at: Date(timeIntervalSince1970: time))))
                }
            }
        }
        let calendar = utcCalendar()
        let referenceDate = Date(timeIntervalSince1970: fixture.referenceTime)
        let insights = WaitHistoryInsights(sessions: sessions, referenceDate: referenceDate, calendar: calendar)
        let sessionResults = sessions.map { session in
            let breakdown = activityBreakdown(session)
            let durations = WaitHistoryInsights.classificationDurations(for: session)
            let reviewUnits = WaitPresentationSupport.pendingReviewUnits(from: [session]).map {
                ScenarioRunResult.ReviewUnitResult(
                    label: $0.label,
                    presence: $0.presenceState?.rawValue ?? "unknown",
                    totalSeconds: $0.totalDuration,
                    sourceSliceCount: $0.sourceSliceIDs.count
                )
            }
            let semantics = session.activitySegments.compactMap { segment -> ScenarioRunResult.SemanticResult? in
                guard let description = SemanticActivityDescription(context: segment.context) else { return nil }
                let inference = analyzer.inference(for: segment.context)
                let evidence: String
                switch analyzer.evidence(for: segment.context) {
                case .productive: evidence = "productive"
                case .distracting: evidence = "distracting"
                case nil: evidence = "none"
                }
                return .init(input: description.text, category: inference?.category.rawValue, similarity: inference?.similarity, runnerUp: inference?.competingCategory?.rawValue, margin: inference?.margin, evidence: evidence)
            }
            return ScenarioRunResult.SessionResult(
                id: fixture.sessions.first(where: { $0.sessionID == session.codexSessionID && $0.turnID == session.codexTurnID })?.id ?? session.id.uuidString,
                automaticClassification: session.activityClassificationSlices == nil ? session.automaticClassification?.title : nil,
                automaticReasonCodes: session.activityClassificationSlices == nil ? session.classificationResult?.reasonCodes.map(reasonCode) ?? [] : [],
                effectiveClassification: session.activityClassificationSlices == nil ? session.effectiveClassification?.title : nil,
                reviewRequested: session.shouldRequestClassificationReview,
                classificationDurations: .init(
                    productiveSeconds: durations.productive,
                    distractedSeconds: durations.distracted,
                    unclassifiedSeconds: durations.unclassified,
                    notRecordedSeconds: durations.notRecorded
                ),
                reviewUnits: reviewUnits,
                activity: breakdown, semanticContexts: semantics
            )
        }
        let dashboard = makeDashboard(insights, reference: referenceDate, calendar: calendar)
        var result = ScenarioRunResult(name: fixture.name, sessions: sessionResults, lifecycleState: lifecycle.snapshot.state.rawValue, permissionState: describe(permission.state), permissionUpdates: permissionUpdates, dashboard: dashboard, assertionFailures: [])
        result = ScenarioRunResult(name: result.name, sessions: result.sessions, lifecycleState: result.lifecycleState, permissionState: result.permissionState, permissionUpdates: result.permissionUpdates, dashboard: result.dashboard, assertionFailures: assertionFailures(fixture.expected, result: result))
        return result
    }

    private static func makeSession(_ fixture: ScenarioSessionFixture, classifier: WaitSessionClassifier) throws -> WaitSession {
        guard fixture.end >= fixture.start else { throw ScenarioHarnessError.invalidFixture("\(fixture.id): end precedes start") }
        let id = deterministicUUID(stableSeed(fixture.id))
        let segments = try fixture.activities.enumerated().map { index, activity in
            guard activity.end >= activity.start,
                  let context = ActivityContext(applicationBundleIdentifier: activity.bundleID, applicationName: activity.app, windowTitle: activity.windowTitle, browserDomain: activity.domain, browserPageTitle: activity.pageTitle, browserURL: activity.url, resourceKind: activity.resourceKind, resourceName: activity.resourceName, documentName: activity.documentName, resourcePath: activity.resourcePath, presenceState: activity.presence)
            else { throw ScenarioHarnessError.invalidFixture("\(fixture.id): invalid activity \(index)") }
            let start = Date(timeIntervalSince1970: activity.start)
            return ActivitySegment(id: deterministicUUID(stableSeed("\(fixture.id)-\(index)")), waitSessionID: id, context: context, startedAt: start, endedAt: Date(timeIntervalSince1970: activity.end), duration: activity.end - activity.start)
        }
        var session = WaitSession(id: id, codexSessionID: fixture.sessionID, codexTurnID: fixture.turnID, startTime: Date(timeIntervalSince1970: fixture.start), endTime: Date(timeIntervalSince1970: fixture.end), duration: fixture.end - fixture.start, state: .completed, activitySegments: segments)
        if fixture.classificationMode?.hasPrefix("legacy") == true {
            if fixture.classificationMode != "legacyNotRecorded" {
                session.classificationResult = classifier.classify(session)
            }
            for override in fixture.manualOverrideSequence { session.manualClassificationOverride = override }
        } else {
            var slices = classifier.classificationSlices(for: session)
            session.classificationResult = classifier.summary(for: slices)
            for action in fixture.sliceReviewActions ?? [] {
                let sourceIDs = Set(action.activityIndexes.compactMap { index in
                    segments.indices.contains(index) ? segments[index].id : nil
                })
                guard sourceIDs.count == action.activityIndexes.count else {
                    throw ScenarioHarnessError.invalidFixture("\(fixture.id): slice action has an invalid activity index")
                }
                for index in slices.indices where slices[index].sourceActivitySegmentID.map(sourceIDs.contains) == true {
                    switch action.action {
                    case "productive":
                        slices[index].manualClassificationOverride = .productive
                        slices[index].classificationReviewHandled = true
                    case "distracted":
                        slices[index].manualClassificationOverride = .distracted
                        slices[index].classificationReviewHandled = true
                    case "clear":
                        slices[index].manualClassificationOverride = nil
                        slices[index].classificationReviewHandled = false
                    default:
                        throw ScenarioHarnessError.invalidFixture("\(fixture.id): unsupported slice action \(action.action)")
                    }
                }
            }
            session.activityClassificationSlices = slices
        }
        return session
    }

    private static func activityBreakdown(_ session: WaitSession) -> ScenarioRunResult.ActivityBreakdown {
        var active: TimeInterval = 0; var idle: TimeInterval = 0; var away: TimeInterval = 0
        for segment in session.activitySegments {
            let duration = max(0, segment.duration ?? 0)
            switch segment.context.presenceState {
            case .idle: idle += duration
            case .away: away += duration
            default: active += duration
            }
        }
        return .init(totalSeconds: session.duration ?? 0, activeSeconds: active, idleSeconds: idle, awaySeconds: away)
    }

    private static func makeDashboard(_ insights: WaitHistoryInsights, reference: Date, calendar: Calendar) -> ScenarioRunResult.DashboardResult {
        let summary = insights.lastSevenDaysSummary
        let referenceStart = calendar.startOfDay(for: reference)
        return .init(productiveSeconds: summary.productiveDuration, distractedSeconds: summary.distractedDuration, unclassifiedSeconds: summary.unclassifiedDuration, notRecordedSeconds: summary.notRecordedDuration, days: insights.lastSevenDays.map { period in
            let offset = calendar.dateComponents([.day], from: referenceStart, to: period.startDate).day ?? 0
            return .init(dayOffset: offset, productiveSeconds: period.summary.productiveDuration, distractedSeconds: period.summary.distractedDuration, unclassifiedSeconds: period.summary.unclassifiedDuration, notRecordedSeconds: period.summary.notRecordedDuration)
        })
    }

    private static func assertionFailures(_ expected: ScenarioExpectedOutcome?, result: ScenarioRunResult) -> [String] {
        guard let expected else { return [] }
        guard let primary = result.sessions.first else { return ["Expected a session result, but none was produced."] }
        var failures: [String] = []
        check(expected.automaticClassification?.title, primary.automaticClassification, "automatic classification", &failures)
        check(expected.effectiveClassification?.title, primary.effectiveClassification, "effective classification", &failures)
        check(expected.reviewRequested, primary.reviewRequested, "review requested", &failures)
        check(expected.productiveSeconds, primary.classificationDurations.productiveSeconds, "Productive seconds", &failures)
        check(expected.distractedSeconds, primary.classificationDurations.distractedSeconds, "Distracted seconds", &failures)
        check(expected.unclassifiedSeconds, primary.classificationDurations.unclassifiedSeconds, "Unclassified seconds", &failures)
        check(expected.reviewUnitCount, primary.reviewUnits.count, "review unit count", &failures)
        if let units = expected.reviewUnits {
            for unit in units {
                let matches = primary.reviewUnits.filter {
                    $0.presence == unit.presence.rawValue && $0.totalSeconds == unit.totalSeconds
                }
                if matches.isEmpty {
                    failures.append("review unit: expected \(unit.presence.rawValue) \(unit.totalSeconds)s")
                } else if let count = unit.sourceSliceCount, matches[0].sourceSliceCount != count {
                    failures.append("review unit \(unit.presence.rawValue) source slices: expected \(count), got \(matches[0].sourceSliceCount)")
                }
            }
        }
        if let reasons = expected.automaticReasonCodes?.map(reasonCode), reasons != primary.automaticReasonCodes { failures.append("automatic reason codes: expected \(reasons), got \(primary.automaticReasonCodes)") }
        check(expected.permissionState, result.permissionState, "permission state", &failures)
        if let dashboard = expected.dashboard {
            check(dashboard.productiveSeconds, result.dashboard.productiveSeconds, "dashboard Productive seconds", &failures)
            check(dashboard.distractedSeconds, result.dashboard.distractedSeconds, "dashboard Distracted seconds", &failures)
            check(dashboard.unclassifiedSeconds, result.dashboard.unclassifiedSeconds, "dashboard Unclassified seconds", &failures)
            check(dashboard.notRecordedSeconds, result.dashboard.notRecordedSeconds, "dashboard Not recorded seconds", &failures)
            for day in dashboard.days ?? [] {
                guard let actual = result.dashboard.days.first(where: { $0.dayOffset == day.dayOffset }) else { failures.append("dashboard day \(day.dayOffset) missing"); continue }
                check(day.productiveSeconds, actual.productiveSeconds, "day \(day.dayOffset) Productive seconds", &failures)
                check(day.distractedSeconds, actual.distractedSeconds, "day \(day.dayOffset) Distracted seconds", &failures)
                check(day.unclassifiedSeconds, actual.unclassifiedSeconds, "day \(day.dayOffset) Unclassified seconds", &failures)
                check(day.notRecordedSeconds, actual.notRecordedSeconds, "day \(day.dayOffset) Not recorded seconds", &failures)
            }
        }
        return failures
    }

    private static func check<T: Equatable>(_ expected: T?, _ actual: T, _ label: String, _ failures: inout [String]) {
        if let expected, expected != actual { failures.append("\(label): expected \(expected), got \(actual)") }
    }
    private static func reasonCode(_ reason: WaitSessionClassificationReason) -> String { (try? JSONDecoder().decode(String.self, from: JSONEncoder().encode(reason))) ?? String(describing: reason) }
    private static func describe(_ state: DelayedPermissionAttentionState) -> String { switch state { case .inactive: return "inactive"; case .pending: return "pending"; case .mayNeedAttention: return "mayNeedAttention" } }
    private static func describe(_ update: DelayedPermissionAttentionUpdate) -> String { switch update { case .unchanged: return "unchanged"; case .pending: return "pending"; case .cleared: return "cleared"; case .becamePersistent: return "becamePersistent" } }
    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 } & 0x0000_FFFF_FFFF_FFFF
    }
    private static func deterministicUUID(_ seed: UInt64) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", seed))! }
    private static func utcCalendar() -> Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar }
}
