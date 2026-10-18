import Foundation
import Testing
@testable import InbetweenCore

struct ActivityContextTests {
    @Test func activityStartsOnlyWithAnActiveWaitSession() throws {
        var tracker = WaitSessionTracker()
        let observation = try observation(app: "Safari", bundleID: "com.apple.Safari", time: 1_001)

        #expect(tracker.recordActivity(observation) == .ignored)

        tracker.apply(event(.userPromptSubmit, time: 1_000))
        guard case .started = tracker.recordActivity(observation) else {
            Issue.record("Expected the first foreground activity segment to start")
            return
        }
        #expect(tracker.currentSession?.activitySegments.count == 1)
        #expect(tracker.currentSession?.currentActivitySegment?.context.applicationName == "Safari")
        #expect(tracker.currentSession?.recordOrigin == .captured)
    }

    @Test func foregroundTransitionClosesPreviousSegment() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(try observation(app: "Safari", bundleID: "com.apple.Safari", time: 1_001))

        let update = tracker.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_006)
        )

        guard case .transitioned = update else {
            Issue.record("Expected an activity transition")
            return
        }
        let segments = try #require(tracker.currentSession?.activitySegments)
        #expect(segments.count == 2)
        #expect(segments[0].endedAt == Date(timeIntervalSince1970: 1_006))
        #expect(segments[0].duration == 5)
        #expect(segments[1].endedAt == nil)
    }

    @Test func identicalContextCoalescesWithoutTinySegments() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        let first = try observation(
            app: "Safari",
            bundleID: "com.apple.Safari",
            title: "Documentation",
            time: 1_001
        )
        tracker.recordActivity(first)

        let update = tracker.recordActivity(
            try observation(
                app: "Safari",
                bundleID: "com.apple.Safari",
                title: "Documentation",
                time: 1_004
            )
        )

        guard case .coalesced = update else {
            Issue.record("Expected the matching observation to coalesce")
            return
        }
        #expect(tracker.currentSession?.activitySegments.count == 1)
        #expect(tracker.currentSession?.currentActivitySegment?.lastObservedAt
            == Date(timeIntervalSince1970: 1_004))
    }

    @Test func completingWaitClosesCurrentActivitySegment() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_002))

        tracker.apply(event(.stop, time: 1_010))

        let segment = try #require(tracker.sessions[0].activitySegments.first)
        #expect(segment.endedAt == Date(timeIntervalSince1970: 1_010))
        #expect(segment.duration == 8)
        #expect(tracker.currentSession == nil)
    }

    @Test func repeatedStartDoesNotBreakTheCurrentActivitySegment() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_002))

        tracker.apply(event(.userPromptSubmit, time: 1_004))
        tracker.apply(event(.stop, time: 1_010))

        let segment = try #require(tracker.sessions[0].activitySegments.first)
        #expect(tracker.sessions[0].activitySegments.count == 1)
        #expect(segment.endedAt == Date(timeIntervalSince1970: 1_010))
        #expect(segment.duration == 8)
    }

    @Test func activityPersistenceRoundTripIncludesOptionalMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-activity-store-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let sessionID = UUID()
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            applicationCategoryIdentifier: "public.app-category.productivity",
            windowTitle: "Local documentation",
            browserDomain: "example.com",
            browserPageTitle: "Example"
        ))
        let segment = ActivitySegment(
            waitSessionID: sessionID,
            context: context,
            startedAt: Date(timeIntervalSince1970: 1_001),
            endedAt: Date(timeIntervalSince1970: 1_006),
            duration: 5
        )
        let session = WaitSession(
            id: sessionID,
            codexSessionID: "session-1",
            codexTurnID: "turn-1",
            startTime: Date(timeIntervalSince1970: 1_000),
            endTime: Date(timeIntervalSince1970: 1_010),
            duration: 10,
            state: .completed,
            activitySegments: [segment]
        )

        try store.save([session])

        #expect(try store.load() == [session])
    }

    @Test func legacyContextDecodesWithUnknownSourcesAndNewContextPersistsProvenance() throws {
        let legacy = Data(#"{"applicationBundleIdentifier":"com.example.legacy","applicationName":"Legacy App","windowTitle":"Project · Legacy App"}"#.utf8)
        let decoded = try JSONDecoder().decode(ActivityContext.self, from: legacy)
        #expect(decoded.provenance.applicationIdentity == .legacyUnknown)
        #expect(decoded.provenance.windowTitle == nil)
        #expect(decoded.provenance.presentationDescription == "Source details were not recorded for this context.")

        let captured = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.dt.Xcode",
            applicationName: "Xcode",
            applicationCategoryIdentifier: "public.app-category.developer-tools",
            windowTitle: "Inbetween",
            provenance: ActivityContextProvenance(
                applicationIdentity: .foregroundApplication,
                applicationCategory: .applicationBundle,
                windowTitle: .accessibility
            )
        ))
        let roundTrip = try JSONDecoder().decode(ActivityContext.self, from: JSONEncoder().encode(captured))
        #expect(roundTrip.provenance == captured.provenance)
        #expect(roundTrip.provenance.presentationDescription.contains("sampled from the macOS foreground app"))
        #expect(roundTrip.provenance.presentationDescription.contains("read through Accessibility"))
    }

    @Test func enrichmentKeepsObservedBrowserSourceSeparateFromDerivedMetadata() throws {
        let base = try #require(ActivityContext(
            applicationBundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            provenance: ActivityContextProvenance(applicationIdentity: .foregroundApplication)
        ))
        let browser = try #require(ActivityEnrichmentParser.browser(
            urlString: "https://developer.apple.com/documentation/swift",
            pageTitle: "Swift Documentation",
            source: .accessibility
        ))
        let enriched = try #require(base.enriching(with: browser, presenceState: .active))
        #expect(enriched.provenance.browserURL == .accessibility)
        #expect(enriched.provenance.browserPageTitle == .accessibility)
        #expect(enriched.provenance.browserDomain == .parserDerived)
        #expect(enriched.provenance.presenceEstimate == .recentInputEstimate)
        #expect(enriched.provenance.presentationDescription.contains("derived from the available URL"))
        #expect(enriched.provenance.presentationDescription.contains("does not measure attention"))
    }

    @Test func activitySegmentIdentityRoundTripsAndLegacyMissingIDDecodesSafely() throws {
        let waitID = UUID()
        let segmentID = UUID()
        let segment = ActivitySegment(
            id: segmentID,
            waitSessionID: waitID,
            context: try context(app: "Xcode", bundleID: "com.apple.dt.Xcode"),
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_020),
            duration: 20
        )
        let roundTrip = try JSONDecoder().decode(
            ActivitySegment.self,
            from: JSONEncoder().encode(segment)
        )
        #expect(roundTrip.id == segmentID)

        let encoded = try JSONEncoder().encode(segment)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "id")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ActivitySegment.self, from: legacyData)
        #expect(legacy.id != segmentID)
        let reencoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        #expect(reencoded["id"] != nil)
    }

    @Test func oldSessionJSONWithoutActivityDecodesAsEmpty() throws {
        let data = Data(#"""
        [{
          "id":"84E062E1-0810-412A-B084-EC421B738A3A",
          "codexSessionID":"session-1",
          "codexTurnID":"turn-1",
          "startTime":1000000,
          "state":"completed",
          "hookSource":"codex-lifecycle-hooks",
          "hookVersion":1,
          "attentionEvents":[]
        }]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let sessions = try decoder.decode([WaitSession].self, from: data)

        #expect(sessions[0].activitySegments.isEmpty)
        #expect(sessions[0].classificationResult == nil)
        #expect(sessions[0].recordOrigin == .legacyUnknown)
    }

    @Test func taggedLegacySessionDecodesAsSyntheticWithoutChangingItsManualOverride() throws {
        let data = Data(#"""
        [{
          "id":"84E062E1-0810-412A-B084-EC421B738A3A",
          "codexSessionID":"session-1",
          "codexTurnID":"turn-1",
          "startTime":1000000,
          "state":"completed",
          "hookSource":"inbetween-demo-seeder",
          "hookVersion":1,
          "attentionEvents":[],
          "syntheticDataSetID":"demo-v1",
          "manualClassificationOverride":"distracted"
        }]
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let session = try #require(decoder.decode([WaitSession].self, from: data).first)

        #expect(session.recordOrigin == .synthetic)
        #expect(session.manualClassificationOverride == .distracted)
    }

    @Test func restartLeavesUnobservedOpenSegmentUnfinished() throws {
        let sessionID = UUID()
        let segment = ActivitySegment(
            waitSessionID: sessionID,
            context: try context(app: "Notes", bundleID: "com.apple.Notes"),
            startedAt: Date(timeIntervalSince1970: 1_001)
        )
        let active = WaitSession(
            id: sessionID,
            codexSessionID: "session-1",
            codexTurnID: "turn-1",
            startTime: Date(timeIntervalSince1970: 1_000),
            activitySegments: [segment]
        )

        var recovered = WaitSessionTracker(sessions: [active])

        #expect(recovered.sessions[0].state == .unfinished)
        #expect(recovered.sessions[0].activitySegments[0].endedAt == nil)
        #expect(recovered.sessions[0].activitySegments[0].duration == nil)
        #expect(recovered.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_010)
        ) == .ignored)

        recovered.apply(event(.stop, time: 1_015))
        #expect(recovered.sessions[0].activitySegments[0].endedAt == nil)
        #expect(recovered.sessions[0].activitySegments[0].duration == nil)

        var resumed = WaitSessionTracker(sessions: [active])
        resumed.apply(event(.userPromptSubmit, time: 1_020))
        resumed.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_021)
        )
        #expect(resumed.sessions[0].activitySegments.count == 2)
        #expect(resumed.sessions[0].activitySegments[0].endedAt == nil)
    }

    @Test func sleepWakeCreatesAnUnobservedGapWithoutChangingWaitState() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_001)
        )

        let sessionID = try #require(tracker.currentSession?.id)
        #expect(tracker.suspendActivityCollection(
            at: Date(timeIntervalSince1970: 1_010)
        ) == .suspended(sessionID))
        #expect(tracker.currentSession?.state == .active)
        #expect(tracker.currentSession?.activitySegments[0].duration == 9)
        #expect(tracker.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_050)
        ) == .ignored)

        #expect(tracker.resumeActivityCollection(
            at: Date(timeIntervalSince1970: 1_100)
        ) == .resumed(sessionID))
        tracker.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_101)
        )
        tracker.apply(event(.stop, time: 1_110))

        #expect(tracker.sessions[0].state == .completed)
        #expect(tracker.sessions[0].duration == 110)
        #expect(tracker.sessions[0].activitySegments.map(\.duration) == [9, 9])
    }

    @Test func duplicateSleepWakeTransitionsAreIgnored() throws {
        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_001)
        )

        #expect(tracker.suspendActivityCollection(
            at: Date(timeIntervalSince1970: 1_010)
        ) != .ignored)
        #expect(tracker.suspendActivityCollection(
            at: Date(timeIntervalSince1970: 1_011)
        ) == .ignored)
        #expect(tracker.resumeActivityCollection(
            at: Date(timeIntervalSince1970: 1_020)
        ) != .ignored)
        #expect(tracker.resumeActivityCollection(
            at: Date(timeIntervalSince1970: 1_021)
        ) == .ignored)
    }

    @Test func quitRelaunchPreservesOnlyObservedActivityAndWaitsForStop() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbetween-relaunch-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WaitSessionStore(fileURL: directory.appendingPathComponent("sessions.json"))

        var beforeQuit = WaitSessionTracker()
        beforeQuit.apply(event(.userPromptSubmit, time: 1_000))
        beforeQuit.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_001)
        )
        beforeQuit.suspendActivityCollection(at: Date(timeIntervalSince1970: 1_010))
        try store.save(beforeQuit.sessions)

        var relaunched = WaitSessionTracker(sessions: try store.load())
        #expect(relaunched.sessions[0].state == .unfinished)
        #expect(relaunched.sessions[0].endTime == nil)
        #expect(relaunched.sessions[0].activitySegments.map(\.duration) == [9])
        #expect(relaunched.recordActivity(
            try observation(app: "Notes", bundleID: "com.apple.Notes", time: 1_050)
        ) == .ignored)

        let completion = relaunched.apply(event(.stop, time: 1_100))
        #expect(completion.notification == .ready)
        #expect(relaunched.sessions[0].state == .completed)
        #expect(relaunched.sessions[0].duration == 100)
        #expect(relaunched.sessions[0].activitySegments.map(\.duration) == [9])
    }

    @Test func missingOptionalMetadataIsValidAndMalformedOrStaleInputIsIgnored() throws {
        let appOnly = try context(app: "Finder", bundleID: "com.apple.finder")
        #expect(appOnly.windowTitle == nil)
        #expect(appOnly.browserDomain == nil)
        #expect(ActivityContext(
            applicationBundleIdentifier: "com.example.browser",
            applicationName: "Browser",
            browserDomain: "example.com/private/path?token=secret"
        ) == nil)

        var tracker = WaitSessionTracker()
        tracker.apply(event(.userPromptSubmit, time: 1_000))
        tracker.recordActivity(ActivityObservation(context: appOnly, observedAt: Date(timeIntervalSince1970: 1_005)))
        #expect(tracker.recordActivity(
            ActivityObservation(context: appOnly, observedAt: Date(timeIntervalSince1970: 1_004))
        ) == .ignored)
    }

    private func context(
        app: String,
        bundleID: String,
        title: String? = nil
    ) throws -> ActivityContext {
        try #require(ActivityContext(
            applicationBundleIdentifier: bundleID,
            applicationName: app,
            windowTitle: title
        ))
    }

    private func observation(
        app: String,
        bundleID: String,
        title: String? = nil,
        time: TimeInterval
    ) throws -> ActivityObservation {
        ActivityObservation(
            context: try context(app: app, bundleID: bundleID, title: title),
            observedAt: Date(timeIntervalSince1970: time)
        )
    }

    private func event(
        _ name: LifecycleEventName,
        time: TimeInterval
    ) -> LifecycleEvent {
        LifecycleEvent(
            name: name,
            sessionID: "session-1",
            turnID: "turn-1",
            observedAt: time
        )
    }
}
