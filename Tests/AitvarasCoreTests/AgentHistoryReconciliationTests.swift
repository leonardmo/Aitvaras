import Foundation
import Testing
import GRDB
import AitvarasAgents
@testable import AitvarasStore

@Suite struct AgentHistoryReconciliationTests {
    @Test func correctionsDeletionsBranchesAndStreamedRowsUseCanonicalIDs() throws {
        let stores = try inMemoryStores()
        let (chat, original) = try agentStoreChat(stores)
        var session = original
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: "00000000-0000-4000-8000-000000000001")
        try stores.saveAgentSession(session)
        let input = AgentInput(text: "question")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        let user = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: .claude, kind: "user", text: input.text, sessionID: session.id))
        let streamed = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "partial", sessionID: session.id, nativeMessageID: "reply"))
        try stores.finishAgentTurn(id: input.id, state: .completed)
        let messages = [historyEntry(session, input.id.uuidString, "user", "question"), historyEntry(session, "reply", "assistant", "canonical")]
        try stores.reconcileAgentHistory(session: session, entries: messages)
        let first = try stores.agentEntries(chatID: chat.id)
        #expect(first.map(\.id) == [user.id, streamed.id])
        #expect(first.map(\.text) == ["question", "canonical"])
        try stores.reconcileAgentHistory(session: session, entries: messages)
        #expect(try stores.agentEntries(chatID: chat.id) == first)
        #expect(try observationCount(stores) == 1)
        let branch = [messages[0], historyEntry(session, "replacement", "assistant", "new branch"), historyEntry(session, "external", "user", "external turn")]
        try stores.reconcileAgentHistory(session: session, entries: branch)
        #expect(try stores.agentEntries(chatID: chat.id).map(\.text) == ["question", "new branch", "external turn"])
        #expect(try stores.agentTurn(id: input.id)?.prompt == "question")
        #expect(try stores.db.queue.read { try AgentTranscriptEntry.fetchOne($0, key: streamed.id) != nil })
        #expect(try observationCount(stores) == 2)
        try stores.reconcileAgentHistory(session: session, entries: messages)
        #expect(try stores.agentEntries(chatID: chat.id).map(\.id) == first.map(\.id))
        var wrongRole = messages; wrongRole[1].kind = "user"
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.reconcileAgentHistory(session: session, entries: wrongRole) }
        #expect(try stores.agentEntries(chatID: chat.id).map(\.id) == first.map(\.id))
    }

    @Test func interruptedCodexDeltaReconcilesWithoutACompletedItemEvent() throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        let native = AgentSessionID(provider: .codex, profile: "default", nativeID: "thread")
        session.sessionID = native
        try stores.saveAgentSession(session)
        let input = AgentInput(text: "question"), outputID = UUID()
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        var state = ChatState(chatID: chat.id)
        state.begin(input, session: session, outputID: outputID)
        let scope = AgentEventScope(runID: UUID(), session: native, inputID: input.id, turnID: "turn", itemID: "reply")
        let userID = native.canonicalMessageID("user", turnID: "turn")
        state.reduce(.init(scope: scope, kind: .message(id: userID, role: "user", text: input.text)), newEntryID: UUID())
        state.reduce(.init(scope: scope, kind: .textDelta("partial")), newEntryID: UUID())
        for entry in state.entries { _ = try stores.saveAgentEntry(entry) }
        try stores.finishAgentTurn(id: input.id, state: .interrupted)
        let replyID = native.canonicalMessageID("reply", turnID: "turn")
        #expect(try stores.agentEntries(chatID: chat.id).last?.nativeMessageID == replyID)
        try stores.reconcileAgentHistory(session: session, entries: [historyEntry(session, userID, "user", "question", completed: false, turnID: "turn"),
            historyEntry(session, replyID, "assistant", "persisted partial", completed: false, turnID: "turn")])
        let entries = try stores.agentEntries(chatID: chat.id)
        #expect(entries.map(\.text) == ["question", "persisted partial"])
        #expect(entries.last?.id == outputID)
        #expect(try stores.agentTurn(id: input.id)?.state == .interrupted)
    }

    @Test func publicationIsAtomicAndRejectsDuplicateOrForeignIDs() throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        let first = historyEntry(session, "one", "assistant", "original")
        try stores.reconcileAgentHistory(session: session, entries: [first])
        let before = try stores.agentEntries(chatID: chat.id)
        try stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER fixtureHistoryFailure BEFORE INSERT ON agentHistoryObservation BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        #expect(throws: (any Error).self) {
            try stores.reconcileAgentHistory(session: session, entries: [historyEntry(session, "new", "assistant", "changed")])
        }
        #expect(try stores.agentEntries(chatID: chat.id) == before)
        #expect(try observationCount(stores) == 1)
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.reconcileAgentHistory(session: session, entries: [first, first]) }
        var foreign = first; foreign.chatID = UUID()
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.reconcileAgentHistory(session: session, entries: [foreign]) }
        let running = AgentInput(text: "running")
        try stores.prepareAgentTurn(.init(input: running, chatID: chat.id, sessionID: session.id))
        #expect(throws: AgentSessionManagerError.chatBusy) { try stores.reconcileAgentHistory(session: session, entries: [first]) }
    }

    @Test func batchRefreshRollsBackEveryProviderAndRejectsIdentityDrift() throws {
        let stores = try inMemoryStores()
        var (chat, claude) = try agentStoreChat(stores)
        claude.sessionID = .init(provider: .claude, profile: "default", nativeID: "claude-native")
        try stores.saveAgentSession(claude)
        var codex = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        codex.sessionID = .init(provider: .codex, profile: "default", nativeID: "codex-native")
        try stores.saveAgentSession(codex)
        try stores.reconcileAgentHistory(session: claude, entries: [historyEntry(claude, "one", "assistant", "original")])
        let original = try stores.agentEntries(chatID: chat.id)
        let invalid = historyEntry(codex, "two", "tool", "invalid")
        #expect(throws: AgentNativeHistoryError.identityConflict) {
            try stores.reconcileAgentHistories([(claude, [historyEntry(claude, "one", "assistant", "changed")]), (codex, [invalid])])
        }
        #expect(try stores.agentEntries(chatID: chat.id) == original)
        #expect(try observationCount(stores) == 1)
        claude.sessionID = .init(provider: .claude, profile: "other", nativeID: "claude-native")
        try stores.saveAgentSession(claude)
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.reconcileAgentHistory(session: claude, entries: []) }
        #expect(try stores.agentEntries(chatID: chat.id) == original)
    }

    @Test func codexItemIdentityIncludesTurnAndCompletionState() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
