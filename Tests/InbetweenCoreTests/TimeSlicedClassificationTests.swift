import Foundation
import Testing
@testable import InbetweenCore

struct TimeSlicedClassificationTests {
    @Test func mixedTimelineReconcilesExactlyAndPreservesShortIntervals() throws {
        let sessionID = UUID()
        let session = completed(
            id: sessionID,
            duration: 60,
            segments: [
                segment(sessionID, 0, 20, context: context("com.apple.dt.Xcode", "Xcode")),
                segment(sessionID, 25, 40, context: context("com.valvesoftware.steam", "Steam")),
                segment(sessionID, 40, 50, context: context("com.apple.dt.Xcode", "Xcode", presence: .idle))
            ]
        )
        let slices = WaitSessionClassifier().classificationSlices(for: session)

        #expect(slices.reduce(0) { $0 + $1.duration } == 60)
        #expect(slices.map(\.duration) == [20, 5, 15, 10, 10])
        #expect(slices.map(\.automaticClassification) == [
            .productive, .unclassified, .distracted, .unclassified, .unclassified
        ])
        #expect(slices.filter(\.isUnobservedGap).map(\.duration) == [5, 10])
        #expect(slices[0].sourceActivitySegmentID == session.activitySegments[0].id)
        #expect(slices[2].sourceActivitySegmentID == session.activitySegments[1].id)
    }

    @Test func slicePersistenceKeepsAutomaticResultOverrideAndSourceIdentity() throws {
        let sourceID = UUID()
        let slice = ActivityClassificationSlice(
            sourceActivitySegmentID: sourceID,
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_020),
            duration: 20,
            automaticClassificationResult: .init(
                classification: .productive,
                reasonCodes: [.sustainedProductiveApplication]
            ),
            manualClassificationOverride: .distracted,
            classificationReviewHandled: true
        )
        let session = WaitSession(
            codexSessionID: "s", codexTurnID: "t",
            startTime: slice.startedAt, endTime: slice.endedAt,
            duration: 20, state: .completed,
            activityClassificationSlices: [slice]
        )
        let decoded = try JSONDecoder().decode(
            WaitSession.self,
            from: JSONEncoder().encode(session)
        )
        #expect(decoded.activityClassificationSlices == [slice])
        #expect(decoded.activityClassificationSlices?.first?.sourceActivitySegmentID == sourceID)
        #expect(decoded.activityClassificationSlices?.first?.effectiveClassification == .distracted)
    }

    @Test func stopCreatesSlicesButLegacyJSONRetainsNilDiscriminator() throws {
        var tracker = WaitSessionTracker()
        _ = tracker.apply(event(.userPromptSubmit, 1_000))
        _ = tracker.recordActivity(ActivityObservation(
            context: context("com.apple.dt.Xcode", "Xcode"),
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))
        _ = tracker.apply(event(.stop, 1_020))
        #expect(tracker.sessions[0].activityClassificationSlices?.first?.duration == 20)

        let legacy = try JSONDecoder().decode(WaitSession.self, from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","codexSessionID":"s","codexTurnID":"t","startTime":1000,"endTime":1020,"duration":20,"state":"completed","hookSource":"h","hookVersion":1}"#.utf8))
        #expect(legacy.activityClassificationSlices == nil)
    }

    @Test func stopClassifiesPersistedBrowserTitlesPerSlice() throws {
        let classifier = WaitSessionClassifier(
            rules: .init(usuallyProductiveBundleIdentifiers: []),
            semanticAnalyzer: SemanticActivityAnalyzer(provider: SliceSemanticStub([:]))
        )
        var tracker = WaitSessionTracker(classifier: classifier)
        _ = tracker.apply(event(.userPromptSubmit, 1_000))
        let gameshow = context(
            "com.google.Chrome", "Google Chrome", domain: "youtube.com",
            title: "(42) This gameshow lets you use ANY GAME you own - YouTube - Audio playing - Google Chrome"
        )
        let tutorial = context(
            "com.google.Chrome", "Google Chrome", domain: "youtube.com",
            title: "Swift concurrency tutorial: actors and async await"
        )
        _ = tracker.recordActivity(ActivityObservation(
            context: gameshow,
            observedAt: Date(timeIntervalSince1970: 1_000)
        ))
        _ = tracker.recordActivity(ActivityObservation(
            context: tutorial,
            observedAt: Date(timeIntervalSince1970: 1_030)
        ))
        _ = tracker.apply(event(.stop, 1_060))

        let session = try #require(tracker.sessions.first)
        let slices = try #require(session.activityClassificationSlices)
        #expect(session.activitySegments.map(\.context.browserPageTitle) == [
            gameshow.browserPageTitle, tutorial.browserPageTitle
        ])
        #expect(slices.map(\.automaticClassification) == [.distracted, .productive])
        #expect(slices.map(\.sourceActivitySegmentID) == session.activitySegments.map(\.id))
        #expect(session.classificationResult?.classification == .unclassified)
        #expect(session.classificationResult?.reasonCodes.contains(.mixedEvidence) == true)
    }

    @Test func presenceGatesAllForegroundEvidence() {
        let classifier = WaitSessionClassifier()
        for presence in [UserPresenceState.idle, .away] {
            let result = classifier.classify(context: context(
                "com.valvesoftware.steam", "Steam", category: "public.app-category.games",
                presence: presence
            ))
            #expect(result.classification == .unclassified)
            #expect(result.reasonCodes.contains(.meaningfulInactiveTime))
        }
    }

    @Test func builtInsGamesCanonicalizationAndPersonalRulesFollowPrecedence() throws {
        let classifier = WaitSessionClassifier()
        for (bundle, name) in [
            ("com.valvesoftware.steam", "Steam"),
            ("com.valvesoftware.steam.helper", "Steam Helper"),
            ("com.hnc.Discord", "Discord"),
            ("com.apple.ScreenContinuity", "iPhone Mirroring")
        ] {
            #expect(classifier.classify(context: context(bundle, name)).classification == .distracted)
        }
        #expect(BuiltInActivityEvidencePolicy.canonicalBundleIdentifier(
            "com.valvesoftware.steam.helper"
        ) == "com.valvesoftware.steam")
        #expect(classifier.classify(context: context(
            "com.example.game", "Game", category: "public.app-category.games"
        )).reasonCodes.contains(.gameApplicationCategory))

        let productiveSteam = try #require(PersonalContextRule(
            scope: .applicationBundleIdentifier,
            pattern: "com.valvesoftware.steam",
            disposition: .productive
        ))
        let overridden = WaitSessionClassifier(rules: .init(personalContextRules: [productiveSteam]))
        #expect(overridden.classify(context: context(
            "com.valvesoftware.steam", "Steam"
        )).classification == .productive)
        #expect(overridden.classify(context: context(
            "com.valvesoftware.steam.helper", "Steam Helper"
        )).classification == .productive)

        let unresolvedSteam = try #require(PersonalContextRule(
            scope: .applicationBundleIdentifier,
            pattern: "com.valvesoftware.steam",
            disposition: .contextDependent
        ))
        let unresolved = WaitSessionClassifier(rules: .init(personalContextRules: [unresolvedSteam]))
        #expect(unresolved.classify(context: context(
            "com.valvesoftware.steam", "Steam"
        )).classification == .unclassified)
    }

    @Test func contextualAppsAndGenericBrowserStayUnclassifiedWhileStructureCounts() {
        let classifier = WaitSessionClassifier()
        #expect(classifier.classify(context: context("com.openai.chat", "ChatGPT")).classification == .unclassified)
        #expect(classifier.classify(context: context(
            "com.google.Chrome", "Google Chrome", domain: "example.net", title: "Welcome"
        )).classification == .unclassified)
        #expect(classifier.classify(context: context(
            "com.google.Chrome", "Google Chrome", resourceKind: .project
        )).classification == .productive)
    }

    @Test func nativeApplicationCategoriesClassifyConservativelyAndPersistReasons() throws {
        let classifier = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []))
        let productiveCategories = [
            "business", "developer-tools", "education", "finance",
            "productivity", "reference", "utilities"
        ]
        for category in productiveCategories {
            let result = classifier.classify(context: context(
                "com.example.\(category)", category,
                category: "public.app-category.\(category)"
            ))
            #expect(result.classification == .productive)
            #expect(result.reasonCodes.contains(.productiveApplicationCategory))
        }

        for category in ["entertainment", "games", "board-games", "strategy-games"] {
            let result = classifier.classify(context: context(
                "com.example.\(category)", category,
                category: "public.app-category.\(category)"
            ))
            #expect(result.classification == .distracted)
            #expect(result.reasonCodes.contains(.distractingApplicationCategory))
        }

        let result = classifier.classify(context: context(
            "com.example.utility", "Utility",
            category: "public.app-category.utilities"
        ))
        let decoded = try JSONDecoder().decode(
            WaitSessionClassificationResult.self,
            from: JSONEncoder().encode(result)
        )
        #expect(decoded.reasonCodes.contains(.productiveApplicationCategory))
    }

    @Test func contextualAndAmbiguousCategoriesRemainUnclassifiedWithoutStrongerEvidence() {
        let classifier = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: []))
        for bundle in WaitSessionClassificationRules.defaultContextDependentBundleIdentifiers {
            let result = classifier.classify(context: context(
                bundle, "Context-dependent app",
                category: "public.app-category.productivity"
            ))
            #expect(result.classification == .unclassified)
            #expect(!result.reasonCodes.contains(.productiveApplicationCategory))
        }

        for category in [
            "music", "video", "social-networking", "news", "lifestyle",
            "photography", "graphics-design"
        ] {
            let result = classifier.classify(context: context(
                "com.example.\(category)", category,
                category: "public.app-category.\(category)"
            ))
            #expect(result.classification == .unclassified)
            #expect(result.reviewSuggested)
        }
    }

    @Test func personalRuleOverridesNativeApplicationCategory() throws {
        let rule = try #require(PersonalContextRule(
            scope: .applicationBundleIdentifier,
            pattern: "com.example.utility",
            disposition: .distracting
        ))
        let classifier = WaitSessionClassifier(rules: .init(
            usuallyProductiveBundleIdentifiers: [],
            personalContextRules: [rule]
        ))

        let result = classifier.classify(context: context(
            "com.example.utility", "Utility",
            category: "public.app-category.utilities"
        ))

        #expect(result.classification == .distracted)
        #expect(result.reasonCodes.contains(.personalDistractingRule))
        #expect(!result.reasonCodes.contains(.productiveApplicationCategory))
    }

    @Test func semanticConfidenceCompetesAcrossDispositionsNotSiblingCategories() {
        let analyzer = SemanticActivityAnalyzer(provider: SliceSemanticStub([
            .softwareDevelopment: 0.70,
            .technicalDocumentation: 0.695,
            .communication: 0.66,
            .entertainment: 0.40
        ]))
        let evidence = analyzer.evidence(for: context(
            "com.google.Chrome", "Google Chrome",
            domain: "developer.apple.com", title: "Swift concurrency documentation"
        ))
        guard case let .productive(inference) = evidence else {
            Issue.record("Expected Productive semantic evidence")
            return
        }
        #expect(inference.category == .softwareDevelopment)
        #expect(inference.competingCategory == .communication)
        #expect(inference.margin > 0.015)
    }

    @Test func browserSemanticInputRejectsChromeAndUsesCleanTechnicalMetadata() throws {
        #expect(SemanticActivityDescription(context: context(
            "com.google.Chrome", "Google Chrome", title: "New Tab"
        )) == nil)
        let aws = context(
            "com.google.Chrome", "Google Chrome",
            domain: "docs.aws.amazon.com",
            title: "AWS Lambda developer guide",
            url: "https://docs.aws.amazon.com/lambda/123e4567-e89b-12d3-a456-426614174000/latest/dg/welcome.html?tracking=secret#anchor"
        )
        let description = try #require(SemanticActivityDescription(context: aws))
        #expect(description.text.hasPrefix("Page: AWS Lambda developer guide | Domain: docs.aws.amazon.com | Path:"))
        #expect(!description.text.contains("tracking"))
        #expect(!description.text.contains("secret"))
        #expect(!description.text.contains("anchor"))
        #expect(!description.text.contains("123e4567"))
    }

    @Test func entertainmentYouTubeDoesNotBecomeProductive() {
        let analyzer = SemanticActivityAnalyzer(provider: SliceSemanticStub([
            .entertainment: 0.91, .studyingLearning: 0.42, .generalBrowsing: 0.50
        ]))
        let classifier = WaitSessionClassifier(
            rules: .init(usuallyProductiveBundleIdentifiers: []),
            semanticAnalyzer: analyzer
        )
        let result = classifier.classify(context: context(
            "com.google.Chrome", "Google Chrome", domain: "youtube.com",
            title: "Celebrity highlights and comedy compilation"
        ))
        #expect(result.classification == .distracted)
        #expect(!result.reasonCodes.contains(.sustainedSemanticProductiveContext))
    }

    private func completed(id: UUID, duration: TimeInterval, segments: [ActivitySegment]) -> WaitSession {
        let start = Date(timeIntervalSince1970: 1_000)
        return WaitSession(id: id, codexSessionID: "s", codexTurnID: "t", startTime: start, endTime: start.addingTimeInterval(duration), duration: duration, state: .completed, activitySegments: segments)
    }

    private func segment(_ waitID: UUID, _ startOffset: TimeInterval, _ endOffset: TimeInterval, context: ActivityContext) -> ActivitySegment {
        let origin = Date(timeIntervalSince1970: 1_000)
        let start = origin.addingTimeInterval(startOffset)
        let end = origin.addingTimeInterval(endOffset)
        return ActivitySegment(waitSessionID: waitID, context: context, startedAt: start, endedAt: end, duration: endOffset - startOffset, lastObservedAt: end)
    }

    private func context(
        _ bundle: String,
        _ name: String,
        category: String? = nil,
        domain: String? = nil,
        title: String? = nil,
        url: String? = nil,
        resourceKind: ActivityResourceKind? = nil,
        presence: UserPresenceState = .active
    ) -> ActivityContext {
        ActivityContext(applicationBundleIdentifier: bundle, applicationName: name, applicationCategoryIdentifier: category, browserDomain: domain, browserPageTitle: title, browserURL: url, resourceKind: resourceKind, presenceState: presence)!
    }

    private func event(_ name: LifecycleEventName, _ time: TimeInterval) -> LifecycleEvent {
        LifecycleEvent(name: name, sessionID: "s", turnID: "t", observedAt: time)
    }
}

private struct SliceSemanticStub: SemanticSimilarityProviding {
    let scores: [SemanticActivityCategory: Double]
    init(_ scores: [SemanticActivityCategory: Double]) { self.scores = scores }
    func similarity(between text: String, and prototype: String) -> Double? {
        guard let category = SemanticActivityCategory.allCases.first(where: {
            $0.prototypes.contains(prototype)
        }) else { return nil }
        return scores[category] ?? 0.1
    }
}
