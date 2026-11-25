import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2)))
struct AgentStoppedTurnTests {
    @Test(arguments: [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged])
    func labelsActionsAndComposerFollowFailureAndDelivery(delivery: AgentDeliveryState) throws {
        let input = AgentInput(text: "Example")
        let session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "test")
        var turn = AgentJournalTurn(input: input, chatID: session.chatID, sessionID: session.id)
        turn.delivery = delivery
        let cases: [(AgentStopReason, String, AgentRecoveryAction?)] = [
            (.failure(.offline), "Connection lost", nil),
            (.failure(.providerError), "Connection lost", nil),
            (.failure(.crashed(exitCode: 7)), "Connection lost", nil),
            (.failure(.unknown, category: AgentProcessError.writeFailed.safeErrorCategory), "Connection lost", nil),
            (.failure(.quota(resetsAt: nil)), "Usage limit reached", nil),
            (.failure(.quota(resetsAt: Date(timeIntervalSince1970: 1800))), "Usage limit reached · resets at 00:30", nil),
            (.failure(.authRequired), "Sign in", .signIn),
            (.failure(.unknown), "Aitvaras error · AgentFailure.unknown", .copyDetails),
            (.failure(.invalidTransition), "Aitvaras error · AgentFailure.invalidTransition", .copyDetails),
            (.failure(.unknown, category: AgentStoreError.identityConflict.safeErrorCategory), "Aitvaras error · AgentStoreError.identityConflict", .copyDetails),
            (.failure(.unknown, category: AgentNativeHistoryError.malformedHistory.safeErrorCategory), "Aitvaras error · AgentNativeHistoryError.malformedHistory", .copyDetails),
            (.interrupted, "Stopped", nil)
        ]
        for (reason, label, action) in cases {
            var stop = AgentStoppedTurn(turn: turn, session: session, reason: reason)
            #expect(stop.label(timeZone: TimeZone(secondsFromGMT: 0)!) == label)
            #expect(stop.actions == [action ?? (delivery == .acknowledged ? .continueTurn : .retry)])
            let row = AgentTranscriptEntry(chatID: session.chatID, provider: .claude, kind: "stopped", payloadJSON: try stop.payload())
            #expect(row.stoppedTurn == stop)
            var state = ChatState(chatID: session.chatID, entries: [row])
            turn.state = .failed; state.restore(turn: turn)
            #expect(state.showsComposerFailure == (reason.kind != .interrupted && delivery == .prepared))
            stop.recoveryInputID = UUID()
            #expect(stop.actions == (reason.kind == .internalError ? [.copyDetails] : []))
        }
    }

    /// CLI-started turns carry no user prompt: never offer Retry or a composer error.
    @Test(arguments: [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged])
    func autonomousTurnsOfferOnlyContinue(delivery: AgentDeliveryState) throws {
        let session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "test")
        var turn = AgentJournalTurn(autonomousID: UUID(), reason: .backgroundTask, chatID: session.chatID, sessionID: session.id)
        turn.delivery = delivery
        let stop = AgentStoppedTurn(turn: turn, session: session, reason: .failure(.offline))
        #expect(stop.autonomous == true)
        #expect(stop.actions == [.continueTurn])
        #expect(AgentStoppedTurn(turn: turn, session: session, reason: .failure(.unknown)).actions == [.copyDetails])
        let row = AgentTranscriptEntry(chatID: session.chatID, provider: .claude, kind: "stopped", payloadJSON: try stop.payload())
        var state = ChatState(chatID: session.chatID, entries: [row])
        turn.state = .failed; state.restore(turn: turn)
        #expect(!state.showsComposerFailure)
        let user = AgentStoppedTurn(turn: AgentJournalTurn(input: .init(text: "Example"), chatID: session.chatID, sessionID: session.id),
                                    session: session, reason: .failure(.offline))
        #expect(user.autonomous == nil)
    }

    @Test func stoppedRowAndJournalCommitTogetherAndSurviveReopening() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stopped-" + UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = AgentInput(text: "Example")
        let chat: UUID
        let stoppedID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (record, session) = try agentStoreChat(stores, provider: .claude)
            chat = record.id
            try stores.prepareAgentTurn(.init(input: input, chatID: chat, sessionID: session.id))
            _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat, provider: .claude, kind: "user", text: input.text, sessionID: session.id))
            try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
            try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
            try stores.saveAgentPartial(id: input.id, text: "Partial answer")
            try stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER testStoppedInsert BEFORE INSERT ON agentTranscriptEntry WHEN NEW.kind = 'stopped' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
            #expect(throws: (any Error).self) {
                try stores.finishAgentTurn(id: input.id, state: .failed, stop: .failure(.quota(resetsAt: Date(timeIntervalSince1970: 1800))))
            }
            #expect(try stores.agentTurn(id: input.id)?.state == .running)
            #expect(try stores.agentEntries(chatID: chat).count == 1)
            try stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testStoppedInsert") }
            let row = try #require(try stores.finishAgentTurn(id: input.id, state: .failed,
                stop: .failure(.quota(resetsAt: Date(timeIntervalSince1970: 1800)))))
            stoppedID = row.id
            #expect(try stores.finishAgentTurn(id: input.id, state: .failed, stop: .failure(.offline))?.id == row.id)
        }
        for _ in 0..<2 {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let manager = try AgentSessionManager(persistence: stores, backend: { _ in throw AgentFailure.unsupported }, audit: { _ in })
            #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "stopped" }.map(\.id) == [stoppedID])
            #expect(try stores.agentTurn(id: input.id)?.partialOutput == "Partial answer")
            #expect(try stores.agentEntries(chatID: chat).last?.stoppedTurn?.reason.resetsAt == Date(timeIntervalSince1970: 1800))
            _ = manager
        }
    }

    @Test(arguments: [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged])
    func startupRecoveryCreatesOneRowAndSendsNothing(delivery: AgentDeliveryState) async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores, provider: .claude)
        let input = AgentInput(text: "Unfinished input")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: .claude, kind: "user", text: input.text, sessionID: session.id))
        if delivery != .prepared { try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
        if delivery == .acknowledged { try stores.advanceAgentDelivery(id: input.id, to: .acknowledged) }
        for _ in 0..<2 {
            let manager = try AgentSessionManager(persistence: stores, backend: { _ in Issue.record("Recovery must not start a backend"); throw AgentFailure.unsupported }, audit: { _ in })
            let state = try await manager.state(chatID: chat.id)
            #expect(state.entries.filter { $0.kind == "stopped" }.count == 1)
            #expect(state.currentStoppedTurn?.delivery == delivery)
            #expect(state.currentStoppedTurn?.reason.kind == .connection)
            #expect(!state.isRunning)
            try await manager.shutdown()
        }
    }

    @Test func continueResumesExactSessionOnceAndReconcilesAsAMarker() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
