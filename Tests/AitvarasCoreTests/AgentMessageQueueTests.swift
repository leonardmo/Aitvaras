import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1)))
struct AgentMessageQueueTests {
    @Test func editHoldsItsPlaceAndReorderedMessagesSendOneAtATime() async throws {
        let (stores, session, manager, backend) = try fixture()
        let chat = session.chatID
        let active = AgentInput(text: "Active")
        let first = AgentInput(text: "First"), second = AgentInput(text: "Second"), removed = AgentInput(text: "Remove")
        try await manager.send(chatID: chat, provider: .codex, input: active)
        let run = try #require(await backend.runs.first)
        for input in [first, second, removed] {
            try await manager.enqueueMessage(chatID: chat, choice: session.choice, input: input)
            #expect(try stores.agentTurn(id: input.id) == nil)
        }
        try await manager.removeQueuedMessage(chatID: chat, messageID: removed.id)
        try await manager.moveQueuedMessage(chatID: chat, messageID: second.id, to: first.id)
        _ = try await manager.beginQueuedEdit(chatID: chat, messageID: second.id)
        await run.finish(.completed)
        try await waitAgentCondition { try await !manager.state(chatID: chat).isRunning }
        #expect(try await manager.state(chatID: chat).messageQueue.messages.map(\.id) == [second.id, first.id])
        #expect(try stores.agentTurn(id: second.id) == nil)

        let attachment = try AgentAttachment(name: "notes.txt", data: Data("example".utf8))
        try await manager.endQueuedEdit(chatID: chat, messageID: second.id,
            replacement: AgentInput(id: second.id, text: "Edited", attachments: [attachment]))
        try await waitAgentCondition { try stores.agentTurn(id: second.id)?.delivery == .acknowledged }
        #expect(try stores.agentTurn(id: first.id) == nil)
        let editedRow = try #require(try stores.agentEntries(chatID: chat).first { $0.id == second.id })
        let restored = try AgentInput.restoring(id: editedRow.id, text: editedRow.text, payload: editedRow.payloadJSON)
        #expect(restored.text == "Edited")
        #expect(restored.attachments == [attachment])
        let editRun = try #require(await backend.runs.last)
        await editRun.finish(.completed)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "user" }.map(\.id) == [active.id, second.id, first.id])
        try await manager.shutdown()
    }

    @Test func failurePausesAndRestartRecoversUnsentMessageAndDropsJournaledClaim() async throws {
        let (stores, session, manager, backend) = try fixture()
        let chat = session.chatID
        let active = AgentInput(text: "Active"), queued = AgentInput(text: "Queued")
        try await manager.send(chatID: chat, provider: .codex, input: active)
        try await manager.enqueueMessage(chatID: chat, choice: session.choice, input: queued)
        let run = try #require(await backend.runs.first)
        await run.finish(.failed(.offline))
        try await waitAgentCondition { try await manager.state(chatID: chat).messageQueue.pause == .failed }
        #expect(try stores.agentTurn(id: queued.id) == nil)
        _ = try await manager.beginQueuedEdit(chatID: chat, messageID: queued.id)
        try await manager.shutdown()

        let restarted = try makeManager(stores, backend: backend)
        let restored = try await restarted.state(chatID: chat).messageQueue
        #expect(restored.messages.map(\.id) == [queued.id])
        #expect(restored.pause == .restarted)
        #expect(restored.editingID == nil)
        try await restarted.resumeMessageQueue(chatID: chat)
        try await waitAgentCondition { try stores.agentTurn(id: queued.id)?.delivery == .acknowledged }
        try await restarted.shutdown()

        var interruptedWrite = AgentMessageQueue()
        interruptedWrite.messages = [.init(input: queued, session: session)]
        interruptedWrite.dispatchingID = queued.id
        try stores.saveMessageQueue(interruptedWrite, chatID: chat)
        let reconciled = try makeManager(stores, backend: backend)
        #expect(try await reconciled.state(chatID: chat).messageQueue.messages.isEmpty)
        try await reconciled.shutdown()
    }

    @Test func aQueuedEditSavedDuringPassiveHistoryRefreshDispatchesAfterRefresh() async throws {
        let (stores, session, manager, backend) = try fixture()
        let chat = session.chatID
        let active = AgentInput(text: "Active"), queued = AgentInput(text: "Queued")
        try await manager.send(chatID: chat, provider: .codex, input: active)
        try await manager.enqueueMessage(chatID: chat, choice: session.choice, input: queued)
        _ = try await manager.beginQueuedEdit(chatID: chat, messageID: queued.id)
        let run = try #require(await backend.runs.first)
        await run.finish(.completed)
        try await waitAgentCondition { try await !manager.state(chatID: chat).isRunning }
        let gate = AutoContinueGate()
        await backend.pauseNextHistoryRead(gate)
        let refresh = Task { try await manager.refreshNativeHistory(chatID: chat) }
        await gate.waitUntilEntered()
        try await manager.endQueuedEdit(chatID: chat, messageID: queued.id, replacement: nil)
        #expect(try stores.agentTurn(id: queued.id) == nil)
        await gate.release()
        _ = await refresh.result
        try await waitAgentCondition { try stores.agentTurn(id: queued.id)?.delivery == .acknowledged }
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.codex, .claude, .local])
    func sendNowSteersOrStopsLocal(provider: AgentProvider) async throws {
        let (stores, session, manager, _) = try fixture(provider: provider)
        let chat = session.chatID
        let active = AgentInput(text: "Active"), queued = AgentInput(text: "Send now")
        try await manager.send(chatID: chat, provider: provider, input: active)
        try await manager.enqueueMessage(chatID: chat, choice: session.choice, input: queued)
        try await manager.sendQueuedMessageNow(chatID: chat, messageID: queued.id)
        try await waitAgentCondition { try await manager.state(chatID: chat).messageQueue.messages.isEmpty }
        let journal = try #require(try stores.agentTurn(id: queued.id))
        if provider == .local {
            #expect(journal.parentInputID == nil)
            #expect(try stores.agentTurn(id: active.id)?.state == .interrupted)
        } else {
            #expect(journal.parentInputID == active.id)
            #expect(try stores.agentTurn(id: active.id)?.state == .running)
        }
        try await manager.shutdown()
    }

    private func fixture(provider: AgentProvider = .codex) throws -> (Stores, AgentChatSession, AgentSessionManager, QueueBackend) {
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores, provider: provider)
        let backend = QueueBackend(provider: provider)
        return (stores, session, try makeManager(stores, backend: backend), backend)
    }

    private func makeManager(_ stores: Stores, backend: QueueBackend) throws -> AgentSessionManager {
        try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
    }
}

