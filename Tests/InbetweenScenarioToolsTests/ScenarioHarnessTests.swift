import Foundation
import Testing
@testable import InbetweenScenarioTools

struct ScenarioHarnessTests {
    @Test func manualOverrideAndDashboardUseProductionEffectiveClassification() throws {
        let fixture = ScenarioFixture(
            name: "override", description: "test", referenceTime: 1_700_006_400,
            sessions: [ScenarioSessionFixture(
                id: "override", sessionID: "session", turnID: "turn",
                start: 1_700_006_400, end: 1_700_006_520, classificationMode: nil,
                activities: [ScenarioActivityFixture(
                    start: 1_700_006_400, end: 1_700_006_520, app: "Google Chrome",
                    bundleID: "com.google.Chrome", windowTitle: nil, domain: "example.net",
                    url: nil, pageTitle: "Welcome", resourceKind: nil, resourceName: nil,
                    documentName: nil, resourcePath: nil, presence: .active
                )], manualOverrideSequence: [],
                sliceReviewActions: [.init(activityIndexes: [0], action: "productive")]
            )],
            expected: ScenarioExpectedOutcome(
                productiveSeconds: 120, distractedSeconds: 0, unclassifiedSeconds: 0,
                reviewUnitCount: 0,
                dashboard: ScenarioDashboardExpectation(
                    productiveSeconds: 120, distractedSeconds: 0, unclassifiedSeconds: 0,
                    notRecordedSeconds: 0, days: nil
                )
            )
        )

        let result = try ScenarioHarness.run(fixture)

        #expect(result.passed)
        #expect(result.sessions.first?.automaticClassification == nil)
        #expect(result.sessions.first?.classificationDurations.productiveSeconds == 120)
    }

    @Test func injectedPermissionTimelinePromotesOnlyOnceThenContinuationClears() throws {
        let fixture = ScenarioFixture(
            name: "permission", description: "test", referenceTime: 1_700_006_400,
            sessions: [ScenarioSessionFixture(id: "session", sessionID: "session", turnID: "turn", start: 1_700_006_400, end: 1_700_006_460, classificationMode: "legacyNotRecorded", activities: [], manualOverrideSequence: [])],
            lifecycleEvents: [
                .init(name: .userPromptSubmit, sessionID: "session", turnID: "turn", time: 1_700_006_400, permissionMode: nil),
                .init(name: .permissionRequest, sessionID: "session", turnID: "turn", time: 1_700_006_410, permissionMode: nil),
                .init(name: .userPromptSubmit, sessionID: "session", turnID: "turn", time: 1_700_006_419, permissionMode: nil),
            ],
            permissionChecks: [1_700_006_418],
            expected: ScenarioExpectedOutcome(automaticClassification: nil, effectiveClassification: nil, reviewRequested: false, automaticReasonCodes: nil, permissionState: "inactive", dashboard: nil)
        )

        let result = try ScenarioHarness.run(fixture)

        #expect(result.passed)
        #expect(result.permissionUpdates == ["unchanged", "pending", "becamePersistent", "cleared"])
    }
}
