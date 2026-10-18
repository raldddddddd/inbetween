import Foundation

public enum ReflectionMessageRole: String, Codable, Equatable, Sendable { case user, assistant }

public struct ReflectionChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: ReflectionMessageRole
    public let text: String
    public let evidenceIDs: [String]
    public let metrics: [ReflectionChatMetric]

    public init(id: UUID = UUID(), role: ReflectionMessageRole, text: String, evidenceIDs: [String] = [], metrics: [ReflectionChatMetric] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.metrics = metrics
    }
}

/// A metric reference selected by the provider but valued and formatted locally.
public struct ReflectionChatMetric: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct ReflectionChatResponse: Equatable, Sendable {
    public let text: String
    public let evidenceIDs: [String]
    public let metrics: [ReflectionChatMetric]
    public init(text: String, evidenceIDs: [String], metrics: [ReflectionChatMetric] = []) {
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.metrics = metrics
    }
}

public struct ReflectionConversationKey: Hashable, Equatable, Sendable {
    public let scope: ReflectionScope
    public let snapshotFingerprint: String
    public init(scope: ReflectionScope, snapshotFingerprint: String) {
        self.scope = scope
        self.snapshotFingerprint = snapshotFingerprint
    }
}

public struct ReflectionExchange: Equatable, Sendable {
    public let key: ReflectionConversationKey
    public let messages: [ReflectionChatMessage]
    public let response: ReflectionChatResponse
}

public enum ReflectionChatError: Error, Equatable, LocalizedError, Sendable {
    case timeout
    case networkUnavailable
    case rateLimited
    case providerUnavailable(statusCode: Int)
    case malformedResponse
    case emptyAnswer
    case unknownEvidence
    case unknownMetric
    case missingEvidence
    case staleResponse

    public var errorDescription: String? {
        switch self {
        case .timeout: "Reflection timed out. Your local summary is unchanged."
        case .networkUnavailable: "Reflection is offline. Your local summary is unchanged."
        case .rateLimited: "Reflection is temporarily busy. Try again shortly."
        case .providerUnavailable: "Reflection is temporarily unavailable. Your local summary is still available."
        case .malformedResponse: "Reflection couldn’t provide a usable answer. Please try again."
        case .emptyAnswer: "Reflection didn’t return an answer. Please try again."
        case .unknownEvidence: "Reflection couldn’t connect its answer to your activity. Please try again."
        case .unknownMetric: "Reflection couldn’t verify part of its answer. Please try again."
        case .missingEvidence: "Reflection couldn’t verify its answer. Please try again."
        case .staleResponse: "Your activity changed while Reflection was responding. Please ask again."
        }
    }
}

public protocol ReflectionChatProviding: Sendable {
    func respond(
        to question: String,
        snapshot: AIInsightAnalysisSnapshot,
        recentMessages: [ReflectionChatMessage]
    ) async throws -> ReflectionChatResponse
}

public enum ReflectionChatPrompt {
    public static let systemInstructions = """
    Answer the user's reflection question directly and concisely using only the supplied local snapshot and selected period. The app is authoritative for metrics, durations, counts, comparisons, and dates. Explain what recorded activity supports the answer, distinguish observations from interpretation, and acknowledge when the snapshot does not contain enough evidence. Never treat unobserved or unrecorded time as distraction, and do not invent activities, goals, comparisons, or reasons. The answer string must be qualitative only: do not use digits, number words, dates, counts, durations, percentages, or other numeric claims. If the activity can be described qualitatively, answer without mentioning measured time. Put any requested numeric result only in metric_ids; the app supplies and displays those locally calculated values. Cite one or more supplied evidence IDs. Return only JSON with exactly this shape: {"answer":"qualitative explanation","evidence_ids":["known-id"],"metric_ids":["known-metric-id"]}. Use an empty metric_ids array when no metric is needed. Do not include markdown or extra keys.
    """

    static func snapshotContent(_ snapshot: AIInsightAnalysisSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(snapshot), encoding: .utf8) else {
            throw ReflectionChatError.malformedResponse
        }
        let metricCatalog = FeatherlessReflectionChatProvider.metrics(in: snapshot).values
            .sorted { $0.id < $1.id }
            .map { ["id": $0.id, "label": $0.label] }
        let catalogData = try encoder.encode(metricCatalog)
        guard let catalogText = String(data: catalogData, encoding: .utf8) else {
            throw ReflectionChatError.malformedResponse
        }
        return "LOCAL SNAPSHOT:\n\(text)\nAVAILABLE METRIC IDS (values remain authoritative in the snapshot):\n\(catalogText)"
    }
}

