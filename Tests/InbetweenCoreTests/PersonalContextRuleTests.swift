import Foundation
import Testing
@testable import InbetweenCore

struct PersonalContextRuleTests {
    @Test func appLevelRulesMatchOnlyTheirApplication() throws {
        let intentional = try #require(PersonalContextRule(
            scope: .applicationBundleIdentifier,
            pattern: "com.apple.dt.Xcode",
            disposition: .productive
        ))
        let distracting = try #require(PersonalContextRule(
            scope: .applicationName,
            pattern: "Example Player",
            disposition: .distracting
        ))

        #expect(intentional.matches(try context(bundleID: "com.apple.dt.Xcode", name: "Xcode")))
        #expect(!intentional.matches(try context(bundleID: "com.microsoft.VSCode", name: "Code")))
        #expect(distracting.matches(try context(bundleID: "com.example.player", name: "example player")))
    }

    @Test func domainRuleMatchesSubdomainsWithoutMatchingLookalikes() throws {
        let rule = try #require(PersonalContextRule(
            scope: .browserDomain,
            pattern: "developer.apple.com",
            disposition: .productive
        ))

        #expect(rule.matches(try context(domain: "developer.apple.com")))
        #expect(rule.matches(try context(domain: "docs.developer.apple.com")))
        #expect(!rule.matches(try context(domain: "developer.apple.com.example.test")))
    }

    @Test func specificRuleOverridesBroaderApplicationRule() throws {
        let appRule = try #require(PersonalContextRule(
            scope: .applicationBundleIdentifier,
            pattern: "com.google.Chrome",
            disposition: .contextDependent
        ))
        let domainRule = try #require(PersonalContextRule(
            scope: .browserDomain,
            pattern: "developer.apple.com",
            disposition: .productive
        ))
        let evaluator = PersonalContextRuleEvaluator(rules: [domainRule, appRule])

        #expect(evaluator.matchingRule(for: try context(domain: "developer.apple.com")) == domainRule)
    }

    @Test func rulesPersistLocally() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-rule-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContextRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        let rule = try #require(PersonalContextRule(
            scope: .resourcePath,
            pattern: "/Developer/inbetween",
            disposition: .productive
        ))

        try store.save([rule])

        #expect(try store.load() == [rule])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    }

    @Test func usefulScopesNormalizeAndRejectMalformedPatterns() throws {
        let cases: [(ContextRuleScope, String)] = [
            (.applicationBundleIdentifier, "com.apple.dt.Xcode"),
            (.applicationName, "Xcode"),
            (.windowTitle, "Inbetween"),
            (.browserDomain, "Developer.Apple.Com."),
            (.browserURL, "https://developer.apple.com/documentation"),
            (.resourceName, "Inbetween"),
            (.documentName, "WaitSession.swift"),
            (.resourcePath, "/Developer/inbetween")
        ]
        for (scope, pattern) in cases {
            #expect(PersonalContextRule(scope: scope, pattern: pattern, disposition: .productive) != nil)
        }
        #expect(PersonalContextRule.normalizedPattern(scope: .browserDomain, pattern: "Developer.Apple.Com.") == "developer.apple.com")
        #expect(PersonalContextRule(scope: .browserDomain, pattern: "https://developer.apple.com", disposition: .productive) == nil)
        #expect(PersonalContextRule(scope: .browserURL, pattern: "developer.apple.com", disposition: .productive) == nil)
        #expect(PersonalContextRule(scope: .applicationBundleIdentifier, pattern: "com.example bad", disposition: .productive) == nil)
    }

    @Test func legacyRulePatternsRemainDecodableWhileNewPatternsStayStrict() throws {
        let json = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"scope\":\"browserURL\",\"pattern\":\"github.com/inbetween\",\"disposition\":\"productive\"}"
        let legacy = try JSONDecoder().decode(PersonalContextRule.self, from: Data(json.utf8))
        #expect(legacy.pattern == "github.com/inbetween")
        #expect(PersonalContextRule(scope: .browserURL, pattern: legacy.pattern, disposition: .productive) == nil)
    }

    @Test func duplicateValidationEditingAndDeletionKeepRuleIdentityClear() throws {
        let original = try #require(PersonalContextRule(
            scope: .browserDomain, pattern: "github.com", disposition: .productive
        ))
        var rules = [original]
        #expect(PersonalContextRule.duplicates(scope: .browserDomain, pattern: "GITHUB.COM", in: rules))
        #expect(!PersonalContextRule.duplicates(scope: .browserDomain, pattern: "GITHUB.COM", in: rules, excludingID: original.id))

        let edited = try #require(PersonalContextRule(
            id: original.id, scope: original.scope, pattern: original.pattern,
            disposition: .contextDependent
        ))
        rules[0] = edited
        #expect(rules[0].id == original.id)
        #expect(rules[0].disposition == .contextDependent)
        rules.removeAll { $0.id == original.id }
        #expect(rules.isEmpty)
    }

    @Test func richActivitySuggestionsPreferDomainOverWholeApplication() throws {
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserDomain: "developer.apple.com",
            browserPageTitle: "Swift documentation",
            browserURL: "https://developer.apple.com/documentation/swift",
            resourceName: "Inbetween",
            documentName: "WaitSession.swift",
            resourcePath: "/Developer/inbetween"
        ))
        let suggestions = PersonalContextRule.suggestions(for: context)
        #expect(suggestions.first?.scope == ContextRuleScope.browserDomain)
        #expect(suggestions.first?.pattern == "developer.apple.com")
        #expect(suggestions.contains(where: { $0.scope == ContextRuleScope.resourceName && $0.pattern == "Inbetween" }))
        #expect(suggestions.contains(where: { $0.scope == ContextRuleScope.resourcePath && $0.pattern == "/Developer/inbetween" }))
    }

    @Test func newRulesAffectFutureClassificationWithoutChangingStoredHistory() throws {
        let context = try context(domain: "github.com")
        let start = Date(timeIntervalSince1970: 1_000)
        let segment = ActivitySegment(
            waitSessionID: UUID(), context: context, startedAt: start,
            endedAt: start.addingTimeInterval(120), duration: 120
        )
        let historical = WaitSession(
            codexSessionID: "old", codexTurnID: "old", startTime: start,
            endTime: start.addingTimeInterval(120), duration: 120, state: .completed,
            activitySegments: [segment], classificationResult: .init(classification: .unclassified, reasonCodes: [.noStrongEvidence])
        )
        let rule = try #require(PersonalContextRule(scope: .browserDomain, pattern: "github.com", disposition: .productive))
        let future = WaitSession(
            codexSessionID: "new", codexTurnID: "new", startTime: start,
            endTime: start.addingTimeInterval(120), duration: 120, state: .completed,
            activitySegments: [segment]
        )
        let classifier = WaitSessionClassifier(rules: .init(usuallyProductiveBundleIdentifiers: [], personalContextRules: [rule]))
        #expect(classifier.classify(future)?.classification == .productive)
        #expect(historical.automaticClassification == .unclassified)
    }

    private func context(
        bundleID: String = "com.google.Chrome",
        name: String = "Google Chrome",
        domain: String? = nil
    ) throws -> ActivityContext {
        try #require(ActivityContext(
            applicationBundleIdentifier: bundleID,
            applicationName: name,
            browserDomain: domain,
            presenceState: .active
        ))
    }
}
