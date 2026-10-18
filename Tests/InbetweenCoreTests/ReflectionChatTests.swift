import Foundation
import Testing
@testable import InbetweenCore

struct ReflectionChatTests {
    @Test func reflectionValidationErrorsUseUserFacingLanguage() {
        let userFacingErrors: [ReflectionChatError] = [
            .providerUnavailable(statusCode: 503),
            .malformedResponse,
            .emptyAnswer,
            .unknownEvidence,
            .unknownMetric,
            .missingEvidence,
            .staleResponse
        ]
        let messages = userFacingErrors.map(\.localizedDescription)

        for message in messages {
            #expect(!message.localizedCaseInsensitiveContains("snapshot"))
            #expect(!message.localizedCaseInsensitiveContains("validation"))
            #expect(!message.localizedCaseInsensitiveContains("featherless"))
            #expect(!message.localizedCaseInsensitiveContains("http"))
        }
    }

    @Test func weeklySnapshotHasSevenLocalDaysComparisonsAndStableEvidence() throws {
        let calendar = manilaCalendar()
        let reference = date("2026-09-29 12:00", calendar: calendar)
        let store = WaitSessionStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("reflection-unused-\(UUID()).json"))
        let sessions = try DemoHistorySeeder(store: store, calendar: calendar).makeSessions(referenceDay: calendar.startOfDay(for: reference))

        let first = AIInsightSnapshotBuilder.prepare(sessions: sessions, referenceDate: reference, calendar: calendar, scope: .lastSevenDays)
        let second = AIInsightSnapshotBuilder.prepare(sessions: sessions, referenceDate: reference, calendar: calendar, scope: .lastSevenDays)