public enum ReflectionQuestionSubmission {
    /// A selected suggestion takes precedence over the draft because SwiftUI state
    /// writes are deferred until after the current button action completes.
    public static func resolve(draft: String, suggestion: String? = nil) -> String? {
        let value = (suggestion ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public struct FeatherlessReflectionChatProvider: ReflectionChatProviding {
    private let configuration: FeatherlessConfiguration
    private let transport: any FeatherlessHTTPTransport

    public init(
        configuration: FeatherlessConfiguration,
        transport: any FeatherlessHTTPTransport = URLSessionFeatherlessHTTPTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func respond(
        to question: String,
        snapshot: AIInsightAnalysisSnapshot,
        recentMessages: [ReflectionChatMessage]
    ) async throws -> ReflectionChatResponse {
        let question = AITextSanitizer.sanitize(question, maximumLength: 500)
        var messages = [
            Message(role: "system", content: ReflectionChatPrompt.systemInstructions),
            Message(role: "user", content: try ReflectionChatPrompt.snapshotContent(snapshot))
        ]
        messages.append(contentsOf: recentMessages.suffix(6).map {
            Message(role: $0.role.rawValue, content: AITextSanitizer.sanitize($0.text, maximumLength: 1_000))
        })
        messages.append(Message(role: "user", content: question))

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Inbetween", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONEncoder().encode(Request(model: configuration.model, messages: messages, temperature: 0, maxTokens: 500))
        let response: FeatherlessHTTPResponse
        do { response = try await transport.send(request) }
        catch FeatherlessTransportError.timeout { throw ReflectionChatError.timeout }
        catch { throw ReflectionChatError.networkUnavailable }
        switch response.statusCode {
        case 200..<300: break
        case 429: throw ReflectionChatError.rateLimited
        default: throw ReflectionChatError.providerUnavailable(statusCode: response.statusCode)
        }
        guard let completion = try? JSONDecoder().decode(Response.self, from: response.data),
              let content = completion.choices.first?.message.content,
              let data = content.data(using: .utf8) else { throw ReflectionChatError.malformedResponse }
        return try Self.validate(data, snapshot: snapshot)
    }

    public static func validate(_ data: Data, snapshot: AIInsightAnalysisSnapshot) throws -> ReflectionChatResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["answer", "evidence_ids", "metric_ids"],
              let answer = object["answer"] as? String,
              let evidence = object["evidence_ids"] as? [String],
              let metricIDs = object["metric_ids"] as? [String]
        else { throw ReflectionChatError.malformedResponse }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReflectionChatError.emptyAnswer }
        guard !evidence.isEmpty else { throw ReflectionChatError.missingEvidence }
        let known = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.id, $0) })
        guard evidence.allSatisfy({ known[$0] != nil }) else { throw ReflectionChatError.unknownEvidence }
        guard evidence.contains(where: {
            guard let item = known[$0] else { return false }
            return item.kind != .periodSummary && item.durationSeconds > 0
        }) else { throw ReflectionChatError.missingEvidence }
        let availableMetrics = metrics(in: snapshot)
        guard metricIDs.allSatisfy({ availableMetrics[$0] != nil }) else { throw ReflectionChatError.unknownMetric }
        let safeAnswer: String
        if containsNumericClaim(answer) {
            let qualitativeSentences = answerWithoutNumericSentences(answer)
            let note = "I left out an unconfirmed number; the local summary below has the recorded figures."
            safeAnswer = qualitativeSentences.isEmpty ? note : "\(qualitativeSentences) \(note)"
        } else {
            safeAnswer = answer
        }
        return ReflectionChatResponse(
            text: AITextSanitizer.sanitize(safeAnswer, maximumLength: 1_200),
            evidenceIDs: Array(Set(evidence)).sorted(),
            metrics: Array(Set(metricIDs)).sorted().compactMap { availableMetrics[$0] }
        )
    }

    fileprivate static func metrics(in snapshot: AIInsightAnalysisSnapshot) -> [String: ReflectionChatMetric] {
        var result: [String: ReflectionChatMetric] = [:]
        func add(_ id: String, _ label: String, _ value: String) {
            result[id] = ReflectionChatMetric(id: id, label: label, value: value)
        }
        func addDurations(_ durations: AIInsightDurations, prefix: String, labelPrefix: String) {
            for (key, label, seconds) in [
                ("productive_duration", "Productive", durations.productiveSeconds),
                ("distracted_duration", "Distracted", durations.distractedSeconds),
                ("unclassified_duration", "Unclassified", durations.unclassifiedSeconds),
                ("not_recorded_duration", "Not recorded", durations.notRecordedSeconds),
                ("active_duration", "Active", durations.activeSeconds),
                ("idle_duration", "Idle", durations.idleSeconds),
                ("away_duration", "Away", durations.awaySeconds),
                ("unobserved_duration", "Unobserved", durations.unobservedSeconds)
            ] {
                add("\(prefix).\(key)", "\(labelPrefix)\(label)", WaitDurationFormat.compact(TimeInterval(seconds)))
            }
        }
        addDurations(snapshot.durations, prefix: "period", labelPrefix: "")
        add("period.completed_sessions", "Completed sessions", "\(snapshot.completedSessionCount)")
        add("period.context_switches", "Context switches", "\(snapshot.contextSwitchCount)")
        for day in snapshot.days {
            let prefix = "day.\(day.date)"
            let labelPrefix = "\(day.date) · "
            addDurations(day.durations, prefix: prefix, labelPrefix: labelPrefix)
            add("\(prefix).completed_sessions", "\(labelPrefix)Completed sessions", "\(day.completedSessionCount)")
            add("\(prefix).context_switches", "\(labelPrefix)Context switches", "\(day.contextSwitchCount)")
            add("\(prefix).focus_blocks", "\(labelPrefix)Focus blocks", "\(day.focusBlockCount)")
            add("\(prefix).distraction_clusters", "\(labelPrefix)Distraction clusters", "\(day.distractionClusterCount)")
        }
        for comparison in snapshot.dayComparisons {
            let prefix = "comparison.\(comparison.id)"
            let labelPrefix = "\(comparison.fromDate) to \(comparison.toDate) · "
            add("\(prefix).productive_delta", "\(labelPrefix)Productive change", durationDelta(comparison.productiveDeltaSeconds))
            add("\(prefix).distracted_delta", "\(labelPrefix)Distracted change", durationDelta(comparison.distractedDeltaSeconds))
            add("\(prefix).unclassified_delta", "\(labelPrefix)Unclassified change", durationDelta(comparison.unclassifiedDeltaSeconds))
            let switches = comparison.contextSwitchDelta
            add("\(prefix).context_switch_delta", "\(labelPrefix)Context-switch change", switches == 0 ? "No change" : "\(abs(switches))" + (switches < 0 ? " fewer" : " more"))
        }
        return result
    }

    private static func durationDelta(_ seconds: Int) -> String {
        seconds == 0 ? "No change" : WaitDurationFormat.spoken(TimeInterval(abs(seconds))) + (seconds < 0 ? " less" : " more")
    }

    /// Numeric statements belong in metric references, where the value is rendered locally.
    /// This lexical guard is defense in depth; the response contract does not ask the model
    /// to author metric values in prose.
    private static func containsNumericClaim(_ text: String) -> Bool {
        if text.contains(where: \.isNumber) { return true }
        let numberWords: Set<String> = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
            "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
            "million", "billion", "first", "second", "third", "fourth", "fifth", "half", "quarter", "percent", "percentage"
        ]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains(where: numberWords.contains)
    }

    private static func answerWithoutNumericSentences(_ text: String) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
            guard let sentence, !containsNumericClaim(sentence) else { return }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { sentences.append(trimmed) }
        }
        return sentences.joined(separator: " ")
    }

    private struct Message: Codable { let role: String; let content: String }
    private struct Request: Encodable {
        let model: String; let messages: [Message]; let temperature: Double; let maxTokens: Int
        enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens" }
    }
    private struct Response: Decodable { let choices: [Choice]; struct Choice: Decodable { let message: Message } }
}

