import Foundation
import NaturalLanguage

/// Removes presentation-only browser chrome from titles used by the local
/// classifier. The captured `ActivityContext` remains unchanged and is still
/// the source of truth for history and review.
enum ClassificationTitleNormalizer {
    private static let genericTitles: Set<String> = [
        "arc", "audio playing", "brave", "chromium", "google chrome",
        "leetcode", "microsoft edge", "mozilla firefox", "safari", "youtube"
    ]
    private static let trailingChromePattern =
        #"\s*[-–—|]\s*(?:arc|audio playing|brave|chromium|google chrome|leetcode|microsoft edge|mozilla firefox|safari|youtube)\s*$"#

    static func normalize(_ value: String?) -> String? {
        guard var normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else { return nil }

        normalized = normalized.replacingOccurrences(
            of: #"^(?:\(\d+\)\s*)+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        while true {
            let stripped = normalized.replacingOccurrences(
                of: trailingChromePattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard stripped != normalized else { break }
            normalized = stripped
        }

        guard !normalized.isEmpty,
              !genericTitles.contains(normalized.lowercased())
        else { return nil }
        return normalized
    }
}

/// A compact, inspectable description made solely from activity metadata that
/// Inbetween already collects. It deliberately excludes page bodies, source
/// contents, prompts, and all input data.
public struct SemanticActivityDescription: Equatable, Sendable {
    public let text: String

    public init?(context: ActivityContext) {
        let isBrowser = context.browserDomain != nil
            || context.browserURL != nil
            || Self.browserBundleIdentifiers.contains(context.applicationBundleIdentifier)
        var parts: [String] = []
        if isBrowser {
            // Browser tab APIs and Accessibility do not always agree. A generic
            // tab title must not hide a useful window title.
            if let title = Self.meaningfulBrowserTitle(context.browserPageTitle)
                ?? Self.meaningfulBrowserTitle(context.windowTitle) {
                parts.append("Page: \(title)")
            }
            if let domain = context.browserDomain.map(Self.normalizedDomain),
               !Self.genericBrowserDomains.contains(domain) {
                parts.append("Domain: \(domain)")
            }
            if let path = Self.meaningfulBrowserPath(context.browserURL) {
                parts.append("Path: \(path)")
            }
            guard !parts.isEmpty else { return nil }
        } else {
            parts.append("App: \(context.applicationName)")
            if let title = ClassificationTitleNormalizer.normalize(context.browserPageTitle) {
                parts.append("Page: \(title)")
            }
            if let title = ClassificationTitleNormalizer.normalize(context.windowTitle) {
                parts.append("Window: \(title)")
            }
        }
        if let kind = context.resourceKind { parts.append("Resource type: \(kind.rawValue)") }
        if let name = context.resourceName { parts.append("Context: \(name)") }
        if let document = context.documentName { parts.append("Document: \(document)") }
        if let path = context.resourcePath { parts.append("Path: \(path)") }
        let representation = parts.joined(separator: " | ")
        guard representation != "App: \(context.applicationName)" || context.hasRichMetadata else {
            return nil
        }
        text = String(representation.prefix(800))
    }

    private static let browserBundleIdentifiers: Set<String> = [
        "com.apple.Safari", "com.brave.Browser", "com.google.Chrome",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "org.mozilla.firefox"
    ]

    private static let genericBrowserTitles: Set<String> = [
        "about:blank", "blank page", "new tab", "start page", "welcome"
    ]
    private static let genericBrowserDomains: Set<String> = [
        "example.com", "example.net", "example.org", "localhost"
    ]

    private static func meaningfulBrowserTitle(_ value: String?) -> String? {
        guard let normalized = ClassificationTitleNormalizer.normalize(value),
              !genericBrowserTitles.contains(normalized.lowercased())
        else { return nil }
        return normalized
    }

