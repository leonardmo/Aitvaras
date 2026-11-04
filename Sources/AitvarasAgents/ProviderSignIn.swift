import Foundation

public enum ProviderSignInError: Error, Sendable { case invalidURL, timedOut, staleIntent }

/// Serializes durable intent consumption. The manager independently claims the
/// journal retry, so duplicate completion and a crash cannot replay an input.
public actor ProviderSignIn {
    private let persistence: any PendingSendPersistence
    public init(persistence: any PendingSendPersistence) { self.persistence = persistence }

    public func prepare(_ pending: PendingSend) throws { try persistence.savePendingSend(pending) }
    public func cancel() throws { try persistence.savePendingSend(nil) }
    public func signIn(backend: any AgentBackend, timeout: Duration = .seconds(300),
                       onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        let intent = try persistence.pendingSend()?.inputID
        do { try await Self.run(backend: backend, timeout: timeout, onBrowserURL: onBrowserURL) }
        catch {
            if let intent, try persistence.pendingSend()?.inputID == intent {
                try persistence.savePendingSend(nil)
            }
            throw error
        }
    }
    public func consume(inputID: UUID, turn: AgentJournalTurn, session: AgentChatSession,
                        accountID: String? = nil, now: Date = .now) throws -> PendingSend {
        guard let pending = try persistence.pendingSend(), pending.inputID == inputID else {
            throw ProviderSignInError.staleIntent
        }
        // Clear even on drift/expiry, preserving text in the composer's draft.
        try persistence.savePendingSend(nil)
        guard pending.permitsRetry(turn: turn, session: session, accountID: accountID, now: now) else {
            throw ProviderSignInError.staleIntent
        }
        return pending
    }

    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              !host.contains(where: { $0.isWhitespace }) else { throw ProviderSignInError.invalidURL }
    }

    /// Backends own login completion. Only transient, validated browser URLs
    /// cross into the app. Cancellation propagates to the CLI login task.
    public static func run(backend: any AgentBackend, timeout: Duration = .seconds(300),
                           onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let urls = SignInURLs()
                try await backend.signIn { url in
                    if await urls.accept(url) { await onBrowserURL(url) }
                }
                guard await urls.hasValidURL else { throw ProviderSignInError.invalidURL }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProviderSignInError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private actor SignInURLs {
    private(set) var hasValidURL = false
    func accept(_ url: URL) -> Bool {
        guard !hasValidURL, (try? ProviderSignIn.validate(url)) != nil else { return false }
        hasValidURL = true
        return true
    }
}
