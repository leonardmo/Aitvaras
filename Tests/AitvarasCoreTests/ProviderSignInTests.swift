import Foundation
import Testing
import AitvarasAgents
import AitvarasStore

@Suite struct ProviderSignInTests {
    @Test func validatesBrowserURLs() throws {
        try ProviderSignIn.validate(URL(string: "https://example.invalid/login?code=transient")!)
        for value in ["http://example.invalid/login", "file:///tmp/login", "javascript:alert(1)", "https://user:password@example.invalid/login", "https://example.invalid:8080/login"] {
            #expect(throws: ProviderSignInError.invalidURL) { try ProviderSignIn.validate(URL(string: value)!) }
        }
    }

    @Test func durableIntentIsBoundedExpiresAndOnlyConsumesOnce() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "Waiting message")
        var turn = AgentJournalTurn(input: input, chatID: chat.id, sessionID: session.id)
        try stores.prepareAgentTurn(turn)
        try stores.finishAgentTurn(id: input.id, state: .failed)
        turn = try #require(try stores.agentTurn(id: input.id))
        let now = Date()
        let pending = try PendingSend(inputID: input.id, text: input.text, session: session, now: now)
        try stores.savePendingSend(pending)
        let coordinator = ProviderSignIn(persistence: stores)
        #expect(try stores.pendingSend() == pending)
        #expect(!pending.permitsRetry(turn: turn, session: session, now: now.addingTimeInterval(301)))
        #expect(throws: AgentFailure.invalidRequest) {
            try PendingSend(inputID: input.id, text: String(repeating: "é", count: PendingSend.maximumBytes), session: session)
        }
        let consumed = try await coordinator.consume(inputID: input.id, turn: turn, session: session)
        #expect(consumed == pending)
        #expect(try stores.pendingSend() == nil)
        await #expect(throws: ProviderSignInError.staleIntent) {
            try await coordinator.consume(inputID: input.id, turn: turn, session: session)
        }
    }

    @Test func driftAndUncertainOrAlreadyRetriedTurnsCannotReplay() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "Kept in composer")
        var turn = AgentJournalTurn(input: input, chatID: chat.id, sessionID: session.id)
        turn.state = .failed
        let pending = try PendingSend(inputID: input.id, text: input.text, session: session)
        for delivery in [AgentDeliveryState.deliveryUnknown, .acknowledged] {
            turn.delivery = delivery
            #expect(!pending.permitsRetry(turn: turn, session: session))
        }
        turn.delivery = .prepared; turn.resendCount = 1
        #expect(!pending.permitsRetry(turn: turn, session: session))
        turn.resendCount = 0; turn.state = .running
        #expect(!pending.permitsRetry(turn: turn, session: session))
        turn.state = .failed
        var changed = session
        changed.chatID = UUID()
        #expect(!pending.permitsRetry(turn: turn, session: changed))
        changed = session; changed.provider = .codex
        #expect(!pending.permitsRetry(turn: turn, session: changed))
        changed = session; changed.model = "changed"
        #expect(!pending.permitsRetry(turn: turn, session: changed))
        changed = session; changed.sessionID = .init(provider: .claude, profile: "other-account-profile", nativeID: "other-session")
        let unknownAccount = try PendingSend(inputID: input.id, text: input.text, session: changed)
        #expect(!unknownAccount.permitsRetry(turn: turn, session: changed))
        try stores.savePendingSend(pending)
        let coordinator = ProviderSignIn(persistence: stores)
        await #expect(throws: ProviderSignInError.staleIntent) {
            try await coordinator.consume(inputID: input.id, turn: turn, session: changed)
        }
        #expect(try stores.pendingSend() == nil)
        #expect(pending.text == input.text)
    }

    @Test func accountDriftAndExpirationConsumeWithoutResending() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "Kept")
        var turn = AgentJournalTurn(input: input, chatID: chat.id, sessionID: session.id)
        turn.state = .failed
        let now = Date()
        let pending = try PendingSend(inputID: input.id, text: input.text, session: session, accountID: "test-account", now: now)
        #expect(!pending.permitsRetry(turn: turn, session: session, accountID: "other-account"))
        #expect(!pending.permitsRetry(turn: turn, session: session))
        let coordinator = ProviderSignIn(persistence: stores)
        try await coordinator.prepare(pending)
        await #expect(throws: ProviderSignInError.staleIntent) {
            try await coordinator.consume(inputID: input.id, turn: turn, session: session, accountID: "other-account")
        }
        #expect(try stores.pendingSend() == nil)
        try await coordinator.prepare(pending)
        await #expect(throws: ProviderSignInError.staleIntent) {
            try await coordinator.consume(inputID: input.id, turn: turn, session: session, accountID: "test-account", now: now.addingTimeInterval(301))
        }
        #expect(try stores.pendingSend() == nil)
    }

    @Test func authenticationFailureThenLoginResendsOriginalInputExactlyOnce() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let backend = SignInDeliveryBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "Waiting message")
        await #expect(throws: AgentFailure.authRequired) {
            try await manager.send(chatID: chat.id, provider: .claude, input: input)
        }
        let turn = try #require(try stores.agentTurn(id: input.id))
        #expect(turn.delivery == .prepared)
        let coordinator = ProviderSignIn(persistence: stores)
        let pending = try PendingSend(inputID: input.id, text: input.text, session: session)
        try await coordinator.prepare(pending)
        // Reopening the intent alone does not sign in or send.
        #expect(try stores.pendingSend() == pending)
        #expect(await backend.signIns == 0)
        try await ProviderSignIn.run(backend: backend) { _ in }
        _ = try await coordinator.consume(inputID: input.id, turn: turn, session: session)
        try await manager.resendPrepared(turnID: input.id)
        for _ in 0..<100 {
            if try await manager.state(chatID: chat.id).outcome == .completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await manager.state(chatID: chat.id).outcome == .completed)
        #expect(try stores.agentTurn(id: input.id)?.resendCount == 1)
        #expect(try stores.agentTurn(id: input.id)?.delivery == .acknowledged)
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "user" }.map(\.id) == [input.id])
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.resendPrepared(turnID: input.id) }
        #expect(await backend.run.sends == 1)
        try await manager.shutdown()
    }

    @Test func browserCompletionDeduplicatesURLsAndTimeoutAndCancelClearIntent() async throws {
        let backend = SignInBackend()
        let opened = SignInCounter()
        try await ProviderSignIn.run(backend: backend) { _ in await opened.increment() }
        #expect(await opened.value == 1)
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores)
        let pending = try PendingSend(inputID: UUID(), text: "Kept", session: session)
        let coordinator = ProviderSignIn(persistence: stores)
        try await coordinator.prepare(pending)
        await backend.setWaiting()
        await #expect(throws: ProviderSignInError.timedOut) {
            try await coordinator.signIn(backend: backend, timeout: .milliseconds(20)) { _ in }
        }
        #expect(await backend.cancelled)
        #expect(try stores.pendingSend() == nil)
        try await coordinator.prepare(pending)
        let task = Task { try await coordinator.signIn(backend: backend) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try stores.pendingSend() == nil)
        #expect(pending.text == "Kept")
    }

    @Test func oldLoginCancellationDoesNotClearANewerIntent() async throws {
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores)
        let coordinator = ProviderSignIn(persistence: stores)
        let first = try PendingSend(inputID: UUID(), text: "First", session: session)
        let next = try PendingSend(inputID: UUID(), text: "Next", session: session)
        try await coordinator.prepare(first)
        let backend = SignInBackend()
        await backend.setWaiting()
        let (urls, opened) = AsyncStream<URL>.makeStream()
        let login = Task { try await coordinator.signIn(backend: backend) { opened.yield($0) } }
        for await _ in urls { break }
        try await coordinator.prepare(next)
        login.cancel()
        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(try stores.pendingSend() == next)
    }

    @Test func failedPersistenceCannotAuthorizeRetry() async throws {
        let coordinator = ProviderSignIn(persistence: UnavailablePendingStore())
        let session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "test")
        let pending = try PendingSend(inputID: UUID(), text: "Kept", session: session)
        await #expect(throws: AgentFailure.unknown) { try await coordinator.prepare(pending) }
        var turn = AgentJournalTurn(input: .init(id: pending.inputID, text: pending.text), chatID: session.chatID, sessionID: session.id)
        turn.state = .failed
        let clearFailure = ProviderSignIn(persistence: UnclearablePendingStore(pending: pending))
        await #expect(throws: AgentFailure.unknown) {
            try await clearFailure.consume(inputID: pending.inputID, turn: turn, session: session)
        }
    }
}