        #expect(first.payload.scope == .lastSevenDays)
        #expect(first.payload.days.count == 7)
        #expect(first.payload.days.map(\.date) == ["2026-09-23", "2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29"])
        #expect(first.payload.dayComparisons.count == 6)
        #expect(first.payload.days.first { $0.date == "2026-09-26" }?.durations.productiveSeconds == 1_995)
        #expect(first.payload.days.first { $0.date == "2026-09-28" }?.durations.unclassifiedSeconds == 480)
        #expect(first.payload.evidence.contains { $0.id == "day-2026-09-28" })
        #expect(first.evidenceLinks["day-2026-09-28"] != nil)
        #expect(first.fingerprint == second.fingerprint)
        let requestContent = try ReflectionChatPrompt.snapshotContent(first.payload)
        #expect(requestContent.contains("period.productive_duration"))
        #expect(requestContent.contains("day.2026-09-28.context_switches"))
    }

    @Test func selectedSuggestionWinsOverStaleDraftState() {
        let suggestion = "What productive work took the most time today?"
        #expect(ReflectionQuestionSubmission.resolve(draft: "", suggestion: suggestion) == suggestion)
        #expect(ReflectionQuestionSubmission.resolve(draft: "previous question", suggestion: suggestion) == suggestion)
        #expect(ReflectionQuestionSubmission.resolve(draft: "  typed question  ") == "typed question")
        #expect(ReflectionQuestionSubmission.resolve(draft: " \n ") == nil)
    }

    @Test func suggestedQuestionsFollowSnapshotDataAndSelectedPeriod() throws {
        let calendar = manilaCalendar()
        let reference = date("2026-09-29 12:00", calendar: calendar)
        let sessions = [
            try observedSession(at: date("2026-09-26 09:00", calendar: calendar), classification: .productive, id: "suggestion-focus"),
            try observedSession(at: date("2026-09-29 09:00", calendar: calendar), classification: .distracted, id: "suggestion-distraction")
        ]

        let weekly = AIInsightSnapshotBuilder.prepare(
            sessions: sessions,
            referenceDate: reference,
            calendar: calendar,
            scope: .lastSevenDays
        )
        let weeklyQuestions = ReflectionSuggestedQuestions.forSnapshot(weekly.payload)
        #expect(!weeklyQuestions.isEmpty)
        #expect(weeklyQuestions.count <= 3)
        #expect(weeklyQuestions.allSatisfy { $0.localizedCaseInsensitiveContains("week") })
        #expect(!weeklyQuestions.contains { $0.localizedCaseInsensitiveContains("monday") })
        #expect(!weeklyQuestions.contains { $0.localizedCaseInsensitiveContains("compare") || $0.localizedCaseInsensitiveContains("changed across") })
        #expect(Set(weeklyQuestions.map { $0.lowercased() }).count == weeklyQuestions.count)

        let today = AIInsightSnapshotBuilder.prepare(
            sessions: sessions,
            referenceDate: reference,
            calendar: calendar,
            scope: .today
        )
        let todayQuestions = ReflectionSuggestedQuestions.forSnapshot(today.payload)
        #expect(!todayQuestions.isEmpty)
        #expect(todayQuestions.allSatisfy { $0.localizedCaseInsensitiveContains("today") })
        #expect(!todayQuestions.contains { $0.localizedCaseInsensitiveContains("this week") })
    }

    @Test func suggestionsOmitEmptyUnobservedAndInsufficientTrendData() throws {
        let calendar = manilaCalendar()
        let reference = date("2026-09-29 12:00", calendar: calendar)
        let empty = AIInsightSnapshotBuilder.prepare(
            sessions: [], referenceDate: reference, calendar: calendar, scope: .lastSevenDays
        )
        #expect(ReflectionSuggestedQuestions.forSnapshot(empty.payload).isEmpty)

        let unobserved = WaitSession(
            codexSessionID: "unobserved-only",
            codexTurnID: "turn",
            startTime: date("2026-09-29 09:00", calendar: calendar),
            endTime: date("2026-09-29 09:10", calendar: calendar),
            duration: 600,
            state: .completed
        )
        let unobservedSnapshot = AIInsightSnapshotBuilder.prepare(
            sessions: [unobserved], referenceDate: reference, calendar: calendar, scope: .today
        )
        #expect(unobservedSnapshot.payload.durations.unobservedSeconds == 600)
        #expect(ReflectionSuggestedQuestions.forSnapshot(unobservedSnapshot.payload).isEmpty)

        let oneDayWeek = AIInsightSnapshotBuilder.prepare(
            sessions: [try observedSession(at: date("2026-09-29 09:00", calendar: calendar), classification: .productive, id: "one-day-focus")],
            referenceDate: reference,
            calendar: calendar,
            scope: .lastSevenDays
        )
        let oneDayQuestions = ReflectionSuggestedQuestions.forSnapshot(oneDayWeek.payload)
        #expect(!oneDayQuestions.isEmpty)
    }

    @Test func providerBuildsChatCompletionRequestAndParsesAnswer() async throws {
        let prepared = try weeklySnapshot()
        let evidenceID = try #require(prepared.payload.evidence.first { $0.id.hasPrefix("day-") && $0.durationSeconds > 0 }?.id)
        let response = try chatCompletionResponse(
            answer: "Recorded activity shows a clear focus pattern.",
            evidenceIDs: [evidenceID],
            metricIDs: ["period.productive_duration"]
        )
        let transport = RecordingReflectionTransport(response: response)
        let configuration = try #require(FeatherlessConfiguration(apiKey: "test-only-key", model: "test-model"))
        let provider = FeatherlessReflectionChatProvider(configuration: configuration, transport: transport)

        let answer = try await provider.respond(to: "What took the most time?", snapshot: prepared.payload, recentMessages: [])
        let request = try #require(await transport.capturedRequest())
        #expect(request.url?.absoluteString == "https://api.featherless.ai/v1/chat/completions")
        #expect(request.method == "POST")
        #expect(request.contentType == "application/json")
        #expect(request.hasAuthorization)
        let body = try #require(request.body)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["model"] as? String == "test-model")
        let messages = try #require(object["messages"] as? [[String: String]])
        #expect(messages.last?["content"] == "What took the most time?")
        #expect(messages.first?["content"]?.contains("selected period") == true)
        #expect(messages.first?["content"]?.contains("do not use digits, number words") == true)
        #expect(answer.text == "Recorded activity shows a clear focus pattern.")
        #expect(answer.evidenceIDs == [evidenceID])
        #expect(answer.metrics.first?.id == "period.productive_duration")
    }

    @Test func failedReflectionRequestCanBeRetriedWithoutSavingFailedTurn() async throws {
        let prepared = try weeklySnapshot()
        let evidenceID = try #require(prepared.payload.evidence.first { $0.id.hasPrefix("day-") && $0.durationSeconds > 0 }?.id)
        let transport = RetryReflectionTransport(responses: [
            FeatherlessHTTPResponse(data: Data("private failure detail".utf8), statusCode: 503),
            try chatCompletionResponse(answer: "Recorded activity supports this observation.", evidenceIDs: [evidenceID])
        ])
        let configuration = try #require(FeatherlessConfiguration(apiKey: "test-only-key", model: "test-model"))
        let coordinator = ReflectionConversationCoordinator(
            provider: FeatherlessReflectionChatProvider(configuration: configuration, transport: transport)
        )
        let key = ReflectionConversationKey(scope: prepared.payload.scope, snapshotFingerprint: prepared.fingerprint)

        await #expect(throws: ReflectionChatError.providerUnavailable(statusCode: 503)) {
            try await coordinator.send(question: "Try again", prepared: prepared)
        }
        #expect(await coordinator.messages(for: key).isEmpty)
        let exchange = try await coordinator.send(question: "Try again", prepared: prepared)
        #expect(exchange.messages.count == 2)
        #expect(exchange.response.text == "Recorded activity supports this observation.")
        #expect(await coordinator.messages(for: key).count == 2)
    }

    @Test func validatesSanitizedKnownEvidenceOnly() throws {
        let prepared = try weeklySnapshot()
        let evidenceIDs = Array(prepared.payload.evidence.filter {
            $0.id.hasPrefix("day-") && $0.durationSeconds > 0
        }.prefix(2).map(\.id))
        #expect(evidenceIDs.count == 2)
        let valid = try JSONSerialization.data(withJSONObject: [
            "answer": "The pattern around /Users/alice/Secret and person@example.com stands out.",
            "evidence_ids": evidenceIDs,
            "metric_ids": ["period.productive_duration", "day.2026-09-28.context_switches"]
        ])
        let response = try FeatherlessReflectionChatProvider.validate(valid, snapshot: prepared.payload)
        #expect(response.text.contains("[redacted]"))
        #expect(!response.text.contains("alice"))
        #expect(response.evidenceIDs == evidenceIDs.sorted())
        #expect(response.metrics.count == 2)
        #expect(response.metrics.first { $0.id == "period.productive_duration" }?.value == WaitDurationFormat.compact(TimeInterval(prepared.payload.durations.productiveSeconds)))

        let unknown = try JSONSerialization.data(withJSONObject: ["answer": "A pattern emerges.", "evidence_ids": ["unknown"], "metric_ids": []])
        #expect(throws: ReflectionChatError.unknownEvidence) {
            try FeatherlessReflectionChatProvider.validate(unknown, snapshot: prepared.payload)
        }
        let missing = try JSONSerialization.data(withJSONObject: ["answer": "A pattern emerges.", "evidence_ids": [], "metric_ids": []])
        #expect(throws: ReflectionChatError.missingEvidence) {
            try FeatherlessReflectionChatProvider.validate(missing, snapshot: prepared.payload)
        }
        let summaryOnly = try JSONSerialization.data(withJSONObject: ["answer": "A pattern emerges.", "evidence_ids": ["period-summary"], "metric_ids": []])
        #expect(throws: ReflectionChatError.missingEvidence) {
            try FeatherlessReflectionChatProvider.validate(summaryOnly, snapshot: prepared.payload)
        }
    }

    @Test func numericClaimsAreOmittedAndLocallyCalculatedMetricsRemainAuthoritative() throws {
        let prepared = try weeklySnapshot()
        let evidenceID = try #require(prepared.payload.evidence.first { $0.id.hasPrefix("day-") && $0.durationSeconds > 0 }?.id)
        for answer in ["You were focused for 354 seconds.", "You had thirty eight context switches."] {
            let data = try JSONSerialization.data(withJSONObject: [
                "answer": answer, "evidence_ids": [evidenceID], "metric_ids": []
            ])
            let response = try FeatherlessReflectionChatProvider.validate(data, snapshot: prepared.payload)
            #expect(response.text.contains("I left out an unconfirmed number"))
            #expect(!response.text.contains("354"))
            #expect(!response.text.contains("thirty eight"))
            #expect(response.evidenceIDs == [evidenceID])
        }

        let mixedAnswer = try JSONSerialization.data(withJSONObject: [
            "answer": "You focused for 354 seconds. Your recorded activity was software development.",
            "evidence_ids": [evidenceID],
            "metric_ids": ["period.productive_duration"]
        ])
        let mixedResponse = try FeatherlessReflectionChatProvider.validate(mixedAnswer, snapshot: prepared.payload)
        #expect(mixedResponse.text.contains("Your recorded activity was software development."))
        #expect(!mixedResponse.text.contains("354"))
        #expect(mixedResponse.metrics.first?.id == "period.productive_duration")

        let localMetric = try #require(mixedResponse.metrics.first)
        #expect(localMetric.value == WaitDurationFormat.compact(TimeInterval(prepared.payload.durations.productiveSeconds)))
        #expect(!localMetric.value.contains("354"))

        let qualitativeAnswer = try JSONSerialization.data(withJSONObject: [
            "answer": "Your recorded activity was software development.",
            "evidence_ids": [evidenceID],
            "metric_ids": []
        ])
        let qualitativeResponse = try FeatherlessReflectionChatProvider.validate(qualitativeAnswer, snapshot: prepared.payload)
        #expect(qualitativeResponse.text == "Your recorded activity was software development.")

        let unknownMetric = try JSONSerialization.data(withJSONObject: [
            "answer": "Your focus appears more consistent.", "evidence_ids": [evidenceID], "metric_ids": ["period.secret_metric"]
        ])
        #expect(throws: ReflectionChatError.unknownMetric) {
            try FeatherlessReflectionChatProvider.validate(unknownMetric, snapshot: prepared.payload)
        }
    }

    @Test func malformedReflectionContractIsRejected() throws {
        let prepared = try weeklySnapshot()
        for data in [Data("not json".utf8), try JSONSerialization.data(withJSONObject: [
            "answer": "A grounded observation.", "evidence_ids": ["day-2026-09-28"]
        ])] {
            #expect(throws: ReflectionChatError.malformedResponse) {
                try FeatherlessReflectionChatProvider.validate(data, snapshot: prepared.payload)
            }
        }
    }

    @Test func emptyAndLongAnswersKeepSafeResponseBehavior() throws {
        let prepared = try weeklySnapshot()
        let evidenceID = try #require(prepared.payload.evidence.first { $0.id.hasPrefix("day-") && $0.durationSeconds > 0 }?.id)
        let empty = try JSONSerialization.data(withJSONObject: [
            "answer": " \n ", "evidence_ids": [evidenceID], "metric_ids": []
        ])
        #expect(throws: ReflectionChatError.emptyAnswer) {
            try FeatherlessReflectionChatProvider.validate(empty, snapshot: prepared.payload)
        }

        let longText = String(repeating: "x", count: 1_500)
        let long = try JSONSerialization.data(withJSONObject: [
            "answer": longText, "evidence_ids": [evidenceID], "metric_ids": []
        ])
        let response = try FeatherlessReflectionChatProvider.validate(long, snapshot: prepared.payload)
        #expect(response.text.count == 1_200)
        #expect(response.text.hasSuffix("…"))
    }

    @Test func comparisonMetricsDisplayBothExplicitDates() throws {
        let prepared = try weeklySnapshot()
        let comparison = try #require(prepared.payload.dayComparisons.first)
        let evidenceID = try #require(prepared.payload.evidence.first { $0.id.hasPrefix("day-") && $0.durationSeconds > 0 }?.id)
        let metricID = "comparison.\(comparison.id).productive_delta"
        let data = try JSONSerialization.data(withJSONObject: [
            "answer": "Your focus changed between these days.",
            "evidence_ids": [evidenceID],
            "metric_ids": [metricID]
        ])
        let response = try FeatherlessReflectionChatProvider.validate(data, snapshot: prepared.payload)
        let metric = try #require(response.metrics.first)
        #expect(metric.label.contains(comparison.fromDate))
        #expect(metric.label.contains(comparison.toDate))
        #expect(metric.label.contains("to"))
    }

    @Test func providerMapsTimeoutAndHTTPFailureWithoutExposingResponseBody() async throws {
        let snapshot = try weeklySnapshot().payload
        let config = try #require(FeatherlessConfiguration(apiKey: "private-key", model: "test-model"))
        let timeoutProvider = FeatherlessReflectionChatProvider(configuration: config, transport: StubReflectionTransport(error: .timeout))
        await #expect(throws: ReflectionChatError.timeout) {
            try await timeoutProvider.respond(to: "question", snapshot: snapshot, recentMessages: [])
        }
        let failureProvider = FeatherlessReflectionChatProvider(configuration: config, transport: StubReflectionTransport(response: FeatherlessHTTPResponse(data: Data("private server detail".utf8), statusCode: 503)))
        do {
            _ = try await failureProvider.respond(to: "question", snapshot: snapshot, recentMessages: [])
            Issue.record("Expected provider failure")
        } catch let error as ReflectionChatError {
            #expect(error == .providerUnavailable(statusCode: 503))
            #expect(error.localizedDescription != "private server detail")
        }
    }

    @Test func conversationsAreScopedBoundedAndResetByFingerprint() async throws {
        let weekly = try weeklySnapshot()
        let provider = RecordingReflectionProvider()
        let coordinator = ReflectionConversationCoordinator(provider: provider)

        for index in 1...5 {
            _ = try await coordinator.send(question: "Question \(index)", prepared: weekly)
        }
        #expect(await provider.maximumReceivedHistoryCount() == 6)
        let weeklyKey = ReflectionConversationKey(scope: .lastSevenDays, snapshotFingerprint: weekly.fingerprint)
        #expect(await coordinator.messages(for: weeklyKey).count == 10)

        let today = AIInsightSnapshotBuilder.prepare(sessions: [], referenceDate: date("2026-09-29 12:00", calendar: manilaCalendar()), calendar: manilaCalendar(), scope: .today)
        _ = try await coordinator.send(question: "Today?", prepared: today)
        let todayKey = ReflectionConversationKey(scope: .today, snapshotFingerprint: today.fingerprint)
        #expect(await coordinator.messages(for: todayKey).count == 2)
        #expect(await coordinator.messages(for: weeklyKey).count == 10)

        var changedPayloadSessions = try DemoHistorySeeder(store: WaitSessionStore(fileURL: URL(fileURLWithPath: "/tmp/unused")), calendar: manilaCalendar()).makeSessions(referenceDay: manilaCalendar().startOfDay(for: date("2026-09-29 12:00", calendar: manilaCalendar())))
        changedPayloadSessions.append(WaitSession(codexSessionID: "real", codexTurnID: "today", startTime: date("2026-09-29 09:00", calendar: manilaCalendar()), endTime: date("2026-09-29 09:01", calendar: manilaCalendar()), duration: 60, state: .completed))
        let changedToday = AIInsightSnapshotBuilder.prepare(sessions: changedPayloadSessions, referenceDate: date("2026-09-29 12:00", calendar: manilaCalendar()), calendar: manilaCalendar(), scope: .today)
        _ = try await coordinator.send(question: "Updated?", prepared: changedToday)
        let changedKey = ReflectionConversationKey(scope: .today, snapshotFingerprint: changedToday.fingerprint)
        #expect(await coordinator.messages(for: changedKey).count == 2)
        #expect(await coordinator.messages(for: todayKey).isEmpty)
    }

    @Test func credentialResolutionSeparatesMissingFieldsAndPrefersKeychain() throws {
        let missing = FeatherlessConfigurationResolver.resolve(storedAPIKey: nil, storedModel: nil, environment: [:])
        #expect(missing.missingAPIKey)
        #expect(missing.missingModel)
        #expect(missing.status.contains("API key and model"))

        let environment = FeatherlessConfigurationResolver.resolve(
            storedAPIKey: nil,
            storedModel: nil,
            environment: [FeatherlessConfiguration.apiKeyEnvironmentKey: "env-secret", FeatherlessConfiguration.modelEnvironmentKey: "env-model"]
        )
        #expect(environment.credentialSource == .environment)
        #expect(environment.configuration?.model == "env-model")

        let keychain = FeatherlessConfigurationResolver.resolve(
            storedAPIKey: "saved-secret",
            storedModel: "saved-model",
            environment: [FeatherlessConfiguration.apiKeyEnvironmentKey: "env-secret", FeatherlessConfiguration.modelEnvironmentKey: "env-model"]
        )
        #expect(keychain.credentialSource == .keychain)
        #expect(keychain.configuration?.apiKey == "saved-secret")
        #expect(!keychain.status.contains("saved-secret"))

        let store = InMemoryAICredentialStore()
        #expect(store.apiKey() == nil)
        store.setAPIKey("secret")
        #expect(store.apiKey() == "secret")
        store.removeAPIKey()
        #expect(store.apiKey() == nil)
    }

    @Test func blockedCredentialReadTimesOutWithoutReturningLateValue() async {
        let store = BlockingCredentialStore(delay: 0.3, value: "must-not-escape")
        let started = Date()
        do {
            _ = try await apiKeyWithTimeout(from: store, timeout: 0.02)
            Issue.record("Expected a timed-out credential read")
        } catch is AICredentialReadTimeoutError {
            #expect(Date().timeIntervalSince(started) < 0.2)
        } catch {
            Issue.record("Unexpected credential read error: \(error)")
        }
    }

    @Test func lateResponseIsDiscardedWithoutErasingExistingConversation() async throws {
        let prepared = try weeklySnapshot()
        let provider = DelayedReflectionProvider()
        let coordinator = ReflectionConversationCoordinator(provider: provider)
        let key = ReflectionConversationKey(scope: .lastSevenDays, snapshotFingerprint: prepared.fingerprint)

        let pending = Task { try await coordinator.send(question: "Slow question", prepared: prepared) }
        try await Task.sleep(for: .milliseconds(5))
        await coordinator.cancelPendingResponse(for: .lastSevenDays)
        await #expect(throws: ReflectionChatError.staleResponse) { try await pending.value }
        #expect(await coordinator.messages(for: key).isEmpty)
    }

    private func weeklySnapshot() throws -> AIInsightPreparedSnapshot {
        let calendar = manilaCalendar()
        let reference = date("2026-09-29 12:00", calendar: calendar)
        let sessions = try DemoHistorySeeder(store: WaitSessionStore(fileURL: URL(fileURLWithPath: "/tmp/unused")), calendar: calendar).makeSessions(referenceDay: calendar.startOfDay(for: reference))
        return AIInsightSnapshotBuilder.prepare(sessions: sessions, referenceDate: reference, calendar: calendar, scope: .lastSevenDays)
    }

    private func manilaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila")!
        return calendar
    }

    private func date(_ value: String, calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }

    private func chatCompletionResponse(
        answer: String,
        evidenceIDs: [String],
        metricIDs: [String] = []
    ) throws -> FeatherlessHTTPResponse {
        let content = try JSONSerialization.data(withJSONObject: [
            "answer": answer,
            "evidence_ids": evidenceIDs,
            "metric_ids": metricIDs
        ])
        let envelope = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": String(decoding: content, as: UTF8.self)]]]
        ])
        return FeatherlessHTTPResponse(data: envelope, statusCode: 200)
    }

    private func observedSession(
        at start: Date,
        classification: WaitSessionClassification,
        id: String
    ) throws -> WaitSession {
        let sessionID = UUID()
        let segmentID = UUID()
        let end = start.addingTimeInterval(300)
        let context = try #require(ActivityContext(
            applicationBundleIdentifier: classification == .productive ? "com.apple.dt.Xcode" : "com.valvesoftware.steam",
            applicationName: classification == .productive ? "Xcode" : "Steam",
            windowTitle: classification == .productive ? "Project.swift" : "Library",
            presenceState: .active,
            provenance: ActivityContextProvenance(applicationIdentity: .foregroundApplication)
        ))
        let segment = ActivitySegment(
            id: segmentID,
            waitSessionID: sessionID,
            context: context,
            startedAt: start,
            endedAt: end,
            duration: 300
        )
        let slice = ActivityClassificationSlice(
            sourceActivitySegmentID: segmentID,
            startedAt: start,
            endedAt: end,
            duration: 300,
            automaticClassificationResult: .init(classification: classification, reasonCodes: [], reviewSuggested: false)
        )
        return WaitSession(
            id: sessionID,
            codexSessionID: id,
            codexTurnID: id,
            startTime: start,
            endTime: end,
            duration: 300,
            state: .completed,
            activitySegments: [segment],
            activityClassificationSlices: [slice]
        )
    }
}

