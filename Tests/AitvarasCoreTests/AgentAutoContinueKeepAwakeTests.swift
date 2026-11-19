import Foundation
import Synchronization
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

final class AutoContinueTestAssertions: Sendable {
    private struct State: Sendable {
        var next: UInt32 = 1
        var live: Set<UInt32> = []
        var creations = 0
        var releases = 0
        var failCreate = false
        var failRelease = false
    }
    private let state = Mutex(State())
    var creations: Int { state.withLock { $0.creations } }
    var releases: Int { state.withLock { $0.releases } }
    var liveCount: Int { state.withLock { $0.live.count } }
    func failCreate(_ value: Bool) { state.withLock { $0.failCreate = value } }
    func failRelease(_ value: Bool) { state.withLock { $0.failRelease = value } }
    var driver: AgentAutoContinueAssertionDriver {
        .init(create: {
            try self.state.withLock { value in
                value.creations += 1
                if value.failCreate { throw AgentAutoContinuePowerError.createFailed }
                let id = value.next; value.next += 1; value.live.insert(id)
                return id
            }
        }, release: { id in
            try self.state.withLock { value in
                if value.failRelease { throw AgentAutoContinuePowerError.releaseFailed }
                guard value.live.remove(id) != nil else { throw AgentAutoContinuePowerError.releaseFailed }
                value.releases += 1
            }
        })
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueKeepAwakeTests {
    private func keeper(_ stores: Stores, _ assertions: AutoContinueTestAssertions, _ clock: UsageResetTestClock,
                        enabled: Bool = true) -> AgentAutoContinueKeepAwake {
        .init(persistence: AgentAutoContinueStore(db: stores.db), driver: assertions.driver,
              audit: { _ = try stores.record($0) }, clock: clock.clock, enabled: enabled)
    }
    private func request(_ stores: Stores) throws -> AgentAutoContinue {
        let value = try autoContinueIntent(stores)
        return try AgentAutoContinueStore(db: stores.db).setOptions(id: value.id, enabled: true, keepAwake: true, now: autoContinueTestDate)
    }

    @Test func defaultsAndUnknownOrBatteryPowerNeverAcquire() async throws {
        let stores = try inMemoryStores(), value = try autoContinueIntent(stores)
        let assertions = AutoContinueTestAssertions(), clock = UsageResetTestClock(autoContinueTestDate)
        let keeper = keeper(stores, assertions, clock)
        try await keeper.updatePower(.ac)
        #expect(assertions.creations == 0)
        let storage = AgentAutoContinueStore(db: stores.db)
        try storage.setOptions(id: value.id, enabled: true, keepAwake: true, now: clock.now)
        for power in [AgentAutoContinuePower.battery, .unknown] { try await keeper.updatePower(power) }
        #expect(assertions.creations == 0)
        try await keeper.updatePower(.ac)
        #expect(assertions.liveCount == 1)
        try await keeper.updatePower(.battery)
        #expect(assertions.liveCount == 0)
        try await keeper.updatePower(.ac)
        #expect(assertions.creations == 2)
        try await keeper.updatePower(.unknown)
        let holding = await keeper.isHolding
        #expect(assertions.releases == 2 && !holding)
        try await keeper.shutdown()
    }

    @Test func directPowerRecheckOverridesAQueuedACNotification() async throws {
        let stores = try inMemoryStores(); _ = try request(stores)
        let assertions = AutoContinueTestAssertions(), actual = Mutex(AgentAutoContinuePower.ac)
        let fake = assertions.driver
        let driver = AgentAutoContinueAssertionDriver(create: fake.create, release: fake.release,
            currentPower: { actual.withLock { $0 } })
        let keeper = AgentAutoContinueKeepAwake(persistence: AgentAutoContinueStore(db: stores.db), driver: driver,
            audit: { _ = try stores.record($0) }, clock: UsageResetTestClock(autoContinueTestDate).clock, enabled: true)
        try await keeper.updatePower(.ac)
        actual.withLock { $0 = .battery }
        try await keeper.updatePower(.ac)
        #expect(assertions.liveCount == 0 && assertions.creations == 1)
        actual.withLock { $0 = .unknown }
        try await keeper.refresh()
        #expect(assertions.creations == 1)
        actual.withLock { $0 = .ac }
        try await keeper.refresh()
        #expect(assertions.creations == 2)
        try await keeper.shutdown()
    }

    @Test func oneAssertionServesMultipleChatsAndTransfersProvenance() async throws {
        let stores = try inMemoryStores(), first = try request(stores), second = try request(stores)
        let assertions = AutoContinueTestAssertions(), clock = UsageResetTestClock(autoContinueTestDate)
        let keeper = keeper(stores, assertions, clock), storage = AgentAutoContinueStore(db: stores.db)
        try await keeper.updatePower(.ac); try await keeper.refresh(); try await keeper.updatePower(.ac)
        #expect(assertions.creations == 1)
        // Cancel whichever intent owns the one assertion, retaining the other.
        let firstOwner = try #require(try stores.recentActivity().first { $0.detailJSON.flatMap(JSONValue.parse)?["status"]?.stringValue == "requested" }?.sourceID)
        let owned = firstOwner == first.failedInputID.uuidString ? first : second
        let remaining = owned.id == first.id ? second : first
        try storage.finish(id: owned.id, state: .cancelled, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.creations == 1 && assertions.releases == 0)
        #expect(try stores.recentActivity().contains { $0.sourceID == remaining.failedInputID.uuidString && $0.detailJSON.flatMap(JSONValue.parse)?["status"]?.stringValue == "transferred" })
        try storage.finish(id: remaining.id, state: .expired, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.releases == 1)
        let audit = String(decoding: try JSONEncoder().encode(stores.recentActivity()), as: UTF8.self)
        for canary in ["ACCOUNT_CANARY", "NATIVE_CANARY", "PRIVATE_PROMPT_CANARY"] { #expect(!audit.contains(canary)) }
    }

    @Test(arguments: [AgentAutoContinue.State.fired, .cancelled, .expired])
    func everyTerminalStateReleases(state: AgentAutoContinue.State) async throws {
        let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions()
        let clock = UsageResetTestClock(autoContinueTestDate), storage = AgentAutoContinueStore(db: stores.db)
        let keeper = keeper(stores, assertions, clock)
        try await keeper.updatePower(.ac)
        if state == .fired {
            let input = UUID()
            try storage.claim(id: saved.id, version: saved.version, inputID: input, now: clock.now)
            try storage.advanceDelivery(id: saved.id, inputID: input, to: .deliveryUnknown, now: clock.now)
            try storage.advanceDelivery(id: saved.id, inputID: input, to: .acknowledged, now: clock.now)
        }
        try storage.finish(id: saved.id, state: state, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.liveCount == 0 && assertions.releases == 1)
    }

    @Test func startingDeliveryReleasesAndQuotaRetryCanReacquire() async throws {
        let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions()
        let clock = UsageResetTestClock(autoContinueTestDate), storage = AgentAutoContinueStore(db: stores.db)
        let keeper = keeper(stores, assertions, clock)
        try await keeper.updatePower(.ac)
        let input = UUID()
        try storage.claim(id: saved.id, version: saved.version, inputID: input, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.liveCount == 1)
        try storage.advanceDelivery(id: saved.id, inputID: input, to: .deliveryUnknown, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.liveCount == 0)
        try storage.retryAfterQuota(id: saved.id, inputID: input, nextCheckAt: clock.now.addingTimeInterval(600), now: clock.now)
        try await keeper.refresh()
        #expect(assertions.liveCount == 1)
        try await keeper.shutdown()
    }

    @Test func disabledChoiceExpiryAndShutdownReleaseWithoutLosingIntent() async throws {
        let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions()
        let clock = UsageResetTestClock(autoContinueTestDate), storage = AgentAutoContinueStore(db: stores.db)
        let keeper = keeper(stores, assertions, clock)
        try await keeper.updatePower(.ac)
        try storage.setOptions(id: saved.id, enabled: false, keepAwake: true, now: clock.now)
        try await keeper.refresh()
        #expect(assertions.liveCount == 0)
        try storage.setOptions(id: saved.id, enabled: true, keepAwake: true, now: clock.now)
        try await keeper.refresh()
        clock.advance(24 * 3600)
        try await keeper.refresh()
        #expect(assertions.liveCount == 0)
        clock.set(autoContinueTestDate)
        try await keeper.refresh()
        try await keeper.shutdown()
        #expect(assertions.liveCount == 0)
        #expect(try storage.continuation(id: saved.id)?.state == .pending)
        try await keeper.updatePower(.ac)
        #expect(assertions.liveCount == 0)
        try await keeper.setActive(true)
        #expect(assertions.liveCount == 1)
        try await keeper.shutdown()
    }

    @Test func batteryAndCancellationWinWhileAcquireAuditIsSuspended() async throws {
        for unplug in [true, false] {
            let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions(), gate = AutoContinueGate()
            let clock = UsageResetTestClock(autoContinueTestDate), storage = AgentAutoContinueStore(db: stores.db)
            let keeper = AgentAutoContinueKeepAwake(persistence: storage, driver: assertions.driver, audit: { _ in await gate.wait() }, clock: clock.clock, enabled: true)
            let acquiring = Task { try await keeper.updatePower(.ac) }
            await gate.waitUntilEntered()
            if unplug { try await keeper.updatePower(.battery) }
            else { try storage.finish(id: saved.id, state: .cancelled, now: clock.now); try await keeper.refresh() }
            await gate.release(); try await acquiring.value
            #expect(assertions.creations == 0 && assertions.liveCount == 0)
        }
    }

    @Test func auditFailurePreventsAcquireAndNeverBlocksRelease() async throws {
        let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions(), clock = UsageResetTestClock(autoContinueTestDate)
        let failing = AgentAutoContinueKeepAwake(persistence: AgentAutoContinueStore(db: stores.db), driver: assertions.driver,
            audit: { _ in throw AgentFailure.offline }, clock: clock.clock, enabled: true)
        await #expect(throws: AgentFailure.offline) { try await failing.updatePower(.ac) }
        #expect(assertions.creations == 0)
        let keeper = AgentAutoContinueKeepAwake(persistence: AgentAutoContinueStore(db: stores.db), driver: assertions.driver, audit: { event in
            if event.detailJSON.flatMap(JSONValue.parse)?["status"]?.stringValue == "released" { throw AgentFailure.offline }
            _ = try stores.record(event)
        }, clock: clock.clock, enabled: true)
        try await keeper.updatePower(.ac)
        await #expect(throws: AgentFailure.offline) { try await keeper.updatePower(.battery) }
        let holding = await keeper.isHolding
        #expect(assertions.liveCount == 0 && !holding)
        #expect(try AgentAutoContinueStore(db: stores.db).continuation(id: saved.id)?.state == .pending)
    }

    @Test func driverFailuresRetainIntentAndReleaseCanBeRetried() async throws {
        let stores = try inMemoryStores(), saved = try request(stores), assertions = AutoContinueTestAssertions(), clock = UsageResetTestClock(autoContinueTestDate)
        let keeper = keeper(stores, assertions, clock)
        assertions.failCreate(true)
        await #expect(throws: AgentAutoContinuePowerError.createFailed) { try await keeper.updatePower(.ac) }
        #expect(assertions.liveCount == 0)
        assertions.failCreate(false); try await keeper.refresh()
        assertions.failRelease(true)
        await #expect(throws: AgentAutoContinuePowerError.releaseFailed) { try await keeper.shutdown() }
        #expect(await keeper.isHolding)
        assertions.failRelease(false); try await keeper.shutdown()
        #expect(assertions.liveCount == 0)
        #expect(try AgentAutoContinueStore(db: stores.db).continuation(id: saved.id)?.state == .pending)
    }

    @Test func productionGatePreventsAssertionsEvenWithStoredConsent() async throws {
        let stores = try inMemoryStores(); _ = try request(stores)
        let assertions = AutoContinueTestAssertions(), clock = UsageResetTestClock(autoContinueTestDate)
        let keeper = AgentAutoContinueKeepAwake(persistence: AgentAutoContinueStore(db: stores.db), driver: assertions.driver,
            audit: { _ = try stores.record($0) }, clock: clock.clock)
        try await keeper.updatePower(.ac)
        #expect(assertions.creations == 0)
    }
}
