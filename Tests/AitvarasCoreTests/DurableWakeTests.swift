import Foundation
import Testing
import GRDB
import AitvarasCore
@testable import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct DurableWakeTests {
    @Test func claimsOnceGraceCronAndArchive() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let now = Date.now
        var wake = AgentPendingWake(chatID: chat.id, sessionID: session.id, kind: .wakeup,
            fireAt: now.addingTimeInterval(-119), prompt: "Check progress", nativeToolID: "wake", transportID: UUID())
        try stores.saveAgentWake(wake)
        #expect(try stores.claimAgentWake(id: wake.id, now: now) == nil)
        let claimID = wake.id
        let count = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<2 { group.addTask { try stores.claimAgentWake(id: claimID, now: now.addingTimeInterval(2)) == nil ? 0 : 1 } }
            var total = 0; for try await n in group { total += n }; return total
        }
        #expect(count == 1)
        // A crash before preparing a turn releases the claim; unknown delivery does not.
        try stores.releaseAgentWakeTransport(nil)
        #expect(try stores.pendingAgentWakes().first?.claimedAt == nil)
        let claimed = try #require(try stores.claimAgentWake(id: wake.id, now: now))
        var turn = AgentJournalTurn(autonomousID: try #require(claimed.claimedTurnID), reason: .wakeup,
            chatID: chat.id, sessionID: session.id)
        turn.autonomousPrompt = "Scheduled check"
        try stores.prepareAgentTurn(turn)
        try stores.advanceAgentDelivery(id: turn.id, to: .deliveryUnknown)
        try stores.finishAgentTurn(id: turn.id, state: .interrupted)
        try stores.releaseAgentWakeTransport(nil)
        #expect(try stores.pendingAgentWakes().isEmpty)
        wake = .init(chatID: chat.id, sessionID: session.id, kind: .cron,
            fireAt: now.addingTimeInterval(-180), cronSpec: "* * * * *", prompt: "Check once", nativeToolID: "cron")
        try stores.saveAgentWake(wake)
        #expect(try stores.claimAgentWake(id: wake.id, now: now) != nil)
        try stores.finishAgentWake(id: wake.id, now: now)
        let next = try #require(try stores.pendingAgentWakes().first)
        #expect(try #require(next.fireAt) > now)
        #expect(try #require(next.fireAt).timeIntervalSince(now) <= 60)
        #expect(try stores.claimAgentWake(id: wake.id, now: now) == nil)
        try stores.archiveAgentChat(chatID: chat.id, archived: true)
        #expect(try stores.pendingAgentWakes().isEmpty)
        #expect(try await stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func schedulerPauseBusyConcurrentAndAutonomousInput(provider: AgentProvider) async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores, provider: provider)
        let backend = WakeTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let wake = AgentPendingWake(chatID: chat.id, sessionID: session.id, kind: .wakeup,
            fireAt: .now.addingTimeInterval(-180), prompt: "Check progress", nativeToolID: "wake")
        try stores.saveAgentWake(wake)
        try await manager.runDueWakeups(permitted: false)
        #expect(await backend.runs.isEmpty)
        let manual = AgentInput(text: "Still busy")
        try await manager.send(chatID: chat.id, provider: provider, input: manual)
        try await manager.runDueWakeups(permitted: true)
        #expect(try stores.pendingAgentWakes().first?.claimedAt == nil)
        let run = try #require(await backend.runs.first)
        await run.emit(.turnEnded(.completed), input: manual.id)
        try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        async let one: Void = manager.runDueWakeups(permitted: true)
        async let two: Void = manager.runDueWakeups(permitted: true)
        _ = try await (one, two)
        let inputs = await run.inputs
        #expect(inputs.count == 2)
        let input = try #require(inputs.last)
        #expect(input.text.contains("Scheduled wake-up (was due"))
        #expect(input.text.contains("Check progress"))
        #expect(try stores.agentTurn(id: input.id)?.origin == .autonomous(.wakeup))
        #expect(try stores.agentTurn(id: input.id)?.autonomousPrompt == input.text)
        #expect(try stores.activityRun(id: input.id)?.title == "Chat woke up (late)")
        let state = try await manager.state(chatID: chat.id)
        #expect(state.entries.filter { $0.kind == "user" }.count == 1)
        #expect(state.entries.filter { $0.kind == "wakeup" }.count == 1)
        #expect(try stores.pendingAgentWakes().isEmpty)
        try await manager.shutdown()
    }

    @Test func liveClearIdleHoldTransportTransferAndGrace() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores)
        let backend = WakeTestBackend()
        let manager = try AgentSessionManager(persistence: stores, idleTimeout: .milliseconds(40), backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "Schedule")
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        let run = try #require(await backend.runs.first)
        await run.tool("wake", name: "ScheduleWakeup", input: .object(["delaySeconds": .number(0), "prompt": .string("Check")]), turn: input.id)
        await run.emit(.turnEnded(.completed), input: input.id)
        try await wakeWait {
            let completed = try await manager.state(chatID: chat.id).outcome == .completed
            return try stores.pendingAgentWakes().count == 1 && completed
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !run.closed)
        try await manager.runDueWakeups(permitted: true)
        #expect(await run.inputs.count == 1)
        let autonomousID = UUID()
        await run.emit(.autonomousTurnStarted(autonomousID, .wakeup), input: autonomousID)
        await run.emit(.turnEnded(.completed), input: autonomousID)
        try await wakeWait { try stores.pendingAgentWakes().isEmpty }
        try await manager.runDueWakeups(permitted: true)
        #expect(await run.inputs.count == 1)
        try await manager.shutdown()

        // A second generation owns a pending timer until disposal or grace.
        let another = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let second = AgentInput(text: "Schedule again")
        try await another.send(chatID: chat.id, provider: .claude, input: second)
        let laterRun = try #require(await backend.runs.last)
        await laterRun.tool("later", name: "ScheduleWakeup", input: .object(["delaySeconds": .number(0), "prompt": .string("Later")]), turn: second.id)
        await laterRun.emit(.turnEnded(.completed), input: second.id)
        try await wakeWait {
            let completed = try await another.state(chatID: chat.id).outcome == .completed
            return try stores.pendingAgentWakes().count == 1 && completed
        }
        try await another.runDueWakeups(now: .now.addingTimeInterval(121), permitted: true)
        #expect(await laterRun.closed)
        #expect(await backend.runs.count == 3)
        #expect(try stores.pendingAgentWakes().isEmpty)
        try await another.shutdown()
    }

    @Test func capEvictsLatestFire() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let chats = try (0..<9).map { _ in try agentStoreChat(stores).0 }
        for (i, chat) in chats.prefix(8).enumerated() {
            let input = AgentInput(text: "Schedule")
            try await manager.send(chatID: chat.id, provider: .claude, input: input)
            let run = try #require(await backend.runs.last)
            await run.tool("timer", name: "ScheduleWakeup", input: .object(["delaySeconds": .number(Double((i + 1) * 1000)), "prompt": .string("Check")]), turn: input.id)
            await run.emit(.turnEnded(.completed), input: input.id)
            try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        }
        let runs = await backend.runs
        try await manager.send(chatID: chats[8].id, provider: .claude, input: .init(text: "New"))
        #expect(await runs[7].closed)
        #expect(await !runs[0].closed)
        #expect(try stores.pendingAgentWakes(chatID: chats[7].id).first?.transportID == nil)
        try await manager.shutdown()
        #expect(try stores.pendingAgentWakes().count == 8)
        #expect(try stores.pendingAgentWakes().allSatisfy { $0.transportID == nil })
    }

    @Test func taskCompletionWithoutAssistantTurnRearmsIdleEviction() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let (chat, _) = try agentStoreChat(stores)
        let manager = try AgentSessionManager(persistence: stores, idleTimeout: .milliseconds(40), backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "Start task")
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        let run = try #require(await backend.runs.first)
        await run.tool("task", name: "Bash", input: .object(["run_in_background": .bool(true)]), turn: input.id,
            output: .object(["task_id": .string("task-native")]))
        await run.emit(.turnEnded(.completed), input: input.id)
        try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !run.closed)
        await run.emit(.unknown(name: "backgroundTaskFinished", payload: .string("task-native")), input: nil)
        try await wakeWait { await run.closed }
        #expect(try stores.pendingAgentWakes().isEmpty)
        try await manager.shutdown()
    }

    @Test func cronValidationAndBoundedPrompt() throws {
        let now = Date.now
        for spec in ["bad", "60 * * * *", "*/0 * * * *", "* * * * 8", "* * * *"] {
            #expect(AgentWakeCron.next(spec, after: now) == nil)
        }
        #expect(AgentWakeCron.next("*/5 0-23 * * 0,7", after: now) != nil)
        let wake = AgentPendingWake(chatID: UUID(), sessionID: UUID(), kind: .wakeup,
            prompt: String(repeating: "x", count: 20_000), nativeToolID: "bounded")
        #expect(wake.prompt?.count == 16_384)
    }

    @Test func undatedBackgroundTaskRoundTrip() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let wake = AgentPendingWake(chatID: chat.id, sessionID: session.id,
            kind: .backgroundTask, nativeToolID: "task-native", transportID: UUID())
        try stores.saveAgentWake(wake)
        #expect(try stores.pendingAgentWakes().first?.id == wake.id)
        #expect(try stores.pendingAgentWakes().first?.fireAt == nil)
    }

    @Test func unavailableChatDoesNotStarveOtherDueChats() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let (offline, offlineSession) = try agentStoreChat(stores, cwd: "/tmp/unavailable-project")
        let (ready, readySession) = try agentStoreChat(stores, cwd: "/tmp/ready-project")
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        await backend.setUnavailableDirectory(offlineSession.cwd)
        for (chat, session) in [(offline, offlineSession), (ready, readySession)] {
            try stores.saveAgentWake(.init(chatID: chat.id, sessionID: session.id, kind: .wakeup,
                fireAt: .now.addingTimeInterval(-10), prompt: "Check", nativeToolID: "wake"))
        }
        await #expect(throws: AgentFailure.offline) { try await manager.runDueWakeups(permitted: true) }
        #expect(try stores.pendingAgentWakes().map(\.chatID) == [offline.id])
        #expect(try stores.pendingAgentWakes().first?.claimedAt == nil)
        #expect(await backend.runs.count == 1)
        #expect(try await manager.state(chatID: ready.id).turnOrigin == .autonomous(.wakeup))
        try await manager.shutdown()
    }

    @Test func cancellationOnlyRemovesUnclaimedAppOwnedItems() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let (chat, session) = try agentStoreChat(stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let appWake = AgentPendingWake(chatID: chat.id, sessionID: session.id, kind: .wakeup,
            fireAt: .now.addingTimeInterval(-10), nativeToolID: "app")
        var nativeWake = appWake
        nativeWake.id = UUID(); nativeWake.nativeToolID = "native"; nativeWake.transportID = UUID()
        try stores.saveAgentWake(appWake); try stores.saveAgentWake(nativeWake)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.cancelWake(id: nativeWake.id) }
        try await manager.cancelWake(id: appWake.id)
        #expect(try stores.pendingAgentWakes().map(\.id) == [nativeWake.id])
        let cancellations = try await stores.db.queue.read { try ActivityEvent.filter(Column("connectorID") == "agent.wakeups").fetchAll($0) }
        #expect(cancellations.count == 1)
        #expect(cancellations.first?.sourceID == "chat:" + chat.id.uuidString)
        #expect(cancellations.first?.detailJSON?.contains("reversibleWrite") == true)
        #expect(await backend.runs.isEmpty)
        try await manager.shutdown()
    }

    @Test func catchupUsesCreatingSessionAfterProfileSelectionChanges() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let (chat, defaultSession) = try agentStoreChat(stores)
        let profile = AgentProviderProfile(name: "Example profile", configDirectory: "/tmp/example-cli-profile")
        try stores.saveClaudeProfile(profile)
        var original = AgentChatSession(chatID: chat.id, provider: .claude, cwd: "/tmp", model: "test-model",
            providerProfile: profile.nativeProfile)
        original.sessionID = .init(provider: .claude, profile: profile.nativeProfile, nativeID: UUID().uuidString)
        try stores.saveAgentSession(original)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, profileBackend: { _ in backend }, audit: { _ in })
        try stores.saveAgentWake(.init(chatID: chat.id, sessionID: original.id, kind: .wakeup,
            fireAt: .now.addingTimeInterval(-10), prompt: "Check", nativeToolID: "wake"))
        // The composer has switched to the default profile since scheduling.
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.id == defaultSession.id)
        try await manager.runDueWakeups(permitted: true)
        #expect(try stores.pendingAgentWakes().isEmpty)
        #expect(await backend.configurations.first?.resume == original.sessionID)
        let run = try #require(await backend.runs.first)
        let input = try #require(await run.inputs.first)
        #expect(try stores.agentTurn(id: input.id)?.sessionID == original.id)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.id == defaultSession.id)
        try await manager.shutdown()
    }

    @Test func uncertainDeliveryIsNeverResentAcrossTicksOrRestart() async throws {
        let stores = try inMemoryStores(), backend = WakeTestBackend()
        let (chat, session) = try agentStoreChat(stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        try stores.saveAgentWake(.init(chatID: chat.id, sessionID: session.id, kind: .wakeup,
            fireAt: .now.addingTimeInterval(-10), prompt: "Check", nativeToolID: "wake"))
        await backend.setDeliveryFailure(true)
        await #expect(throws: AgentFailure.offline) { try await manager.runDueWakeups(permitted: true) }
        let pending = try #require(try stores.pendingAgentWakes().first)
        let turnID = try #require(pending.claimedTurnID)
        #expect(try stores.agentTurn(id: turnID)?.delivery == .deliveryUnknown)
        try await manager.runDueWakeups(permitted: true)
        #expect(await backend.runs.count == 1)
        try await manager.shutdown()
        let restarted = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(try stores.pendingAgentWakes().isEmpty)
        try await restarted.runDueWakeups(permitted: true)
        #expect(await backend.runs.count == 1)
        try await restarted.shutdown()
    }
}

