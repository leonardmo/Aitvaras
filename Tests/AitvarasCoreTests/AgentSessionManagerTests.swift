import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite struct AgentSessionManagerTests {
    @Test func twoExecutableChatsDetachStopAndCap() async throws {
        let fixture = try BackendExecutableFixture(script: managerClaudeScript)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let chats = try (0..<4).map { _ in try agentStoreChat(stores, cwd: fixture.directory.path).0.id }
        // Merely attaching/detaching views must not create or dispose a process.
        let view = Task {
            for await _ in try await manager.updates(chatID: chats[0]) { if Task.isCancelled { break } }
        }
        let first = AgentInput(text: "hold")
        let second = AgentInput(text: "hold")
        async let one: Void = manager.send(chatID: chats[0], provider: .claude, input: first)
        async let two: Void = manager.send(chatID: chats[1], provider: .claude, input: second)
        _ = try await (one, two)
        try await waitManager {
            let one = try await manager.state(chatID: chats[0])
            let two = try await manager.state(chatID: chats[1])
            return one.streamingText == "partial" && two.streamingText == "partial"
        }
        view.cancel()
        #expect(try await manager.state(chatID: chats[0]).isRunning)
        #expect(try await manager.state(chatID: chats[0]).pendingCards.isEmpty)
        try await manager.stop(chatID: chats[0])
        try await waitManager { try await manager.state(chatID: chats[0]).outcome == .interrupted }
        #expect(try await manager.state(chatID: chats[1]).isRunning)
        #expect(try stores.agentTurn(id: second.id)?.state == .running)
        try await manager.send(chatID: chats[2], provider: .claude, input: .init(text: "hold"))
        await #expect(throws: AgentSessionManagerError.runningChatLimit) {
            try await manager.send(chatID: chats[3], provider: .claude, input: .init(text: "hold"))
        }
        #expect(try await manager.state(chatID: chats[3]).outcome == .failed(.invalidTransition))
        let sessionOne = try #require(try stores.agentSession(chatID: chats[0], provider: .claude)?.sessionID)
        let sessionTwo = try #require(try stores.agentSession(chatID: chats[1], provider: .claude)?.sessionID)
        #expect(sessionOne != sessionTwo)
        try await manager.shutdown()
        #expect(try stores.agentTurn(id: second.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: second.id)?.partialOutput == "partial")
    }

    @Test func idleExecutableResumesAndCancelledQuitCanSendAgain() async throws {
        let fixture = try BackendExecutableFixture(script: managerClaudeScript)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores, cwd: fixture.directory.path).0.id
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let starts = ManagerStartCounter(backend: backend)
        let manager = try AgentSessionManager(persistence: stores, idleTimeout: .milliseconds(40), backend: { _ in starts }, audit: { _ = try stores.record($0) })
        #expect(await starts.count == 0)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "finish"))
        try await waitManager { try await manager.state(chatID: chat).outcome == .completed }
        let native = try #require(try stores.agentSession(chatID: chat, provider: .claude)?.sessionID)
        try await Task.sleep(for: .milliseconds(160))
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "finish"))
        try await waitManager { try await manager.state(chatID: chat).outcome == .completed }
        #expect(await starts.count == 2)
        #expect(try stores.agentSession(chatID: chat, provider: .claude)?.sessionID == native)
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "assistant" }.count == 2)
        try await manager.shutdown(timeout: .milliseconds(100))
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "finish"))
        try await waitManager { try await manager.state(chatID: chat).outcome == .completed }
        #expect(await starts.count == 3)
        try await manager.shutdown()
    }

    @Test func deliveryFailureBeforeAndAfterBarrierAndOneExplicitRetry() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        await backend.setFailure(.before)
        let prepared = AgentInput(text: "before barrier")
        await #expect(throws: AgentFailure.offline) { try await manager.send(chatID: chat, provider: .claude, input: prepared) }
        #expect(try stores.agentTurn(id: prepared.id)?.delivery == .prepared)
        await backend.setFailure(.after)
        await #expect(throws: AgentFailure.offline) { try await manager.resendPrepared(turnID: prepared.id) }
        #expect(try stores.agentTurn(id: prepared.id)?.delivery == .deliveryUnknown)
        #expect(try stores.agentTurn(id: prepared.id)?.resendCount == 1)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.resendPrepared(turnID: prepared.id) }
        let after = AgentInput(text: "after barrier")
        await #expect(throws: AgentFailure.offline) { try await manager.send(chatID: chat, provider: .claude, input: after) }
        #expect(try stores.agentTurn(id: after.id)?.delivery == .deliveryUnknown)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.resendPrepared(turnID: after.id) }
        await backend.setFailure(.none)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "new input"))
        try await manager.shutdown()
    }

    @Test func journalBarrierFailurePreventsWriteAndDuplicateInputDoesNotDisturbLiveTurn() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        // An SQL trigger simulates a failed durable barrier rather than a pipe failure.
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER testBarrierFailure BEFORE UPDATE OF delivery ON agentTurn WHEN NEW.delivery IS NOT OLD.delivery BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "must not leave")
        await #expect(throws: (any Error).self) { try await manager.send(chatID: chat, provider: .claude, input: input) }
        #expect(await backend.totalWrites() == 0)
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testBarrierFailure") }
        try await manager.resendPrepared(turnID: input.id)
        await #expect(throws: AgentSessionManagerError.chatBusy) { try await manager.send(chatID: chat, provider: .claude, input: input) }
        #expect(try stores.agentTurn(id: input.id)?.state == .running)
        try await manager.shutdown()
    }

    @Test func restartMarksRunningInterruptedWithoutStartingBackend() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "interrupted input")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        try stores.saveAgentPartial(id: input.id, text: "kept")
        _ = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "kept", sessionID: session.id))
        let backend = ManagerTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(try stores.agentTurn(id: input.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: input.id)?.delivery == .deliveryUnknown)
        #expect(try await manager.state(chatID: chat.id).entries.first?.text == "kept")
        #expect(await backend.runs.isEmpty)
        #expect(try await manager.state(chatID: chat.id).outcome == .interrupted)
        try await manager.shutdown()
    }

    @Test func staleCallbacksCannotEndNewInputOrPolluteTranscript() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let first = AgentInput(text: "first")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        let old = try #require(await backend.runs.first)
        await old.emit(.turnEnded(.completed), input: first.id)
        try await waitManager { try await manager.state(chatID: chat).outcome == .completed }
        let next = AgentInput(text: "next")
        try await manager.send(chatID: chat, provider: .claude, input: next)
        await old.emit(.textDelta("stale text"), input: first.id)
        await old.emit(.turnEnded(.completed), input: first.id)
        // Wrong generations are ignored by the coordinator too.
        await old.emit(.textDelta("wrong generation"), input: next.id, run: UUID())
        await old.emit(.textDelta("current"), input: next.id)
        try await waitManager { try await manager.state(chatID: chat).streamingText == "current" }
        #expect(try stores.agentTurn(id: next.id)?.state == .running)
        try await manager.shutdown()
        await old.emit(.textDelta("after shutdown"), input: next.id)
        #expect(try await manager.state(chatID: chat).streamingText == "current")
    }

    @Test func boundedShutdownRecoversEvenWhenRunIgnoresCancellation() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        await backend.setHungShutdown(true)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "first"))
        let clock = ContinuousClock(); let began = clock.now
        try await manager.shutdown(timeout: .milliseconds(30))
        #expect(clock.now - began < .seconds(1))
        await backend.setHungShutdown(false)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "after cancelled quit"))
        #expect(try await manager.state(chatID: chat).isRunning)
        for run in await backend.runs { await run.releaseShutdown() }
        try await manager.shutdown()
    }

    @Test func stopDuringStartupRejectsLateRunWithoutTouchingReplacement() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        await backend.pauseNextStart()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let first = AgentInput(text: "stop before startup finishes")
        let task = Task { try await manager.send(chatID: chat, provider: .claude, input: first) }
        try await waitManager { await backend.isStarting }
        try await manager.stop(chatID: chat)
        let second = AgentInput(text: "replacement")
        try await manager.send(chatID: chat, provider: .claude, input: second)
        await backend.releaseStart()
        await #expect(throws: AgentSessionManagerError.staleRun) { try await task.value }
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: first.id)?.delivery == .prepared)
        #expect(try stores.agentTurn(id: second.id)?.state == .running)
        #expect(await backend.totalWrites() == 1)
        try await manager.shutdown()
    }

    @Test func cardsComeFromPendingCoordinatorRequestsAndExpire() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = ManagerTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "hooks and approvals")
        try await manager.send(chatID: chat, provider: .claude, input: input)
        let run = try #require(await backend.runs.first)
        let scope = AgentEventScope(runID: run.id, inputID: input.id)
        let hook = AgentRequest(id: .integer(1), scope: scope, kind: .preToolUse(.init(name: "Read", input: .null)))
        await run.emit(.request(hook), input: input.id)
        try await waitManager { await run.responses.count == 1 }
        #expect(try await manager.state(chatID: chat).pendingCards.isEmpty)
        let permission = AgentRequest(id: .integer(2), scope: scope, kind: .permission(.init(name: "Read", input: .null)))
        await run.emit(.request(permission), input: input.id)
        try await waitManager { try await manager.state(chatID: chat).pendingCards == [permission] }
        try await manager.respond(chatID: chat, to: permission, with: .deny)
        #expect(try await manager.state(chatID: chat).pendingCards.isEmpty)
        await #expect(throws: AgentFailure.invalidRequest) { try await manager.respond(chatID: chat, to: permission, with: .deny) }
        await run.emit(.turnEnded(.completed), input: input.id)
        try await waitManager { try await manager.state(chatID: chat).outcome == .completed }
        try await manager.shutdown()
    }

    @Test func reducerStableMessagesToolsHooksUsageAndOutcome() {
        let chat = UUID(); let input = AgentInput(text: "test")
        let session = AgentChatSession(chatID: chat, provider: .claude, cwd: "/tmp", model: "test")
        var state = ChatState(chatID: chat)
        let assistant = UUID()
        state.begin(input, session: session, outputID: assistant)
        let scope = AgentEventScope(runID: UUID(), inputID: input.id, itemID: "item")
        func event(_ kind: AgentEvent.Kind) -> AgentEvent { .init(scope: scope, kind: kind) }
        state.reduce(event(.textDelta("partial")), newEntryID: UUID())
        state.reduce(event(.thinkingDelta("reasoning")), newEntryID: UUID())
        state.reduce(event(.toolStarted(.init(name: "Read", input: .null))), newEntryID: UUID())
        state.reduce(event(.toolFinished(output: .string("read"), isError: false)), newEntryID: UUID())
        state.reduce(event(.message(id: "native", role: "assistant", text: "complete")), newEntryID: UUID())
        state.reduce(event(.message(id: "native", role: "assistant", text: "complete")), newEntryID: UUID())
        state.reduce(event(.request(.init(id: .integer(1), scope: scope, kind: .preToolUse(.init(name: "Read", input: .null))))), newEntryID: UUID())
        state.reduce(event(.usage(.init(scope: .turn, outputTokens: 5))), newEntryID: UUID())
        state.reduce(event(.rateLimits([.init(id: "window", utilization: 0.5)])), newEntryID: UUID())
        state.reduce(event(.turnEnded(.completed)), newEntryID: UUID())
        #expect(state.entries.filter { $0.kind == "assistant" }.count == 1)
        #expect(state.entries.first { $0.id == assistant }?.text == "complete")
        #expect(state.thinking == "reasoning")
        #expect(state.tools.first?.isFinished == true)
        #expect(state.pendingCards.isEmpty)
        #expect(state.usage?.outputTokens == 5)
        #expect(state.rateLimits.first?.utilization == 0.5)
        #expect(state.outcome == .completed)
    }
}

