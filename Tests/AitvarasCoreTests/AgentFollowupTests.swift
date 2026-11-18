import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2)))
struct AgentFollowupTests {
    @Test func claudeOneResultCompletesEveryWrittenInputAndAttributesAnswerToLatest() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']=='first'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'queue-session'})
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'one'}}})
a=read(); assert a['message']['content']=='same text'
b=read(); assert b['message']['content']=='same text'
emit({'type':'assistant','uuid':'reply-example','message':{'role':'assistant','content':[{'type':'text','text':'combined answer'}]}})
emit({'type':'result','uuid':'result-example','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let first = AgentInput(text: "first"), second = AgentInput(text: "same text"), third = AgentInput(text: "same text")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        try await manager.send(chatID: chat, provider: .claude, input: second)
        #expect(try stores.agentTurn(id: second.id)?.delivery == .deliveryUnknown)
        #expect(try stores.agentEntries(chatID: chat).first { $0.id == second.id }?.payloadJSON?.contains("queued") == true)
        await #expect(throws: AgentSessionManagerError.chatBusy) {
            try await manager.send(chatID: chat, provider: .claude, input: second)
        }
        #expect(try stores.agentTurn(id: first.id)?.state == .running)
        try await manager.send(chatID: chat, provider: .claude, input: third)
        try await waitAgentCondition { try stores.agentTurn(id: third.id)?.state == .completed }
        for input in [first, second, third] {
            #expect(try stores.agentTurn(id: input.id)?.delivery == .acknowledged)
            #expect(try stores.agentTurn(id: input.id)?.state == .completed)
        }
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "assistant" }.map(\.text) == ["combined answer"])
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "user" }.map(\.id) == [first.id, second.id, third.id])
        #expect(try stores.agentTurn(id: third.id)?.partialOutput == "combined answer")
        #expect(try stores.agentTurn(id: first.id)?.partialOutput == "")
        #expect(try await !manager.state(chatID: chat).isRunning)
        #expect(try stores.agentEntries(chatID: chat).last?.kind == "assistant")
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func followupDuringApprovalCompletesBothJournalsAndClearsTheSpinner() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
first=read(); assert first['message']['content']=='first'
emit({'type':'system','subtype':'init','session_id':'session-example','apiKeySource':'none'})
emit({'type':'user','uuid':first['uuid'],'message':first['message']})
emit({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo example'}}})
second=read(); assert second['message']['content']=='second'
r=read(); assert r['response']['response']['behavior']=='allow'
emit({'type':'user','uuid':second['uuid'],'message':second['message']})
emit({'type':'assistant','uuid':'answer-example','message':{'role':'assistant','content':[{'type':'text','text':'answer to second'}]}})
emit({'type':'result','uuid':'result-example','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let first = AgentInput(text: "first"), second = AgentInput(text: "second")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        try await waitAgentCondition { try await manager.state(chatID: chat).pendingCards.count == 1 }
        let card = try #require(try await manager.state(chatID: chat).pendingCards.first)
        try await manager.send(chatID: chat, provider: .claude, input: second)
        #expect(try stores.agentTurn(id: second.id)?.delivery == .deliveryUnknown)
        try await manager.respond(chatID: chat, to: card, with: .allow(updatedInput: nil))
        try await waitAgentCondition { try stores.agentTurn(id: second.id)?.state == .completed }
        let state = try await manager.state(chatID: chat)
        #expect(!state.isRunning); #expect(state.pendingCards.isEmpty)
        #expect(state.inputID == second.id)
        #expect(try stores.agentTurn(id: first.id)?.state == .completed)
        #expect(try stores.agentTurn(id: second.id)?.delivery == .acknowledged)
        #expect(try stores.agentTurn(id: second.id)?.partialOutput == "answer to second")
        #expect(state.entries.last?.text == "answer to second")
        #expect(state.entries.first { $0.id == first.id }?.nativeMessageID == first.id.uuidString)
        #expect(state.entries.first { $0.id == second.id }?.nativeMessageID == second.id.uuidString)
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test func resultRacingAnUnwrittenFollowupLeavesNoRunningInput() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']=='first'
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'first answer'}}})
for _ in range(5):
    if os.path.exists('release-result'): break
    time.sleep(1)
