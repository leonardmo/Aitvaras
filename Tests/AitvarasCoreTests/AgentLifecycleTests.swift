import Foundation
import Testing
import GRDB
import AitvarasAgents
import AitvarasStore

struct AgentLifecycleTests {
    @Test(arguments: [AgentProvider.claude, .codex])
    func recordedInterruptRemainsAvailableAfterWindowDetaches(provider: AgentProvider) async throws {
        let fixture = try BackendExecutableFixture(provider: provider.rawValue, name: "interrupt")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path)
        session.model = provider == .codex ? "gpt-6-luna" : "default"
        session.mode = provider == .codex ? .plan : .ask
        let backend = lifecycleBackend(provider, fixture)
        let manager = try lifecycleManager(stores, backend)
        try await manager.configure(session)
        let updates = try await manager.updates(chatID: chat.id)
        let window = Task { for await _ in updates {} }
        let input = AgentInput(text: try fixture.prompt(provider: provider.rawValue, name: "interrupt"))
        try await manager.send(chatID: chat.id, provider: provider, input: input)
        try await waitAgentCondition { try await !manager.state(chatID: chat.id).streamingText.isEmpty }
        window.cancel(); await window.value
        #expect(ChatSidebarStatus(try await manager.state(chatID: chat.id)) == .running)
        try await manager.stop(chatID: chat.id)
        #expect(ChatSidebarStatus(try await manager.state(chatID: chat.id)) == .interrupted)
        #expect(try stores.agentTurn(id: input.id)?.state == .interrupted)
        #expect(try stores.agentSession(chatID: chat.id, provider: provider)?.sessionID != nil)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown()
        if let codex = backend as? CodexBackend { try await codex.shutdown() }
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func backgroundChatsRetainScopedStatusAndArchiveDoesNotStopWork(provider: AgentProvider) async throws {
        let fixture = try BackendExecutableFixture(script: lifecycleScript(provider))
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let first = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path).0
        let second = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path).0
        let backend = lifecycleBackend(provider, fixture)
        let manager = try lifecycleManager(stores, backend)
        let updates = try await manager.updates(chatID: first.id)
        let window = Task { for await _ in updates {} }
        let one = AgentInput(text: "hold"), two = AgentInput(text: "needs-you")
        async let sendOne: Void = manager.send(chatID: first.id, provider: provider, input: one)
        async let sendTwo: Void = manager.send(chatID: second.id, provider: provider, input: two)
        _ = try await (sendOne, sendTwo)
        try await waitAgentCondition {
            let first = try await manager.state(chatID: first.id)
            let second = try await manager.state(chatID: second.id)
            return first.streamingText == "partial" && !second.pendingCards.isEmpty
        }
        // Closing all transcript subscribers has no ownership of either run.
        window.cancel(); await window.value
        #expect(ChatSidebarStatus(try await manager.state(chatID: first.id)) == .running)
        #expect(ChatSidebarStatus(try await manager.state(chatID: second.id)) == .needsYou)
        var reopened = try await manager.updates(chatID: first.id).makeAsyncIterator()
        #expect(await reopened.next()?.streamingText == "partial")

        let native = try stores.agentSession(chatID: second.id, provider: provider)
        let entries = try stores.agentEntries(chatID: second.id)
        try await manager.setArchived(chatID: second.id, archived: true)
        let archived = try #require(try stores.workspaceChat(id: second.id)?.archivedAt)
        try await manager.rename(chatID: second.id, title: "  Renamed chat  ")
        try await manager.setArchived(chatID: second.id, archived: true)
        #expect(try stores.workspaceChat(id: second.id)?.archivedAt == archived)
        #expect(try stores.workspaceChat(id: second.id)?.title == "Renamed chat")
        #expect(try stores.workspaceChat(id: second.id)?.localConversationID == second.localConversationID)
        #expect(try stores.workspaceChat(id: first.id)?.title == first.title)
        #expect(try stores.agentSession(chatID: second.id, provider: provider) == native)
        #expect(try stores.agentEntries(chatID: second.id) == entries)
        let rejected = AgentInput(text: "must not send")
        await #expect(throws: AgentSessionManagerError.chatUnavailable) {
            try await manager.send(chatID: second.id, provider: provider, input: rejected)
        }
        #expect(try stores.agentTurn(id: rejected.id) == nil)
        let card = try #require(try await manager.state(chatID: second.id).pendingCards.first)
        try await manager.respond(chatID: second.id, to: card, with: .deny)
        try await waitAgentCondition { try stores.agentTurn(id: two.id)?.state == .completed }
        #expect(ChatSidebarStatus(try await manager.state(chatID: second.id)) == .idle)
        #expect(ChatSidebarStatus(try await manager.state(chatID: first.id)) == .running)
        #expect(try stores.workspaceChat(id: second.id)?.archivedAt == archived)
        try await manager.setArchived(chatID: second.id, archived: false)
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: second.id, provider: provider, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: second.id, provider: provider)?.sessionID == native?.sessionID)
        try await manager.setArchived(chatID: first.id, archived: true)
        try await manager.stop(chatID: first.id)
        #expect(ChatSidebarStatus(try await manager.state(chatID: first.id)) == .interrupted)
        try await manager.shutdown()
        if let codex = backend as? CodexBackend { try await codex.shutdown() }
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func quitAndRelaunchResumeOnlyOnNextSend(provider: AgentProvider) async throws {
        let fixture = try BackendExecutableFixture(script: lifecycleScript(provider))
        defer { fixture.remove() }
        let database = fixture.directory.appendingPathComponent("state.sqlite")
        let stores = Stores(db: try AitvarasDatabase(url: database))
        let chat = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path).0
        let backend = lifecycleBackend(provider, fixture)
        let manager = try lifecycleManager(stores, backend)
        let first = AgentInput(text: "hold")
        try await manager.send(chatID: chat.id, provider: provider, input: first)
        try await waitAgentCondition { try await manager.state(chatID: chat.id).streamingText == "partial" }
        let native = try #require(try stores.agentSession(chatID: chat.id, provider: provider)?.sessionID)
        let queued = AgentInput(text: "queued")
        if provider == .claude { try await manager.send(chatID: chat.id, provider: provider, input: queued) }
        try await manager.rename(chatID: chat.id, title: "Kept title")
        try await manager.shutdown()
        if let codex = backend as? CodexBackend { try await codex.shutdown() }
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: first.id)?.partialOutput == "partial")
        if provider == .claude {
            #expect(try stores.agentTurn(id: queued.id)?.state == .interrupted)
            #expect(try stores.agentEntries(chatID: chat.id).first { $0.id == queued.id }?.payloadJSON?.contains("interrupted") == true)
        }
        let logBefore = try lifecycleLog(fixture)
        let reopened = Stores(db: try AitvarasDatabase(url: database))
        let newBackend = lifecycleBackend(provider, fixture)
        let relaunched = try lifecycleManager(reopened, newBackend)
        var view = try await relaunched.updates(chatID: chat.id).makeAsyncIterator()
        #expect(ChatSidebarStatus(await view.next()) == .interrupted)
        #expect(try await relaunched.state(chatID: chat.id).pendingCards.isEmpty)
        #expect(try reopened.workspaceChat(id: chat.id)?.title == "Kept title")
        #expect(try lifecycleLog(fixture) == logBefore)
        let next = AgentInput(text: "continue")
        try await relaunched.send(chatID: chat.id, provider: provider, input: next)
        try await waitAgentCondition { try reopened.agentTurn(id: next.id)?.state == .completed }
        #expect(try reopened.agentSession(chatID: chat.id, provider: provider)?.sessionID == native)
        let log = try lifecycleLog(fixture)
        #expect(log.filter { $0["text"]?.stringValue == "hold" }.count == 1)
        #expect(log.filter { $0["text"]?.stringValue == "continue" }.count == 1)
        #expect(log.last { $0["resume"] != nil }?["resume"]?.stringValue == native.nativeID)
        #expect(try reopened.agentTurn(id: first.id)?.resendCount == 0)
        try await relaunched.shutdown()
        if let codex = newBackend as? CodexBackend { try await codex.shutdown() }
    }

    @Test(arguments: [AgentProvider.claude, .codex],
          [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged])
    func crashRecoveryDoesNotReplayAnyDeliveryState(provider: AgentProvider, delivery: AgentDeliveryState) async throws {
        let fixture = try BackendExecutableFixture(script: lifecycleScript(provider))
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: provider, cwd: fixture.directory.path)
        session.sessionID = .init(provider: provider, profile: "default", nativeID: "lifecycle-known")
        try stores.saveAgentSession(session)
        let first = AgentInput(text: "old input")
        try stores.prepareAgentTurn(.init(input: first, chatID: chat.id, sessionID: session.id))
        if delivery != .prepared { try stores.advanceAgentDelivery(id: first.id, to: .deliveryUnknown) }
        if delivery == .acknowledged { try stores.advanceAgentDelivery(id: first.id, to: .acknowledged) }
        let entry = try stores.saveAgentEntry(.init(chatID: chat.id, provider: provider, kind: "assistant", text: "partial", sessionID: session.id))
        let backend = lifecycleBackend(provider, fixture)
        let manager = try lifecycleManager(stores, backend)
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: first.id)?.delivery == delivery)
        #expect(try await manager.state(chatID: chat.id).entries == [entry])
        #expect(try lifecycleLog(fixture).isEmpty)
        let next = AgentInput(text: "continue")
        try await manager.send(chatID: chat.id, provider: provider, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentSession(chatID: chat.id, provider: provider)?.sessionID == session.sessionID)
        #expect(try lifecycleLog(fixture).compactMap { $0["text"]?.stringValue } == ["continue"])
        try await manager.shutdown()
        if let codex = backend as? CodexBackend { try await codex.shutdown() }
    }

    @Test func invalidMetadataAndFailedWritesLeaveChatsUntouched() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let original = try stores.workspaceChat(id: chat.id)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in throw AgentFailure.unsupported }, audit: { _ in })
        for title in [" \n ", String(repeating: "x", count: 201), "bad\0title"] {
            await #expect(throws: (any Error).self) { try await manager.rename(chatID: chat.id, title: title) }
        }
        await #expect(throws: WorkspaceStoreError.chatNotFound) { try await manager.rename(chatID: UUID(), title: "Missing") }
        await #expect(throws: WorkspaceStoreError.chatNotFound) { try await manager.setArchived(chatID: UUID(), archived: true) }
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER metadataFailure BEFORE UPDATE ON workspaceChat BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await #expect(throws: (any Error).self) { try await manager.rename(chatID: chat.id, title: "Unsaved") }
        await #expect(throws: (any Error).self) { try await manager.setArchived(chatID: chat.id, archived: true) }
        #expect(try stores.workspaceChat(id: chat.id) == original)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude) == session)
        #expect(try stores.agentEntries(chatID: chat.id).isEmpty)
        try await manager.shutdown()
    }

    @Test func archivedHiddenAndBogusChatsRejectSendWithoutPreparingInput() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in throw AgentFailure.unsupported }, audit: { _ in })
        try await manager.setArchived(chatID: chat.id, archived: true)
        let input = AgentInput(text: "must not leave")
        await #expect(throws: AgentSessionManagerError.chatUnavailable) { try await manager.send(chatID: chat.id, provider: .claude, input: input) }
        await #expect(throws: AgentSessionManagerError.chatUnavailable) { try await manager.configure(session) }
        try await manager.setArchived(chatID: chat.id, archived: false)
        var project = try #require(try stores.workspaceProject(id: chat.projectID))
        project.isVisible = false; try stores.saveWorkspaceProject(project)
        await #expect(throws: AgentSessionManagerError.chatUnavailable) { try await manager.send(chatID: chat.id, provider: .claude, input: input) }
        await #expect(throws: AgentSessionManagerError.chatUnavailable) { try await manager.send(chatID: UUID(), provider: .claude, input: input) }
        #expect(try stores.agentTurn(id: input.id) == nil)
        try await manager.shutdown()
    }

    @Test func agentActivityOrdersChatsAndProtectsRunningChatsFromExpiry() throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores)
        chat.kind = .temporary
        try stores.saveWorkspaceChat(chat)
        let input = AgentInput(text: "work")
        var turn = AgentJournalTurn(input: input, chatID: chat.id, sessionID: session.id)
        let future = Date(timeIntervalSince1970: 4_000_000_000)
        turn.startedAt = future
        try stores.prepareAgentTurn(turn)
        #expect(try stores.workspaceChat(id: chat.id)?.lastActivityAt == future)
        #expect(try stores.recentWorkspaceChats(limit: 1).first?.id == chat.id)
        #expect(try stores.archiveExpiredWorkspaceChats(now: future.addingTimeInterval(8 * 24 * 3600)) == 0)
        try stores.finishAgentTurn(id: input.id, state: .completed)
        #expect(try stores.archiveExpiredWorkspaceChats(now: future.addingTimeInterval(8 * 24 * 3600)) == 1)
        #expect(try stores.agentTurn(id: input.id)?.state == .completed)
    }
}