extension DurableWakeTests {
    @Test func catchupResumesCLIAndHistoryKeepsPromptOutOfUserRows() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
native=open('native-id').read()
assert '--resume' in sys.argv and sys.argv[sys.argv.index('--resume')+1]==native
claude_init()
request=read()
assert request['type']=='user'
assert request['message']['content'].startswith('Scheduled wake-up (was due')
assert 'Check progress' in request['message']['content']
emit({'type':'system','subtype':'init','session_id':native,'apiKeySource':'none'})
emit({'type':'user','uuid':request['uuid'],'message':{'role':'user','content':[{'type':'text','text':request['message']['content']}]}})
emit({'type':'assistant','uuid':'catchup-answer','message':{'role':'assistant','content':[{'type':'text','text':'Progress checked'}]}})
emit({'type':'result','uuid':'catchup-result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, initialSession) = try agentStoreChat(stores, cwd: fixture.directory.path)
        var session = initialSession
        let nativeID = UUID().uuidString
        try nativeID.write(to: fixture.directory.appendingPathComponent("native-id"), atomically: true, encoding: .utf8)
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: nativeID)
        try stores.saveAgentSession(session)
        let backend = AgentHistoryTestBackend(ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
            overrides: ["CLAUDE_CONFIG_DIR": fixture.directory.path]), stores: stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try stores.saveAgentWake(.init(chatID: chat.id, sessionID: session.id, kind: .wakeup,
            fireAt: .now.addingTimeInterval(-180), prompt: "Check progress", nativeToolID: "wake"))
        try await manager.runDueWakeups(permitted: true)
        try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        try fixture.assertComplete()
        let state = try await manager.state(chatID: chat.id)
        let marker = try #require(state.entries.first { $0.kind == "wakeup" })
        let turn = try #require(try stores.agentTurn(id: marker.id))
        #expect(turn.origin == .autonomous(.wakeup))
        #expect(turn.prompt == nil)
        #expect(turn.autonomousPrompt?.contains("Check progress") == true)
        #expect(state.entries.filter { $0.kind == "user" }.isEmpty)
        // A later native refresh sees the input as a user message. The durable
        // autonomous identity must keep it out of the visible user transcript.
        try stores.reconcileAgentHistory(session: session, entries: [
            .init(chatID: chat.id, provider: .claude, kind: "user", text: try #require(turn.autonomousPrompt),
                sessionID: session.id, nativeMessageID: marker.id.uuidString),
            .init(chatID: chat.id, provider: .claude, kind: "assistant", text: "Progress checked",
                sessionID: session.id, nativeMessageID: "catchup-answer")
        ])
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "user" }.isEmpty)
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "wakeup" }.count == 1)
        try await manager.shutdown()
    }

    @Test func claudeFixtureTracksSuccessCancellationNotificationsAndIgnoresReplay() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
