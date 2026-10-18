import Foundation

/// The classification stored for new sessions.  `recovered`, used by earlier
/// local JSON, is decoded as Productive so historical data remains readable.
public enum WaitSessionClassification: Codable, Equatable, Hashable, Sendable {
    case productive
    case distracted
    case unclassified

    public var title: String {
        switch self {
        case .productive: "Productive"
        case .distracted: "Distracted"
        case .unclassified: "Unclassified"
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "productive", "recovered": self = .productive
        case "distracted": self = .distracted
        case "unclassified": self = .unclassified
        default: throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Unsupported wait-session classification")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .productive: value = "productive"
        case .distracted: value = "distracted"
        case .unclassified: value = "unclassified"
        }
        try container.encode(value)
    }
}

public enum WaitSessionClassificationReason: Codable, Equatable, Sendable {
    case sustainedProductiveApplication
    case personalProductiveRule
    case sustainedProductiveContext
    case richActivityContext
    case personalDistractingRule
    case sustainedDistractingApplication
    case sustainedDistractingContext
    case sustainedSemanticProductiveContext
    case sustainedSemanticDistractingContext
    case mixedEvidence
    case insufficientActivityData
    case contextDependentActivity
    case meaningfulInactiveTime
    case noStrongEvidence
    case legacyIntentionSignal
    case legacyNoIntentionSignal
    case legacyMoveEvidence
    case unobservedGap
    case gameApplicationCategory
    case productiveApplicationCategory
    case distractingApplicationCategory
    case highConfidenceEntertainmentEvidence
    case codingPracticeContext
    case codingActivityContext
    case deterministicFallback
    case semanticContextUnavailable
    case semanticEmbeddingUnavailable
    case neutralSemanticCandidate
    case insufficientSemanticConfidence

