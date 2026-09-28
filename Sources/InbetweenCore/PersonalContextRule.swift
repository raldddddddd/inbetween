import Foundation

public enum ContextRuleDisposition: Codable, CaseIterable, Identifiable, Sendable {
    case productive
    case distracting
    case contextDependent

    public var id: Self { self }

    public var title: String {
        switch self {
        case .productive: "Productive"
        case .distracting: "Distracting"
        case .contextDependent: "Context-dependent"
        }
    }

    public init(from decoder: Decoder) throws {
        switch try decoder.singleValueContainer().decode(String.self) {
        case "productive", "intentional": self = .productive
        case "distracting": self = .distracting
        case "contextDependent": self = .contextDependent
        default: throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Unsupported context-rule disposition")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .productive: value = "productive"
        case .distracting: value = "distracting"
        case .contextDependent: value = "contextDependent"
        }
        try container.encode(value)
    }
}

public enum ContextRuleScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case applicationBundleIdentifier
    case applicationName
    case windowTitle
    case browserDomain
    case browserURL
    case resourceName
    case documentName
    case resourcePath

    public var id: Self { self }

    public var title: String {
        switch self {
        case .applicationBundleIdentifier: "Application bundle ID"
        case .applicationName: "Application name"
        case .windowTitle: "Window title"
        case .browserDomain: "Browser domain"
        case .browserURL: "Browser URL"
        case .resourceName: "Project or context"
        case .documentName: "Document"
        case .resourcePath: "Folder or path"
        }
    }

    fileprivate var specificity: Int {
        switch self {
        case .applicationName: 90
        case .applicationBundleIdentifier: 100
        case .windowTitle: 200
        case .browserDomain: 300
        case .resourceName: 350
        case .documentName: 400
        case .resourcePath: 450
        case .browserURL: 500
        }
    }
}

public struct PersonalContextRule: Identifiable, Codable, Equatable, Sendable {
    public static let maximumPatternLength = 500

    public let id: UUID
    public let scope: ContextRuleScope
    public let pattern: String
    public let disposition: ContextRuleDisposition

    public init?(
        id: UUID = UUID(),
        scope: ContextRuleScope,
        pattern: String,
        disposition: ContextRuleDisposition
    ) {
        guard let normalized = Self.normalizedPattern(scope: scope, pattern: pattern) else {
            return nil
        }
        self.id = id
        self.scope = scope
        self.pattern = normalized
        self.disposition = disposition
    }

    /// The shared normalization used when rules are created or edited. It
    /// preserves the evaluator's matching semantics while rejecting patterns
    /// that could never match the supported local metadata safely.
    public static func normalizedPattern(
        scope: ContextRuleScope,
        pattern: String
    ) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumPatternLength else { return nil }

