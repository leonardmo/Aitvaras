import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

let autoContinueTestDate = Date(timeIntervalSince1970: 2_000_000_000)

func configureAutoContinueProvider(_ stores: Stores, provider: AgentProvider = .codex) throws {
    guard try stores.providerProfile(.init(provider: provider)) == nil else { return }
    let root = FileManager.default.temporaryDirectory
    try stores.createProviderProfile(kind: provider, name: provider.rawValue.capitalized,
        stateDirectory: root, claudeDefaultDirectory: root, useExistingCLI: true)
}

func autoContinueIntent(_ stores: Stores, provider: AgentProvider = .codex, reset: Date? = autoContinueTestDate,
                        profile: String = "default") throws -> AgentAutoContinue {
    if profile == "default" { try configureAutoContinueProvider(stores, provider: provider) }
    var session = try agentStoreChat(stores, provider: provider).1
    if profile != "default" {
        session = AgentChatSession(chatID: session.chatID, provider: provider, cwd: session.cwd, model: session.model, providerProfile: profile)
    }
    session.sessionID = .init(provider: provider, profile: profile, nativeID: "NATIVE_CANARY-" + session.id.uuidString)
    try stores.saveAgentSession(session)
    let input = AgentInput(text: "PRIVATE_PROMPT_CANARY")
    try stores.prepareAgentTurn(.init(input: input, chatID: session.chatID, sessionID: session.id))
    try stores.finishAgentTurn(id: input.id, state: .failed)
    return try AgentAutoContinueStore(db: stores.db).schedule(.init(chatID: session.chatID, failedInputID: input.id,
        sessionID: session.id, native: try #require(session.sessionID),
        scope: .init(provider: provider, providerProfile: profile, accountID: "ACCOUNT_CANARY"), createdAt: autoContinueTestDate, inputRevision: 0,
        resetsAt: reset, resetSource: reset == nil ? .fallback : .request, nextCheckAt: reset ?? autoContinueTestDate))
}

actor AutoContinueGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

func autoWait(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Expected asynchronous state did not settle")
    throw AgentFailure.invalidTransition
}

actor AutoContinueBackend: AgentBackend {
    var authentication: AgentStatus.Authentication = .subscription
    var accountID: String? = "ACCOUNT_CANARY"
    var windows: [AgentRateLimitWindow] = []
    var history: [AgentEvent]?
    var statusGate: AutoContinueGate?
    var startGate: AutoContinueGate?
    var pollGate: AutoContinueGate?
    var sendGate: AutoContinueGate?
    var failure: AgentFailure?
    var sendFailure: AgentFailure?
    private(set) var configurations: [AgentSessionConfiguration] = []
    private(set) var runs: [AutoContinueRun] = []
    private(set) var reads = 0
    func setAccount(_ value: String?) { accountID = value }
    func setAuthentication(_ value: AgentStatus.Authentication) { authentication = value }
    func setWindows(_ value: [AgentRateLimitWindow]) { windows = value }
    func setHistory(_ value: [AgentEvent]?) { history = value }
    func setStatusGate(_ gate: AutoContinueGate?) { statusGate = gate }
    func setStartGate(_ gate: AutoContinueGate?) { startGate = gate }
    func setPollGate(_ gate: AutoContinueGate?) { pollGate = gate }
    func setSendGate(_ gate: AutoContinueGate?) { sendGate = gate }
    func setFailure(_ value: AgentFailure?) { failure = value }
    func setSendFailure(_ value: AgentFailure?) { sendFailure = value }
    func status() async -> AgentStatus {
        let result = AgentStatus(installed: true, authentication: authentication, capabilities: [], accountID: accountID)
        if let statusGate { await statusGate.wait() }
        return result
    }
    func rateLimits() async -> [AgentRateLimitWindow] { reads += 1; if let pollGate { await pollGate.wait() }; return windows }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun {
        configurations.append(configuration)
        if let startGate { await startGate.wait() }
        if let failure { throw failure }
        let run = AutoContinueRun(session: configuration.resume ?? .init(provider: .codex, profile: "default", nativeID: "fixture-" + UUID().uuidString),
                                  gate: sendGate, accountID: accountID, sendFailure: sendFailure)
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
    nonisolated let accountID: String?
    nonisolated let session: AgentSessionID
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let gate: AutoContinueGate?
    private let sendFailure: AgentFailure?
    private var inputID: UUID?
    private(set) var inputs: [AgentInput] = []
    private(set) var responses: [AgentResponse] = []
    init(session: AgentSessionID, gate: AutoContinueGate? = nil, accountID: String? = "ACCOUNT_CANARY",
         sendFailure: AgentFailure? = nil) {
        self.session = session; self.gate = gate; self.accountID = accountID; self.sendFailure = sendFailure
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        if let gate { await gate.wait() }
        try await willDeliver()
        inputID = input.id; inputs.append(input)
        if let sendFailure { throw sendFailure }
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
