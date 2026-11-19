import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AutonomousTurnTests {
    @Test(arguments: ["complete", "approval", "followup", "interrupt", "interruptThenWake", "disconnect"])
    func claudeLifecycle(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'assistant','uuid':'user-answer','session_id':'session-test','message':{'role':'assistant','content':[{'type':'tool_use','id':'schedule','name':'ScheduleWakeup','input':{}}]}})
emit({'type':'result','uuid':'first-result','is_error':False})
while not os.path.exists('wake'): time.sleep(0.005)
emit({'type':'user','uuid':'injected','message':{'role':'user','content':'<system-reminder>scheduled-wakeup</system-reminder>'}})
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'Autonomous answer'}}})
scenario='\(scenario)'
if scenario=='approval':
    emit({'type':'control_request','request_id':'approve','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo example'}}})
    reply=read()
    assert reply['response']['response']['behavior']=='allow'
if scenario=='followup':
    followup=read()
    assert followup['type']=='user' and followup['message']['content']=='Follow up'
if scenario in ['interrupt','interruptThenWake']:
    r=read()
    assert r['request']['subtype']=='interrupt'
    emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
if scenario=='disconnect': sys.exit(7)
while scenario in ['complete','followup'] and not os.path.exists('finish'): time.sleep(0.005)
emit({'type':'result','uuid':'autonomous-result','is_error':False,'usage':{'input_tokens':11,'output_tokens':7}})
if scenario=='interruptThenWake':
    while not os.path.exists('next-wake'): time.sleep(0.005)
    emit({'type':'assistant','uuid':'later-answer','message':{'role':'assistant','content':[{'type':'text','text':'Later check'}]}})
    emit({'type':'result','uuid':'later-result','is_error':False})
