import Foundation

public enum AITextSanitizer {
    public static func sanitize(_ value: String, maximumLength: Int = 240) -> String {
        var sanitized = value.components(separatedBy: .controlCharacters).joined(separator: " ")
        for pattern in [
            #"(?i)(?:https?|file)://\S+"#,
            #"(?i)\b(?:www\.)?[a-z0-9.-]+\.[a-z]{2,}(?:/[^\s]*)?\?[^\s]+"#,
            #"(?i)\b[\w.%+-]+@[\w.-]+\.[a-z]{2,}\b"#,
            #"(?i)(?:file://)?/(?:Users|home)/.*"#,
            #"(?i)\b[A-Z]:\\.*"#,
            #"(?<!\w)/(?:[^\s/]+/)+.*"#
        ] {
            sanitized = sanitized.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        sanitized = sanitized.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { return "Context unavailable" }
        if sanitized.count > maximumLength { return String(sanitized.prefix(maximumLength - 1)) + "…" }
        return sanitized
    }
}

public struct FeatherlessConfiguration: Equatable, Sendable {
    public static let apiKeyEnvironmentKey = "INBETWEEN_FEATHERLESS_API_KEY"
    public static let modelEnvironmentKey = "INBETWEEN_FEATHERLESS_MODEL"
    public static let baseURLEnvironmentKey = "INBETWEEN_FEATHERLESS_BASE_URL"
    public static let timeoutEnvironmentKey = "INBETWEEN_FEATHERLESS_TIMEOUT_SECONDS"
    public static let defaultBaseURL = URL(string: "https://api.featherless.ai/v1")!

    public let apiKey: String
    public let model: String
    public let baseURL: URL
    public let timeout: TimeInterval

    public init?(apiKey: String, model: String, baseURL: URL = Self.defaultBaseURL, timeout: TimeInterval = 20) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty, baseURL.scheme?.lowercased() == "https",
              baseURL.host?.isEmpty == false, baseURL.query == nil, baseURL.fragment == nil,
              timeout.isFinite, (1...120).contains(timeout) else { return nil }
        self.apiKey = key
        self.model = model
        self.baseURL = baseURL
        self.timeout = timeout
    }
}

public enum FeatherlessCredentialSource: String, Equatable, Sendable {
    case keychain = "Saved in Keychain"
    case environment = "Development environment"
}

public struct FeatherlessConfigurationResolution: Equatable, Sendable {
    public let configuration: FeatherlessConfiguration?
    public let credentialSource: FeatherlessCredentialSource?
    public let missingAPIKey: Bool
    public let missingModel: Bool

    public var status: String {
        if missingAPIKey && missingModel { return "API key and model are missing." }
        if missingAPIKey { return "API key is missing." }
        if missingModel { return "Model is missing." }
        return credentialSource?.rawValue ?? "Configured"
    }
}

public enum FeatherlessConfigurationResolver {
    public static func resolve(
        storedAPIKey: String?,
        storedModel: String?,
        environment: [String: String]
    ) -> FeatherlessConfigurationResolution {
        let storedKey = normalized(storedAPIKey)
        let environmentKey = normalized(environment[FeatherlessConfiguration.apiKeyEnvironmentKey])
        let key = storedKey ?? environmentKey
        let model = normalized(storedModel) ?? normalized(environment[FeatherlessConfiguration.modelEnvironmentKey])
        let baseURL = environment[FeatherlessConfiguration.baseURLEnvironmentKey].flatMap(URL.init(string:)) ?? FeatherlessConfiguration.defaultBaseURL
        let timeout = environment[FeatherlessConfiguration.timeoutEnvironmentKey].flatMap(TimeInterval.init) ?? 20
        return FeatherlessConfigurationResolution(
            configuration: key.flatMap { key in model.flatMap { FeatherlessConfiguration(apiKey: key, model: $0, baseURL: baseURL, timeout: timeout) } },
            credentialSource: storedKey != nil ? .keychain : (environmentKey != nil ? .environment : nil),
            missingAPIKey: key == nil,
            missingModel: model == nil
        )
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

public protocol AICredentialStoring: AnyObject, Sendable {
    func apiKey() throws -> String?
    func setAPIKey(_ value: String) throws
    func removeAPIKey() throws
}

public final class InMemoryAICredentialStore: AICredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    public init(apiKey: String? = nil) { value = apiKey }
    public func apiKey() -> String? { lock.withLock { value } }
    public func setAPIKey(_ value: String) { lock.withLock { self.value = value } }
    public func removeAPIKey() { lock.withLock { value = nil } }
}

public enum FeatherlessTransportError: Error, Equatable, Sendable {
    case timeout
    case networkUnavailable
}

public struct FeatherlessHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public init(data: Data, statusCode: Int) { self.data = data; self.statusCode = statusCode }
}

public protocol FeatherlessHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> FeatherlessHTTPResponse
}

public struct URLSessionFeatherlessHTTPTransport: FeatherlessHTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> FeatherlessHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw FeatherlessTransportError.networkUnavailable }
            return FeatherlessHTTPResponse(data: data, statusCode: response.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            throw FeatherlessTransportError.timeout
        } catch let error as FeatherlessTransportError {
            throw error
        } catch {
            throw FeatherlessTransportError.networkUnavailable
        }
    }
}