def tool(id,name,args,output,error=False):
    emit({'type':'assistant','uuid':'msg-'+id,'message':{'role':'assistant','content':[{'type':'tool_use','id':id,'name':name,'input':args}]}})
    emit({'type':'user','uuid':'result-'+id,'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':id,'content':output,'is_error':error}]}})
tool('wake','ScheduleWakeup',{'delaySeconds':0,'prompt':'Check once'},'Wake scheduled')
tool('cron','CronCreate',{'schedule':'* * * * *','prompt':'Recurring check','recurring':True},'{"id":"cron-native"}')
tool('bg','Bash',{'run_in_background':True,'command':'echo example'},'{"task_id":"task-native"}')
tool('monitor','Monitor',{},'<task-id>monitor-native</task-id>')
tool('failed-wake','ScheduleWakeup',{'delaySeconds':0,'prompt':'Failed'},'Failed',True)
tool('failed-delete','CronDelete',{'id':'cron-native'},'Failed',True)
emit({'type':'assistant','uuid':'replay','isReplay':True,'message':{'role':'assistant','content':[{'type':'tool_use','id':'ignored','name':'ScheduleWakeup','input':{'delaySeconds':0,'prompt':'Old'}}]}})
emit({'type':'user','uuid':'replay-result','isReplay':True,'message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'ignored','content':'Old'}]}})
while not os.path.exists('cancel'): time.sleep(0.005)
tool('delete','CronDelete',{'id':'cron-native'},'Deleted')
tool('stop','TaskStop',{'task_id':'task-native'},'Stopped')
emit({'type':'system','subtype':'task_notification','task_id':'monitor-native','status':'completed'})
tool('bad','ScheduleWakeup',{'delaySeconds':-1},'Invalid')
emit({'type':'result','uuid':'first','is_error':False})
while not os.path.exists('wake'): time.sleep(0.005)
emit({'type':'user','uuid':'injected','message':{'role':'user','content':'<system-reminder>scheduled-wakeup</system-reminder>'}})
emit({'type':'assistant','uuid':'answer','message':{'role':'assistant','content':[{'type':'text','text':'Check completed'}]}})
emit({'type':'result','uuid':'second','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        let backend = AgentHistoryTestBackend(ClaudeBackend(executable: fixture.executable, environment: fixture.environment), stores: stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: chat.id, provider: .claude, input: .init(text: "Schedule checks"))
        do { try await wakeWait { try stores.pendingAgentWakes().count == 4 } }
        catch {
            Issue.record("Initial fixture records: \(try stores.pendingAgentWakes().map(\.kind.rawValue)), state: \(try await manager.state(chatID: chat.id).outcome as Any)")
            throw error
        }
        let items = try stores.pendingAgentWakes()
        #expect(Set(items.map(\.kind.rawValue)) == Set(["wakeup", "cron", "backgroundTask", "monitor"]))
        #expect(items.first { $0.kind == .cron }?.nativeToolID == "cron-native")
        try Data().write(to: fixture.directory.appendingPathComponent("cancel"))
        try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        #expect(try stores.pendingAgentWakes().map(\.kind) == [.wakeup])
        try Data().write(to: fixture.directory.appendingPathComponent("wake"))
        try await wakeWait { try stores.pendingAgentWakes().isEmpty }
        try await manager.runDueWakeups(permitted: true)
        try await wakeWait { try await manager.state(chatID: chat.id).outcome == .completed }
        try fixture.assertComplete()
        try await manager.shutdown()
    }

    @Test func restartDropsProcessesRetainsWakeAndRetriesEngineFailure() async throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        for kind in [AgentWakeKind.wakeup, .backgroundTask, .monitor] {
            try stores.saveAgentWake(.init(chatID: chat.id, sessionID: session.id, kind: kind,
                fireAt: .now.addingTimeInterval(-10), prompt: "Check", nativeToolID: kind.rawValue, transportID: UUID()))
        }
        let backend = WakeTestBackend()
        await backend.setUnavailable(true)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(try stores.pendingAgentWakes().map(\.kind) == [.wakeup])
        #expect(try stores.pendingAgentWakes().first?.transportID == nil)
        #expect(try await stores.db.queue.read { try ActivityRun.filter(Column("title") == "Background task stopped when Aitvaras quit").fetchCount($0) } == 2)
        await #expect(throws: AgentFailure.offline) { try await manager.runDueWakeups(permitted: true) }
        #expect(try stores.pendingAgentWakes().first?.claimedAt == nil)
        await backend.setUnavailable(false)
        try await manager.runDueWakeups(permitted: true)
        #expect(try stores.pendingAgentWakes().isEmpty)
        #expect(await backend.runs.count == 1)
        try await manager.shutdown()
    }

    @Test func migrationReopenRetainsWakeAndSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wake-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let chatID: UUID, sessionID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url, migrateThrough: "v39-repair-claude-user-identities"))
            let (chat, session) = try agentStoreChat(stores)
            chatID = chat.id; sessionID = session.id
        }
        let wakeID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let wake = AgentPendingWake(chatID: chatID, sessionID: sessionID, kind: .wakeup,
                fireAt: .now, prompt: "Retained prompt", nativeToolID: "wake")
            wakeID = wake.id; try stores.saveAgentWake(wake)
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.pendingAgentWakes().first?.id == wakeID)
        #expect(try stores.pendingAgentWakes().first?.prompt == "Retained prompt")
        #expect(try stores.claimAgentWake(id: wakeID, now: .now) != nil)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }
}