# Duplicate canonical history/result must not open another turn.
emit({'type':'assistant','uuid':'user-answer','message':{'role':'assistant','content':[{'type':'text','text':'replay'}]}})
emit({'type':'result','uuid':'autonomous-result','is_error':False})
open('done','w').close()
while sys.stdin.readline(): pass
open('closed','w').close()
""")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        let raw = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let backend = AgentHistoryTestBackend(raw, stores: stores)
        let manager = try AgentSessionManager(persistence: stores, idleTimeout: .milliseconds(300), backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat.id, provider: .claude, input: .init(text: "Schedule a check"))
        try await wait { try await manager.state(chatID: chat.id).outcome == .completed }
        try Data().write(to: fixture.directory.appendingPathComponent("wake"))
        try await wait { try await manager.state(chatID: chat.id).entries.contains { $0.kind == "wakeup" } }
        let state = try await manager.state(chatID: chat.id)
        let id = try #require(state.entries.first { $0.kind == "wakeup" }?.id)
        #expect(state.entries.filter { $0.kind == "user" }.count == 1)
        #expect(try stores.agentTurn(id: id)?.origin == .autonomous(.wakeup))
        #expect(try stores.agentTurn(id: id)?.prompt == nil)
        #expect(try stores.activityRun(id: id)?.title == "Chat woke up")
        if scenario == "approval" {
            try await wait { try await !manager.state(chatID: chat.id).pendingCards.isEmpty }
            let request = try #require(try await manager.state(chatID: chat.id).pendingCards.first)
            #expect(request.scope.inputID == id)
            try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
        } else if scenario == "followup" {
            let followup = AgentInput(text: "Follow up")
            try await manager.send(chatID: chat.id, provider: .claude, input: followup)
            #expect(try stores.agentTurn(id: followup.id)?.parentInputID == id)
        } else if scenario == "interrupt" || scenario == "interruptThenWake" {
            try await manager.stop(chatID: chat.id)
        }
        if scenario == "complete" || scenario == "followup" {
            // Running work survives the old idle deadline, then completion
            // re-arms eviction instead of retaining this transport forever.
            try await Task.sleep(for: .milliseconds(350))
            #expect(try await manager.state(chatID: chat.id).isRunning)
            #expect(try stores.agentTurn(id: id)?.partialOutput == "Autonomous answer")
            try Data().write(to: fixture.directory.appendingPathComponent("finish"))
        }
        try await wait { try stores.agentTurn(id: id)?.state != .running }
        let expected: AgentJournalState = scenario == "disconnect" ? .failed : (scenario == "interrupt" || scenario == "interruptThenWake") ? .interrupted : .completed
        #expect(try stores.agentTurn(id: id)?.state == expected)
        if expected == .completed {
            #expect(try await manager.state(chatID: chat.id).usage?.outputTokens == 7)
            try fixture.assertComplete()
        }
        #expect(try await manager.state(chatID: chat.id).entries.filter { $0.kind == "wakeup" }.count == 1)
        if scenario == "interruptThenWake" {
            try Data().write(to: fixture.directory.appendingPathComponent("next-wake"))
            try await wait { try await manager.state(chatID: chat.id).outcome == .completed }
            let later = try await manager.state(chatID: chat.id)
            #expect(later.entries.filter { $0.kind == "wakeup" }.count == 2)
            let nextID = try #require(later.entries.last { $0.kind == "wakeup" }?.id)
            #expect(try stores.agentTurn(id: nextID)?.state == .completed)
            #expect(later.entries.contains { $0.text == "Later check" })
            try fixture.assertComplete()
        }
        try await Task.sleep(for: .milliseconds(400))
        if scenario == "complete" || scenario == "followup" {
            try await wait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("closed").path) }
        }
        try await manager.shutdown()
    }

    @Test func codexUnsolicitedTurnAndDuplicateCompletion() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
while not os.path.exists('wake'): time.sleep(0.005)
emit({'method':'turn/started','params':{'threadId':'thread-test','turn':{'id':'autonomous'}}})
emit({'id':42,'method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'autonomous','itemId':'command','command':'echo example'}})
reply=read()
assert reply['id']==42 and reply['result']['decision']=='accept'
emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'autonomous','itemId':'answer','delta':'Background answer'}})
emit({'method':'item/completed','params':{'threadId':'thread-test','turnId':'autonomous','item':{'id':'answer','type':'agentMessage','text':'Background answer'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'autonomous','status':'completed'}}})
emit({'method':'turn/started','params':{'threadId':'thread-test','turn':{'id':'autonomous'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'autonomous','status':'completed'}}})
emit({'method':'account/rateLimits/updated','params':{}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try Data().write(to: fixture.directory.appendingPathComponent("wake"))
        var events: [AgentEvent] = []
        for try await event in run.events {
            events.append(event)
            if case .request(let request) = event.kind {
                try await run.respond(to: request, with: .allow(updatedInput: nil))
            }
            if case .rateLimits = event.kind { break }
        }
        let started = try #require(events.first { if case .autonomousTurnStarted = $0.kind { true } else { false } })
        #expect(started.scope.inputID != nil)
        let request = try #require(events.compactMap { if case .request(let request) = $0.kind { request } else { nil } }.first)
        #expect(request.scope.inputID == started.scope.inputID)
        #expect(events.contains { $0.kind == .textDelta("Background answer") && $0.scope.inputID == started.scope.inputID })
        #expect(events.filter { $0.kind == .turnEnded(.completed) }.count == 1)
        #expect(events.filter { if case .autonomousTurnStarted = $0.kind { true } else { false } }.count == 1)
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func resumeReplayDoesNotOpenTurn() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
while not os.path.exists('wake'): time.sleep(0.005)
emit({'type':'assistant','uuid':'old-answer','message':{'role':'assistant','content':[{'type':'text','text':'old'}]}})
emit({'type':'user','uuid':'old-injection','isReplay':True,'message':{'role':'user','content':'<task-notification>old</task-notification>'}})
emit({'type':'result','uuid':'old-result','is_error':False})
# A lifecycle inventory proves preceding replay frames were consumed.
emit({'type':'rate_limit_event','rate_limit_info':{}})
done()
"""#)
        defer { fixture.remove() }
        let nativeID = UUID().uuidString
        let project = fixture.directory.appendingPathComponent("projects/example")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        // Tool-only messages are absent from the text projection but still replay.
        let records: [JSONValue] = [.object(["type": .string("assistant"), "uuid": .string("old-answer"),
            "cwd": .string(fixture.directory.path), "sessionId": .string(nativeID),
            "message": .object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("tool_use"), "id": .string("old-tool"), "name": .string("Read"), "input": .object([:])])])])])]
        try (records.map(\.jsonString).joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent(nativeID + ".jsonl"), atomically: true, encoding: .utf8)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
            overrides: ["CLAUDE_CONFIG_DIR": fixture.directory.path])
        let config = AgentSessionConfiguration(directory: fixture.directory, resume: .init(provider: .claude, profile: "default", nativeID: nativeID), model: "test")
        let run = try await backend.start(config)
        try Data().write(to: fixture.directory.appendingPathComponent("wake"))
        for try await event in run.events {
            if case .autonomousTurnStarted = event.kind { Issue.record("Replay started autonomous work") }
            if case .rateLimits = event.kind { break }
        }
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: ["wakeup", "backgroundTask", "monitor", "scheduled", "unknown", "override", "requestFirst"])
    func claudeInfersReasonAndOpensOnRequest(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
scenario='\(scenario)'
tools={'wakeup':('ScheduleWakeup',{}),'backgroundTask':('Bash',{'run_in_background':True}),
       'monitor':('Monitor',{}),'scheduled':('CronCreate',{}),'override':('Monitor',{})}
if scenario in tools:
    name,args=tools[scenario]
    emit({'type':'assistant','uuid':'scheduled-answer','message':{'role':'assistant','content':[{'type':'tool_use','id':'schedule','name':name,'input':args}]}})
emit({'type':'result','uuid':'first','is_error':False})
while not os.path.exists('wake'): time.sleep(0.005)
if scenario=='override':
    emit({'type':'user','uuid':'reminder','message':{'role':'user','content':[{'type':'text','text':'<task-notification>finished</task-notification>'}]}})
if scenario=='requestFirst':
    emit({'type':'control_request','request_id':'first-request','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo example'}}})
    reply=read()
    assert reply['response']['response']['behavior']=='allow'
