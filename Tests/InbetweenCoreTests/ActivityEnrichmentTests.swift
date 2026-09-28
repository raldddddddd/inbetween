import Foundation
import Testing
@testable import InbetweenCore

struct ActivityEnrichmentTests {
    @Test func legacyAppOnlyContextDecodesWithAbsentRichMetadata() throws {
        let data = Data(#"""
        {
          "applicationBundleIdentifier":"com.apple.finder",
          "applicationName":"Finder"
        }
        """#.utf8)

        let context = try JSONDecoder().decode(ActivityContext.self, from: data)

        #expect(context.applicationName == "Finder")
        #expect(context.windowTitle == nil)
        #expect(context.browserURL == nil)
        #expect(context.resourceKind == nil)
        #expect(context.resourceName == nil)
        #expect(context.documentName == nil)
        #expect(context.resourcePath == nil)
        #expect(context.presenceState == nil)
        #expect(!context.hasRichMetadata)
    }

    @Test func richContextRoundTripsAllOptionalMetadata() throws {
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.microsoft.VSCode",
            applicationName: "Visual Studio Code",
            windowTitle: "InbetweenApp.swift — Inbetween — Visual Studio Code",
            browserDomain: "developer.apple.com",
            browserPageTitle: "Swift documentation",
            browserURL: "https://developer.apple.com/documentation/swift",
            resourceKind: .workspace,
            resourceName: "Inbetween",
            documentName: "InbetweenApp.swift",
            resourcePath: "/Users/example/Developer/inbetween/InbetweenApp.swift",
            presenceState: .active
        ))

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(ActivityContext.self, from: encoded)

        #expect(decoded == context)
        #expect(decoded.hasRichMetadata)
    }

    @Test func browserParserExtractsNormalizedDomainAndFallsBackToTitle() throws {
        let rich = try #require(ActivityEnrichmentParser.browser(
            urlString: "https://Developer.Apple.com/documentation/swift?language=swift",
            pageTitle: "Swift Documentation"
        ))
        #expect(rich.browserDomain == "developer.apple.com")
        #expect(rich.browserURL == "https://Developer.Apple.com/documentation/swift?language=swift")
        #expect(rich.browserPageTitle == "Swift Documentation")

        let titleOnly = try #require(ActivityEnrichmentParser.browser(
            urlString: nil,
            pageTitle: "A browser page"
        ))
        #expect(titleOnly.browserURL == nil)
        #expect(titleOnly.browserDomain == nil)
        #expect(titleOnly.browserPageTitle == "A browser page")

        let malformedURLFallback = try #require(ActivityEnrichmentParser.browser(
            urlString: "not a URL",
            pageTitle: "Still useful"
        ))
        #expect(malformedURLFallback.browserURL == nil)
        #expect(malformedURLFallback.browserPageTitle == "Still useful")
        #expect(ActivityEnrichmentParser.browser(urlString: nil, pageTitle: nil) == nil)
    }

    @Test func browserParserRejectsContentBearingURLSchemes() throws {
        let dataURL = try #require(ActivityEnrichmentParser.browser(
            urlString: "data:text/html,<main>private page body</main>",
            pageTitle: "Local page"
        ))
        #expect(dataURL.browserURL == nil)
        #expect(dataURL.browserDomain == nil)
        #expect(dataURL.browserPageTitle == "Local page")

        let scriptURL = try #require(ActivityEnrichmentParser.browser(
            urlString: "javascript:document.body.innerText",
            pageTitle: "Script bookmark"
        ))
        #expect(scriptURL.browserURL == nil)
        #expect(scriptURL.browserDomain == nil)
        let blobURL = try #require(ActivityEnrichmentParser.browser(
            urlString: "blob:data:text/html,private page body",
            pageTitle: "Generated page"
        ))
        #expect(blobURL.browserURL == nil)
        #expect(blobURL.browserDomain == nil)
        #expect(ActivityEnrichmentParser.browser(
            urlString: "data:text/plain,private contents",
            pageTitle: nil
        ) == nil)
    }

    @Test func decodingUnsafeLegacyBrowserURLDropsOnlyTheURLPayload() throws {
        let data = Data(#"""
        {
          "applicationBundleIdentifier":"com.google.Chrome",
          "applicationName":"Google Chrome",
          "browserPageTitle":"Local page",
          "browserURL":"data:text/html,<main>private page body</main>"
        }
        """#.utf8)

        let context = try JSONDecoder().decode(ActivityContext.self, from: data)

        #expect(context.applicationName == "Google Chrome")
        #expect(context.browserPageTitle == "Local page")
        #expect(context.browserURL == nil)
        #expect(context.browserDomain == nil)
    }

    @Test func nativeParsersUseReliableMetadataAndRetainFallbacks() throws {
        let xcode = try #require(ActivityEnrichmentParser.nativeApplication(
            bundleIdentifier: "com.apple.dt.Xcode",
            windowTitle: "InbetweenApp.swift — Inbetween — Xcode",
            documentURLString: "file:///Users/example/Developer/inbetween/Inbetween.xcworkspace"
        ))
        #expect(xcode.resourceKind == .workspace)
        #expect(xcode.resourceName == "Inbetween")
        #expect(xcode.documentName == "InbetweenApp.swift")
        #expect(xcode.resourcePath == "/Users/example/Developer/inbetween/Inbetween.xcworkspace")

        let code = try #require(ActivityEnrichmentParser.nativeApplication(
            bundleIdentifier: "com.microsoft.VSCode",
            windowTitle: "ActivityContext.swift — inbetween — Visual Studio Code",
            documentURLString: nil
        ))
        #expect(code.resourceKind == .workspace)
        #expect(code.resourceName == "inbetween")
        #expect(code.documentName == "ActivityContext.swift")

        let terminal = try #require(ActivityEnrichmentParser.nativeApplication(
            bundleIdentifier: "com.apple.Terminal",
            windowTitle: "gerald — zsh",
            documentURLString: nil
        ))
        #expect(terminal.resourceKind == .terminal)
        #expect(terminal.resourcePath == nil)

        #expect(ActivityEnrichmentParser.nativeApplication(
            bundleIdentifier: "com.example.Unsupported",
            windowTitle: "Useful generic title",
            documentURLString: nil
        ) == nil)
    }

    @Test func presencePolicySeparatesActiveIdleAndAwayWithoutInputContents() {
        let policy = UserPresencePolicy(idleThreshold: 30, awayThreshold: 120)

        #expect(policy.state(secondsSinceLastInput: 0) == .active)
        #expect(policy.state(secondsSinceLastInput: 29.9) == .active)
        #expect(policy.state(secondsSinceLastInput: 30) == .idle)
        #expect(policy.state(secondsSinceLastInput: 119.9) == .idle)
        #expect(policy.state(secondsSinceLastInput: 120) == .away)
        #expect(policy.state(secondsSinceLastInput: nil) == nil)
        #expect(policy.state(secondsSinceLastInput: -1) == nil)
    }

    @Test func groupingCollapsesAdjacentMatchingActivityButPreservesRawSegments() throws {
        let sessionID = UUID()
        let activeContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.openai.codex",
            applicationName: "ChatGPT",
            presenceState: .active
        ))
        let awayContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.openai.codex",
            applicationName: "ChatGPT",
            presenceState: .away
        ))
        let browserContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.google.Chrome",
            applicationName: "Google Chrome",
            browserDomain: "developer.apple.com",
            browserPageTitle: "Swift Documentation",
            browserURL: "https://developer.apple.com/documentation/swift",
            presenceState: .active
        ))
        let segments = [
            segment(sessionID: sessionID, context: activeContext, start: 1_000, duration: 25),
            segment(sessionID: sessionID, context: awayContext, start: 1_060, duration: 41),
            segment(sessionID: sessionID, context: browserContext, start: 1_101, duration: 67),
            segment(sessionID: sessionID, context: activeContext, start: 1_168, duration: 10)
        ]

        let groups = ActivityHistoryGrouper.grouped(segments)

        #expect(segments.count == 4)
        #expect(groups.count == 3)
        #expect(groups[0].segmentCount == 2)
        #expect(groups[0].knownDuration == 66)
        #expect(groups[0].presenceDurations[.active] == 25)
        #expect(groups[0].presenceDurations[.away] == 41)
        #expect(groups[0].displayComponents == ["ChatGPT"])
        #expect(groups[1].displayComponents == [
            "Google Chrome", "developer.apple.com", "Swift Documentation"
        ])
        #expect(groups[2].segmentCount == 1)
    }

    @Test func terminalAndFolderHistoryPreferAnAbbreviatedReliablePath() throws {
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.Terminal",
            applicationName: "Terminal",
            windowTitle: "zsh",
            resourceKind: .terminal,
            resourceName: "inbetween",
            resourcePath: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Developer/inbetween")
                .path
        ))

        #expect(context.compactDisplayComponents == ["Terminal", "~/Developer/inbetween"])
    }

    @Test func currentActivityDurationIncludesPresenceTransitionsWithoutBridgingGaps() throws {
        let sessionID = UUID()
        let activeContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            resourceKind: .workspace,
            resourceName: "Inbetween",
            presenceState: .active
        ))
        let idleContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            resourceKind: .workspace,
            resourceName: "Inbetween",
            presenceState: .idle
        ))
        let awayContext = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            resourceKind: .workspace,
            resourceName: "Inbetween",
            presenceState: .away
        ))
        let openStart = Date(timeIntervalSince1970: 1_100)
        let openSegment = ActivitySegment(
            waitSessionID: sessionID,
            context: awayContext,
            startedAt: openStart
        )
        let session = WaitSession(
            id: sessionID,
            codexSessionID: "session",
            codexTurnID: "turn",
            startTime: Date(timeIntervalSince1970: 900),
            activitySegments: [
                segment(sessionID: sessionID, context: activeContext, start: 1_000, duration: 25),
                segment(sessionID: sessionID, context: idleContext, start: 1_060, duration: 40),
                openSegment
            ]
        )

        #expect(session.currentActivityObservedDuration(
            at: openStart.addingTimeInterval(15)
        ) == 80)
    }

    private func segment(
        sessionID: UUID,
        context: ActivityContext,
        start: TimeInterval,
        duration: TimeInterval
    ) -> ActivitySegment {
        let startedAt = Date(timeIntervalSince1970: start)
        return ActivitySegment(
            waitSessionID: sessionID,
            context: context,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            duration: duration
        )
    }
}
