import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

struct AgentInterruptTests {
    @Test(arguments: [AgentProvider.claude, .codex], [false, true])
    func stopDuringOutputOrApprovalContinuesSameNativeSession(provider: AgentProvider, approval: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: interruptScript(provider: provider, approval: approval, failure: "none"))
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: provider)
        let first = AgentInput(text: "first")
        try await manager.send(chatID: chat, provider: provider, input: first)
        try await waitAgentCondition {
            let state = try await manager.state(chatID: chat)
            return approval ? !state.pendingCards.isEmpty : state.streamingText == "partial"
        }
        let native = try #require(try stores.agentSession(chatID: chat, provider: provider)?.sessionID)
        let card = try await manager.state(chatID: chat).pendingCards.first
        let began = ContinuousClock.now
        try await manager.stop(chatID: chat)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(try await manager.state(chatID: chat).outcome == .interrupted)
        #expect(try await manager.state(chatID: chat).pendingCards.isEmpty)
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        if let card {
            await #expect(throws: (any Error).self) { try await manager.respond(chatID: chat, to: card, with: .allow(updatedInput: nil)) }
        }
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat, provider: provider, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: chat, provider: provider)?.sessionID == native)
        #expect(try stores.agentTurn(id: first.id)?.partialOutput == (approval ? "" : "partial"))
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], ["noAck", "noResult"])
    func missingAcknowledgementOrResultForcesBoundedDisposalAndResume(provider: AgentProvider, failure: String) async throws {
        let fixture = try BackendExecutableFixture(script: interruptScript(provider: provider, approval: false, failure: failure))
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: provider)
        let first = AgentInput(text: "first")
        try await manager.send(chatID: chat, provider: provider, input: first)
        try await waitAgentCondition { try await manager.state(chatID: chat).streamingText == "partial" }
        let native = try #require(try stores.agentSession(chatID: chat, provider: provider)?.sessionID)
        let began = ContinuousClock.now
        try await manager.stop(chatID: chat)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(try await manager.state(chatID: chat).outcome == .interrupted)
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat, provider: provider, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: chat, provider: provider)?.sessionID == native)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func stopAfterFastCompletionRetiresAnUnacknowledgedSteer() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
if os.path.exists('steered'):
    r=read(); account(r)
    r=read(); assert r['method']=='thread/resume' and r['params']['threadId']=='thread-test'
    emit({'id':r['id'],'result':{'thread':{'id':'thread-test','modelProvider':'openai'}}})
    r=read(); assert r['method']=='turn/start' and r['params']['input'][0]['text']=='continue'
    emit({'id':r['id'],'result':{'turn':{'id':'next-turn'}}})
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'next-turn','status':'completed','items':[]}}})
    done()
start_thread()
r=read(); emit({'id':r['id'],'result':{'turn':{'id':'first-turn'}}})
r=read(); assert r['method']=='turn/steer'
open('steered','w').close()
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'first-turn','status':'completed','items':[]}}})
while True: read()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        try await manager.send(chatID: chat, provider: .codex, input: .init(text: "first"))
        let followup = AgentInput(text: "steer")
        let send = Task { try await manager.send(chatID: chat, provider: .codex, input: followup) }
        try await waitAgentCondition { try await manager.state(chatID: chat).outcome == .completed }
        let began = ContinuousClock.now
        try await manager.stop(chatID: chat)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(try stores.agentTurn(id: followup.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: followup.id)?.delivery == .deliveryUnknown)
        await #expect(throws: (any Error).self) { try await send.value }
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat, provider: .codex, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: chat, provider: .codex)?.nativeID == "thread-test")
        try await manager.shutdown()
    }

    @Test func stoppingClaudeAlsoRetiresQueuedInputsWithoutResending() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
if os.path.exists('stopped'):
    assert '--resume' in sys.argv and sys.argv[sys.argv.index('--resume')+1]=='queue-session'
    assert read()['message']['content']=='continue'
    emit({'type':'result','is_error':False})
    done()
assert read()['message']['content']=='first'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'queue-session'})
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
assert read()['message']['content']=='queued'
r=read(); assert r['request']['subtype']=='interrupt'
open('stopped','w').close()
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'still_queued':[]}}})
emit({'type':'result','terminal_reason':'aborted_streaming','is_error':True})
while True: read()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "first"))
        try await waitAgentCondition { try await manager.state(chatID: chat).streamingText == "partial" }
        let queued = AgentInput(text: "queued")
        try await manager.send(chatID: chat, provider: .claude, input: queued)
        let began = ContinuousClock.now
        try await manager.stop(chatID: chat)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(try stores.agentTurn(id: queued.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: queued.id)?.delivery == .deliveryUnknown)
        #expect(try stores.agentEntries(chatID: chat).first { $0.id == queued.id }?.payloadJSON?.contains("interrupted") == true)
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat, provider: .claude, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        try await manager.shutdown()
    }

    @Test func identityArrivingDuringStopIsRetainedForContinuation() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