private func waitManager(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}

private let managerClaudeScript = #"""
claude_init()
session = sys.argv[sys.argv.index('--resume')+1] if '--resume' in sys.argv else 'fixture-'+str(os.getpid())
counter=0
while True:
    request=read()
    if request.get('type')=='control_request':
        assert request['request']['subtype']=='interrupt'
        emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
        emit({'type':'result','is_error':True,'subtype':'error_during_execution'})
        continue
    assert request['type']=='user'
    counter+=1
    emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':session})
    emit({'type':'stream_event','event':{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'partial'}}})
    if request['message']['content']=='finish':
        emit({'type':'assistant','uuid':'message-'+str(os.getpid())+'-'+str(counter),'message':{'role':'assistant','content':[{'type':'text','text':'complete'}]}})
        emit({'type':'result','is_error':False,'subtype':'success'})
"""#

private actor ManagerStartCounter: AgentBackend {
    let backend: any AgentBackend
    private(set) var count = 0
    init(backend: any AgentBackend) { self.backend = backend }
    func status() async throws -> AgentStatus { try await backend.status() }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws { try await backend.signIn(onBrowserURL: onBrowserURL) }
    func models() async throws -> [AgentModel] { try await backend.models() }
    func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun { count += 1; return try await backend.start(configuration) }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}

private actor ManagerTestBackend: AgentBackend {
    enum Failure: Sendable { case none, before, after }
    private var failure: Failure = .none
    private var hungShutdown = false
    private var pauseStart = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    var isStarting: Bool { startWaiter != nil }
    func pauseNextStart() { pauseStart = true }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
    private(set) var runs: [ManagerTestRun] = []
    func setFailure(_ failure: Failure) { self.failure = failure }
    func setHungShutdown(_ value: Bool) { hungShutdown = value }
    func totalWrites() async -> Int { var count = 0; for run in runs { count += await run.writes }; return count }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: []) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) async -> any AgentRun {
        if pauseStart {
            pauseStart = false
            await withCheckedContinuation { startWaiter = $0 }
        }
        let run = ManagerTestRun(failure: failure, hungShutdown: hungShutdown); runs.append(run); return run
    }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
private actor ManagerTestRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let failure: ManagerTestBackend.Failure
    private let hungShutdown: Bool
    private var shutdownWaiter: CheckedContinuation<Void, Never>?
    private(set) var writes = 0
    private(set) var responses: [AgentResponse] = []
    init(failure: ManagerTestBackend.Failure, hungShutdown: Bool) {
        self.failure = failure; self.hungShutdown = hungShutdown
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        if failure == .before { throw AgentFailure.offline }
        try await willDeliver()
        writes += 1
        if failure == .after { throw AgentFailure.offline }
    }
    func respond(to request: AgentRequest, with response: AgentResponse) { responses.append(response) }
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() async {
        if hungShutdown { await withCheckedContinuation { shutdownWaiter = $0 } }
        continuation.finish()
    }
    func releaseShutdown() { shutdownWaiter?.resume(); shutdownWaiter = nil }
    func emit(_ kind: AgentEvent.Kind, input: UUID, run: UUID? = nil) {
        continuation.yield(.init(scope: .init(runID: run ?? id, inputID: input), kind: kind))
    }
}