private actor QueueBackend: AgentBackend {
    let provider: AgentProvider
    private var historyGate: AutoContinueGate?
    private(set) var runs: [QueueRun] = []
    init(provider: AgentProvider) { self.provider = provider }
    func status() -> AgentStatus {
        .init(installed: true, authentication: provider == .local ? .local : .subscription, capabilities: [.followups])
    }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) async -> any AgentRun {
        let session = configuration.resume ?? .init(provider: provider, profile: "default", nativeID: UUID().uuidString)
        let run = QueueRun(session: session)
        runs.append(run)
        await run.emit(.sessionStarted(session))
        return run
    }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func pauseNextHistoryRead(_ gate: AutoContinueGate) { historyGate = gate }
    func readHistory(session: AgentSessionID, cursor: String?) async throws -> AgentPage<AgentEvent> {
        let gate = historyGate
        historyGate = nil
        if let gate { await gate.wait() }
        throw AgentFailure.unsupported
    }
}

private actor QueueRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let session: AgentSessionID
    private var active: UUID?
    init(session: AgentSessionID) {
        self.session = session
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver()
        active = input.id
        emit(.delivery(.acknowledged))
    }
    func followup(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver()
        if session.provider == .codex { emit(.delivery(.acknowledged), inputID: input.id) }
    }
    func emit(_ kind: AgentEvent.Kind, inputID: UUID? = nil) {
        continuation.yield(.init(scope: .init(runID: id, session: session, inputID: inputID ?? active), kind: kind))
    }
    func finish(_ outcome: AgentTurnOutcome) { emit(.turnEnded(outcome)); active = nil }
    func interrupt() { finish(.interrupted) }
    func respond(to request: AgentRequest, with response: AgentResponse) {}
    func setMode(_ mode: AgentMode) {}
    func shutdown() { continuation.finish() }
}