actor WakeTestBackend: AgentBackend {
    private(set) var runs: [WakeTestRun] = []
    private(set) var configurations: [AgentSessionConfiguration] = []
    private var unavailable = false
    private var unavailableDirectory: String?
    private var deliveryFailure = false
    func setUnavailable(_ value: Bool) { unavailable = value }
    func setUnavailableDirectory(_ value: String) { unavailableDirectory = value }
    func setDeliveryFailure(_ value: Bool) { deliveryFailure = value }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: []) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun {
        if unavailable || configuration.directory.path == unavailableDirectory { throw AgentFailure.offline }
        configurations.append(configuration)
        let run = WakeTestRun(failAfterDelivery: deliveryFailure); runs.append(run); return run
    }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
actor WakeTestRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private(set) var inputs: [AgentInput] = []
    private(set) var closed = false
    private let failAfterDelivery: Bool
    init(failAfterDelivery: Bool = false) {
        self.failAfterDelivery = failAfterDelivery
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver()
        if failAfterDelivery { throw AgentFailure.offline }
        inputs.append(input)
    }
    func respond(to request: AgentRequest, with response: AgentResponse) {}
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { closed = true; continuation.finish() }
    func emit(_ kind: AgentEvent.Kind, input: UUID?, item: String? = nil) {
        continuation.yield(.init(scope: .init(runID: id, inputID: input, itemID: item), kind: kind))
    }
    func tool(_ item: String, name: String, input: JSONValue, turn: UUID, output: JSONValue = .null) {
        emit(.toolStarted(.init(name: name, input: input)), input: turn, item: item)
        emit(.toolFinished(output: output, isError: false), input: turn, item: item)
    }
}
func wakeWait(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<500 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure.unknown
}