public actor ReflectionConversationCoordinator {
    private let provider: any ReflectionChatProviding
    private var conversations: [ReflectionConversationKey: [ReflectionChatMessage]] = [:]
    private var revisions: [ReflectionScope: Int] = [:]

    public init(provider: any ReflectionChatProviding) { self.provider = provider }

    public func messages(for key: ReflectionConversationKey) -> [ReflectionChatMessage] {
        conversations[key] ?? []
    }

    public func send(question: String, prepared: AIInsightPreparedSnapshot) async throws -> ReflectionExchange {
        let key = ReflectionConversationKey(scope: prepared.payload.scope, snapshotFingerprint: prepared.fingerprint)
        conversations = conversations.filter { $0.key.scope != key.scope || $0.key == key }
        let current = conversations[key] ?? []
        let revision = revisions[key.scope, default: 0]
        let response = try await provider.respond(to: question, snapshot: prepared.payload, recentMessages: Array(current.suffix(6)))
        guard revisions[key.scope, default: 0] == revision else {
            throw ReflectionChatError.staleResponse
        }
        let updated = current + [
            ReflectionChatMessage(role: .user, text: AITextSanitizer.sanitize(question, maximumLength: 500)),
            ReflectionChatMessage(role: .assistant, text: response.text, evidenceIDs: response.evidenceIDs, metrics: response.metrics)
        ]
        conversations[key] = updated
        return ReflectionExchange(key: key, messages: updated, response: response)
    }

    public func newConversation(for key: ReflectionConversationKey) {
        revisions[key.scope, default: 0] += 1
        conversations = conversations.filter { $0.key.scope != key.scope }
        conversations[key] = []
    }

    public func cancelPendingResponse(for scope: ReflectionScope) {
        revisions[scope, default: 0] += 1
    }
}