emit({'type':'assistant','uuid':'new-answer','message':{'role':'assistant','content':[{'type':'text','text':'Finished check'}]}})
emit({'type':'result','uuid':'second','is_error':False})
emit({'type':'rate_limit_event','rate_limit_info':{}})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "Schedule a check")) {}
        var starts: [AgentEvent] = [], requests: [AgentRequest] = [], completions = 0
        for try await event in run.events {
            switch event.kind {
            case .turnEnded:
                completions += 1
                if completions == 1 { try Data().write(to: fixture.directory.appendingPathComponent("wake")) }
            case .autonomousTurnStarted: starts.append(event)
            case .request(let request):
                requests.append(request)
                try await run.respond(to: request, with: .allow(updatedInput: nil))
            case .rateLimits: break
            default: continue
            }
            if case .rateLimits = event.kind { break }
        }
        let expected = scenario == "override" ? AgentAutonomousReason.backgroundTask
            : AgentAutonomousReason(rawValue: scenario) ?? .unknown
        #expect(starts.count == 1)
        let start = try #require(starts.first)
        #expect(start.kind == .autonomousTurnStarted(try #require(start.scope.inputID), expected))
        #expect(completions == 2)
        if scenario == "requestFirst" {
            #expect(requests.count == 1)
            #expect(requests.first?.scope.inputID == start.scope.inputID)
        }
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func autonomousUnreadReceiptTracksRunningAndTerminalStates() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let turn = AgentJournalTurn(autonomousID: UUID(), reason: .wakeup, chatID: chat.id, sessionID: session.id)
        try stores.prepareAgentTurn(turn)
        #expect(try stores.chatHasUnseenCompletion(chat.id))
        try stores.markChatSeen(chat.id)
        #expect(try !stores.chatHasUnseenCompletion(chat.id))
        try stores.finishAgentTurn(id: turn.id, state: .completed)
        #expect(try Stores(db: stores.db).chatHasUnseenCompletion(chat.id))
        try stores.markChatSeen(chat.id)
        #expect(try !stores.chatHasUnseenCompletion(chat.id))
    }

    @Test func migrationRetainsUserTurnAndFollowupReferences() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("turn-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let url = fixture.appendingPathComponent("fixture.sqlite")
        let rootID: UUID, childID: UUID, chatID: UUID, sessionID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, session) = try agentStoreChat(stores)
            chatID = chat.id; sessionID = session.id
            let root = AgentJournalTurn(input: .init(text: "Existing question"), chatID: chatID, sessionID: sessionID)
            rootID = root.id
            try stores.prepareAgentTurn(root)
            let child = AgentJournalTurn(input: .init(text: "Existing followup"), chatID: chatID, sessionID: sessionID, parentInputID: rootID)
            childID = child.id
            try stores.prepareAgentTurn(child)
            try stores.saveAgentPartial(id: rootID, text: "Retained answer")
            try stores.finishAgentTurn(id: rootID, state: .completed)
            try stores.finishAgentTurn(id: childID, state: .completed)
            // Restore the released table shape, preserving actual data and
            // letting the real migration recreate every index and trigger.
            try stores.db.queue.writeWithoutTransaction { db in
                // Match GRDB's deferred migration checks while rebuilding the
                // fixture's self-referencing table, then restore enforcement.
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
                try db.inTransaction {
                    try db.execute(sql: """
                    CREATE TABLE agentTurn_old (
                        id TEXT PRIMARY KEY NOT NULL,
                        chatID TEXT NOT NULL REFERENCES workspaceChat(id) ON DELETE RESTRICT,
                        sessionID TEXT NOT NULL REFERENCES agentChatSession(id) ON DELETE RESTRICT,
                        prompt TEXT NOT NULL, delivery TEXT NOT NULL, state TEXT NOT NULL,
                        resendCount INTEGER NOT NULL, partialOutput TEXT NOT NULL,
                        startedAt DATETIME NOT NULL, endedAt DATETIME,
                        parentInputID TEXT REFERENCES agentTurn(id) ON DELETE RESTRICT
                    );
                    INSERT INTO agentTurn_old SELECT id,chatID,sessionID,prompt,delivery,state,resendCount,
                        partialOutput,startedAt,endedAt,parentInputID FROM agentTurn;
                    DROP TABLE agentTurn;
                    ALTER TABLE agentTurn_old RENAME TO agentTurn;
                    DELETE FROM grdb_migrations WHERE identifier = 'v38-agent-autonomous-turns';
                    """)
                    return .commit
                }
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.agentTurn(id: rootID)?.origin == .user)
        #expect(try stores.agentTurn(id: rootID)?.prompt == "Existing question")
        #expect(try stores.agentTurn(id: rootID)?.partialOutput == "Retained answer")
        #expect(try stores.agentTurn(id: childID)?.parentInputID == rootID)
        let autonomous = AgentJournalTurn(autonomousID: UUID(), reason: .backgroundTask, chatID: chatID, sessionID: sessionID)
        try stores.prepareAgentTurn(autonomous)
        #expect(try stores.agentTurn(id: autonomous.id)?.prompt == nil)
        #expect(throws: (any Error).self) {
            try stores.prepareAgentTurn(.init(input: .init(text: "Conflicting root"), chatID: chatID, sessionID: sessionID))
        }
        try stores.db.queue.read { db in
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            #expect(violations.isEmpty)
        }
    }

    @Test(arguments: AgentAutonomousReason.allFixtureReasons)
    func journalRoundTripRecoveryAndNoResend(reason: AgentAutonomousReason) throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let turn = AgentJournalTurn(autonomousID: UUID(), reason: reason, chatID: chat.id, sessionID: session.id)
        try stores.prepareAgentTurn(turn)
        let saved = try #require(try stores.agentTurn(id: turn.id))
        #expect(saved.id == turn.id && saved.origin == turn.origin && saved.prompt == nil)
        #expect(saved.chatID == chat.id && saved.sessionID == session.id && saved.state == .running)
        try stores.saveAgentPartial(id: turn.id, text: "partial")
        try stores.recoverAgentTurns()
        #expect(try stores.agentTurn(id: turn.id)?.state == .interrupted)
        #expect(try stores.agentTurn(id: turn.id)?.origin == .autonomous(reason))
        #expect(try stores.agentTurn(id: turn.id)?.partialOutput == "partial")
        #expect(throws: AgentFailure.invalidTransition) { try stores.claimAgentResend(id: turn.id) }
        #expect(try stores.activityRun(id: turn.id)?.title == reason.activityTitle)
    }
}

private extension AgentAutonomousReason {
    static let allFixtureReasons: [Self] = [.wakeup, .backgroundTask, .monitor, .scheduled, .unknown]
}
private func wait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<500 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure.unknown
}