private func lifecycleBackend(_ provider: AgentProvider, _ fixture: BackendExecutableFixture) -> any AgentBackend {
    provider == .claude ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        : CodexBackend(executable: fixture.executable, environment: fixture.environment)
}
private func lifecycleManager(_ stores: Stores, _ backend: any AgentBackend) throws -> AgentSessionManager {
    try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
}
private func lifecycleLog(_ fixture: BackendExecutableFixture) throws -> [JSONValue] {
    let url = fixture.directory.appendingPathComponent("requests.jsonl")
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
}

// Protocol shapes follow the checked-in interrupt recordings. The process log
// proves that restoring subscribers/startup never launches or replays a prompt.
private func lifecycleScript(_ provider: AgentProvider) -> String {
    let log = #"""
def log(value):
    with open('requests.jsonl','a') as f: f.write(json.dumps(value)+'\n')
log({'launch':True})
"""#
    if provider == .claude { return log + "\n" + #"""
claude_init()
native=sys.argv[sys.argv.index('--resume')+1] if '--resume' in sys.argv else 'lifecycle-'+str(os.getpid())
if '--resume' in sys.argv: log({'resume':native})
while True:
    r=read()
    if r.get('type')=='user':
        text=r['message']['content']; log({'text':text})
        emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':native})
        if text=='continue':
            emit({'type':'assistant','uuid':'continued','message':{'role':'assistant','content':[{'type':'text','text':'continued'}]}})
            emit({'type':'result','is_error':False})
        elif text=='needs-you':
            emit({'type':'control_request','request_id':'approval','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo test'}}})
        elif text=='hold':
            emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
        else: assert text=='queued'
    elif r.get('type')=='control_response':
        assert r['response']['response']['behavior']=='deny'
        emit({'type':'result','is_error':False})
    elif r.get('type')=='control_request':
        assert r['request']['subtype']=='interrupt'
        emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'still_queued':[]}}})
        emit({'type':'result','terminal_reason':'aborted_streaming','is_error':True})
    else: fail('known Claude frame',r)
