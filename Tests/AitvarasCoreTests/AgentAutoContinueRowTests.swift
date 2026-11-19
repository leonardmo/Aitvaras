import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueRowTests {
    private func stop(_ intent: AgentAutoContinue, failure: AgentFailure) -> AgentStoppedTurn {
        var session = AgentChatSession(id: intent.sessionID, chatID: intent.chatID, provider: .codex, cwd: "/tmp", model: "example")
        session.sessionID = intent.native
        var turn = AgentJournalTurn(input: .init(id: intent.failedInputID, text: "Example"), chatID: intent.chatID, sessionID: intent.sessionID)
        turn.delivery = .acknowledged
        var value = AgentStoppedTurn(turn: turn, session: session, reason: .failure(failure))
        value.quotaContext = .init(windowID: nil, accountKey: intent.scope.accountKey, inputRevision: 0, stoppedAt: autoContinueTestDate)
        return value
    }

    @Test func quotaRowShowsDefaultsResetAndCheckingWithoutChangingManualContinue() throws {
        let stores = try inMemoryStores(), intent = try autoContinueIntent(stores)
        let reset = Date(timeIntervalSince1970: 1800)
        let quota = stop(intent, failure: .quota(resetsAt: reset))
        let row = try #require(AgentAutoContinueRow(stop: quota, intent: nil, isCurrent: true, timeZone: TimeZone(secondsFromGMT: 0)!))
        #expect(row.enabled && row.canToggle && row.canChangeKeepAwake && !row.keepAwake)
        #expect(row.status == "Waiting for usage reset · continues at 00:30")
        #expect(quota.actions == [.continueTurn])
        let unknown = stop(intent, failure: .quota(resetsAt: nil))
        #expect(AgentAutoContinueRow(stop: unknown, intent: nil, isCurrent: true)?.status == "Checking when the limit resets…")
        #expect(AgentAutoContinueRow(stop: quota, intent: nil, isCurrent: false)?.canToggle == false)
        for failure in [AgentFailure.offline, .authRequired, .unknown] {
            #expect(AgentAutoContinueRow(stop: stop(intent, failure: failure), intent: nil, isCurrent: true) == nil)
        }
    }

    @Test func savedChoiceAndDeliveryDetermineAvailableControls() throws {
        let stores = try inMemoryStores()
        var intent = try autoContinueIntent(stores)
        let quota = stop(intent, failure: .quota(resetsAt: nil))
        intent.enabled = false
        intent.keepAwake = true
        let off = try #require(AgentAutoContinueRow(stop: quota, intent: intent, isCurrent: true))
        #expect(off.canToggle && !off.enabled && !off.canChangeKeepAwake && off.keepAwake && off.status == nil)
        intent.enabled = true
        intent.state = .claimed
        #expect(AgentAutoContinueRow(stop: quota, intent: intent, isCurrent: false)?.canToggle == true)
        intent.delivery = .deliveryUnknown
        #expect(AgentAutoContinueRow(stop: quota, intent: intent, isCurrent: false)?.canToggle == false)
        intent.state = .fired
        #expect(AgentAutoContinueRow(stop: quota, intent: intent, isCurrent: false)?.enabled == false)
    }

    @Test func checkboxDisarmsThenRearmsTheSameIntentAndFiresOnlyOnce() async throws {
        let stores = try inMemoryStores(), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let reset = clock.now.addingTimeInterval(3600)
        let intent = try autoContinueIntent(stores, reset: reset)
        let storage = AgentAutoContinueStore(db: stores.db)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: clock.clock)
        let scheduler = AgentAutoContinueScheduler(manager: manager, turns: stores, persistence: storage,
            backend: { _ in backend }, audit: { _ = try stores.record($0) }, clock: clock.clock)
        try await scheduler.start()
        try await scheduler.setRowOption(failedInputID: intent.failedInputID, .keepAwake(true))
        try await scheduler.setRowOption(failedInputID: intent.failedInputID, .enabled(false))
        clock.advance(3600)
        try await scheduler.wake()
        #expect(await backend.runs.isEmpty)
        #expect(try storage.continuation(id: intent.id)?.enabled == false)
        try await scheduler.setRowOption(failedInputID: intent.failedInputID, .enabled(true))
        try await autoWait { await backend.runs.first?.inputs.count == 1 }
        let run = try #require(await backend.runs.first)
        await run.emit(.textDelta("Example answer"))
        await run.emit(.turnEnded(.completed))
        try await autoWait { try stores.agentEntries(chatID: intent.chatID).contains { $0.kind == "automaticContinuation" } }
        #expect(try storage.continuation(failedInputID: intent.failedInputID)?.state == .fired)
        #expect(try storage.continuation(id: intent.id)?.keepAwake == true)
        await #expect(throws: AgentFailure.invalidTransition) {
            try await scheduler.setRowOption(failedInputID: intent.failedInputID, .enabled(true))
        }
        try await scheduler.wake()
        #expect(await run.inputs.count == 1)
        let rows = try await manager.state(chatID: intent.chatID).entries
        #expect(rows.filter { $0.kind == "automaticContinuation" }.count == 1)
        #expect(!rows.contains { $0.kind == "user" })
        let activity = try stores.recentActivity().filter { $0.sourceID == intent.failedInputID.uuidString }
        #expect(activity.contains { $0.summary.hasSuffix("cancelled") })
        #expect(activity.contains { $0.summary.hasSuffix("fired") })
        await scheduler.shutdown()
        try await manager.shutdown()
    }
    @Test func optOutDuringRegistrationSurvivesAndManualContinueStillWorks() async throws {
        let stores = try inMemoryStores(), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let (chat, _) = try agentStoreChat(stores, provider: .codex)
        let storage = AgentAutoContinueStore(db: stores.db)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: clock.clock)
        let scheduler = AgentAutoContinueScheduler(manager: manager, turns: stores, persistence: storage,
            backend: { _ in backend }, audit: { _ = try stores.record($0) }, clock: clock.clock)
        try await scheduler.start()
        let input = AgentInput(text: "Example")
        try await manager.send(chatID: chat.id, provider: .codex, input: input)
        let run = try #require(await backend.runs.first)
        let gate = AutoContinueGate()
        await backend.setStatusGate(gate)
        await run.emit(.turnEnded(.failed(.quota(resetsAt: clock.now.addingTimeInterval(3600)))))
        await gate.waitUntilEntered()
        #expect(try storage.continuation(failedInputID: input.id) == nil)
        do {
            try await scheduler.setRowOption(failedInputID: input.id, .enabled(false))
        } catch {
            await gate.release()
            throw error
        }
        await backend.setStatusGate(nil)
        await gate.release()
        let off = try #require(try storage.continuation(failedInputID: input.id))
        #expect(!off.enabled && !off.keepAwake)
        let row = try #require(try stores.agentEntries(chatID: chat.id).last { $0.stoppedTurn?.inputID == input.id })
        try await manager.recover(chatID: chat.id, stoppedEntryID: row.id, action: .continueTurn)
        #expect(await run.inputs.map(\.text) == ["Example", AgentStoppedTurn.continuationText])
        #expect(try storage.continuation(id: off.id)?.state == .cancelled)
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "continued" }.count == 1)
        clock.advance(3600)
        try await scheduler.wake()
        #expect(await run.inputs.count == 2)
        await scheduler.shutdown()
        try await manager.shutdown()
    }

}
