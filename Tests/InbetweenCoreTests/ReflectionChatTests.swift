import Foundation
import Testing
@testable import InbetweenCore

struct ReflectionChatTests {
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
    }

    @Test func validatesSanitizedKnownEvidenceOnly() throws {
        let prepared = try weeklySnapshot()
        let evidenceID = try #require(prepared.payload.evidence.first {
            $0.id.hasPrefix("day-") && $0.durationSeconds > 0
        }?.id)
        let valid = try JSONSerialization.data(withJSONObject: [
            "answer": "The strongest pattern is in /Users/alice/Secret and person@example.com",
            "evidence_ids": [evidenceID]
        ])
        let response = try FeatherlessReflectionChatProvider.validate(valid, snapshot: prepared.payload)
        #expect(response.text.contains("[redacted]"))
        #expect(!response.text.contains("alice"))

        let unknown = try JSONSerialization.data(withJSONObject: ["answer": "A pattern.", "evidence_ids": ["unknown"]])
        #expect(throws: ReflectionChatError.unknownEvidence) {
            try FeatherlessReflectionChatProvider.validate(unknown, snapshot: prepared.payload)
        }
        let missing = try JSONSerialization.data(withJSONObject: ["answer": "A pattern.", "evidence_ids": []])
        #expect(throws: ReflectionChatError.missingEvidence) {
            try FeatherlessReflectionChatProvider.validate(missing, snapshot: prepared.payload)
        }
        let summaryOnly = try JSONSerialization.data(withJSONObject: ["answer": "A pattern.", "evidence_ids": ["period-summary"]])
        #expect(throws: ReflectionChatError.missingEvidence) {
            try FeatherlessReflectionChatProvider.validate(summaryOnly, snapshot: prepared.payload)
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