emit({'type':'result','uuid':'result-example','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let first = AgentInput(text: "first"), second = AgentInput(text: "second")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        await #expect(throws: (any Error).self) {
            try await manager.send(chatID: chat, provider: .claude, input: second, onAccepted: {
                try? Data().write(to: fixture.directory.appendingPathComponent("release-result"))
                for _ in 0..<400 {
                    if (try? stores.agentTurn(id: first.id)?.state) == .completed { return }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            })
        }
        #expect(try stores.agentTurn(id: first.id)?.state == .completed)
        #expect(try stores.agentTurn(id: second.id)?.state == .failed)
        #expect(try stores.agentTurn(id: second.id)?.delivery == .prepared)
        #expect(try await !manager.state(chatID: chat).isRunning)
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test(arguments: [false, true])
    func codexSteersExactTurnAndDoesNotReplaceOutputOwner(fastCompletion: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: """
codex_init()
start_thread()
r=read(); assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'active-turn'}}})
emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'active-turn','itemId':'reply','delta':'before '}})
r=read(); assert r['method']=='turn/steer'
assert r['params']['threadId']=='thread-test' and r['params']['expectedTurnId']=='active-turn'
assert r['params']['input']==[{'type':'text','text':'follow-up'}]
assert r['params']['clientUserMessageId']
followup=r['params']['clientUserMessageId']
emit({'method':'item/completed','params':{'threadId':'thread-test','turnId':'active-turn','item':{'id':followup,'type':'userMessage','content':[{'type':'text','text':'follow-up'}]}}})
if \(fastCompletion ? "True" : "False"):
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'active-turn','status':'completed','items':[]}}})
emit({'id':r['id'],'result':{'turnId':'active-turn'}})
if not \(fastCompletion ? "True" : "False"):
    emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'active-turn','itemId':'reply','delta':'after'}})
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'active-turn','status':'completed','items':[]}}})
done()
""")
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        let first = AgentInput(text: "first"), followup = AgentInput(text: "follow-up")
        try await manager.send(chatID: chat, provider: .codex, input: first)
        try await waitAgentCondition { try await manager.state(chatID: chat).streamingText == "before " }
        try await manager.send(chatID: chat, provider: .codex, input: followup)
        try await waitAgentCondition { try stores.agentTurn(id: followup.id)?.state == .completed }
        #expect(try stores.agentTurn(id: followup.id)?.delivery == .acknowledged)
        #expect(try stores.agentTurn(id: first.id)?.partialOutput == (fastCompletion ? "before " : "before after"))
        #expect(try stores.agentTurn(id: followup.id)?.partialOutput == "")
        #expect(try stores.agentEntries(chatID: chat).first { $0.id == followup.id }?.nativeMessageID == AgentSessionID(provider: .codex, profile: "default", nativeID: "thread-test").canonicalMessageID(followup.id.uuidString, turnID: "active-turn"))
        #expect(try stores.agentEntries(chatID: chat).first { $0.id == first.id }?.nativeMessageID == nil)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func staleSteerResponseIsUncertainAndNeverResent() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read(); emit({'id':r['id'],'result':{'turn':{'id':'active-turn'}}})
r=read(); assert r['method']=='turn/steer'
emit({'id':r['id'],'result':{'turnId':'wrong-turn'}})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        try await manager.send(chatID: chat, provider: .codex, input: .init(text: "first"))
        let followup = AgentInput(text: "follow-up")
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.send(chatID: chat, provider: .codex, input: followup) }
        #expect(try stores.agentTurn(id: followup.id)?.delivery == .deliveryUnknown)
        #expect(try stores.agentTurn(id: followup.id)?.state == .interrupted)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.resendPrepared(turnID: followup.id) }
        try await manager.shutdown()
    }

    @Test func failedFollowupBarrierPreservesActiveTurnAndAllowsNextInput() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']=='first'
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
assert read()['message']['content']=='good'
emit({'type':'assistant','uuid':'reply','message':{'role':'assistant','content':[{'type':'text','text':'follow-up reply'}]}})
emit({'type':'result','uuid':'combined-result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let first = AgentInput(text: "first"), bad = AgentInput(text: "bad"), good = AgentInput(text: "good")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER testFollowupBarrier BEFORE UPDATE OF delivery ON agentTurn WHEN NEW.delivery IS NOT OLD.delivery BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await #expect(throws: (any Error).self) { try await manager.send(chatID: chat, provider: .claude, input: bad) }
        #expect(try stores.agentTurn(id: bad.id)?.delivery == .prepared)
        #expect(try stores.agentTurn(id: bad.id)?.state == .failed)
        #expect(try stores.agentTurn(id: first.id)?.state == .running)
        #expect(try await manager.state(chatID: chat).isRunning)
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testFollowupBarrier") }
        try await manager.send(chatID: chat, provider: .claude, input: good)
        try await waitAgentCondition { try stores.agentTurn(id: good.id)?.state == .completed }
        try await manager.shutdown()
    }

    @Test func codexPlanReviewRejectsSteerBeforeDeliveryWithoutLosingCard() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read(); assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'plan-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'plan-turn','status':'completed','items':[{'id':'plan','type':'plan','text':'A plan.'}]}}})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        var session = try #require(try stores.agentSession(chatID: chat, provider: .codex))
        session.mode = .plan
        try await manager.configure(session)
        let first = AgentInput(text: "plan"), followup = AgentInput(text: "steer")
        try await manager.send(chatID: chat, provider: .codex, input: first)
        try await waitAgentCondition { try await !manager.state(chatID: chat).pendingCards.isEmpty }
        let card = try #require(try await manager.state(chatID: chat).pendingCards.first)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.send(chatID: chat, provider: .codex, input: followup) }
        #expect(try stores.agentTurn(id: followup.id)?.delivery == .prepared)
        #expect(try stores.agentTurn(id: first.id)?.state == .running)
        #expect(try await manager.state(chatID: chat).pendingCards == [card])
        try await manager.respond(chatID: chat, to: card, with: .deny)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.state == .completed }
        try await manager.shutdown()
    }

    @Test func queuedDeliveryAndStopAreScopedToTheirChat() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
