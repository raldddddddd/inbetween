import Foundation

public enum ReflectionMessageRole: String, Codable, Equatable, Sendable { case user, assistant }

public struct ReflectionChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let role: ReflectionMessageRole
    public let text: String
    public let evidenceIDs: [String]

    public init(id: UUID = UUID(), role: ReflectionMessageRole, text: String, evidenceIDs: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.evidenceIDs = evidenceIDs
    }
}

public struct ReflectionChatResponse: Equatable, Sendable {
    public let text: String
    public let evidenceIDs: [String]
    public init(text: String, evidenceIDs: [String]) { self.text = text; self.evidenceIDs = evidenceIDs }
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
    case missingEvidence
    case staleResponse

    public var errorDescription: String? {
        switch self {
        case .timeout: "Reflection timed out. Your local summary is unchanged."
        case .networkUnavailable: "Reflection is offline. Your local summary is unchanged."
        case .rateLimited: "Reflection is temporarily busy. Try again shortly."
        case let .providerUnavailable(code): "Featherless or the model is unavailable (HTTP \(code))."
        case .malformedResponse: "Featherless returned an invalid reflection response."
        case .emptyAnswer: "Featherless returned an empty reflection."
        case .unknownEvidence: "Featherless cited evidence that is not in the local snapshot."
        case .missingEvidence: "Featherless did not cite local evidence."
        case .staleResponse: "The stale Reflection response was discarded."
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
    Answer the user's reflection question using only the supplied deterministic local snapshot. The app, not you, is authoritative for metrics, durations, counts, comparisons, and dates. Interpret supplied facts; never invent or recalculate a metric. Be concise and practical. Cite one or more supplied evidence IDs. Return only JSON with exactly this shape: {"answer":"plain text","evidence_ids":["known-id"]}. Do not include markdown or extra keys.
    """

    static func snapshotContent(_ snapshot: AIInsightAnalysisSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let text = String(data: try encoder.encode(snapshot), encoding: .utf8) else {
            throw ReflectionChatError.malformedResponse
        }
        return "LOCAL SNAPSHOT:\n\(text)"
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
              Set(object.keys) == ["answer", "evidence_ids"],
              let answer = object["answer"] as? String,
              let evidence = object["evidence_ids"] as? [String]
        else { throw ReflectionChatError.malformedResponse }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ReflectionChatError.emptyAnswer }
        guard !evidence.isEmpty else { throw ReflectionChatError.missingEvidence }
        let known = Dictionary(uniqueKeysWithValues: snapshot.evidence.map { ($0.id, $0) })
        guard evidence.allSatisfy({ known[$0] != nil }) else { throw ReflectionChatError.unknownEvidence }
        guard evidence.contains(where: {
            guard let item = known[$0] else { return false }
            return item.kind != .periodSummary && item.durationSeconds > 0
        }) else { throw ReflectionChatError.missingEvidence }
        return ReflectionChatResponse(text: AITextSanitizer.sanitize(answer, maximumLength: 1_200), evidenceIDs: Array(Set(evidence)).sorted())
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
            ReflectionChatMessage(role: .assistant, text: response.text, evidenceIDs: response.evidenceIDs)
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