r=read(); assert r['request']['subtype']=='interrupt'
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'late-session'})
emit({'type':'result','uuid':'stopped','terminal_reason':'aborted_streaming','is_error':True})
assert read()['message']['content']=='continue'
emit({'type':'result','uuid':'next','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "first"))
        try await waitAgentCondition { try await manager.state(chatID: chat).streamingText == "partial" }
        #expect(try stores.agentSession(chatID: chat, provider: .claude)?.sessionID == nil)
        try await manager.stop(chatID: chat)
        #expect(try stores.agentSession(chatID: chat, provider: .claude)?.nativeID == "late-session")
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat, provider: .claude, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: chat, provider: .claude)?.nativeID == "late-session")
        try await manager.shutdown()
    }

    @Test func stopBeforeDeliveryPreventsLateBarrierAndKeepsPreparedProof() async throws {
        let stores = try inMemoryStores()
        let chat = try agentStoreChat(stores).0.id
        let backend = InterruptBarrierBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let first = AgentInput(text: "first")
        let send = Task { try await manager.send(chatID: chat, provider: .claude, input: first) }
        try await waitAgentCondition { await backend.run.waiting }
        let began = ContinuousClock.now
        try await manager.stop(chatID: chat)
        #expect(ContinuousClock.now - began < .seconds(2))
        #expect(try stores.agentTurn(id: first.id)?.delivery == .prepared)
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        await backend.run.release()
        await #expect(throws: (any Error).self) { try await send.value }
        #expect(await backend.run.writes == 0)
        try await manager.shutdown()
    }
}

private func interruptScript(provider: AgentProvider, approval: Bool, failure: String) -> String {
    if provider == .claude {
        return """
claude_init()
restarted=os.path.exists('stopped')
if restarted:
    assert '--resume' in sys.argv and sys.argv[sys.argv.index('--resume')+1]=='stop-session'
else:
    assert read()['message']['content']=='first'
    emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'stop-session'})
    if \(approval ? "True" : "False"):
        emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo test'}}})
        assert read()['response']['response']['behavior']=='deny'
    else:
        emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
    r=read(); assert r['request']['subtype']=='interrupt'
    open('stopped','w').close()
    if '\(failure)' != 'noAck':
        emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'still_queued':[]}}})
    if '\(failure)' == 'none':
        emit({'type':'result','uuid':'stopped-result','subtype':'error_during_execution','is_error':True})
    else:
        while True: read()
assert read()['message']['content']=='continue'
emit({'type':'assistant','uuid':'next-reply','message':{'role':'assistant','content':[{'type':'text','text':'continued'}]}})
emit({'type':'result','uuid':'next-result','is_error':False})
done()
"""
    }
    return """
codex_init()
restarted=os.path.exists('stopped')
r=read(); assert r['method']=='account/read'; account(r)
r=read(); assert r['method']==('thread/resume' if restarted else 'thread/start')
if restarted: assert r['params']['threadId']=='thread-test'
emit({'id':r['id'],'result':{'thread':{'id':'thread-test','modelProvider':'openai'}}})
if not restarted:
    r=read(); assert r['method']=='turn/start'
    emit({'id':r['id'],'result':{'turn':{'id':'first-turn'}}})
    if \(approval ? "True" : "False"):
        emit({'id':99,'method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'first-turn','itemId':'command','command':'echo test'}})
        assert read()['result']['decision']=='decline'
    else:
        emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'first-turn','itemId':'reply','delta':'partial'}})
    r=read(); assert r['method']=='turn/interrupt' and r['params']['turnId']=='first-turn'
    open('stopped','w').close()
    if '\(failure)' != 'noAck': emit({'id':r['id'],'result':{}})
    if '\(failure)' == 'none':
        emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'first-turn','status':'interrupted','items':[]}}})
    else:
        while True: read()
r=read(); assert r['method']=='turn/start' and r['params']['input'][0]['text']=='continue'
emit({'id':r['id'],'result':{'turn':{'id':'next-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'next-turn','status':'completed','items':[]}}})
done()
"""
}

private actor InterruptBarrierBackend: AgentBackend {
    let run = InterruptBarrierRun()
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: [.followups]) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) -> any AgentRun { run }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
private actor InterruptBarrierRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    private(set) var writes = 0
    init() { (events, continuation) = AsyncThrowingStream.makeStream() }
    func release() { waiter?.resume(); waiter = nil }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        await withCheckedContinuation { waiter = $0 }
        try await willDeliver()
        writes += 1
    }
    func respond(to request: AgentRequest, with response: AgentResponse) {}
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { continuation.finish() }
}