private actor SignInCounter {
    var value = 0
    func increment() { value += 1 }
}
private struct UnavailablePendingStore: PendingSendPersistence {
    func pendingSend() throws -> PendingSend? { throw AgentFailure.unknown }
    func savePendingSend(_ pending: PendingSend?) throws { throw AgentFailure.unknown }
}
private actor SignInBackend: AgentBackend {
    var waiting = false
    var cancelled = false
    func setWaiting() { waiting = true }
    func status() -> AgentStatus { .init(installed: true, authentication: .signedOut, capabilities: []) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        let url = URL(string: "https://example.invalid/login")!
        await onBrowserURL(url); await onBrowserURL(url)
        if waiting {
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true; throw error }
        }
    }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun { throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}

private actor SignInDeliveryBackend: AgentBackend {
    let run = SignInDeliveryRun()
    var signIns = 0
    func status() -> AgentStatus { .init(installed: true, authentication: signIns == 0 ? .signedOut : .subscription, capabilities: []) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async {
        await onBrowserURL(URL(string: "https://example.invalid/login")!); signIns += 1
    }
    func models() -> [AgentModel] { [.init(id: "test", name: "Test")] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun {
        guard signIns > 0 else { throw AgentFailure.authRequired }; return run
    }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
private actor SignInDeliveryRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    var sends = 0
    init() {
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver(); sends += 1
        let scope = AgentEventScope(runID: id, inputID: input.id)
        continuation.yield(.init(scope: scope, kind: .delivery(.acknowledged)))
        continuation.yield(.init(scope: scope, kind: .textDelta("Reply")))
        continuation.yield(.init(scope: scope, kind: .turnEnded(.completed)))
    }
    func respond(to request: AgentRequest, with response: AgentResponse) throws { throw AgentFailure.unsupported }
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { continuation.finish() }
}

private struct UnclearablePendingStore: PendingSendPersistence {
    let pending: PendingSend
    func pendingSend() -> PendingSend? { pending }
    func savePendingSend(_ pending: PendingSend?) throws { throw AgentFailure.unknown }
}