    private var value: String {
        switch self {
        case .sustainedProductiveApplication: "sustainedProductiveApplication"
        case .personalProductiveRule: "personalProductiveRule"
        case .sustainedProductiveContext: "sustainedProductiveContext"
        case .richActivityContext: "richActivityContext"
        case .personalDistractingRule: "personalDistractingRule"
        case .sustainedDistractingApplication: "sustainedDistractingApplication"
        case .sustainedDistractingContext: "sustainedDistractingContext"
        case .sustainedSemanticProductiveContext: "sustainedSemanticProductiveContext"
        case .sustainedSemanticDistractingContext: "sustainedSemanticDistractingContext"
        case .mixedEvidence: "mixedEvidence"
        case .insufficientActivityData: "insufficientActivityData"
        case .contextDependentActivity: "contextDependentActivity"
        case .meaningfulInactiveTime: "meaningfulInactiveTime"
        case .noStrongEvidence: "noStrongEvidence"
        case .legacyIntentionSignal: "legacyIntentionSignal"
        case .legacyNoIntentionSignal: "legacyNoIntentionSignal"
        case .legacyMoveEvidence: "legacyMoveEvidence"
        case .unobservedGap: "unobservedGap"
        case .gameApplicationCategory: "gameApplicationCategory"
        case .productiveApplicationCategory: "productiveApplicationCategory"
        case .distractingApplicationCategory: "distractingApplicationCategory"
        case .highConfidenceEntertainmentEvidence: "highConfidenceEntertainmentEvidence"
        case .codingPracticeContext: "codingPracticeContext"
        case .codingActivityContext: "codingActivityContext"
        case .deterministicFallback: "deterministicFallback"
        case .semanticContextUnavailable: "semanticContextUnavailable"
        case .semanticEmbeddingUnavailable: "semanticEmbeddingUnavailable"
        case .neutralSemanticCandidate: "neutralSemanticCandidate"
        case .insufficientSemanticConfidence: "insufficientSemanticConfidence"
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "sustainedProductiveApplication", "sustainedIntentionalApplication": self = .sustainedProductiveApplication
        case "personalProductiveRule", "personalIntentionalRule": self = .personalProductiveRule
        case "sustainedProductiveContext", "sustainedIntentionalContext": self = .sustainedProductiveContext
        case "richActivityContext": self = .richActivityContext
        case "personalDistractingRule": self = .personalDistractingRule
        case "sustainedDistractingApplication", "userMarkedDistractingApplication": self = .sustainedDistractingApplication
        case "sustainedDistractingContext": self = .sustainedDistractingContext
        case "sustainedSemanticProductiveContext": self = .sustainedSemanticProductiveContext
        case "sustainedSemanticDistractingContext": self = .sustainedSemanticDistractingContext
        case "mixedEvidence": self = .mixedEvidence
        case "insufficientActivityData": self = .insufficientActivityData
        case "contextDependentActivity", "contextDependentApplication": self = .contextDependentActivity
        case "meaningfulInactiveTime": self = .meaningfulInactiveTime
        case "noStrongEvidence": self = .noStrongEvidence
        case "intentionSelected": self = .legacyIntentionSignal
        case "noIntentionSelected": self = .legacyNoIntentionSignal
        case "moveWithStableDesktopContext", "moveWithSustainedAway": self = .legacyMoveEvidence
        case "unobservedGap": self = .unobservedGap
        case "gameApplicationCategory": self = .gameApplicationCategory
        case "productiveApplicationCategory": self = .productiveApplicationCategory
        case "distractingApplicationCategory": self = .distractingApplicationCategory
        case "highConfidenceEntertainmentEvidence": self = .highConfidenceEntertainmentEvidence
        case "codingPracticeContext": self = .codingPracticeContext
        case "codingActivityContext": self = .codingActivityContext
        case "deterministicFallback": self = .deterministicFallback
        case "semanticContextUnavailable": self = .semanticContextUnavailable
        case "semanticEmbeddingUnavailable": self = .semanticEmbeddingUnavailable
        case "neutralSemanticCandidate": self = .neutralSemanticCandidate
        case "insufficientSemanticConfidence": self = .insufficientSemanticConfidence
        default: throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Unsupported wait-session classification reason")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct WaitSessionClassificationResult: Codable, Equatable, Sendable {
    public let classification: WaitSessionClassification
    public let reasonCodes: [WaitSessionClassificationReason]
    public let explanation: String?
    public let reviewSuggested: Bool

    public init(classification: WaitSessionClassification, reasonCodes: [WaitSessionClassificationReason], explanation: String? = nil, reviewSuggested: Bool = false) {
        self.classification = classification
        self.reasonCodes = reasonCodes
        self.explanation = explanation
        self.reviewSuggested = reviewSuggested
    }

    private enum CodingKeys: String, CodingKey { case classification, reasonCodes, explanation, reviewSuggested }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        classification = try c.decode(WaitSessionClassification.self, forKey: .classification)
        reasonCodes = try c.decode([WaitSessionClassificationReason].self, forKey: .reasonCodes)
        explanation = try c.decodeIfPresent(String.self, forKey: .explanation)
        reviewSuggested = try c.decodeIfPresent(Bool.self, forKey: .reviewSuggested) ?? false
    }
}

public struct WaitSessionClassificationRules: Equatable, Sendable {
    public static let defaultProductiveBundleIdentifiers: Set<String> = [
        "com.apple.dt.Xcode", "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.apple.iWork.Pages", "com.apple.Notes", "com.apple.Preview", "com.apple.Terminal", "com.apple.TextEdit", "com.googlecode.iterm2", "com.microsoft.VSCode"
    ]
    public static let defaultContextDependentBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "com.openai.chat", "com.openai.codex", "company.thebrowser.Browser", "org.mozilla.firefox"
    ]
    public let usuallyProductiveBundleIdentifiers: Set<String>
    public let usuallyDistractingBundleIdentifiers: Set<String>
    public let contextDependentBundleIdentifiers: Set<String>
    public let personalContextRules: [PersonalContextRule]

    public init(usuallyProductiveBundleIdentifiers: Set<String> = Self.defaultProductiveBundleIdentifiers, usuallyDistractingBundleIdentifiers: Set<String> = [], contextDependentBundleIdentifiers: Set<String> = Self.defaultContextDependentBundleIdentifiers, personalContextRules: [PersonalContextRule] = []) {
        self.usuallyProductiveBundleIdentifiers = usuallyProductiveBundleIdentifiers.subtracting(usuallyDistractingBundleIdentifiers)
        self.usuallyDistractingBundleIdentifiers = usuallyDistractingBundleIdentifiers
        self.contextDependentBundleIdentifiers = contextDependentBundleIdentifiers
        self.personalContextRules = personalContextRules
    }
}

