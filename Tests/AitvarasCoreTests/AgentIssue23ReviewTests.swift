import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentIssue23ReviewTests {
    @Test func autonomousOfflineTurnEnablesAndContinuesTheOriginalSession() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[sys.argv.index('--resume')+1]=='original-session'
claude_init()
request=read()
assert request['message']['content']=='Continue where you stopped.'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'original-session'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, initial) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        var session = initial
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: "original-session")
        try stores.saveAgentSession(session)
        let turn = AgentJournalTurn(autonomousID: UUID(), reason: .wakeup, chatID: chat.id, sessionID: session.id)
        try stores.prepareAgentTurn(turn)
        var state = ChatState(chatID: chat.id)
        state.beginAutonomous(id: turn.id, reason: .wakeup, provider: .claude, sessionID: session.id)
        for entry in state.entries { _ = try stores.saveAgentEntry(entry) }
        let stop = try #require(try stores.finishAgentTurn(id: turn.id, state: .failed, stop: .failure(.offline)))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        #expect(try await manager.state(chatID: chat.id).canRecover(stop))
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.recover(chatID: chat.id, stoppedEntryID: stop.id, action: .retry) }
        try await manager.recover(chatID: chat.id, stoppedEntryID: stop.id, action: .continueTurn)
        try await waitAgentCondition { try await manager.state(chatID: chat.id).outcome == .completed }
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.sessionID == session.sessionID)
        #expect(try stores.agentTurn(id: turn.id)?.prompt == nil)
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "continued" }.count == 1)
        #expect(try await !manager.state(chatID: chat.id).canRecover(stop))
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test(arguments: ["claude-result", "claude-assistant", "codex"])
    func providerFailuresRemainRecoverableWithoutRawErrorText(scenario: String) async throws {
        let provider: AgentProvider = scenario == "codex" ? .codex : .claude
        let script = provider == .codex ? #"""
codex_init()
start_thread()
request=read()
emit({'id':request['id'],'result':{'turn':{'id':'failed-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'failed-turn','status':'failed','error':{'codexErrorInfo':'UNKNOWN_PROVIDER_CANARY'},'items':[]}}})
done()
"""# : """
claude_init()
read()
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'provider-session'})
emit({'type':'assistant','error':'UNKNOWN_PROVIDER_CANARY' if '\(scenario)'=='claude-assistant' else None,'message':{'role':'assistant','content':[{'type':'text','text':'Partial'}]}})
emit({'type':'result','is_error':True,'result':'RAW_PROVIDER_CANARY'})
done()
"""
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: provider)
        try await manager.send(chatID: chat, provider: provider, input: .init(text: "Example"))
        try await waitAgentCondition { try await manager.state(chatID: chat).currentStoppedTurn != nil }
        let stop = try #require(try await manager.state(chatID: chat).currentStoppedTurn)
        #expect(stop.reason.kind == .connection)
        #expect(stop.label() == "Connection lost")
        #expect(stop.actions == [.continueTurn])
        #expect(stop.reason.category.name == "AgentFailure.providerError")
        #expect(AgentFailure.sendMessage(for: AgentFailure.providerError, provider: provider)
            == "\(provider.rawValue.capitalized) could not complete the response. Try again.")
        #expect(AgentStopReason.failure(.unknown, category: AgentStoreError.identityConflict.safeErrorCategory).kind == .internalError)
        let audit = String(describing: try stores.recentActivity()) + (try stop.payload())
        #expect(!audit.contains("PROVIDER_CANARY"))
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test(arguments: ["entry", "session", "turn"])
    func repairReadsOnlyItsHistoricalColumns(record: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("migration.sqlite")
        let input = AgentInput(text: "Example")
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, session) = try agentStoreChat(stores, provider: .claude)
            try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
            _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: .claude, kind: "user",
                text: "Example", sessionID: session.id, nativeMessageID: UUID().uuidString))
            try stores.db.queue.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v39-repair-claude-user-identities"])
                // Stand in for an older schema without a field required by a
                // later version of each live record. The repair needs none.
                switch record {
                case "entry": try db.execute(sql: "ALTER TABLE agentTranscriptEntry DROP COLUMN text")
                case "session": try db.execute(sql: "ALTER TABLE agentChatSession DROP COLUMN model")
                default: try db.execute(sql: "ALTER TABLE agentTurn DROP COLUMN partialOutput")
                }
            }
        }
        let migrated = try AitvarasDatabase(url: url)
        try migrated.queue.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT nativeMessageID FROM agentTranscriptEntry WHERE id = ?", arguments: [input.id]))
            #expect(row["nativeMessageID"] == DatabaseValue.null)
        }
    }
}