first=read()['message']['content']
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'session-'+str(os.getpid())})
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
if first=='first':
    assert read()['message']['content']=='follow-up'
    r=read(); assert r['request']['subtype']=='interrupt'
    emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
    emit({'type':'result','terminal_reason':'aborted_streaming','is_error':True})
while True: read()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let other = try agentStoreChat(stores, cwd: fixture.directory.path).0.id
        let otherInput = AgentInput(text: "other"), followup = AgentInput(text: "follow-up")
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "first"))
        try await manager.send(chatID: other, provider: .claude, input: otherInput)
        try await waitAgentCondition { try stores.agentTurn(id: otherInput.id)?.delivery == .acknowledged }
        try await manager.send(chatID: chat, provider: .claude, input: followup)
        #expect(try stores.agentTurn(id: followup.id)?.chatID == chat)
        #expect(try stores.agentTurn(id: followup.id)?.delivery == .deliveryUnknown)
        #expect(try stores.agentEntries(chatID: other).allSatisfy { $0.id != followup.id })
        try await manager.stop(chatID: chat)
        #expect(try stores.agentTurn(id: followup.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: otherInput.id)?.state == .running)
        #expect(try await manager.state(chatID: other).isRunning)
        try await manager.shutdown()
    }

    @Test func followupOnAnotherProviderIsRejectedWithoutJournal() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'working'}}})
while True: read()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        try await manager.send(chatID: chat, provider: .claude, input: .init(text: "first"))
        let wrong = AgentInput(text: "wrong provider")
        await #expect(throws: AgentSessionManagerError.chatBusy) { try await manager.send(chatID: chat, provider: .codex, input: wrong) }
        #expect(try stores.agentTurn(id: wrong.id) == nil)
        try await manager.shutdown(timeout: .milliseconds(100))
    }
}

func followupManager(_ fixture: BackendExecutableFixture, provider: AgentProvider) throws -> (Stores, UUID, AgentSessionManager) {
    let stores = try inMemoryStores()
    let chat = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path).0.id
    let backend: any AgentBackend = provider == .claude
        ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        : CodexBackend(executable: fixture.executable, environment: fixture.environment)
    return (stores, chat, try AgentSessionManager(persistence: stores, backend: { _ in AgentHistoryTestBackend(backend, stores: stores) }, audit: { _ = try stores.record($0) }))
}

func waitAgentCondition(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<600 {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