public struct WaitSessionClassifier: Sendable {
    private static let codingContextTokens: Set<String> = [
        "api", "build", "code", "coding", "commit", "compile", "compiler", "debug",
        "debugging", "git", "gitlab", "implementation", "jupyter", "notebook",
        "programming", "pullrequest", "repository", "repo", "sdk", "source",
        "stacktrace", "testcase", "testing", "tests", "unittest"
    ]
    private static let codingContextPhrases = [
        "api reference", "code review", "coding challenge", "coding problem",
        "debug session", "git repository", "programming exercise", "source code",
        "unit tests"
    ]
    private static let developmentToolBundlePrefixes = [
        "com.apple.dt.", "com.barebones.", "com.jetbrains.", "com.microsoft.VSCode",
        "com.panic.Nova", "com.sublimetext."
    ]
    private static let sourceFileExtensionPattern =
        #"(?i)\.(?:c|cc|cpp|cs|css|go|h|hpp|html|ipynb|java|js|jsx|kt|m|mm|php|py|rb|rs|scala|sh|sql|swift|ts|tsx|vue)(?:$|[^a-z0-9])"#
    private static let productiveContextTokens: Set<String> = [
        "api", "coding", "compiler", "course", "courses", "debug", "debugging",
        "developer", "development", "documentation", "docs", "engineering", "guide",
        "guides", "learn", "learning", "lesson", "lessons", "manual", "programming",
        "reference", "research", "tutorial", "tutorials"
    ]
    private static let productiveContextPhrases = [
        "build a game", "game development", "software engineering", "tech jobs"
    ]
    private static let distractingContextTokens: Set<String> = [
        "gameshow", "gameplay"
    ]
    private static let distractingContextPhrases = [
        "comedy compilation", "game show", "gameplay video", "let s play",
        "movie trailer", "music video", "official trailer", "reaction compilation"
    ]
    private static let namedGameContextTokens: Set<String> = [
        "fortnite", "minecraft", "mario", "pokemon", "roblox", "zelda"
    ]
    public let rules: WaitSessionClassificationRules
    public let semanticAnalyzer: SemanticActivityAnalyzer

    public init(
        rules: WaitSessionClassificationRules = WaitSessionClassificationRules(),
        semanticAnalyzer: SemanticActivityAnalyzer = SemanticActivityAnalyzer()
    ) {
        self.rules = rules
        self.semanticAnalyzer = semanticAnalyzer
    }

    public func classify(_ session: WaitSession) -> WaitSessionClassificationResult? {
        summary(for: classificationSlices(for: session))
    }

    /// Builds a complete, non-overlapping timeline. Observed segments retain their
    /// persisted UUID; every uncovered interval becomes an explicit gap slice.
    public func classificationSlices(for session: WaitSession) -> [ActivityClassificationSlice] {
        guard session.state == .completed,
              let end = session.endTime ?? session.duration.map({ session.startTime.addingTimeInterval($0) }),
              end > session.startTime
        else { return [] }

        let interval = session.startTime..<end
        let observed = session.activitySegments.compactMap { segment -> (ActivitySegment, Date, Date)? in
            let rawEnd = segment.endedAt
                ?? segment.duration.map { segment.startedAt.addingTimeInterval($0) }
            guard let rawEnd else { return nil }
            let start = max(interval.lowerBound, segment.startedAt)
            let finish = min(interval.upperBound, rawEnd)
            guard finish > start else { return nil }
            return (segment, start, finish)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }

        var slices: [ActivityClassificationSlice] = []
        var cursor = interval.lowerBound
        for (segment, rawStart, rawEnd) in observed {
            let start = max(cursor, rawStart)
            if start > cursor { slices.append(gap(from: cursor, to: start)) }
            guard rawEnd > start else { continue }
            slices.append(ActivityClassificationSlice(
                sourceActivitySegmentID: segment.id,
                startedAt: start,
                endedAt: rawEnd,
                duration: rawEnd.timeIntervalSince(start),
                automaticClassificationResult: classify(context: segment.context)
            ))
            cursor = rawEnd
        }
        if cursor < interval.upperBound { slices.append(gap(from: cursor, to: interval.upperBound)) }
        return slices
    }

