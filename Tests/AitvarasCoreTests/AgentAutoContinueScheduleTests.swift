import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueScheduleTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func pending(provider: AgentProvider = .codex) -> AgentAutoContinue {
        .init(chatID: UUID(), failedInputID: UUID(), sessionID: UUID(),
            native: .init(provider: provider, profile: "default", nativeID: "fixture-native"),
            scope: .init(provider: provider), createdAt: now, inputRevision: 0,
            nextCheckAt: now.addingTimeInterval(300), nextPollAt: provider == .codex ? now.addingTimeInterval(600) : nil)
    }

    @Test func fallbackUsesIntervalsAndEndsBeforeTwelveHours() {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        var date = schedule.firstCheck(startedAt: now, reset: nil)
        var elapsed: [Int] = [Int(date.timeIntervalSince(now) / 60)]
        var count = 1
        while let next = schedule.nextFallbackAttempt(startedAt: now, rejectedAttempts: count, rejectedAt: date) {
            #expect(next > date)
            #expect(next < now.addingTimeInterval(12 * 3600))
            date = next; elapsed.append(Int(date.timeIntervalSince(now) / 60)); count += 1
        }
        #expect(elapsed == [5, 15, 35] + Array(stride(from: 65, through: 695, by: 30)))
        #expect(schedule.nextFallbackAttempt(startedAt: now, rejectedAttempts: 0, rejectedAt: now) == nil)
        #expect(schedule.nextFallbackAttempt(startedAt: now, rejectedAttempts: 1, rejectedAt: now.addingTimeInterval(-1)) == nil)
        #expect(schedule.nextFallbackAttempt(startedAt: now, rejectedAttempts: Int.max, rejectedAt: now.addingTimeInterval(12 * 3600)) == nil)
    }

    @Test func codexPollingAndContinuationHaveIndependentDeadlines() throws {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        var value = pending()
        var plan = schedule.plan(value)
        #expect(plan.state == .waiting && plan.nextWakeAt == now.addingTimeInterval(300))
        #expect(plan.pollAt == now.addingTimeInterval(600))
        clock.advance(300)
        #expect(schedule.plan(value).state == .ready)
        value.retryCount = 1
        value.nextCheckAt = try #require(schedule.nextFallbackAttempt(startedAt: now, rejectedAttempts: 1, rejectedAt: clock.now))
        plan = schedule.plan(value)
        #expect(plan.continuationAt == now.addingTimeInterval(900))
        #expect(plan.nextWakeAt == now.addingTimeInterval(600))
        clock.advance(300)
        #expect(schedule.plan(value).pollAt == clock.now)
        value.nextPollAt = schedule.nextPoll(provider: .codex)
        #expect(value.nextPollAt == now.addingTimeInterval(1200))
        #expect(schedule.nextPoll(provider: .claude) == nil)
        #expect(schedule.plan(pending(provider: .claude)).pollAt == nil)
    }

    @Test func newlyLearnedResetReplacesFallbackButStillPollsWhileWaiting() {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        var value = pending()
        let reset = AgentUsageResetResolution(resetsAt: now.addingTimeInterval(7200), windowID: "codex.primary", source: .poll)
        value.resetsAt = reset.resetsAt; value.resetSource = reset.source
        value.nextCheckAt = schedule.firstCheck(startedAt: now, reset: reset)
        let plan = schedule.plan(value)
        #expect(plan.continuationAt == reset.resetsAt)
        #expect(plan.pollAt == now.addingTimeInterval(600))
        #expect(plan.expiresAt == reset.resetsAt.addingTimeInterval(24 * 3600))
        // A quota rejection after that reset defers another attempt rather than spinning.
        clock.set(reset.resetsAt)
        value.retryCount = 1; value.nextCheckAt = clock.now.addingTimeInterval(600)
        #expect(schedule.plan(value).state == .waiting)
        #expect(schedule.plan(value).continuationAt == clock.now.addingTimeInterval(600))
    }

    @Test func wakeAndLaunchUseWallTimeWithoutReplayingMissedChecks() {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        let value = pending()
        clock.advance(3600)
        let plan = schedule.plan(value)
        #expect(plan.state == .ready && plan.continuationAt == clock.now && plan.pollAt == clock.now)
        #expect(schedule.plan(value) == plan)
        clock.advance(11 * 3600)
        #expect(schedule.plan(value).state == .expired)
        #expect(schedule.plan(value).nextWakeAt == nil)
    }

    @Test func exactKnownResetAndFallbackCutoffsAreEnforced() {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        var value = pending()
        clock.set(now.addingTimeInterval(12 * 3600 - 1))
        #expect(schedule.plan(value).state == .ready)
        clock.advance(1)
        #expect(schedule.plan(value).state == .expired)
        value.resetsAt = now.addingTimeInterval(7 * 86400); value.resetSource = .request
        value.nextCheckAt = value.resetsAt!
        #expect(schedule.plan(value).state == .waiting)
        clock.set(value.resetsAt!.addingTimeInterval(24 * 3600 - 1))
        #expect(schedule.plan(value).state == .ready)
        clock.advance(1)
        #expect(schedule.plan(value).state == .expired)
    }

    @Test func disabledTerminalAndClaimedRecordsNeverScheduleDispatch() {
        let schedule = AgentAutoContinueSchedule(clock: UsageResetTestClock(now).clock)
        var value = pending()
        value.enabled = false
        #expect(schedule.plan(value).state == .inactive)
        value.enabled = true
        for state in [AgentAutoContinue.State.fired, .cancelled, .expired] {
            value.state = state
            #expect(schedule.plan(value).nextWakeAt == nil)
        }
        value.state = .claimed
        for delivery in [AgentDeliveryState.prepared, .deliveryUnknown, .acknowledged] {
            value.delivery = delivery
            #expect(schedule.plan(value).state == .claimed)
            #expect(schedule.plan(value).nextWakeAt == nil)
        }
        #expect(schedule.plan(pending(provider: .local)).state == .inactive)
    }

    @Test func clockMovingBackwardKeepsPersistedDatesAndExhaustedFallbackWaitsOnlyUntilExpiry() {
        let clock = UsageResetTestClock(now), schedule = AgentAutoContinueSchedule(clock: clock.clock)
        var value = pending()
        clock.advance(-3600)
        #expect(schedule.plan(value).continuationAt == now.addingTimeInterval(300))
        #expect(schedule.plan(value).pollAt == now.addingTimeInterval(600))
        value.nextCheckAt = now.addingTimeInterval(12 * 3600)
        #expect(schedule.plan(value).continuationAt == nil)
        #expect(schedule.plan(value).expiresAt == now.addingTimeInterval(12 * 3600))
        var claude = pending(provider: .claude)
        claude.nextCheckAt = value.nextCheckAt
        #expect(schedule.plan(claude).nextWakeAt == value.nextCheckAt)
    }

    @Test func injectedWaitAdvancesOnlyFakeTime() async throws {
        let clock = UsageResetTestClock(now)
        try await clock.clock.sleepUntil(now.addingTimeInterval(3600))
        #expect(clock.now == now.addingTimeInterval(3600))
        try await clock.clock.sleepUntil(now)
        #expect(clock.now == now.addingTimeInterval(3600))
    }
}
