import Foundation
import Synchronization
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

/// Scheduled waits suspend until the test advances wall time; no real retry sleeps.
final class AutoContinueTimerClock: Sendable {
    private struct State: Sendable {
        var now = autoContinueTestDate
        var waits: [UUID: (Date, AsyncStream<Void>.Continuation)] = [:]
    }
    private let state = Mutex(State())
    var now: Date { state.withLock { $0.now } }
    func advance(_ seconds: TimeInterval) {
        let ready = state.withLock { value -> [AsyncStream<Void>.Continuation] in
            value.now = value.now.addingTimeInterval(seconds)
            let keys = value.waits.filter { $0.value.0 <= value.now }.map(\.key)
            return keys.compactMap { value.waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.yield(()); $0.finish() }
    }
    private func wait(until date: Date) async throws {
        let id = UUID(), (stream, continuation) = AsyncStream<Void>.makeStream()
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.waits.removeValue(forKey: id) } }
        let immediate = state.withLock { value in
            if value.now >= date { return true }
            value.waits[id] = (date, continuation); return false
        }
        if immediate { continuation.finish(); return }
        for await _ in stream { break }
        continuation.finish()
        try Task.checkCancellation()
    }
    var clock: AgentAutoContinueClock { .init(now: { self.now }, sleepUntil: { try await self.wait(until: $0) }) }
}

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueSchedulerTests {
    private func manager(_ stores: Stores, _ backend: AutoContinueBackend, _ clock: AutoContinueTimerClock) throws -> AgentSessionManager {
        try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: AgentAutoContinueStore(db: stores.db), continuationClock: clock.clock)
    }
    private func scheduler(_ manager: AgentSessionManager, _ stores: Stores, _ backend: AutoContinueBackend,
                           _ clock: AutoContinueTimerClock) -> AgentAutoContinueScheduler {
        .init(manager: manager, turns: stores, persistence: AgentAutoContinueStore(db: stores.db), backend: { _ in backend },
            audit: { _ = try stores.record($0) }, clock: clock.clock)
    }
    @Test func unknownAccountQuotaStopOffersOnlyManualContinue() async throws {
        let stores = try inMemoryStores(), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let (chat, _) = try agentStoreChat(stores, provider: .codex)
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        await backend.setAccount(nil)
        try await scheduler.start()
        let input = AgentInput(text: "Example request")
        try await manager.send(chatID: chat.id, provider: .codex, input: input)
        let run = try #require(await backend.runs.first)
        await run.emit(.turnEnded(.failed(.quota(resetsAt: clock.now.addingTimeInterval(3600)))))
        try await autoWait { try stores.quotaStops().contains { $0.id == input.id } }
        try await scheduler.wake()
        await #expect(throws: AgentFailure.invalidTransition) {
            try await scheduler.setRowOption(failedInputID: input.id, .enabled(true))
        }
        let entry = try #require(try stores.agentEntries(chatID: chat.id).first { $0.stoppedTurn?.inputID == input.id })
        let stopped = try #require(entry.stoppedTurn)
        let row = try #require(AgentAutoContinueRow(stop: stopped, intent: nil, isCurrent: true))
        #expect(!row.enabled && !row.canToggle)
        #expect(row.status == "Automatic continuation requires a verified provider account.")
        #expect(try AgentAutoContinueStore(db: stores.db).continuation(failedInputID: input.id) == nil)
        try await manager.recover(chatID: chat.id, stoppedEntryID: entry.id, action: .continueTurn)
        #expect(await run.inputs.map(\.text) == [input.text, AgentStoppedTurn.continuationText])
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func launchArmsDueQuotaWorkWithoutAFeatureFlag() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock)
        let scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        try await autoWait { await backend.runs.first?.inputs.count == 1 }
        #expect(try AgentAutoContinueStore(db: stores.db).continuation(id: saved.id)?.state == .claimed)
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func simultaneousWakeLaunchAndCompletionFireOnce() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        await withTaskGroup(of: Void.self) { group in for _ in 0..<5 { group.addTask { try? await scheduler.wake() } } }
        let run = try #require(await backend.runs.first)
        #expect(await run.inputs.count == 1)
        await run.emit(.turnEnded(.completed))
        let persistence = AgentAutoContinueStore(db: stores.db)
        try await autoWait { try persistence.continuation(id: saved.id)?.state == .fired }
        try await scheduler.wake()
        #expect(await run.inputs.count == 1)
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func rejectedAttemptsFollowFiveFifteenThirtyFiveSixtyFiveAndExpire() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores, reset: nil), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        let persistence = AgentAutoContinueStore(db: stores.db)
        try await scheduler.start()
        var lastMinute = 0
        for (index, minute) in [5, 15, 35, 65].enumerated() {
            clock.advance(Double(minute - lastMinute) * 60); lastMinute = minute
            try await scheduler.wake()
            try await autoWait { await backend.runs.first?.inputs.count == index + 1 }
            let run = try #require(await backend.runs.first)
            await run.emit(.turnEnded(.failed(.quota(resetsAt: nil))))
            try await autoWait { try persistence.continuation(id: saved.id)?.retryCount == index + 1 }
            let nextMinute = [15, 35, 65, 95][index]
            #expect(try persistence.continuation(id: saved.id)?.nextCheckAt == autoContinueTestDate.addingTimeInterval(Double(nextMinute) * 60))
        }
        clock.advance(Double(720 - lastMinute) * 60)
        try await scheduler.wake()
        try await autoWait { try persistence.continuation(id: saved.id)?.state == .expired }
        #expect(await backend.runs.first?.inputs.count == 4)
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func quotaThrownFromSendKeepsTheFallbackIntentPending() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores, reset: nil), clock = AutoContinueTimerClock()
        let backend = AutoContinueBackend(), storage = AgentAutoContinueStore(db: stores.db)
        await backend.setSendFailure(.quota(resetsAt: nil))
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        clock.advance(5 * 60)
        try await scheduler.wake()
        try await autoWait {
            let intent = try storage.continuation(id: saved.id)
            return intent?.retryCount == 1 || intent?.state == .cancelled
        }
        let retry = try #require(try storage.continuation(id: saved.id))
        #expect(retry.state == .pending)
        #expect(retry.nextCheckAt == autoContinueTestDate.addingTimeInterval(15 * 60))
        #expect(try stores.automaticInput(id: #require(retry.continuationInputID))?.outcome == "quota")
        await backend.setSendFailure(nil)
        clock.advance(10 * 60)
        try await scheduler.wake()
        try await autoWait {
            let runs = await backend.runs
            guard runs.count == 2 else { return false }
            return await runs[1].inputs.count == 1
        }
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func pastResetFromPollDispatchesWithAnAdvancingWallClock() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores, reset: nil), timer = AutoContinueTimerClock()
        let backend = AutoContinueBackend(), storage = AgentAutoContinueStore(db: stores.db)
        try storage.reschedule(id: saved.id, version: saved.version, windowID: nil, resetsAt: nil, source: .fallback,
            nextCheckAt: timer.now.addingTimeInterval(1200), nextPollAt: timer.now.addingTimeInterval(600), now: timer.now)
        let reads = Mutex(0)
        let clock = AgentAutoContinueClock(now: {
            timer.now.addingTimeInterval(reads.withLock { count in count += 1; return Double(count) / 1_000 })
        }, sleepUntil: timer.clock.sleepUntil)
        let pastReset = timer.now.addingTimeInterval(540)
        await backend.setWindows([.init(id: "codex.primary", utilization: 1, resetsAt: pastReset)])
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: clock)
        let scheduler = AgentAutoContinueScheduler(manager: manager, turns: stores, persistence: storage,
            backend: { _ in backend }, audit: { _ = try stores.record($0) }, clock: clock)
        try await scheduler.start()
        timer.advance(600)
        try await scheduler.wake()
        try await autoWait { await backend.runs.first?.inputs.count == 1 }
        #expect(try storage.continuation(id: saved.id)?.resetsAt == pastReset)
        #expect(await backend.reads == 1)
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func pollDiscoversResetWithoutPromptAndCancellationWinsWhilePolling() async throws {
        for cancel in [false, true] {
            let stores = try inMemoryStores(), saved = try autoContinueIntent(stores, reset: nil), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
            let storage = AgentAutoContinueStore(db: stores.db)
            try storage.reschedule(id: saved.id, version: saved.version, windowID: nil, resetsAt: nil, source: .fallback,
                nextCheckAt: clock.now.addingTimeInterval(1200), nextPollAt: clock.now.addingTimeInterval(600), now: clock.now)
            await backend.setWindows([.init(id: "codex.primary", utilization: 1, resetsAt: clock.now.addingTimeInterval(900))])
            let gate = AutoContinueGate()
            if cancel { await backend.setPollGate(gate) }
            let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
            try await scheduler.start()
            clock.advance(600)
            let polling = Task { try await scheduler.wake() }
            if cancel {
                await gate.waitUntilEntered()
                try await scheduler.cancel(id: saved.id)
                await gate.release()
            }
            try await polling.value
            if cancel {
                try await autoWait { try storage.continuation(id: saved.id)?.state == .cancelled }
                #expect(await backend.runs.isEmpty)
            } else {
                try await autoWait { try storage.continuation(id: saved.id)?.resetsAt == autoContinueTestDate.addingTimeInterval(900) }
                #expect(await backend.runs.isEmpty)
                #expect(await backend.reads == 1)
                clock.advance(300); try await scheduler.wake()
                try await autoWait { await backend.runs.first?.inputs.count == 1 }
            }
            await scheduler.shutdown(); try await manager.shutdown()
        }
    }

    @Test(arguments: [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged])
    func reopeningOnlyReplaysProvablyUndeliveredClaims(delivery: AgentDeliveryState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite"), saved: AgentAutoContinue
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url)), storage = AgentAutoContinueStore(db: stores.db)
            saved = try autoContinueIntent(stores)
            let input = AgentInput(text: AgentAutoContinue.prompt)
            let claim = try storage.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
            try stores.prepareAutomaticTurn(.init(input: input, chatID: saved.chatID, sessionID: saved.sessionID), authorization: claim)
            if delivery != .prepared { try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
            if delivery == .acknowledged { try stores.advanceAgentDelivery(id: input.id, to: .acknowledged) }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url)), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        if delivery == .prepared { #expect(await backend.runs.first?.inputs.count == 1) }
        else {
            #expect(await backend.runs.isEmpty)
            #expect(try AgentAutoContinueStore(db: stores.db).continuation(id: saved.id)?.state == (delivery == .acknowledged ? .fired : .cancelled))
        }
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func expiredDisabledAndSignedOutRecordsDoNotSend() async throws {
        for scenario in ["expired", "disabled", "signed-out"] {
            let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
            let storage = AgentAutoContinueStore(db: stores.db)
            if scenario == "expired" { clock.advance(24 * 3600) }
            if scenario == "disabled" { try storage.setOptions(id: saved.id, enabled: false, keepAwake: false, now: clock.now) }
            if scenario == "signed-out" { await backend.setAuthentication(.signedOut) }
            let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
            try await scheduler.start()
            #expect(await backend.runs.isEmpty)
            #expect(try storage.continuation(id: saved.id)?.state == (scenario == "expired" ? .expired : scenario == "disabled" ? .pending : .cancelled))
            await scheduler.shutdown(); try await manager.shutdown()
        }
    }

    @Test func capacityRefusalDefersWithoutClaimingAndRetriesWhenCapacityIsFree() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock)
        for _ in 0..<AgentSessionManager.maximumRunningChats {
            let session = try agentStoreChat(stores, provider: .codex).1
            try await manager.send(chatID: session.chatID, provider: .codex, input: .init(text: "Keep running"))
        }
        let scheduler = scheduler(manager, stores, backend, clock), storage = AgentAutoContinueStore(db: stores.db)
        try await scheduler.start()
        #expect(await backend.runs.count == 8)
        #expect(try storage.continuation(id: saved.id)?.state == .pending)
        #expect(try storage.continuation(id: saved.id)?.nextCheckAt == clock.now.addingTimeInterval(30))
        let first = try #require(await backend.runs.first)
        await first.emit(.turnEnded(.completed))
        try await autoWait { try stores.agentTurn(id: await first.inputs.first!.id)?.state == .completed }
        clock.advance(30); try await scheduler.wake()
        try await autoWait {
            let runs = await backend.runs
            guard runs.count == 9 else { return false }
            return await runs.last?.inputs.count == 1
        }
        #expect(await backend.runs.count == 9)
        #expect(await backend.runs.last?.inputs.count == 1)
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func shutdownDuringStartupPreservesUndeliveredIntentForNextLaunch() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend(), gate = AutoContinueGate()
        await backend.setStartGate(gate)
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        let starting = Task { try await scheduler.start() }
        await gate.waitUntilEntered()
        await scheduler.shutdown()
        await gate.release()
        try await starting.value
        let storage = AgentAutoContinueStore(db: stores.db)
        let claim = try #require(try storage.continuation(id: saved.id))
        #expect(claim.state == .claimed && claim.delivery == .prepared)
        #expect(await backend.runs.first?.inputs.isEmpty == true)
        #expect(try stores.automaticInput(id: #require(claim.continuationInputID))?.outcome == nil)
        try await manager.shutdown()
        await backend.setStartGate(nil)
        let nextManager = try self.manager(stores, backend, clock), nextScheduler = self.scheduler(nextManager, stores, backend, clock)
        try await nextScheduler.start()
        #expect(await backend.runs.last?.inputs.count == 1)
        await nextScheduler.shutdown(); try await nextManager.shutdown()
    }

    @Test func aLaterLimitAfterActualWorkGetsFreshDefaultChoices() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let storage = AgentAutoContinueStore(db: stores.db)
        try storage.setOptions(id: saved.id, enabled: true, keepAwake: true, now: clock.now)
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        let run = try #require(await backend.runs.first)
        await run.emit(.textDelta("Some actual work"))
        try await autoWait { try storage.continuation(id: saved.id)?.state == .fired }
        await run.emit(.turnEnded(.failed(.quota(resetsAt: clock.now.addingTimeInterval(3600)))))
        try await autoWait { try storage.pending().count == 1 }
        let next = try #require(try storage.pending().first)
        #expect(next.id != saved.id && next.enabled && !next.keepAwake)
        #expect(next.failedInputID == (await run.inputs.first?.id))
        await scheduler.shutdown(); try await manager.shutdown()
    }

    @Test func verifiedQuotaArmsOnlyAfterActualProviderFailureAndDefaultsReset() async throws {
        let stores = try inMemoryStores(), session = try agentStoreChat(stores, provider: .codex).1
        let clock = AutoContinueTimerClock(), backend = AutoContinueBackend()
        let manager = try manager(stores, backend, clock), scheduler = scheduler(manager, stores, backend, clock)
        try await scheduler.start()
        #expect(try AgentAutoContinueStore(db: stores.db).pending().isEmpty)
        try await manager.send(chatID: session.chatID, provider: .codex, input: .init(text: "Original question"))
        let run = try #require(await backend.runs.first)
        await run.emit(.turnEnded(.failed(.quota(resetsAt: clock.now.addingTimeInterval(3600)))))
        let storage = AgentAutoContinueStore(db: stores.db)
        try await autoWait { try storage.pending().count == 1 }
        let pending = try #require(try storage.pending().first)
        #expect(pending.enabled && !pending.keepAwake && pending.resetsAt == clock.now.addingTimeInterval(3600))
        try await scheduler.cancel(id: pending.id)
        try await scheduler.wake()
        #expect(try storage.pending().isEmpty)
        await scheduler.shutdown(); try await manager.shutdown()
    }
}
