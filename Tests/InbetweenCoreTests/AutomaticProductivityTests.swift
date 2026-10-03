import Foundation
import Testing
@testable import InbetweenCore

struct AutomaticProductivityTests {
    @Test func newWaitRequiresNoIntention() throws {
        var tracker = WaitSessionTracker()
        #expect(tracker.apply(event(.userPromptSubmit, at: 1_000)) != .ignored)
        #expect(tracker.currentSession?.intention == nil)
        #expect(tracker.currentSession?.intentionPromptHandled == nil)
    }

    @Test func legacyIntentionAndRecoveredClassificationDecodeSafely() throws {
        let json = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"codexSessionID\":\"s\",\"codexTurnID\":\"t\",\"startTime\":1000,\"state\":\"completed\",\"hookSource\":\"h\",\"hookVersion\":1,\"intention\":{\"kind\":\"move\"},\"classificationResult\":{\"classification\":\"recovered\",\"reasonCodes\":[\"moveWithSustainedAway\"]}}"
        let data = Data(json.utf8)
        let session = try JSONDecoder().decode(WaitSession.self, from: data)
        #expect(session.intention?.kind == .move)
        #expect(session.automaticClassification == .productive)
        #expect(session.classificationResult?.reasonCodes == [.legacyMoveEvidence])
    }

    @Test func sustainedProductiveContextNeedsNoIntention() throws {
        let result = WaitSessionClassifier().classify(try completed([segment(bundle: "com.google.Chrome", duration: 120, kind: .workspace)]))
        #expect(result?.classification == .productive)
        #expect(result?.reasonCodes.contains(.sustainedProductiveContext) == true)
    }