"""# }
    return log + "\n" + #"""
codex_init()
threads=0
turns=0
pending={}
def finish(thread,turn,status):
    emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':status,'items':[]}}})
while True:
    r=read(); method=r.get('method'); p=r.get('params',{})
    if method=='account/read': account(r)
    elif method in ['thread/start','thread/resume']:
        threads+=1
        thread=p.get('threadId','lifecycle-'+str(threads))
        if method=='thread/resume': log({'resume':thread})
        emit({'id':r['id'],'result':{'thread':{'id':thread,'modelProvider':'openai'}}})
    elif method=='turn/start':
        turns+=1; turn='turn-'+str(turns); thread=p['threadId']; text=p['input'][0]['text']
        log({'text':text})
        emit({'id':r['id'],'result':{'turn':{'id':turn}}})
        if text=='continue':
            emit({'method':'item/agentMessage/delta','params':{'threadId':thread,'turnId':turn,'itemId':'reply','delta':'continued'}})
            finish(thread,turn,'completed')
        elif text=='needs-you':
            pending[turns+1000]=(thread,turn)
            emit({'id':turns+1000,'method':'item/commandExecution/requestApproval','params':{'threadId':thread,'turnId':turn,'itemId':'command','command':'echo test'}})
        else:
            assert text=='hold'
            emit({'method':'item/agentMessage/delta','params':{'threadId':thread,'turnId':turn,'itemId':'reply','delta':'partial'}})
    elif method=='turn/interrupt':
        emit({'id':r['id'],'result':{}})
        finish(p['threadId'],p['turnId'],'interrupted')
    elif method is None and r.get('id') in pending:
        assert r['result']['decision']=='decline'
        thread,turn=pending.pop(r['id']); finish(thread,turn,'completed')
    else: fail('known Codex frame',r)
"""#
}