    private static func normalizedDomain(_ value: String) -> String {
        let lower = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    private static func meaningfulBrowserPath(_ value: String?) -> String? {
        guard let value, let components = URLComponents(string: value) else { return nil }
        let pieces = components.path.split(separator: "/").compactMap { raw -> String? in
            let part = String(raw).removingPercentEncoding ?? String(raw)
            let alphaNumeric = part.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            let isLongOpaqueToken = part.count >= 24
                && part.rangeOfCharacter(from: CharacterSet(charactersIn: "-_.")) == nil
            let isLongNumericToken = part.count >= 8
                && part.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
            let isLongHexToken = part.count >= 16
                && part.unicodeScalars.allSatisfy(
                    CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains
                )
            guard !part.isEmpty,
                  part.count <= 48,
                  UUID(uuidString: part) == nil,
                  !isLongOpaqueToken,
                  !isLongNumericToken,
                  !isLongHexToken,
                  !alphaNumeric.isEmpty
            else { return nil }
            return part.replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.prefix(4).joined(separator: " / ")
    }
}

public enum SemanticActivityCategory: String, CaseIterable, Sendable {
    case softwareDevelopment
    case technicalDocumentation
    case studyingLearning
    case research
    case workTaskExecution
    case communication
    case entertainment
    case gaming
    case generalBrowsing

    /// Short prototype phrases are centralized here so the classification layer
    /// does not rely on scattered site or title allowlists. Entertainment uses
    /// several focused concepts because one broad centroid under-represented
    /// real gaming, reaction, music, and pop-culture titles.
    public var prototypes: [String] {
        switch self {
        case .softwareDevelopment:
            [
                "software development programming coding source code project workspace",
                "solving programming problems coding interview practice algorithms data structures"
            ]
        case .technicalDocumentation:
            ["technical documentation API reference developer guide"]
        case .studyingLearning:
            ["studying learning tutorial lesson educational course"]
        case .research:
            ["research investigation technical analysis scholarly information"]
        case .workTaskExecution:
            ["work task execution planning writing project management"]
        case .communication:
            ["communication conversation messaging chat email"]
        case .entertainment:
            [
                "comedy reaction entertainment funny compilation humor",
                "casual entertainment video variety show leisure watching",
                "music video movie trailer television entertainment",
                "pop culture celebrity entertainment highlights"
            ]
        case .gaming:
            [
                "gaming entertainment gameplay let's play game stream",
                "video game challenge speedrun gaming race"
            ]
        case .generalBrowsing:
            ["general web browsing news social media website"]
        }
    }

    /// The primary phrase remains available to development tooling that labels
    /// scores by semantic category.
    public var prototype: String { prototypes[0] }

    public var isProductiveConcept: Bool {
        switch self {
        case .softwareDevelopment, .technicalDocumentation, .studyingLearning, .research, .workTaskExecution: true
        case .communication, .entertainment, .gaming, .generalBrowsing: false
        }
    }

    public var isPotentiallyDistractingConcept: Bool {
        self == .entertainment || self == .gaming
    }

    fileprivate var disposition: SemanticActivityDisposition {
        if isProductiveConcept { return .productive }
        if isPotentiallyDistractingConcept { return .distracting }
        return .neutral
    }
}

private enum SemanticActivityDisposition {
    case productive, distracting, neutral
}

public struct SemanticActivityInference: Equatable, Sendable {
    public let description: SemanticActivityDescription
    public let category: SemanticActivityCategory
    /// Normalized native embedding similarity (higher is more similar).
    public let similarity: Double
    public let competingCategory: SemanticActivityCategory?
    public let competingSimilarity: Double?

    public var margin: Double {
        similarity - (competingSimilarity ?? 0)
    }
}

public struct SemanticActivityThresholds: Equatable, Sendable {
    /// Native sentence-vector cosine scores for short local metadata commonly
    /// fall in the 0.4–0.55 range. Productive concepts therefore need at least
    /// 0.45 plus 0.015 separation from their runner-up; weak generic pages in
    /// the evaluation set stay below one or both values.
    public let productiveSimilarity: Double
    public let productiveMargin: Double
    /// Entertainment/gaming is held to a stricter bar before it contributes
    /// distracting evidence. Its larger margin keeps ordinary browsing and
    /// weak gaming/entertainment matches Unclassified.
    public let distractingSimilarity: Double
    public let distractingMargin: Double

    public init(
        productiveSimilarity: Double = 0.45,
        productiveMargin: Double = 0.015,
        distractingSimilarity: Double = 0.50,
        distractingMargin: Double = 0.04
    ) {
        self.productiveSimilarity = productiveSimilarity
        self.productiveMargin = productiveMargin
        self.distractingSimilarity = distractingSimilarity
        self.distractingMargin = distractingMargin
    }
}

public protocol SemanticSimilarityProviding: Sendable {
    func similarity(between text: String, and prototype: String) -> Double?
}

/// Uses macOS's built-in English sentence embedding. When it is unavailable,
/// semantic inference simply returns nil and the existing classifier remains
/// authoritative.
public final class NativeSemanticSimilarityProvider: SemanticSimilarityProviding, @unchecked Sendable {
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    public init() {}

    public func similarity(between text: String, and prototype: String) -> Double? {
        guard let embedding,
              let textVector = embedding.vector(for: text),
              let prototypeVector = embedding.vector(for: prototype),
              textVector.count == prototypeVector.count
        else { return nil }
        let dot = zip(textVector, prototypeVector).reduce(0) { $0 + $1.0 * $1.1 }
        let textMagnitude = sqrt(textVector.reduce(0) { $0 + $1 * $1 })
        let prototypeMagnitude = sqrt(prototypeVector.reduce(0) { $0 + $1 * $1 })
        guard textMagnitude > 0, prototypeMagnitude > 0 else { return nil }
        let score = dot / (textMagnitude * prototypeMagnitude)
        return score.isFinite ? score : nil
    }
}

/// Content-free semantic fallback reasons. They are safe to persist as local
/// classification diagnostics because they contain no activity metadata.
public enum SemanticActivityFallback: Equatable, Sendable {
    case contextUnavailable
    case embeddingUnavailable
    case neutralConcept
    case insufficientConfidence
}

public struct SemanticActivityAnalysis: Equatable, Sendable {
    public let inference: SemanticActivityInference?
    public let evidence: SemanticEvidence?
    public let fallback: SemanticActivityFallback?

    public init(
        inference: SemanticActivityInference?,
        evidence: SemanticEvidence?,
        fallback: SemanticActivityFallback?
    ) {
        self.inference = inference
        self.evidence = evidence
        self.fallback = fallback
    }
}

/// Classification-time semantic analysis. The in-memory cache is keyed by the
/// complete meaningful representation, so unchanged foreground samples are
/// never embedded repeatedly. No vectors are persisted.
public final class SemanticActivityAnalyzer: @unchecked Sendable {
    private let provider: any SemanticSimilarityProviding
    private let thresholds: SemanticActivityThresholds
    private let lock = NSLock()
    private var cache: [String: SemanticActivityAnalysis] = [:]

    public init(
        provider: any SemanticSimilarityProviding = NativeSemanticSimilarityProvider(),
        thresholds: SemanticActivityThresholds = SemanticActivityThresholds()
    ) {
        self.provider = provider
        self.thresholds = thresholds
    }

    public func inference(for context: ActivityContext) -> SemanticActivityInference? {
        analysis(for: context).inference
    }

    public func evidence(for context: ActivityContext) -> SemanticEvidence? {
        analysis(for: context).evidence
    }

    public func analysis(for context: ActivityContext) -> SemanticActivityAnalysis {
        guard let description = SemanticActivityDescription(context: context) else {
            return SemanticActivityAnalysis(
                inference: nil,
                evidence: nil,
                fallback: .contextUnavailable
            )
        }
        lock.lock()
        if let cached = cache[description.text] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let scores = SemanticActivityCategory.allCases.compactMap { category -> (SemanticActivityCategory, Double)? in
            category.prototypes.compactMap {
                provider.similarity(between: description.text, and: $0)
            }.filter(\.isFinite).max().map { (category, $0) }
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.rawValue < $1.0.rawValue
        }
        let analysis: SemanticActivityAnalysis
        if let best = scores.first {
            let competitor = scores.dropFirst().first {
                $0.0.disposition != best.0.disposition
            }
            let inference = SemanticActivityInference(
                description: description,
                category: best.0,
                similarity: best.1,
                competingCategory: competitor?.0,
                competingSimilarity: competitor?.1
            )
            let evidence: SemanticEvidence?
            let fallback: SemanticActivityFallback?
            if best.0.isProductiveConcept,
               best.1 >= thresholds.productiveSimilarity,
               inference.margin >= thresholds.productiveMargin {
                evidence = .productive(inference)
                fallback = nil
            } else if best.0.isPotentiallyDistractingConcept,
                      best.1 >= thresholds.distractingSimilarity,
                      inference.margin >= thresholds.distractingMargin {
                evidence = .distracting(inference)
                fallback = nil
            } else if best.0.disposition == .neutral {
                evidence = nil
                fallback = .neutralConcept
            } else {
                evidence = nil
                fallback = .insufficientConfidence
            }
            analysis = SemanticActivityAnalysis(
                inference: inference,
                evidence: evidence,
                fallback: fallback
            )
        } else {
            analysis = SemanticActivityAnalysis(
                inference: nil,
                evidence: nil,
                fallback: .embeddingUnavailable
            )
        }

        lock.lock()
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[description.text] = analysis
        lock.unlock()
        return analysis
    }
}

public enum SemanticEvidence: Equatable, Sendable {
    case productive(SemanticActivityInference)
    case distracting(SemanticActivityInference)
}