private actor RecordingReflectionProvider: ReflectionChatProviding {
    private var receivedHistoryCounts: [Int] = []
    func respond(to question: String, snapshot: AIInsightAnalysisSnapshot, recentMessages: [ReflectionChatMessage]) async throws -> ReflectionChatResponse {
        receivedHistoryCounts.append(recentMessages.count)
        let evidenceID = snapshot.evidence.first(where: { $0.id.hasPrefix("day-") })?.id ?? "period-summary"
        return ReflectionChatResponse(text: "Grounded response", evidenceIDs: [evidenceID])
    }
    func maximumReceivedHistoryCount() -> Int { receivedHistoryCounts.max() ?? 0 }
}

private struct DelayedReflectionProvider: ReflectionChatProviding {
    func respond(to question: String, snapshot: AIInsightAnalysisSnapshot, recentMessages: [ReflectionChatMessage]) async throws -> ReflectionChatResponse {
        try await Task.sleep(for: .milliseconds(30))
        let evidenceID = snapshot.evidence.first { $0.durationSeconds > 0 && $0.kind != .periodSummary }!.id
        return ReflectionChatResponse(text: "Late response", evidenceIDs: [evidenceID])
    }
}

private struct StubReflectionTransport: FeatherlessHTTPTransport {
    let response: FeatherlessHTTPResponse?
    let error: FeatherlessTransportError?
    init(response: FeatherlessHTTPResponse? = nil, error: FeatherlessTransportError? = nil) {
        self.response = response
        self.error = error
    }
    func send(_ request: URLRequest) async throws -> FeatherlessHTTPResponse {
        if let error { throw error }
        return response!
    }
}