    @Test func personalRulesAreStrongestEvidence() throws {
        let productive = try rule(.applicationBundleIdentifier, "com.example.app", .productive)
        let distracting = try rule(.browserDomain, "social.example", .distracting)
        let classifier = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: [], personalContextRules: [productive, distracting]))
        #expect(classifier.classify(try completed([segment(bundle: "com.example.app", duration: 120)]))?.classification == .productive)
        #expect(classifier.classify(try completed([segment(bundle: "com.google.Chrome", duration: 120, domain: "social.example")]))?.classification == .distracted)
    }

    @Test func ambiguousAndInactiveEvidenceRemainUnclassified() throws {
        let ambiguous = WaitSessionClassifier().classify(try completed([segment(bundle: "com.google.Chrome", duration: 120)]))
        #expect(ambiguous?.classification == .unclassified)
        #expect(ambiguous?.reviewSuggested == true)
        let away = WaitSessionClassifier().classify(try completed([segment(bundle: "com.apple.dt.Xcode", duration: 120, presence: .away)]))
        #expect(away?.classification == .unclassified)
        #expect(away?.reasonCodes.contains(.meaningfulInactiveTime) == true)
    }

    @Test func legacyMoveDoesNotAffectNewClassification() throws {
        let oldMove = WaitSessionIntention(kind: .move)
        let result = WaitSessionClassifier().classify(try completed([segment(bundle: "com.apple.dt.Xcode", duration: 120, presence: .away)], intention: oldMove))
        #expect(result?.classification == .unclassified)
    }

    @Test func manualOverridePreservesAutomaticResultAndCanClear() throws {
        var tracker = WaitSessionTracker(sessions: [try completed([], classification: .unclassified, review: true)])
        let id = try #require(tracker.sessions.first?.id)
        #expect(tracker.sessions[0].shouldRequestClassificationReview)
        #expect(tracker.setManualClassificationOverride(.productive, for: id) == .updated(id))
        #expect(tracker.sessions[0].effectiveClassification == .productive)
        #expect(tracker.sessions[0].automaticClassification == .unclassified)
        #expect(!tracker.sessions[0].shouldRequestClassificationReview)
        #expect(tracker.setManualClassificationOverride(nil, for: id) == .updated(id))
        #expect(tracker.sessions[0].effectiveClassification == .unclassified)
    }

    @Test func notSureReviewIsHandledOnlyOnce() throws {
        var tracker = WaitSessionTracker(sessions: [try completed([], classification: .unclassified, review: true)])
        let id = try #require(tracker.sessions.first?.id)
        #expect(tracker.markClassificationReviewHandled(for: id) == .updated(id))
        #expect(tracker.markClassificationReviewHandled(for: id) == .unchanged)
        #expect(!tracker.sessions[0].shouldRequestClassificationReview)
    }

    @Test func insightsUseEffectiveDurationAndKeepLegacyNotRecordedSeparate() throws {
        var overridden = try completed([], duration: 120, classification: .unclassified)
        overridden.manualClassificationOverride = .productive
        let legacy = try completed([], duration: 60)
        let insights = WaitHistoryInsights(sessions: [overridden, legacy])
        #expect(insights.summary.productiveDuration == 120)
        #expect(insights.summary.unclassifiedDuration == 0)
        #expect(insights.summary.notRecordedDuration == 60)
    }

    @Test func legacyNotRecordedWaitCanStillBeCorrected() throws {
        var tracker = WaitSessionTracker(sessions: [try completed([], classification: nil)])
        let id = try #require(tracker.sessions.first?.id)
        #expect(tracker.setManualClassificationOverride(.distracted, for: id) == .updated(id))
        #expect(tracker.sessions[0].automaticClassification == nil)
        #expect(tracker.sessions[0].effectiveClassification == .distracted)
    }

    @Test func recentPeriodsAreNewestFirst() throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let insights = WaitHistoryInsights(sessions: [], referenceDate: reference, calendar: calendar, recentDayCount: 3, recentWeekCount: 3)
        #expect(insights.recentDays[0].startDate > insights.recentDays[1].startDate)
        #expect(insights.recentWeeks[0].startDate > insights.recentWeeks[1].startDate)
    }

    @Test func sevenDayBucketsAreChronologicalAndKeepZeroDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_704_715_200) // 2024-01-08 noon UTC
        let today = calendar.startOfDay(for: reference)
        let oldest = calendar.date(byAdding: .day, value: -6, to: today)!
        let productiveDay = calendar.date(byAdding: .hour, value: 1, to: oldest)!
        let distractedDay = calendar.date(byAdding: .day, value: -2, to: reference)!
        let legacyDay = calendar.date(byAdding: .day, value: -1, to: reference)!
        let insights = WaitHistoryInsights(
            sessions: [
                completed(at: productiveDay, duration: 120, classification: .productive),
                completed(at: distractedDay, duration: 90, classification: .distracted),
                completed(at: legacyDay, duration: 60)
            ],
            referenceDate: reference,
            calendar: calendar
        )
        #expect(insights.lastSevenDays.count == 7)
        #expect(insights.lastSevenDays.first?.startDate == oldest)
        #expect(insights.lastSevenDays.last?.startDate == today)
        #expect(insights.lastSevenDays.contains(where: { $0.summary.totalCompletedDuration == 0 }))
        #expect(insights.lastSevenDaysSummary.productiveDuration == 120)
        #expect(insights.lastSevenDaysSummary.distractedDuration == 90)
        #expect(insights.lastSevenDaysSummary.notRecordedDuration == 60)
    }

    @Test func sevenDayDashboardUsesOverridesAndRestoresAutomaticDayTotal() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: 1_704_715_200)
        var session = completed(at: reference, duration: 120, classification: .unclassified)
        let automatic = WaitHistoryInsights(sessions: [session], referenceDate: reference, calendar: calendar)
        #expect(automatic.lastSevenDays.last?.summary.unclassifiedDuration == 120)
        session.manualClassificationOverride = .productive
        let corrected = WaitHistoryInsights(sessions: [session], referenceDate: reference, calendar: calendar)
        #expect(corrected.lastSevenDays.last?.summary.productiveDuration == 120)
        #expect(corrected.lastSevenDays.last?.summary.unclassifiedDuration == 0)
        session.manualClassificationOverride = nil
        let restored = WaitHistoryInsights(sessions: [session], referenceDate: reference, calendar: calendar)
        #expect(restored.lastSevenDays.last?.summary.unclassifiedDuration == 120)
    }

    @Test func weekBoundaryKeepsNewestWeekFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let monday = Date(timeIntervalSince1970: 1_704_715_200)
        let sunday = calendar.date(byAdding: .day, value: -1, to: monday)!
        let insights = WaitHistoryInsights(
            sessions: [
                completed(at: monday, duration: 60, classification: .productive),
                completed(at: sunday, duration: 90, classification: .distracted)
            ],
            referenceDate: monday,
            calendar: calendar
        )
        #expect(insights.recentWeeks[0].summary.productiveDuration == 60)
        #expect(insights.recentWeeks[1].summary.distractedDuration == 90)
    }

    @Test func semanticDescriptionIsCompactAndInspectable() throws {
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserDomain: "developer.apple.com",
            browserPageTitle: "Swift concurrency documentation",
            resourceKind: .document,
            documentName: "Actors"
        ))
        let description = try #require(SemanticActivityDescription(context: context))
        #expect(description.text == "Page: Swift concurrency documentation | Domain: developer.apple.com | Resource type: document | Document: Actors")
    }

    @Test func semanticEvidenceClassifiesRepresentativeContextsConservatively() throws {
        let analyzer = SemanticActivityAnalyzer(provider: SemanticStub { context in
            if context.contains("Xcode") || context.contains("VS Code") { return [.softwareDevelopment: 0.92, .workTaskExecution: 0.61] }
            if context.contains("developer.apple.com") || context.contains("GitHub") { return [.technicalDocumentation: 0.88, .research: 0.60] }
            if context.contains("Swift actors") { return [.studyingLearning: 0.86, .communication: 0.54] }
            if context.contains("Celebrity") { return [.entertainment: 0.91, .generalBrowsing: 0.55] }
            if context.contains("gaming") { return [.gaming: 0.91, .entertainment: 0.52] }
            if context.contains("Messages") { return [.communication: 0.90, .generalBrowsing: 0.57] }
            return [.generalBrowsing: 0.63, .communication: 0.59]
        })
        #expect(analyzer.evidence(for: try context(app: "Xcode", title: "Inbetween WaitSession.swift"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "VS Code", title: "Inbetween project"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "Chrome", domain: "developer.apple.com", title: "Swift concurrency"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "Chrome", domain: "github.com", title: "GitHub project"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "YouTube", domain: "youtube.com", title: "Understanding Swift actors"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "ChatGPT", title: "Understanding Swift actors"))?.isProductive == true)
        #expect(analyzer.evidence(for: try context(app: "YouTube", domain: "youtube.com", title: "Celebrity entertainment"))?.isDistracting == true)
        #expect(analyzer.evidence(for: try context(app: "Gaming", title: "gaming gameplay"))?.isDistracting == true)
        #expect(analyzer.evidence(for: try context(app: "Messages", title: "Conversation")) == nil)
        #expect(analyzer.evidence(for: try context(app: "Chrome", domain: "example.com", title: "Welcome")) == nil)
    }

    @Test func semanticClassifierRespectsRulesThresholdsAndMixedEvidence() throws {
        let analyzer = SemanticActivityAnalyzer(provider: SemanticStub { context in
            if context.contains("Entertainment") { return [.entertainment: 0.91, .generalBrowsing: 0.52] }
            if context.contains("Ambiguous") { return [.softwareDevelopment: 0.44, .communication: 0.43] }
            return [.softwareDevelopment: 0.90, .technicalDocumentation: 0.52]
        })
        let classifier = WaitSessionClassifier(
            rules: .init(usuallyProductiveBundleIdentifiers: [], personalContextRules: [try rule(.applicationName, "Entertainment", .productive)]),
            semanticAnalyzer: analyzer
        )
        let ruleWins = classifier.classify(try completed([semanticSegment(app: "Entertainment", title: "Entertainment video", duration: 120)]))
        #expect(ruleWins?.classification == .productive)
        #expect(ruleWins?.reasonCodes.contains(.personalProductiveRule) == true)

        let semanticProductive = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []), semanticAnalyzer: analyzer)
            .classify(try completed([semanticSegment(app: "Chrome", title: "Software design", duration: 120)]))
        #expect(semanticProductive?.classification == .productive)
        #expect(semanticProductive?.reasonCodes.contains(.sustainedSemanticProductiveContext) == true)

        let semanticDistracting = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []), semanticAnalyzer: analyzer)
            .classify(try completed([semanticSegment(app: "Chrome", title: "Entertainment video", duration: 120)]))
        #expect(semanticDistracting?.classification == .distracted)
        #expect(semanticDistracting?.reasonCodes.contains(.sustainedSemanticDistractingContext) == true)

        let ambiguous = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []), semanticAnalyzer: analyzer)
            .classify(try completed([semanticSegment(app: "Chrome", title: "Ambiguous context", duration: 120)]))
        #expect(ambiguous?.classification == .unclassified)

        let shortEvidence = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []), semanticAnalyzer: analyzer)
            .classify(try completed([semanticSegment(app: "Chrome", title: "Software design", duration: 40)], duration: 120))
        #expect(shortEvidence?.classification == .unclassified)

        let mixed = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []), semanticAnalyzer: analyzer)
            .classify(try completed([
                semanticSegment(app: "Chrome", title: "Software design", duration: 70),
                semanticSegment(app: "Chrome", title: "Entertainment video", duration: 70)
            ], duration: 140))
        #expect(mixed?.classification == .unclassified)
        #expect(mixed?.reasonCodes.contains(.mixedEvidence) == true)
    }

    @Test func capturedTitlesDriveConservativeLocalClassification() throws {
        let unavailableSemantics = SemanticActivityAnalyzer(provider: SemanticStub { _ in [:] })
        let classifier = WaitSessionClassifier(
            rules: .init(),
            semanticAnalyzer: unavailableSemantics
        )
        let cases: [(ActivityContext, WaitSessionClassification)] = [
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "(42) This gameshow lets you use ANY GAME you own - YouTube"
            ), .distracted),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "I Was Challenged to an Impossible Zelda Race"
            ), .distracted),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "Doubting My Career Choice in Software Engineering..."
            ), .productive),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "The Reality of Applying for Tech Jobs as a Fresh Graduate"
            ), .productive),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "How to Build a Game in Unity"
            ), .productive),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "Swift concurrency tutorial: actors and async await"
            ), .productive),
            (try activeContext(
                bundle: "com.openai.chat", app: "ChatGPT",
                windowTitle: "Debugging a Swift concurrency crash"
            ), .productive),
            (try activeContext(
                bundle: "com.microsoft.VSCode", app: "Visual Studio Code",
                windowTitle: "WaitSession.swift — Inbetween — Visual Studio Code"
            ), .productive),
            (try activeContext(
                bundle: "com.apple.Safari", app: "Safari", domain: "developer.apple.com",
                pageTitle: "NLEmbedding sentenceEmbedding documentation"
            ), .productive),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "example.net",
                pageTitle: "Welcome to the website"
            ), .unclassified),
            (try activeContext(
                bundle: "com.openai.chat", app: "ChatGPT", windowTitle: "New chat"
            ), .unclassified),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "YouTube"
            ), .unclassified),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "heremyas"
            ), .unclassified),
            (try activeContext(
                bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
                pageTitle: "Game theory discussion"
            ), .unclassified)
        ]

        for (context, expected) in cases {
            #expect(classifier.classify(context: context).classification == expected)
        }

        let rule = try #require(PersonalContextRule(
            scope: .browserDomain,
            pattern: "youtube.com",
            disposition: .productive
        ))
        let ruleClassifier = WaitSessionClassifier(
            rules: .init(
                personalContextRules: [rule]
            ),
            semanticAnalyzer: unavailableSemantics
        )
        let gameshow = cases[0].0
        let ruleResult = ruleClassifier.classify(context: gameshow)
        #expect(ruleResult.classification == .productive)
        #expect(ruleResult.reasonCodes.contains(.personalProductiveRule))

        let automaticResult = classifier.classify(context: gameshow)
        #expect(automaticResult.reasonCodes.contains(.highConfidenceEntertainmentEvidence))
        let decoded = try JSONDecoder().decode(
            WaitSessionClassificationResult.self,
            from: JSONEncoder().encode(automaticResult)
        )
        #expect(decoded.reasonCodes.contains(.highConfidenceEntertainmentEvidence))
    }

    @Test func browserTitleNormalizationKeepsRawCaptureAndMakesChromeVariantsEquivalent() throws {
        let meaningfulTitle = "I was laid off from my AI software engineering job at Amazon"
        let plain = try activeContext(
            bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
            pageTitle: "\(meaningfulTitle) - YouTube - Google Chrome"
        )
        let noisy = try activeContext(
            bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
            pageTitle: "(61) \(meaningfulTitle) - YouTube - Audio playing - Google Chrome"
        )

        #expect(noisy.browserPageTitle == "(61) \(meaningfulTitle) - YouTube - Audio playing - Google Chrome")
        #expect(ClassificationTitleNormalizer.normalize(plain.browserPageTitle) == meaningfulTitle)
        #expect(ClassificationTitleNormalizer.normalize(noisy.browserPageTitle) == meaningfulTitle)
        #expect(SemanticActivityDescription(context: plain) == SemanticActivityDescription(context: noisy))
        #expect(SemanticActivityDescription(context: noisy)?.text.contains("Audio playing") == false)
        #expect(SemanticActivityDescription(context: noisy)?.text.contains("Google Chrome") == false)

        let classifier = WaitSessionClassifier(
            rules: .init(),
            semanticAnalyzer: SemanticActivityAnalyzer(provider: SemanticStub { _ in [:] })
        )
        #expect(classifier.classify(context: plain).classification == .productive)
        #expect(classifier.classify(context: noisy).classification == .productive)
    }

    @Test func browserWindowTitleReachesNativeSemanticBoundary() throws {
        let analyzer = SemanticActivityAnalyzer(provider: SemanticStub { text in
            text.contains("Quarterly planning draft")
                ? [.workTaskExecution: 0.90, .generalBrowsing: 0.30]
                : [:]
        })
        let classifier = WaitSessionClassifier(
            rules: .init(usuallyProductiveBundleIdentifiers: []),
            semanticAnalyzer: analyzer
        )
        let context = try activeContext(
            bundle: "com.google.Chrome",
            app: "Google Chrome",
            windowTitle: "Quarterly planning draft"
        )

        let result = classifier.classify(context: context)

        #expect(result.classification == .productive)
        #expect(result.reasonCodes.contains(.sustainedSemanticProductiveContext))
        #expect(SemanticActivityDescription(context: context)?.text.contains(
            "Quarterly planning draft"
        ) == true)
    }

    @Test func semanticInferenceCachesMeaningfulContextIdentity() throws {
        let provider = CountingSemanticProvider()
        let analyzer = SemanticActivityAnalyzer(provider: provider)
        let context = try context(app: "Chrome", domain: "developer.apple.com", title: "Swift concurrency")
        _ = analyzer.inference(for: context)
        _ = analyzer.inference(for: context)
        #expect(provider.callCount == SemanticActivityCategory.allCases.reduce(0) {
            $0 + $1.prototypes.count
        })
    }

    @Test func semanticInferenceUsesStrongestFocusedEntertainmentPrototype() throws {
        let target = SemanticActivityCategory.entertainment.prototypes.last
        let analyzer = SemanticActivityAnalyzer(provider: PrototypeSemanticStub { prototype in
            if prototype == target { return 0.91 }
            if SemanticActivityCategory.softwareDevelopment.prototypes.contains(prototype) {
                return 0.41
            }
            return 0.12
        })
        let context = try activeContext(
            bundle: "com.google.Chrome", app: "Google Chrome", domain: "youtube.com",
            pageTitle: "Celebrity highlights"
        )

        guard case let .distracting(inference) = analyzer.evidence(for: context) else {
            Issue.record("Expected focused entertainment prototype evidence")
            return
        }
        #expect(inference.category == .entertainment)
        #expect(inference.similarity == 0.91)
    }

    private func event(_ name: LifecycleEventName, at seconds: TimeInterval) -> LifecycleEvent {
        LifecycleEvent(name: name, sessionID: "session", turnID: "turn", observedAt: seconds)
    }

    private func completed(_ segments: [ActivitySegment], duration: TimeInterval = 120, intention: WaitSessionIntention? = nil, classification: WaitSessionClassification? = nil, review: Bool = false) throws -> WaitSession {
        WaitSession(codexSessionID: "session", codexTurnID: UUID().uuidString, startTime: Date(timeIntervalSince1970: 1_000), endTime: Date(timeIntervalSince1970: 1_000 + duration), duration: duration, state: .completed, intention: intention, activitySegments: segments, classificationResult: classification.map { .init(classification: $0, reasonCodes: [], reviewSuggested: review) })
    }

    private func completed(
        at endTime: Date,
        duration: TimeInterval,
        classification: WaitSessionClassification? = nil
    ) -> WaitSession {
        WaitSession(
            codexSessionID: "session",
            codexTurnID: UUID().uuidString,
            startTime: endTime.addingTimeInterval(-duration),
            endTime: endTime,
            duration: duration,
            state: .completed,
            classificationResult: classification.map { .init(classification: $0, reasonCodes: []) }
        )
    }

    private func segment(bundle: String, duration: TimeInterval, kind: ActivityResourceKind? = nil, domain: String? = nil, presence: UserPresenceState? = .active) -> ActivitySegment {
        let start = Date(timeIntervalSince1970: 1_000)
        let context = ActivityContext(applicationBundleIdentifier: bundle, applicationName: "Test", browserDomain: domain, resourceKind: kind, presenceState: presence)!
        return ActivitySegment(waitSessionID: UUID(), context: context, startedAt: start, endedAt: start.addingTimeInterval(duration), duration: duration, lastObservedAt: start.addingTimeInterval(duration))
    }

    private func context(app: String, domain: String? = nil, title: String) throws -> ActivityContext {
        try #require(ActivityContext(applicationBundleIdentifier: "test.\(app.lowercased().replacingOccurrences(of: " ", with: ""))", applicationName: app, browserDomain: domain, browserPageTitle: title))
    }

    private func activeContext(
        bundle: String,
        app: String,
        domain: String? = nil,
        pageTitle: String? = nil,
        windowTitle: String? = nil
    ) throws -> ActivityContext {
        try #require(ActivityContext(
            applicationBundleIdentifier: bundle,
            applicationName: app,
            windowTitle: windowTitle,
            browserDomain: domain,
            browserPageTitle: pageTitle,
            presenceState: .active
        ))
    }

    private func semanticSegment(app: String, title: String, duration: TimeInterval) -> ActivitySegment {
        let start = Date(timeIntervalSince1970: 1_000)
        let context = ActivityContext(applicationBundleIdentifier: "test.\(app.lowercased())", applicationName: app, browserPageTitle: title, presenceState: .active)!
        return ActivitySegment(waitSessionID: UUID(), context: context, startedAt: start, endedAt: start.addingTimeInterval(duration), duration: duration, lastObservedAt: start.addingTimeInterval(duration))
    }

    private func rule(_ scope: ContextRuleScope, _ pattern: String, _ disposition: ContextRuleDisposition) throws -> PersonalContextRule {
        try #require(PersonalContextRule(scope: scope, pattern: pattern, disposition: disposition))
    }
}

private struct SemanticStub: SemanticSimilarityProviding {
    let scores: @Sendable (String) -> [SemanticActivityCategory: Double]

    init(_ scores: @escaping @Sendable (String) -> [SemanticActivityCategory: Double]) {
        self.scores = scores
    }

    func similarity(between text: String, and prototype: String) -> Double? {
        guard let category = SemanticActivityCategory.allCases.first(where: {
            $0.prototypes.contains(prototype)
        }) else { return nil }
        return scores(text)[category] ?? 0.1
    }
}

private struct PrototypeSemanticStub: SemanticSimilarityProviding {
    let score: @Sendable (String) -> Double?

    init(_ score: @escaping @Sendable (String) -> Double?) {
        self.score = score
    }

    func similarity(between text: String, and prototype: String) -> Double? {
        score(prototype)
    }
}

private extension SemanticEvidence {
    var isProductive: Bool {
        if case .productive = self { return true }
        return false
    }

    var isDistracting: Bool {
        if case .distracting = self { return true }
        return false
    }
}

private final class CountingSemanticProvider: SemanticSimilarityProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func similarity(between text: String, and prototype: String) -> Double? {
        callCount += 1
        return 0.5
    }
}