request=read()
if '--resume' not in sys.argv:
    emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'recovery-session'})
    emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
    sys.exit(7)
assert sys.argv[sys.argv.index('--resume')+1]=='recovery-session'
assert request['message']['content']=='Continue where you stopped.'
with open('recoveries','a') as log: log.write('continue\n')
emit({'type':'user','uuid':request['uuid'],'message':{'role':'user','content':[{'type':'text','text':request['message']['content']}]}})
emit({'type':'assistant','uuid':'recovery-answer','message':{'role':'assistant','content':[{'type':'text','text':'resumed'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let input = AgentInput(text: "Start")
        try await manager.send(chatID: chat, provider: .claude, input: input)
        try await waitAgentCondition { try await manager.state(chatID: chat).currentStoppedTurn != nil }
        let stopped = try #require(try stores.agentEntries(chatID: chat).last { $0.kind == "stopped" })
        #expect(stopped.stoppedTurn?.actions == [.continueTurn])
        let clicks = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await manager.recover(chatID: chat, stoppedEntryID: stopped.id, action: .continueTurn); return true }
                    catch { return false }
                }
            }
            var results: [Bool] = []; for await result in group { results.append(result) }; return results
        }
        #expect(clicks.filter { $0 }.count == 1)
        try await waitAgentCondition { try await manager.state(chatID: chat).outcome == .completed }
        let entries = try stores.agentEntries(chatID: chat)
        let continued = try #require(entries.first { $0.kind == "continued" })
        #expect(entries.filter { $0.kind == "user" }.map(\.text) == [input.text])
        #expect(try stores.agentTurn(id: continued.id)?.prompt == AgentStoppedTurn.continuationText)
        #expect(entries.first { $0.id == stopped.id }?.stoppedTurn?.recoveryInputID == continued.id)
        await #expect(throws: AgentFailure.invalidTransition) {
            try await manager.recover(chatID: chat, stoppedEntryID: stopped.id, action: .continueTurn)
        }
        try fixture.assertComplete()
        #expect(try String(contentsOf: fixture.directory.appendingPathComponent("recoveries"), encoding: .utf8) == "continue\n")
        try await manager.shutdown()
        let session = try #require(try stores.agentSession(chatID: chat, provider: .claude))
        func canonical(_ id: UUID, native: String, role: String, text: String) -> AgentTranscriptEntry {
            .init(id: id, chatID: chat, provider: .claude, kind: role, text: text,
                payloadJSON: JSONValue.object(["nativeHistory": .object(["itemID": .string(native), "completed": .bool(true)])]).jsonString,
                sessionID: session.id, nativeMessageID: native)
        }
        let history = [canonical(UUID(), native: input.id.uuidString, role: "user", text: input.text),
            canonical(UUID(), native: continued.id.uuidString, role: "user", text: AgentStoppedTurn.continuationText),
            canonical(UUID(), native: "recovery-answer", role: "assistant", text: "resumed")]
        for _ in 0..<2 { try stores.reconcileAgentHistory(session: session, entries: history) }
        let refreshed = try stores.agentEntries(chatID: chat)
        #expect(refreshed.filter { $0.kind == "continued" }.map(\.id) == [continued.id])
        #expect(refreshed.filter { $0.kind == "user" }.map(\.text) == [input.text])
        #expect(refreshed.filter { $0.kind == "stopped" }.count == 1)
    }

    @Test(arguments: [AgentDeliveryState.prepared, .deliveryUnknown])
    func explicitRetryRestoresWireAndAttachmentBytes(delivery: AgentDeliveryState) async throws {
        let attachment = try AgentAttachment(name: "example.txt", data: Data("Selected bytes".utf8))
        let input = AgentInput(text: "Original input", attachments: [attachment])
        let earlier = AgentTranscriptEntry(chatID: UUID(), provider: .local, kind: "assistant", text: "Earlier answer")
        let context = try #require(ChatContextProjection.make(entries: [earlier], provider: .claude))
        let wire = context.wire(message: input.text)
        let expected = try AgentInput(text: wire, attachments: [attachment]).claudeContent().jsonString
        let encoded = Data(expected.utf8).base64EncodedString()
        let fixture = try BackendExecutableFixture(script: """
claude_init()
assert sys.argv[sys.argv.index('--resume')+1]=='retry-session'
request=read()
assert request['message']['content']==json.loads(base64.b64decode('\(encoded)'))
with open('recoveries','a') as log: log.write('retry\\n')
emit({'type':'assistant','uuid':'retry-answer','message':{'role':'assistant','content':[{'type':'text','text':'retried'}]}})
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, initial) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        var session = initial; session.sessionID = .init(provider: .claude, profile: "default", nativeID: "retry-session")
        try stores.saveAgentSession(session)
        let stopped = try seedStopped(stores, session: session, input: input, delivery: delivery,
            reason: .failure(.offline), wire: wire, context: context)
        // A provider switch must not redirect this recovery into another session.
        try stores.saveProviderProfile(.init(id: AgentProviderProfile.defaultCodexID, name: "Codex", kind: .codex))
        try stores.selectAgentChoice(.init(provider: .codex), chatID: chat.id)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { provider in
            #expect(provider == .claude); return backend
        }, audit: { _ = try stores.record($0) })
        try await manager.recover(chatID: chat.id, stoppedEntryID: stopped.id, action: .retry)
        try await waitAgentCondition { try await manager.state(chatID: chat.id).outcome == .completed }
        let entries = try stores.agentEntries(chatID: chat.id)
        let retried = try #require(entries.last { $0.kind == "user" })
        #expect(retried.id != input.id)
        #expect(retried.text == input.text)
        #expect(try AgentInput.restoring(id: retried.id, text: retried.text, payload: retried.payloadJSON).attachments == [attachment])
        #expect(try stores.agentTurn(id: input.id)?.delivery == delivery)
        #expect(try stores.agentTurn(id: retried.id)?.prompt == wire)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.recover(chatID: chat.id, stoppedEntryID: stopped.id, action: .retry) }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func recoveryPreparationRollsBackClaimAndNeverWritesToProvider() async throws {
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores, provider: .claude)
        let row = try seedStopped(stores, session: session, input: .init(text: "Example"), delivery: .deliveryUnknown, reason: .failure(.offline))
        try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER testRecoveryInsert BEFORE INSERT ON agentTurn BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in Issue.record("Failed claim reached provider"); throw AgentFailure.unsupported }, audit: { _ in })
        await #expect(throws: (any Error).self) { try await manager.recover(chatID: session.chatID, stoppedEntryID: row.id, action: .retry) }
        #expect(try stores.agentEntries(chatID: session.chatID).first { $0.id == row.id }?.stoppedTurn?.recoveryInputID == nil)
        #expect(try await stores.db.queue.read { try AgentJournalTurn.fetchCount($0) } == 1)
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testRecoveryInsert") }
        try await manager.shutdown()
    }

    @Test func internalStopsAlsoRefuseTheLegacyPreparedResend() throws {
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores, provider: .claude)
        let input = AgentInput(text: "Example")
        _ = try seedStopped(stores, session: session, input: input, delivery: .prepared, reason: .failure(.unknown))
        #expect(throws: AgentFailure.invalidTransition) { try stores.claimAgentResend(id: input.id) }
        #expect(try stores.agentTurn(id: input.id)?.state == .failed)
        #expect(try stores.agentTurn(id: input.id)?.resendCount == 0)
    }

    @Test func failedStoppedWriteRemainsVisibleWithoutAComposerErrorOrRecovery() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .local)
        let backend = LocalBackend { _, _ in throw AgentFailure.offline }
        try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER testStoppedWrite BEFORE INSERT ON agentTranscriptEntry WHEN NEW.kind = 'stopped' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat.id, provider: .local, input: .init(text: "Example"))
        try await waitAgentCondition { try await !manager.state(chatID: chat.id).isRunning }
        let state = try await manager.state(chatID: chat.id)
        #expect(state.currentStoppedTurn?.reason.kind == .internalError)
        #expect(state.currentStoppedTurn?.actions == [.copyDetails])
        #expect(!state.showsComposerFailure)
        #expect(try stores.agentEntries(chatID: chat.id).allSatisfy { $0.kind != "stopped" })
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testStoppedWrite") }
        try await manager.shutdown()
    }

    @Test func persistenceErrorAfterCoalescedCompletionStillPersistsAnInternalStop() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'partial'}}})
read()
while not os.path.exists('release'): time.sleep(0.01)
emit({'type':'assistant','uuid':'coalesced-answer','message':{'role':'assistant','content':[{'type':'text','text':'combined'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let first = AgentInput(text: "First"), second = AgentInput(text: "Second")
        try await manager.send(chatID: chat, provider: .claude, input: first)
        try await waitAgentCondition { try stores.agentTurn(id: first.id)?.delivery == .acknowledged }
        try await manager.send(chatID: chat, provider: .claude, input: second)
        try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER testReorder BEFORE UPDATE OF position ON agentTranscriptEntry WHEN NEW.position != OLD.position BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END") }
        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        try await waitAgentCondition {
            try stores.recentActivity(limit: 20).contains { $0.kind == .agentFailure }
        }
        let stop = try #require(try stores.agentEntries(chatID: chat).last { $0.kind == "stopped" }?.stoppedTurn)
        #expect(stop.reason.kind == .internalError)
        #expect(stop.actions == [.copyDetails])
        #expect(stop.reason.category.type == "DatabaseError")
        #expect(try stores.agentTurn(id: first.id)?.state == .completed)
        #expect(try stores.agentTurn(id: second.id)?.state == .completed)
        try await stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testReorder") }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test(arguments: ["missing-native", "empty-native", "changed-native", "internal", "acknowledged-retry", "bogus-row", "stale-row"])
    func unsafeOrStaleRecoveryNeverStartsAProvider(scenario: String) async throws {
        let stores = try inMemoryStores()
        let (chat, initial) = try agentStoreChat(stores, provider: .claude)
        var session = initial
        if scenario != "missing-native" {
            session.sessionID = .init(provider: .claude, profile: "default", nativeID: scenario == "empty-native" ? "" : "original-session")
        }
        try stores.saveAgentSession(session)
        let stopped = try seedStopped(stores, session: session, input: .init(text: "Example"), delivery: .acknowledged,
            reason: scenario == "internal" ? .failure(.unknown) : .failure(.offline))
        if scenario == "changed-native" {
            session.sessionID = .init(provider: .claude, profile: "default", nativeID: "different-session")
            try stores.saveAgentSession(session)
        }
        if scenario == "stale-row" {
            let next = AgentInput(text: "Later input")
            try stores.prepareAgentTurn(.init(input: next, chatID: chat.id, sessionID: session.id))
            try stores.finishAgentTurn(id: next.id, state: .completed)
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in Issue.record("Unsafe recovery started a provider"); throw AgentFailure.unsupported }, audit: { _ in })
        await #expect(throws: AgentFailure.invalidTransition) {
            try await manager.recover(chatID: chat.id, stoppedEntryID: scenario == "bogus-row" ? UUID() : stopped.id,
                action: scenario == "acknowledged-retry" ? .retry : .continueTurn)
        }
        #expect(try stores.agentEntries(chatID: chat.id).first { $0.id == stopped.id }?.stoppedTurn?.recoveryInputID == nil)
        try await manager.shutdown()
    }

    @Test func continueRejectsADifferentAuthoritativeInitSession() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[sys.argv.index('--resume')+1]=='original-session'
claude_init()
request=read()
assert request['message']['content']=='Continue where you stopped.'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'different-session'})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, initial) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        var session = initial
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: "original-session")
        try stores.saveAgentSession(session)
        let stopped = try seedStopped(stores, session: session, input: .init(text: "Example"),
            delivery: .acknowledged, reason: .failure(.offline))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.recover(chatID: chat.id, stoppedEntryID: stopped.id, action: .continueTurn)
        try await waitAgentCondition { try await manager.state(chatID: chat.id).currentStoppedTurn?.reason.kind == .internalError }
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.sessionID == session.sessionID)
        #expect(try await manager.state(chatID: chat.id).currentStoppedTurn?.reason.category.name == "AgentFailure.invalidTransition")
        try await manager.shutdown()
    }

    @Test func quotaResetIsPersistedAndOnlyAnExplicitClickContinues() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'quota-session'})
emit({'type':'rate_limit_event','rate_limit_info':{'status':'rejected','resetsAt':1800}})
emit({'type':'assistant','uuid':'quota-message','error':'rate_limit','message':{'role':'assistant','content':[{'type':'text','text':'Usage limited'}]}})
emit({'type':'result','is_error':True})
request=read()
assert request['message']['content']=='Continue where you stopped.'
emit({'type':'assistant','uuid':'quota-answer','message':{'role':'assistant','content':[{'type':'text','text':'continued manually'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .claude)
        let input = AgentInput(text: "Example")
        try await manager.send(chatID: chat, provider: .claude, input: input)
        try await waitAgentCondition { try await manager.state(chatID: chat).currentStoppedTurn != nil }
        let row = try #require(try stores.agentEntries(chatID: chat).last { $0.kind == "stopped" })
        #expect(row.stoppedTurn?.label(timeZone: TimeZone(secondsFromGMT: 0)!) == "Usage limit reached · resets at 00:30")
        #expect(try stores.latestAgentTurn(chatID: chat)?.id == input.id)
        #expect(row.stoppedTurn?.recoveryInputID == nil)
        try await manager.recover(chatID: chat, stoppedEntryID: row.id, action: .continueTurn)
        try await waitAgentCondition { try await manager.state(chatID: chat).outcome == .completed }
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "continued" }.count == 1)
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func codexContinueUsesTheOriginalThread() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
request=read(); assert request['method']=='account/read'; account(request)
request=read()
resuming=request['method']=='thread/resume'
if resuming: assert request['params']['threadId']=='thread-test'
else: assert request['method']=='thread/start'
emit({'id':request['id'],'result':{'thread':{'id':'thread-test','modelProvider':'openai'}}})
request=read(); assert request['method']=='turn/start'
if resuming: assert request['params']['input']==[{'type':'text','text':'Continue where you stopped.'}]
emit({'id':request['id'],'result':{'turn':{'id':'resumed-turn' if resuming else 'first-turn'}}})
if not resuming:
    emit({'method':'item/agentMessage/delta','params':{'threadId':'thread-test','turnId':'first-turn','itemId':'reply','delta':'partial'}})
    sys.exit(7)
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'resumed-turn','status':'completed','items':[{'id':'answer','type':'agentMessage','text':'resumed'}]}}})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        try await manager.send(chatID: chat, provider: .codex, input: .init(text: "Start"))
        try await waitAgentCondition { try await manager.state(chatID: chat).currentStoppedTurn != nil }
        let row = try #require(try stores.agentEntries(chatID: chat).last { $0.kind == "stopped" })
        #expect(row.stoppedTurn?.actions == [.continueTurn])
        try await manager.recover(chatID: chat, stoppedEntryID: row.id, action: .continueTurn)
        try await waitAgentCondition { try await manager.state(chatID: chat).outcome == .completed }
        #expect(try stores.agentEntries(chatID: chat).filter { $0.kind == "continued" }.count == 1)
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func codexStructuredQuotaFailureRetainsResetTime() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
request=read()
emit({'id':request['id'],'result':{'turn':{'id':'quota-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'quota-turn','status':'failed','items':[],'error':{'codexErrorInfo':'usageLimitExceeded','resetsAt':1800}}}})
done()
"""#)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: .codex)
        try await manager.send(chatID: chat, provider: .codex, input: .init(text: "Example"))
        try await waitAgentCondition { try await manager.state(chatID: chat).currentStoppedTurn != nil }
        let stop = try #require(try stores.agentEntries(chatID: chat).last?.stoppedTurn)
        #expect(stop.label(timeZone: TimeZone(secondsFromGMT: 0)!) == "Usage limit reached · resets at 00:30")
        #expect(stop.actions == [.continueTurn])
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func existingSignInResendResolvesItsRowAndReopensCompleted() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
assert read()['message']['content']=='Saved input'
emit({'type':'assistant','uuid':'signed-in-answer','message':{'role':'assistant','content':[{'type':'text','text':'signed in'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (_, session) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        let input = AgentInput(text: "Saved input")
        let row = try seedStopped(stores, session: session, input: input, delivery: .prepared, reason: .failure(.authRequired))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        try await manager.resendPrepared(turnID: input.id)
        try await waitAgentCondition { try await manager.state(chatID: session.chatID).outcome == .completed }
        #expect(try stores.agentEntries(chatID: session.chatID).first { $0.id == row.id }?.stoppedTurn?.actions == [])
        try fixture.assertComplete()
        try await manager.shutdown()
        let reopened = try AgentSessionManager(persistence: stores, backend: { _ in throw AgentFailure.unsupported }, audit: { _ in })
        #expect(try await reopened.state(chatID: session.chatID).outcome == .completed)
        try await reopened.shutdown()
    }

    @Test func inheritedContinuedMarkerSurvivesForkHistoryRefresh() throws {
        let stores = try inMemoryStores()
        let (chat, initial) = try agentStoreChat(stores, provider: .claude)
        var session = initial
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
        try stores.saveAgentSession(session)
        let input = AgentInput(text: AgentStoppedTurn.continuationText)
        let answer = UUID().uuidString
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
        _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: .claude, kind: "continued",
            text: input.text, sessionID: session.id, nativeMessageID: input.id.uuidString))
        let reply = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant",
            text: "Answer", sessionID: session.id, nativeMessageID: answer))
        try stores.finishAgentTurn(id: input.id, state: .completed)
        let source = try stores.conversationSource(chatID: chat.id)
        let plan = try AgentConversationForkPlan.make(source: source, messageID: reply.id, editing: false)
        let forkID = UUID()
        try stores.createConversationFork(plan, chatID: forkID, directory: URL(fileURLWithPath: "/tmp"), additionalRoots: [])
        var fork = try #require(try stores.agentSession(chatID: forkID, provider: .claude))
        fork.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
        fork.forkOrigin?.pending = false
        try stores.saveAgentSession(fork)
        let history = [(input.id.uuidString, "user", input.text), (answer, "assistant", "Answer")].map { id, kind, text in
            AgentTranscriptEntry(chatID: forkID, provider: .claude, kind: kind, text: text,
                payloadJSON: JSONValue.object(["nativeHistory": .object(["itemID": .string(id), "completed": .bool(true)])]).jsonString,
                sessionID: fork.id, nativeMessageID: id)
        }
        try stores.reconcileAgentHistory(session: fork, entries: history)
        #expect(try stores.agentEntries(chatID: forkID).filter { $0.kind == "continued" }.count == 1)
        #expect(try stores.agentEntries(chatID: forkID).allSatisfy { $0.kind != "user" })
    }
}

private func seedStopped(_ stores: Stores, session: AgentChatSession, input: AgentInput, delivery: AgentDeliveryState,
                         reason: AgentStopReason, wire: String? = nil, context: ChatContextProjection? = nil) throws -> AgentTranscriptEntry {
    let sent = AgentInput(id: input.id, text: wire ?? input.text, attachments: input.attachments)
    try stores.prepareAgentTurn(.init(input: sent, chatID: session.chatID, sessionID: session.id), context: context)
    _ = try stores.saveAgentEntry(.init(id: input.id, chatID: session.chatID, provider: session.provider, kind: "user", text: input.text,
        payloadJSON: input.composerPayload(), sessionID: session.id))
    if delivery != .prepared { try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
    if delivery == .acknowledged { try stores.advanceAgentDelivery(id: input.id, to: .acknowledged) }
    return try #require(try stores.finishAgentTurn(id: input.id, state: .failed, stop: reason))
}