        switch scope {
        case .applicationBundleIdentifier:
            guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return trimmed
        case .browserDomain:
            let domain = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty,
                  domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  domain.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil,
                  domain.contains(".") else { return nil }
            return domain
        case .browserURL:
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host?.isEmpty == false else { return nil }
            var normalized = components
            normalized.scheme = scheme
            normalized.host = components.host?.lowercased()
            return normalized.string
        case .applicationName, .windowTitle, .resourceName, .documentName, .resourcePath:
            return trimmed.components(separatedBy: .controlCharacters).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A duplicate would have identical matching behavior, regardless of its
    /// disposition. Editing that existing rule is clearer than adding another
    /// same-scope, same-pattern entry whose ordering could be surprising.
    public static func duplicates(
        scope: ContextRuleScope,
        pattern: String,
        in rules: [PersonalContextRule],
        excludingID: UUID? = nil
    ) -> Bool {
        guard let normalized = normalizedPattern(scope: scope, pattern: pattern) else { return false }
        return rules.contains {
            $0.id != excludingID && $0.scope == scope
                && $0.pattern.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Suggestions are derived from metadata Inbetween already retains. The
    /// most useful scoped rule appears first; a website therefore suggests a
    /// domain rule before a broad whole-application rule.
    public static func suggestions(for context: ActivityContext) -> [PersonalContextRuleSuggestion] {
        var values: [PersonalContextRuleSuggestion] = []
        func append(_ scope: ContextRuleScope, _ pattern: String?, _ label: String) {
            guard let pattern, let normalized = normalizedPattern(scope: scope, pattern: pattern) else { return }
            values.append(PersonalContextRuleSuggestion(scope: scope, pattern: normalized, label: label))
        }
        append(.browserDomain, context.browserDomain, "Website")
        append(.browserURL, context.browserURL, "Web address")
        append(.resourceName, context.resourceName, "Project or context")
        append(.documentName, context.documentName, "Document")
        append(.resourcePath, context.resourcePath, "Folder or path")
        append(.windowTitle, context.windowTitle, "Window title")
        append(.applicationBundleIdentifier, context.applicationBundleIdentifier, "Application")
        append(.applicationName, context.applicationName, "Application name")
        return values
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case scope
        case pattern
        case disposition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let scope = try container.decode(ContextRuleScope.self, forKey: .scope)
        let pattern = try container.decode(String.self, forKey: .pattern)
        let disposition = try container.decode(ContextRuleDisposition.self, forKey: .disposition)
        if let rule = Self(id: id, scope: scope, pattern: pattern, disposition: disposition) {
            self = rule
            return
        }
        // Rules created by earlier releases predate the stricter editor
        // validation. Keep their local JSON readable; only newly saved edits
        // need to meet the current scope-specific requirements.
        let legacyPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyPattern.isEmpty, legacyPattern.count <= Self.maximumPatternLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .pattern,
                in: container,
                debugDescription: "Invalid personal context-rule pattern"
            )
        }
        self.id = id
        self.scope = scope
        self.pattern = legacyPattern
        self.disposition = disposition
    }

    public func matches(_ context: ActivityContext) -> Bool {
        guard let value = candidateValue(in: context) else { return false }
        switch scope {
        case .applicationBundleIdentifier, .applicationName:
            return value.compare(pattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .browserDomain:
            let domain = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let rule = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == rule || domain.hasSuffix(".\(rule)")
        case .windowTitle, .browserURL, .resourceName, .documentName, .resourcePath:
            return value.range(
                of: pattern,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    fileprivate func candidateValue(in context: ActivityContext) -> String? {
        switch scope {
        case .applicationBundleIdentifier: context.applicationBundleIdentifier
        case .applicationName: context.applicationName
        case .windowTitle: context.windowTitle
        case .browserDomain: context.browserDomain
        case .browserURL: context.browserURL
        case .resourceName: context.resourceName
        case .documentName: context.documentName
        case .resourcePath: context.resourcePath
        }
    }
}

public struct PersonalContextRuleSuggestion: Identifiable, Equatable, Sendable {
    public let scope: ContextRuleScope
    public let pattern: String
    public let label: String

    public init(scope: ContextRuleScope, pattern: String, label: String) {
        self.scope = scope
        self.pattern = pattern
        self.label = label
    }

    public var id: String { "\(scope.rawValue):\(pattern)" }
    public var displayLabel: String { "\(label): \(pattern)" }
}

public struct PersonalContextRuleEvaluator: Sendable {
    public let rules: [PersonalContextRule]

    public init(rules: [PersonalContextRule]) {
        self.rules = rules
    }

    public func matchingRule(for context: ActivityContext) -> PersonalContextRule? {
        rules.enumerated()
            .filter { $0.element.matches(context) }
            .max { lhs, rhs in
                let left = (lhs.element.scope.specificity, lhs.element.pattern.count, lhs.offset)
                let right = (rhs.element.scope.specificity, rhs.element.pattern.count, rhs.offset)
                return left < right
            }?
            .element
    }
}

public struct ContextRuleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Inbetween", isDirectory: true)
            .appendingPathComponent("context-rules.json", isDirectory: false)
    }

    public func load() throws -> [PersonalContextRule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode(
            [PersonalContextRule].self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func save(_ rules: [PersonalContextRule]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