    /// Compatibility summary for legacy presentation fields. New-session
    /// decisions, corrections, and aggregation use the slices themselves.
    public func summary(for slices: [ActivityClassificationSlice]) -> WaitSessionClassificationResult? {
        guard !slices.isEmpty else { return nil }
        let observedSlices = slices
        let classifications = Set(observedSlices.map(\.automaticClassification))
        if classifications.count == 1, let classification = classifications.first {
            var reasons: [WaitSessionClassificationReason] = []
            for slice in observedSlices {
                for reason in slice.automaticClassificationResult.reasonCodes where !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
            return .init(
                classification: classification,
                reasonCodes: reasons,
                explanation: observedSlices.first?.automaticClassificationResult.explanation,
                reviewSuggested: observedSlices.contains { $0.automaticClassificationResult.reviewSuggested }
            )
        }
        let productiveDuration = observedSlices
            .filter { $0.automaticClassification == .productive }
            .reduce(0) { $0 + $1.duration }
        let distractedDuration = observedSlices
            .filter { $0.automaticClassification == .distracted }
            .reduce(0) { $0 + $1.duration }
        let fallback: WaitSessionClassification = productiveDuration > distractedDuration ? .productive : .distracted
        return .init(
            classification: fallback,
            reasonCodes: uniqueReasons(in: observedSlices) + [.mixedEvidence, .deterministicFallback],
            explanation: "This wait contains mixed activity; the summary uses the category with the greater observed duration.",
            reviewSuggested: false
        )
    }

    private func uniqueReasons(in slices: [ActivityClassificationSlice]) -> [WaitSessionClassificationReason] {
        slices.flatMap(\.automaticClassificationResult.reasonCodes).reduce(into: []) { result, reason in
            if !result.contains(reason) { result.append(reason) }
        }
    }

    public func classify(context: ActivityContext) -> WaitSessionClassificationResult {
        guard context.presenceState == .active else {
            return .init(
                classification: .distracted,
                reasonCodes: [.meaningfulInactiveTime, .deterministicFallback],
                explanation: "The captured foreground activity occurred while recent-input metadata indicated idle or away time; it is assigned Distracted as a deterministic fallback."
            )
        }

        let canonicalBundle = BuiltInActivityEvidencePolicy.canonicalBundleIdentifier(
            context.applicationBundleIdentifier
        )
        let personalRule = matchingPersonalRule(
            for: context,
            canonicalBundleIdentifier: canonicalBundle
        )
        if personalRule?.disposition == .productive {
            return .init(
                classification: .productive,
                reasonCodes: [.personalProductiveRule, .sustainedProductiveContext],
                explanation: "A personal Productive rule matched this activity."
            )
        }
        if supportsDistractingContext(context) {
            return .init(
                classification: .distracted,
                reasonCodes: [
                    .highConfidenceEntertainmentEvidence,
                    .sustainedDistractingContext,
                    .richActivityContext
                ],
                explanation: "The normalized title contains high-confidence entertainment or gaming evidence."
            )
        }
        // Specific code or programming-task evidence overrides broad personal
        // application rules, generic app categories, and semantic similarity.
        // A clear entertainment context above still takes precedence.
        if supportsCodingActivityContext(context) {
            var reasons: [WaitSessionClassificationReason] = [.codingActivityContext]
            if supportsCodingPracticeContext(context) {
                reasons.append(.codingPracticeContext)
            }
            reasons.append(.sustainedProductiveContext)
            return .init(
                classification: .productive,
                reasonCodes: reasons,
                explanation: "The captured activity context identifies software development or a programming task."
            )
        }
        if let rule = personalRule {
            switch rule.disposition {
            case .productive:
                return .init(classification: .productive, reasonCodes: [.personalProductiveRule, .sustainedProductiveContext], explanation: "A personal Productive rule matched this activity.")
            case .distracting:
                return .init(classification: .distracted, reasonCodes: [.personalDistractingRule, .sustainedDistractingContext], explanation: "A personal Distracting rule matched this activity.")
            case .contextDependent:
                return .init(
                    classification: .distracted,
                    reasonCodes: [.contextDependentActivity, .noStrongEvidence, .deterministicFallback],
                    explanation: "A personal Context-dependent rule had no decisive override; the deterministic Distracted fallback was applied."
                )
            }
        }
        if isDevelopmentTool(context) {
            return .init(
                classification: .productive,
                reasonCodes: [.codingActivityContext, .sustainedProductiveApplication],
                explanation: "The active application is a development environment without conflicting activity context."
            )
        }

        if BuiltInActivityEvidencePolicy.distractingBundleIdentifiers.contains(canonicalBundle)
            || rules.usuallyDistractingBundleIdentifiers.contains(canonicalBundle) {
            return .init(classification: .distracted, reasonCodes: [.sustainedDistractingApplication], explanation: "The active application has explicit distracting evidence.")
        }
        if rules.usuallyProductiveBundleIdentifiers.contains(canonicalBundle) {
            return .init(classification: .productive, reasonCodes: [.sustainedProductiveApplication], explanation: "The active application has strong work context.")
        }
        if !rules.contextDependentBundleIdentifiers.contains(canonicalBundle),
           let categoryClassification = BuiltInActivityEvidencePolicy.classification(
               forApplicationCategoryIdentifier: context.applicationCategoryIdentifier
           ) {
            switch categoryClassification {
            case .productive:
                return .init(
                    classification: .productive,
                    reasonCodes: [.productiveApplicationCategory, .sustainedProductiveApplication],
                    explanation: "The active application declares a productivity-oriented native category."
                )
            case .distracted:
                var reasonCodes: [WaitSessionClassificationReason] = [
                    .distractingApplicationCategory,
                    .sustainedDistractingApplication
                ]
                if BuiltInActivityEvidencePolicy.isGameCategory(
                    context.applicationCategoryIdentifier
                ) {
                    reasonCodes.insert(.gameApplicationCategory, at: 0)
                }
                return .init(
                    classification: .distracted,
                    reasonCodes: reasonCodes,
                    explanation: "The active application declares an entertainment-oriented native category."
                )
            case .unclassified:
                break
            }
        }
        if supportsProductiveContext(context) {
            return .init(classification: .productive, reasonCodes: [.sustainedProductiveContext, .richActivityContext], explanation: "Project, workspace, terminal, or learning metadata supports productive activity.")
        }
        let semanticAnalysis = semanticAnalyzer.analysis(for: context)
        if let semantic = semanticAnalysis.evidence {
            switch semantic {
            case .productive:
                return .init(classification: .productive, reasonCodes: [.sustainedSemanticProductiveContext, .richActivityContext], explanation: "Semantic context indicates development, documentation, learning, research, or task work.")
            case .distracting:
                return .init(classification: .distracted, reasonCodes: [.sustainedSemanticDistractingContext, .richActivityContext], explanation: "Semantic context strongly indicates entertainment or gaming.")
            }
        }
        let diagnosticReason: WaitSessionClassificationReason
        let explanation: String
        switch semanticAnalysis.fallback {
        case .contextUnavailable:
            diagnosticReason = .semanticContextUnavailable
            explanation = "No meaningful local activity metadata were available for semantic classification."
        case .embeddingUnavailable:
            diagnosticReason = .semanticEmbeddingUnavailable
            explanation = "The local sentence embedding could not score this activity."
        case .neutralConcept:
            diagnosticReason = .neutralSemanticCandidate
            explanation = "The strongest local semantic candidate was neutral."
        case .insufficientConfidence:
            diagnosticReason = .insufficientSemanticConfidence
            explanation = "The local semantic match did not meet its confidence threshold."
        case nil:
            diagnosticReason = .noStrongEvidence
            explanation = "The available local activity metadata are not strong enough to classify this interval."
        }
        return .init(
            classification: .distracted,
            reasonCodes: [.contextDependentActivity, .noStrongEvidence, diagnosticReason, .deterministicFallback],
            explanation: "\(explanation) Distracted is the deterministic fallback when the available evidence does not establish productive activity."
        )
    }

    private func gap(from start: Date, to end: Date) -> ActivityClassificationSlice {
        ActivityClassificationSlice(
            sourceActivitySegmentID: nil,
            startedAt: start,
            endedAt: end,
            duration: end.timeIntervalSince(start),
            automaticClassificationResult: .init(
                classification: .distracted,
                reasonCodes: [.unobservedGap, .insufficientActivityData, .deterministicFallback],
                explanation: "Inbetween did not observe activity during this interval; Distracted was assigned as the deterministic fallback."
            ),
            classificationReviewHandled: true
        )
    }

    private func matchingPersonalRule(
        for context: ActivityContext,
        canonicalBundleIdentifier: String
    ) -> PersonalContextRule? {
        let evaluator = PersonalContextRuleEvaluator(rules: rules.personalContextRules)
        if let direct = evaluator.matchingRule(for: context) { return direct }
        guard canonicalBundleIdentifier != context.applicationBundleIdentifier,
              let canonicalContext = ActivityContext(
                applicationBundleIdentifier: canonicalBundleIdentifier,
                applicationName: context.applicationName,
                applicationCategoryIdentifier: context.applicationCategoryIdentifier,
                windowTitle: context.windowTitle,
                browserDomain: context.browserDomain,
                browserPageTitle: context.browserPageTitle,
                browserURL: context.browserURL,
                resourceKind: context.resourceKind,
                resourceName: context.resourceName,
                documentName: context.documentName,
                resourcePath: context.resourcePath,
                presenceState: context.presenceState,
                provenance: context.provenance
              )
        else { return nil }
        return evaluator.matchingRule(for: canonicalContext)
    }

    private func supportsProductiveContext(_ context: ActivityContext) -> Bool {
        if context.resourceKind == .project || context.resourceKind == .workspace || context.resourceKind == .terminal { return true }
        guard context.hasRichMetadata else { return false }
        if !metadataTokens(in: context).isDisjoint(with: Self.productiveContextTokens) {
            return true
        }
        return classificationTitleValues(in: context).contains { value in
            containsAnyPhrase(Self.productiveContextPhrases, in: value)
        }
    }

    private func supportsCodingActivityContext(_ context: ActivityContext) -> Bool {
        if supportsCodingPracticeContext(context) { return true }

        let values = metadataValues(in: context)
        let tokens = Set(values.flatMap { value in
            value.lowercased().unicodeScalars
                .split { !CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
        })
        if !tokens.isDisjoint(with: Self.codingContextTokens) {
            return true
        }
        if values.contains(where: { containsAnyPhrase(Self.codingContextPhrases, in: $0) }) {
            return true
        }
        if values.contains(where: { $0.range(of: Self.sourceFileExtensionPattern, options: .regularExpression) != nil }) {
            return true
        }

        if let url = context.browserURL,
           let components = URLComponents(string: url),
           let host = components.host?.lowercased(),
           ["github.com", "gitlab.com", "bitbucket.org"].contains(host),
           components.path.split(separator: "/").count >= 2 {
            return true
        }

        return false
    }

    private func isDevelopmentTool(_ context: ActivityContext) -> Bool {
        let bundle = BuiltInActivityEvidencePolicy.canonicalBundleIdentifier(
            context.applicationBundleIdentifier
        )
        return Self.developmentToolBundlePrefixes.contains { bundle.hasPrefix($0) }
            || bundle == "com.apple.Terminal"
            || bundle == "com.googlecode.iterm2"
            || bundle == "com.github.atom"
            || bundle == "org.python.python"
            || bundle == "org.jupyter.jupyterlab"
    }

    /// A LeetCode domain alone is not evidence of programming. A problem URL
    /// with a concrete slug is a specific coding-practice context; a landing,
    /// discussion, or generic browser page remains context-dependent.
    private func supportsCodingPracticeContext(_ context: ActivityContext) -> Bool {
        guard let browserURL = context.browserURL,
              let components = URLComponents(string: browserURL),
              let host = components.host?.lowercased(),
              host == "leetcode.com" || host == "www.leetcode.com"
        else { return false }

        let path = components.path.split(separator: "/").map {
            String($0).removingPercentEncoding?.lowercased() ?? String($0).lowercased()
        }
        guard path.count >= 2,
              path[0] == "problems",
              !["description", "solution", "submissions"].contains(path[1])
        else { return false }
        return path[1].unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    private func supportsDistractingContext(_ context: ActivityContext) -> Bool {
        guard context.hasRichMetadata else { return false }
        let values = classificationTitleValues(in: context)
        let tokens = Set(values.flatMap { value in
            value.lowercased().unicodeScalars
                .split { !CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
        })
        if !tokens.isDisjoint(with: Self.distractingContextTokens) {
            return true
        }
        if values.contains(where: { containsAnyPhrase(Self.distractingContextPhrases, in: $0) }) {
            return true
        }
        let hasNamedGameContext = !tokens.isDisjoint(with: Self.namedGameContextTokens)
        let hasChallengeFraming = tokens.contains("race")
            && (!tokens.isDisjoint(with: ["challenge", "challenged", "impossible"]))
        return hasNamedGameContext && hasChallengeFraming
    }

    private func metadataTokens(in context: ActivityContext) -> Set<String> {
        Set(metadataValues(in: context).flatMap { value in
            value.lowercased().unicodeScalars
                .split { !CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
        })
    }

    private func normalizedMetadataText(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined(separator: " ")
    }

    private func metadataValues(in context: ActivityContext) -> [String] {
        [
            ClassificationTitleNormalizer.normalize(context.windowTitle),
            context.browserDomain,
            ClassificationTitleNormalizer.normalize(context.browserPageTitle),
            context.browserURL,
            context.resourceName,
            context.documentName,
            context.resourcePath
        ].compactMap { $0 }
    }

    private func classificationTitleValues(in context: ActivityContext) -> [String] {
        [
            ClassificationTitleNormalizer.normalize(context.windowTitle),
            ClassificationTitleNormalizer.normalize(context.browserPageTitle),
            context.resourceName,
            context.documentName
        ].compactMap { $0 }
    }

    private func containsAnyPhrase(_ phrases: [String], in value: String) -> Bool {
        let normalized = normalizedMetadataText(value)
        return phrases.contains { phrase in
            " \(normalized) ".contains(" \(phrase) ")
        }
    }
}

public enum BuiltInActivityEvidencePolicy {
    public static let gamesCategoryIdentifier = "public.app-category.games"
    public static let productiveCategoryIdentifiers: Set<String> = [
        "public.app-category.business",
        "public.app-category.developer-tools",
        "public.app-category.education",
        "public.app-category.finance",
        "public.app-category.productivity",
        "public.app-category.reference",
        "public.app-category.utilities"
    ]
    public static let distractingCategoryIdentifiers: Set<String> = [
        "public.app-category.entertainment"
    ]
    public static let distractingBundleIdentifiers: Set<String> = [
        "com.valvesoftware.steam",
        "com.hnc.Discord",
        "com.apple.ScreenContinuity"
    ]

    public static func canonicalBundleIdentifier(_ rawValue: String) -> String {
        switch rawValue {
        case "com.valvesoftware.steam.helper": "com.valvesoftware.steam"
        default: rawValue
        }
    }

    public static func classification(
        forApplicationCategoryIdentifier rawValue: String?
    ) -> WaitSessionClassification? {
        guard let identifier = normalizedCategoryIdentifier(rawValue) else { return nil }
        if productiveCategoryIdentifiers.contains(identifier) { return .productive }
        if distractingCategoryIdentifiers.contains(identifier) || isGameCategory(identifier) {
            return .distracted
        }
        return nil
    }

    public static func isGameCategory(_ rawValue: String?) -> Bool {
        guard let identifier = normalizedCategoryIdentifier(rawValue) else { return false }
        return identifier == gamesCategoryIdentifier
            || (identifier.hasPrefix("public.app-category.") && identifier.hasSuffix("-games"))
    }

    private static func normalizedCategoryIdentifier(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else { return nil }
        return value
    }
}