private actor RecordingReflectionTransport: FeatherlessHTTPTransport {
    struct CapturedRequest: Sendable {
        let url: URL?
        let method: String?
        let contentType: String?
        let hasAuthorization: Bool
        let body: Data?
    }

    private let response: FeatherlessHTTPResponse
    private var request: CapturedRequest?

    init(response: FeatherlessHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> FeatherlessHTTPResponse {
        self.request = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            hasAuthorization: request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true,
            body: request.httpBody
        )
        return response
    }

    func capturedRequest() -> CapturedRequest? { request }
}

private actor RetryReflectionTransport: FeatherlessHTTPTransport {
    private var responses: [FeatherlessHTTPResponse]

    init(responses: [FeatherlessHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> FeatherlessHTTPResponse {
        guard !responses.isEmpty else { throw FeatherlessTransportError.networkUnavailable }
        return responses.removeFirst()
    }
}

private final class BlockingCredentialStore: AICredentialStoring, @unchecked Sendable {
    private let delay: TimeInterval
    private let value: String

    init(delay: TimeInterval, value: String) {
        self.delay = delay
        self.value = value
    }

    func apiKey() throws -> String? {
        Thread.sleep(forTimeInterval: delay)
        return value
    }

    func setAPIKey(_ value: String) throws {}
    func removeAPIKey() throws {}
}
