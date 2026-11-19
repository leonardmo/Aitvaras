import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

let autoContinueTestDate = Date(timeIntervalSince1970: 2_000_000_000)

func autoContinueIntent(_ stores: Stores, provider: AgentProvider = .codex, reset: Date? = autoContinueTestDate) throws -> AgentAutoContinue {
    var session = try agentStoreChat(stores, provider: provider).1
    session.sessionID = .init(provider: provider, profile: "default", nativeID: "NATIVE_CANARY-" + session.id.uuidString)
    try stores.saveAgentSession(session)
    let input = AgentInput(text: "PRIVATE_PROMPT_CANARY")
    try stores.prepareAgentTurn(.init(input: input, chatID: session.chatID, sessionID: session.id))
    try stores.finishAgentTurn(id: input.id, state: .failed)
    return try AgentAutoContinueStore(db: stores.db).schedule(.init(chatID: session.chatID, failedInputID: input.id,
        sessionID: session.id, native: try #require(session.sessionID),
        scope: .init(provider: provider, accountID: "ACCOUNT_CANARY"), createdAt: autoContinueTestDate, inputRevision: 0,
        resetsAt: reset, resetSource: reset == nil ? .fallback : .request, nextCheckAt: reset ?? autoContinueTestDate))
}

actor AutoContinueGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

func autoWait(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        await Task.yield()
    }
    Issue.record("Expected asynchronous state did not settle")
    throw AgentFailure.invalidTransition
}

actor AutoContinueBackend: AgentBackend {
    var authentication: AgentStatus.Authentication = .subscription
    var accountID: String? = "ACCOUNT_CANARY"
    var windows: [AgentRateLimitWindow] = []
    var history: [AgentEvent]?
    var startGate: AutoContinueGate?
    var pollGate: AutoContinueGate?
    var sendGate: AutoContinueGate?
    var failure: AgentFailure?
    private(set) var configurations: [AgentSessionConfiguration] = []
    private(set) var runs: [AutoContinueRun] = []
    private(set) var reads = 0
    func setAccount(_ value: String?) { accountID = value }
    func setAuthentication(_ value: AgentStatus.Authentication) { authentication = value }
    func setWindows(_ value: [AgentRateLimitWindow]) { windows = value }
    func setHistory(_ value: [AgentEvent]?) { history = value }
    func setStartGate(_ gate: AutoContinueGate?) { startGate = gate }
    func setPollGate(_ gate: AutoContinueGate?) { pollGate = gate }
    func setSendGate(_ gate: AutoContinueGate?) { sendGate = gate }
    func setFailure(_ value: AgentFailure?) { failure = value }
    func status() -> AgentStatus { .init(installed: true, authentication: authentication, capabilities: [], accountID: accountID) }
    func rateLimits() async -> [AgentRateLimitWindow] { reads += 1; if let pollGate { await pollGate.wait() }; return windows }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun {
        configurations.append(configuration)
        if let startGate { await startGate.wait() }
        if let failure { throw failure }
        let run = AutoContinueRun(session: configuration.resume ?? .init(provider: .codex, profile: "default", nativeID: "fixture-" + UUID().uuidString), gate: sendGate)
        runs.append(run)
        await run.emit(.sessionStarted(run.session))
        return run
    }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> {
        guard let history else { throw AgentFailure.unsupported }
        return .init(items: history, completedItemIDs: Set(history.compactMap { if case .message(let id, _, _) = $0.kind { id } else { nil } }))
    }
}

actor AutoContinueRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let accountID: String? = "ACCOUNT_CANARY"
    nonisolated let session: AgentSessionID
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let gate: AutoContinueGate?
    private var inputID: UUID?
    private(set) var inputs: [AgentInput] = []
    private(set) var responses: [AgentResponse] = []
    init(session: AgentSessionID, gate: AutoContinueGate? = nil) {
        self.session = session; self.gate = gate
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        if let gate { await gate.wait() }
        try await willDeliver()
        inputID = input.id; inputs.append(input)
        emit(.delivery(.acknowledged))
    }
    func emit(_ kind: AgentEvent.Kind, input: UUID? = nil, turn: String? = nil) {
        continuation.yield(.init(scope: .init(runID: id, session: session, inputID: input ?? inputID, turnID: turn), kind: kind))
    }
    func respond(to request: AgentRequest, with response: AgentResponse) { responses.append(response) }
    func setMode(_ mode: AgentMode) {}
    func interrupt() { emit(.turnEnded(.interrupted)) }
    func shutdown() { continuation.finish() }
}
