import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

private struct AutoContinueLifecycleFixture {
    let stores: Stores
    let saved: AgentAutoContinue
    let storage: AgentAutoContinueStore
    let clock: AutoContinueTimerClock
    let backend: AutoContinueBackend
    let assertions: AutoContinueTestAssertions
    let manager: AgentSessionManager
    let lifecycle: AgentAutoContinueLifecycle
    init(resetAfter: TimeInterval = 3600, enabled: Bool = true) throws {
        stores = try inMemoryStores(); storage = AgentAutoContinueStore(db: stores.db)
        clock = AutoContinueTimerClock(); backend = AutoContinueBackend(); assertions = AutoContinueTestAssertions()
        let value = try autoContinueIntent(stores, reset: autoContinueTestDate.addingTimeInterval(resetAfter))
        saved = try storage.setOptions(id: value.id, enabled: true, keepAwake: true, now: clock.now)
        let stores = stores, storage = storage, backend = backend
        manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: clock.clock)
        let scheduler = AgentAutoContinueScheduler(manager: manager, turns: stores, persistence: storage,
            backend: { _ in backend }, audit: { _ = try stores.record($0) }, clock: clock.clock, armingEnabled: enabled)
        let keepAwake = AgentAutoContinueKeepAwake(persistence: storage, driver: assertions.driver,
            audit: { _ = try stores.record($0) }, clock: clock.clock)
        lifecycle = AgentAutoContinueLifecycle(manager: manager, scheduler: scheduler, keepAwake: keepAwake, armingEnabled: enabled)
    }
    func stop() async throws { try await lifecycle.prepareForTermination(); try await manager.shutdown() }
}

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueLifecycleTests {
    @Test func launchWaitsThenRepeatedWakesDispatchOnceAndOutputReleasesAssertion() async throws {
        let f = try AutoContinueLifecycleFixture()
        try await f.lifecycle.launch(power: .ac)
        #expect(f.assertions.liveCount == 1)
        #expect(await f.backend.runs.isEmpty)
        f.clock.advance(3600)
        async let first: Void = f.lifecycle.didWake(power: .ac)
        async let second: Void = f.lifecycle.didWake(power: .ac)
        _ = try await (first, second)
        try await autoWait { await f.backend.runs.first?.inputs.count == 1 }
        let run = try #require(await f.backend.runs.first)
        try await autoWait { f.assertions.liveCount == 0 }
        await run.emit(.textDelta("Resumed answer"))
        try await autoWait { f.assertions.liveCount == 0 }
        try await autoWait { try f.storage.continuation(id: f.saved.id)?.state == .fired }
        #expect(f.assertions.creations == 1 && f.assertions.releases == 1)
        await run.emit(.turnEnded(.completed))
        try await f.stop()
    }

    @Test func timerExpiryReleasesWithoutAnotherWakeOrPowerNotification() async throws {
        let f = try AutoContinueLifecycleFixture()
        try await f.lifecycle.launch(power: .ac)
        f.clock.advance(3600 + 24 * 3600)
        try await autoWait { try f.storage.continuation(id: f.saved.id)?.state == .expired }
        try await autoWait { f.assertions.liveCount == 0 }
        #expect(await f.backend.runs.isEmpty)
        try await f.stop()
    }

    @Test func optionChangesCancellationAndPowerChangesRefreshImmediately() async throws {
        let f = try AutoContinueLifecycleFixture()
        try await f.lifecycle.launch(power: .ac)
        try await f.lifecycle.powerChanged(.battery)
        #expect(f.assertions.liveCount == 0)
        try await f.lifecycle.powerChanged(.ac)
        #expect(f.assertions.liveCount == 1)
        try await f.lifecycle.setOptions(id: f.saved.id, enabled: true, keepAwake: false)
        #expect(f.assertions.liveCount == 0)
        try await f.lifecycle.setOptions(id: f.saved.id, enabled: true, keepAwake: true)
        #expect(f.assertions.liveCount == 1)
        try await f.lifecycle.cancel(id: f.saved.id)
        #expect(f.assertions.liveCount == 0)
        #expect(try f.storage.continuation(id: f.saved.id)?.state == .cancelled)
        try await f.stop()
    }

    @Test func quitRetainsPendingAndCancelledTerminationUsesFreshPowerAndReopensChatOwner() async throws {
        let f = try AutoContinueLifecycleFixture()
        try await f.lifecycle.launch(power: .ac)
        try await f.lifecycle.prepareForTermination()
        #expect(f.assertions.liveCount == 0)
        #expect(try f.storage.continuation(id: f.saved.id)?.state == .pending)
        try await f.manager.shutdown()
        try await f.lifecycle.didWake(power: .ac)
        try await f.lifecycle.powerChanged(.ac)
        #expect(f.assertions.liveCount == 0)
        try await f.lifecycle.terminationCancelled(power: .battery)
        #expect(f.assertions.liveCount == 0)
        try await f.manager.send(chatID: f.saved.chatID, provider: .codex, input: .init(text: "A new question"))
        #expect(try f.storage.continuation(id: f.saved.id)?.state == .cancelled)
        #expect(await f.backend.runs.first?.inputs.first?.text == "A new question")
        try await f.stop()
    }

    @Test func cancelledTerminationRestartsSchedulingAndReacquiresOnlyOnAC() async throws {
        let f = try AutoContinueLifecycleFixture()
        try await f.lifecycle.launch(power: .ac)
        try await f.lifecycle.prepareForTermination(); try await f.manager.shutdown()
        try await f.lifecycle.terminationCancelled(power: .ac)
        #expect(f.assertions.creations == 2 && f.assertions.liveCount == 1)
        f.clock.advance(3600)
        try await f.lifecycle.didWake(power: .ac)
        try await autoWait { await f.backend.runs.first?.inputs.count == 1 }
        try await f.stop()
        #expect(f.assertions.liveCount == 0)
    }

    @Test func oldStartupCannotCancelOrSendAfterTerminationWasCancelled() async throws {
        let f = try AutoContinueLifecycleFixture(resetAfter: 0), gate = AutoContinueGate()
        await f.backend.setStartGate(gate)
        let launch = Task { try await f.lifecycle.launch(power: .ac) }
        await gate.waitUntilEntered()
        try await f.lifecycle.prepareForTermination()
        try await f.manager.shutdown(timeout: .milliseconds(10))
        #expect(f.assertions.liveCount == 0)
        try await f.lifecycle.terminationCancelled(power: .ac)
        await f.backend.setStartGate(nil)
        await gate.release()
        try await launch.value
        try await autoWait { await f.backend.runs.last?.inputs.count == 1 }
        let runs = await f.backend.runs
        #expect(runs.count == 2)
        #expect(await runs.first?.inputs.isEmpty == true)
        #expect(try f.storage.continuation(id: f.saved.id)?.state == .claimed)
        try await f.stop()
    }

    @Test func retiredSignedOutPollCannotCancelResumedScheduling() async throws {
        let f = try AutoContinueLifecycleFixture(), gate = AutoContinueGate()
        try await f.lifecycle.launch(power: .ac)
        await f.backend.setAuthentication(.signedOut)
        await f.backend.setStatusGate(gate)
        f.clock.advance(600)
        await gate.waitUntilEntered()
        try await f.lifecycle.prepareForTermination(); try await f.manager.shutdown()
        await f.backend.setStatusGate(nil)
        await f.backend.setAuthentication(.subscription)
        try await f.lifecycle.terminationCancelled(power: .ac)
        await gate.release()
        try await autoWait { try f.storage.continuation(id: f.saved.id)?.nextPollAt == f.clock.now.addingTimeInterval(600) }
        #expect(try f.storage.continuation(id: f.saved.id)?.state == .pending)
        f.clock.advance(3000)
        try await f.lifecycle.didWake(power: .ac)
        try await autoWait { await f.backend.runs.first?.inputs.count == 1 }
        try await f.stop()
    }

    @Test(arguments: ["off", "new-input", "expired", "signed-out"])
    func launchEligibilityChecksPreventDispatch(scenario: String) async throws {
        let f = try AutoContinueLifecycleFixture(resetAfter: 0)
        if scenario == "off" { try f.storage.setOptions(id: f.saved.id, enabled: false, keepAwake: true, now: f.clock.now) }
        if scenario == "new-input" { try f.storage.noteNewInput(chatID: f.saved.chatID, now: f.clock.now) }
        if scenario == "expired" { f.clock.advance(24 * 3600) }
        if scenario == "signed-out" { await f.backend.setAuthentication(.signedOut) }
        try await f.lifecycle.launch(power: .ac)
        try await autoWait { f.assertions.liveCount == 0 }
        #expect(await f.backend.runs.isEmpty)
        try await f.stop()
    }

    @Test func assertionFailureDoesNotSuppressContinuationAndCanRecover() async throws {
        let f = try AutoContinueLifecycleFixture(resetAfter: 0)
        f.assertions.failCreate(true)
        await #expect(throws: AgentAutoContinuePowerError.createFailed) { try await f.lifecycle.launch(power: .ac) }
        try await autoWait { await f.backend.runs.first?.inputs.count == 1 }
        #expect(f.assertions.liveCount == 0)
        #expect(await f.lifecycle.lastFailure == .power)
        f.assertions.failCreate(false)
        let waiting = try autoContinueIntent(f.stores, reset: f.clock.now.addingTimeInterval(3600))
        try f.storage.setOptions(id: waiting.id, enabled: true, keepAwake: true, now: f.clock.now)
        try await f.lifecycle.powerChanged(.ac)
        #expect(f.assertions.liveCount == 1)
        try await f.stop()
    }

    @Test func productionGateKeepsLaunchWakeAndPowerInert() async throws {
        #expect(!AgentAutoContinueLifecycle.productionArmingEnabled)
        let f = try AutoContinueLifecycleFixture(resetAfter: 0, enabled: false)
        try await f.lifecycle.launch(power: .ac)
        try await f.lifecycle.didWake(power: .ac)
        try await f.lifecycle.powerChanged(.ac)
        #expect(await f.backend.runs.isEmpty)
        #expect(f.assertions.creations == 0)
        #expect(try f.storage.continuation(id: f.saved.id) == f.saved)
        try await f.lifecycle.prepareForTermination(); try await f.manager.shutdown()
        try await f.lifecycle.terminationCancelled(power: .ac)
        #expect(f.assertions.creations == 0)
        try await f.stop()
    }
}