while True:
    r=read(); assert r['method']=='thread/read'
    emit({'id':r['id'],'result':{'thread':{'id':'thread','turns':[
        {'id':'first','status':'completed','items':[{'id':'reply','type':'agentMessage','text':'completed'}]},
        {'id':'second','status':'interrupted','items':[{'id':'reply','type':'agentMessage','text':'partial'}]}
    ]}}})
    open('done','w').close()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        try await manager.refreshNativeHistory(chatID: chat.id)
        let entries = try stores.agentEntries(chatID: chat.id)
        #expect(entries.map(\.text) == ["completed", "partial"])
        #expect(Set(entries.compactMap(\.nativeMessageID)).count == 2)
        let local = AgentChatSession(chatID: chat.id, provider: .local, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(local)
        #expect(try stores.agentContext(session: local)?.entryCount == 1)
        try fixture.assertComplete()
        try await manager.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: [false, true])
    func stopOrQuitDuringReadCannotPublishOrStartASend(quit: Bool) async throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        let backend = PausedHistoryBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let owner = chat.id
        let send = Task { try await manager.send(chatID: owner, provider: .codex, input: .init(text: "new input")) }
        try await waitAgentCondition { await backend.waiting }
        await #expect(throws: AgentSessionManagerError.chatBusy) { try await manager.configure(session) }
        await #expect(throws: AgentSessionManagerError.chatBusy) { try await manager.send(chatID: owner, provider: .codex, input: .init(text: "racing input")) }
        if quit { try await manager.shutdown() } else { try await manager.stop(chatID: owner) }
        await backend.release()
        await #expect(throws: AgentSessionManagerError.staleRun) { try await send.value }
        #expect(try stores.agentEntries(chatID: owner).isEmpty)
        #expect(try stores.latestAgentTurn(chatID: owner) == nil)
        #expect(try observationCount(stores) == 0)
        #expect(await backend.starts == 0)
        try await manager.shutdown()
    }

    @Test func claudeFollowsParentBranchIncludingToolOnlyRecords() throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        func record(_ id: String, _ parent: String?, _ text: String, role: String = "assistant") -> JSONValue {
            .object(["uuid": .string(id), "parentUuid": parent.map(JSONValue.string) ?? .null, "type": .string(role),
                "cwd": .string(fixture.root.path), "sessionId": .string(fixture.id), "message": .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]), "stop_reason": .string("end_turn")])])
        }
        try fixture.write(records: [record("root", nil, "question", role: "user"), record("old", "root", "abandoned"),
            record("tool", "root", ""), record("new", "tool", "canonical")])
        let page = try fixture.reader.history(session: fixture.session, cursor: nil)
        #expect(page.items.map(\.kind) == [.message(id: "root", role: "user", text: "question"), .message(id: "new", role: "assistant", text: "canonical")])
        #expect(page.completedItemIDs == ["root", "new"])
        try fixture.write(records: [record("leaf", "missing", "incomplete")])
        #expect(throws: AgentNativeHistoryError.incompleteHistory) { try fixture.reader.history(session: fixture.session, cursor: nil) }
    }

    @Test func partialDuplicateAndInconsistentReadsLeaveLastTranscriptIntact() async throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        try stores.reconcileAgentHistory(session: session, entries: [historyEntry(session, "saved", "assistant", "saved")])
        let before = try stores.agentEntries(chatID: chat.id)
        for mode in [HistoryReadBackend.Mode.partial, .duplicate, .changing, .cycle] {
            let backend = HistoryReadBackend(session: session.sessionID!, mode: mode)
            let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
            await #expect(throws: (any Error).self) { try await manager.refreshNativeHistory(chatID: chat.id) }
            #expect(try stores.agentEntries(chatID: chat.id) == before)
            #expect(try observationCount(stores) == 1)
            try await manager.shutdown()
        }
    }

    @Test func claudeNativeOpenResumeAndExternalContinuationCatchUpLocal() async throws {
        let history = try NativeHistoryFixture()
        let fixture = try BackendExecutableFixture(script: #"""
assert '--resume' in sys.argv and sys.argv[sys.argv.index('--resume')+1]=='00000000-0000-4000-8000-000000000001'
claude_init()
r=read(); assert r['type']=='user' and r['message']['content']=='continue'
sid='00000000-0000-4000-8000-000000000001'
reply=str(uuid.uuid4())
folder=os.path.join(os.environ['CLAUDE_CONFIG_DIR'],'projects','example')
path=os.path.join(folder,sid+'.jsonl')
records=[{'type':'user','uuid':r['uuid'],'parentUuid':'answer','sessionId':sid,'cwd':os.environ['CLAUDE_CONFIG_DIR'],'message':r['message']},
         {'type':'assistant','uuid':reply,'parentUuid':r['uuid'],'sessionId':sid,'cwd':os.environ['CLAUDE_CONFIG_DIR'],'message':{'id':'api-message','role':'assistant','stop_reason':'end_turn','content':[{'type':'text','text':'continued answer'}]}}]
with open(path,'a') as f:
    for record in records: f.write(json.dumps(record)+'\n')
emit(records[1])
emit({'type':'result','is_error':False})
done()
"""#)
        defer { history.remove(); fixture.remove() }
        func record(_ id: String, parent: String?, role: String, text: String) -> JSONValue {
            .object(["type": .string(role), "uuid": .string(id), "parentUuid": parent.map(JSONValue.string) ?? .null,
                "cwd": .string(history.root.path), "sessionId": .string(history.id), "message": .object([
                    "role": .string(role), "stop_reason": .string("end_turn"),
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
        }
        try history.write(records: [record("question", parent: nil, role: "user", text: "native question"), record("answer", parent: "question", role: "assistant", text: "native answer")])
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, cwd: history.root.path)
        session.sessionID = history.session
        try stores.saveAgentSession(session)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, overrides: ["CLAUDE_CONFIG_DIR": history.root.path])
        let wire = HistoryContextRecorder()
        let local = LocalBackend { _, input in
            await wire.record(input.text)
            return AsyncThrowingStream { $0.yield("local answer"); $0.finish() }
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { provider in if provider == .local { return local }; return backend }, audit: { _ in })
        try await manager.refreshNativeHistory(chatID: chat.id)
        #expect(try await manager.state(chatID: chat.id).entries.map(\.text) == ["native question", "native answer"])
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path))
        let input = AgentInput(text: "continue")
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        try await waitAgentCondition { try stores.agentTurn(id: input.id)?.state == .completed }
        let streamed = try #require(try stores.agentEntries(chatID: chat.id).last)
        try await manager.refreshNativeHistory(chatID: chat.id)
        let reconciled = try stores.agentEntries(chatID: chat.id)
        #expect(reconciled.map(\.text) == ["native question", "native answer", "continue", "continued answer"])
        #expect(reconciled.last?.id == streamed.id)
        #expect(reconciled.filter { $0.id == input.id }.count == 1)
        // Simulate the native client correcting an earlier answer.
        var records = try String(contentsOf: history.file, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        records[1] = record("answer", parent: "question", role: "assistant", text: "corrected externally")
        try history.write(records: records)
        let localSession = AgentChatSession(chatID: chat.id, provider: .local, cwd: history.root.path, model: "local")
        try await manager.configure(localSession)
        try await manager.send(chatID: chat.id, provider: .local, input: .init(text: "what changed?"))
        try await waitAgentCondition { await wire.text != nil }
        let sent = try #require(await wire.text)
        #expect(sent.contains("corrected externally"))
        #expect(sent.contains("continued answer"))
        #expect(!sent.contains("native answer"))
        #expect(try stores.agentEntries(chatID: chat.id).contains { $0.kind == "handover" })
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func codexNativeOpenAndSendResumeWithoutDuplicatingStreamedItems() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
resumes=0
turns=[{'id':'native-turn','status':'completed','items':[{'id':'native-user','type':'userMessage','content':[{'type':'text','text':'native question'}]}, {'id':'native-reply','type':'agentMessage','text':'native answer'}]}]
while True:
    r=read(); method=r.get('method')
    if method=='thread/read':
        if os.path.exists('external') and not any(t['id']=='external-turn' for t in turns):
            turns.append({'id':'external-turn','status':'completed','items':[{'id':'external','type':'agentMessage','text':'external continuation'}]})
        assert r['params']=={'threadId':'thread','includeTurns':True}
        emit({'id':r['id'],'result':{'thread':{'id':'thread','historyMode':'legacy','turns':turns}}})
    elif method=='account/read': account(r)
    elif method=='thread/resume':
        resumes+=1
        assert r['params']['threadId']=='thread'
        emit({'id':r['id'],'result':{'thread':{'id':'thread','modelProvider':'openai'}}})
    elif method=='turn/start':
        text=r['params']['input'][0]['text']
        assert text in ['continue','again']
        if text=='again':
            assert resumes==2
            assert any(t['id']=='external-turn' for t in turns)
            emit({'id':r['id'],'result':{'turn':{'id':'again-turn'}}})
            emit({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'again-turn','status':'completed','items':[]}}})
            continue
        items=[{'id':'user-new','type':'userMessage','content':[{'type':'text','text':'continue'}]}, {'id':'reply-new','type':'agentMessage','text':'continued answer'}]
        turns.append({'id':'new-turn','status':'completed','itemsView':'full','items':items})
        emit({'id':r['id'],'result':{'turn':{'id':'new-turn'}}})
        for item in items: emit({'method':'item/completed','params':{'threadId':'thread','turnId':'new-turn','item':item}})
        emit({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'new-turn','status':'completed','items':items}}})
        open('done','w').close()
    else: fail('read/resume/start only',r)
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex, cwd: fixture.directory.path)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        try await manager.refreshNativeHistory(chatID: chat.id)
        #expect(try await manager.state(chatID: chat.id).entries.count == 2)
        let input = AgentInput(text: "continue")
        try await manager.send(chatID: chat.id, provider: .codex, input: input)
        try await waitAgentCondition { try stores.agentTurn(id: input.id)?.state == .completed }
        let streamed = try #require(try stores.agentEntries(chatID: chat.id).last)
        try await manager.refreshNativeHistory(chatID: chat.id)
        let entries = try await manager.state(chatID: chat.id).entries
        #expect(entries.map(\.text) == ["native question", "native answer", "continue", "continued answer"])
        #expect(entries.last?.id == streamed.id)
        #expect(entries.filter { $0.id == input.id }.count == 1)
        #expect(try stores.agentTurn(id: input.id)?.delivery == .acknowledged)
        // A native change must evict the idle run's old in-memory context.
        try Data().write(to: fixture.directory.appendingPathComponent("external"))
        let next = AgentInput(text: "again")
        try await manager.send(chatID: chat.id, provider: .codex, input: next)
        try await waitAgentCondition { try stores.agentTurn(id: next.id)?.state == .completed }
        #expect(try stores.agentEntries(chatID: chat.id).contains { $0.text == "external continuation" })
        try fixture.assertComplete()
        try await manager.shutdown(); try await backend.shutdown()
    }

    @Test func codexExecutableDetectsSinglePageMutationWithoutPublishing() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for text in ['first','changed']:
    r=read(); assert r['method']=='thread/read'
    emit({'id':r['id'],'result':{'thread':{'id':'thread','turns':[{'id':'turn','status':'completed','items':[{'id':'reply','type':'agentMessage','text':text}]}]}}})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .codex)
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "thread")
        try stores.saveAgentSession(session)
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        await #expect(throws: AgentNativeHistoryError.staleCursor) { try await manager.refreshNativeHistory(chatID: chat.id) }
        #expect(try stores.agentEntries(chatID: chat.id).isEmpty)
        try fixture.assertComplete()
        try await manager.shutdown(); try await backend.shutdown()
    }
}

func historyEntry(_ session: AgentChatSession, _ id: String, _ role: String, _ text: String, completed: Bool = true, turnID: String? = nil) -> AgentTranscriptEntry {
    .init(chatID: session.chatID, provider: session.provider, kind: role, text: text,
        payloadJSON: JSONValue.object(["nativeHistory": .object(["completed": .bool(completed), "turnID": turnID.map(JSONValue.string) ?? .null])]).jsonString,
        sessionID: session.id, nativeMessageID: id)
}
private func observationCount(_ stores: Stores) throws -> Int {
    try stores.db.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM agentHistoryObservation")! }
}
private actor HistoryReadBackend: AgentBackend {
    enum Mode { case partial, duplicate, changing, cycle }
    let session: AgentSessionID
    let mode: Mode
    var count = 0
    init(session: AgentSessionID, mode: Mode) { self.session = session; self.mode = mode }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: [.history]) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun { throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) -> AgentPage<AgentSessionSummary> { .init(items: []) }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> {
        count += 1
        if mode == .partial && cursor != nil { throw AgentNativeHistoryError.incompleteHistory }
        let text = mode == .changing ? "revision \(count)" : "external"
        let event = AgentEvent(scope: .init(runID: UUID(), session: session, itemID: "item"), kind: .message(id: "item", role: "assistant", text: text))
        return .init(items: [event], nextCursor: mode == .changing ? nil : mode == .cycle ? "loop" : cursor == nil ? "next" : nil)
    }
}

private actor HistoryContextRecorder {
    var text: String?
    func record(_ text: String) { self.text = text }
}

private actor PausedHistoryBackend: AgentBackend {
    var starts = 0
    var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }
    func release() { waiter?.resume(); waiter = nil }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: [.history]) }
    func models() -> [AgentModel] { [] }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) {}
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun { starts += 1; throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) -> AgentPage<AgentSessionSummary> { .init(items: []) }
    func readHistory(session: AgentSessionID, cursor: String?) async -> AgentPage<AgentEvent> {
        await withCheckedContinuation { waiter = $0 }
        return .init(items: [])
    }
}
