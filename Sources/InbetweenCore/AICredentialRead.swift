import Foundation

public struct AICredentialReadTimeoutError: LocalizedError, Sendable {
    public var errorDescription: String? { "Keychain did not respond within the allowed time." }
    public init() {}
}

/// Bounds the wait for synchronous credential providers such as Security.framework.
/// A late result is discarded and never exposed to the caller.
public func apiKeyWithTimeout(
    from store: any AICredentialStoring,
    timeout: TimeInterval = 8
) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
        let gate = AICredentialReadGate(continuation)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                gate.finish(.success(try store.apiKey()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        // The timer runs on the UI process's main queue, independently of any
        // worker threads blocked inside Security.framework.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            gate.finish(.failure(AICredentialReadTimeoutError()))
        }
    }
}

private final class AICredentialReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?

    init(_ continuation: CheckedContinuation<String?, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String?, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
