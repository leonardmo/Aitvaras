import Foundation
import Synchronization
import Testing
@testable import AitvarasAgents

/// A manual clock; waiting advances simulated time instead of sleeping.
final class UsageResetTestClock: Sendable {
    private let time: Mutex<Date>
    init(_ date: Date) { time = Mutex(date) }
    var now: Date { time.withLock { $0 } }
    func set(_ date: Date) { time.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var clock: AgentAutoContinueClock {
        .init(now: { self.now }, sleepUntil: { date in self.time.withLock { $0 = max($0, date) } })
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentUsageResetResolverTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let scope = AgentUsageLimitScope(provider: .codex, accountID: "account-a")

    private func snapshot(_ windows: [AgentRateLimitWindow], scope: AgentUsageLimitScope? = nil) -> AgentUsageLimitSnapshot {
        .init(scope: scope ?? self.scope, windows: windows, observedAt: now)
    }

    @Test func requestThenScopedCacheThenPollThenUnknown() {
        let clock = UsageResetTestClock(now), resolver = AgentUsageResetResolver(clock: clock.clock)
        let request = AgentUsageLimit(status: .rejected, windowID: "codex.primary", resetsAt: now.addingTimeInterval(300))
        let cached = AgentUsageResetObservation(scope: scope, windowID: "codex.primary", resetsAt: now.addingTimeInterval(600), observedAt: now)
        let polled = AgentRateLimitWindow(id: "codex.primary", utilization: 1, resetsAt: now.addingTimeInterval(900))
        #expect(resolver.resolve(scope: scope, failure: request, cached: [cached], polled: snapshot([polled]))
            == .init(resetsAt: request.resetsAt!, windowID: "codex.primary", source: .request))
        let missing = AgentUsageLimit(status: .rejected, windowID: "codex.primary")
        #expect(resolver.resolve(scope: scope, failure: missing, cached: [cached], polled: snapshot([polled]))
            == .init(resetsAt: cached.resetsAt, windowID: "codex.primary", source: .cached))
        #expect(resolver.resolve(scope: scope, failure: missing, polled: snapshot([polled]))
            == .init(resetsAt: polled.resetsAt!, windowID: "codex.primary", source: .poll))
        #expect(resolver.resolve(scope: scope, failure: missing) == nil)
    }

    @Test func cacheNeverCrossesProviderProfileAccountOrHitWindow() {
        let resolver = AgentUsageResetResolver(clock: UsageResetTestClock(now).clock)
        let otherScopes: [AgentUsageLimitScope] = [.init(provider: .claude, accountID: "account-a"),
            .init(provider: .codex, accountID: "account-b"), .init(provider: .codex),
            .init(provider: .codex, providerProfile: "other", accountID: "account-a")]
        var cached = otherScopes.map { AgentUsageResetObservation(scope: $0, windowID: "codex.primary", resetsAt: now.addingTimeInterval(300), observedAt: now) }
        cached.append(.init(scope: scope, windowID: "codex.secondary", resetsAt: now.addingTimeInterval(300), observedAt: now))
        #expect(resolver.resolve(scope: scope, failure: .init(status: .rejected, windowID: "codex.primary"), cached: cached) == nil)
    }

    @Test func knownWindowWinsOverAnEarlierOtherWindowAndWarningsDoNotIdentifyTheHit() {
        let resolver = AgentUsageResetResolver(clock: UsageResetTestClock(now).clock)
        let primary = AgentUsageResetObservation(scope: scope, windowID: "codex.primary", resetsAt: now.addingTimeInterval(3600), observedAt: now)
        let secondary = AgentUsageResetObservation(scope: scope, windowID: "codex.secondary", resetsAt: now.addingTimeInterval(60), observedAt: now)
        #expect(resolver.resolve(scope: scope, failure: .init(status: .rejected, windowID: "codex.primary"), cached: [secondary, primary])?.resetsAt == primary.resetsAt)
        #expect(resolver.resolve(scope: scope, failure: .init(status: .warning, windowID: "codex.primary", resetsAt: primary.resetsAt), cached: [secondary, primary]) == nil)
        #expect(resolver.resolve(scope: scope, failure: nil, cached: [primary, .init(scope: scope,
            windowID: secondary.windowID, resetsAt: secondary.resetsAt, observedAt: now.addingTimeInterval(-1))])?.resetsAt == primary.resetsAt)
    }

    @Test func pollingDoesNotGuessBetweenExhaustedWindows() {
        let resolver = AgentUsageResetResolver(clock: UsageResetTestClock(now).clock)
        let primary = AgentRateLimitWindow(id: "codex.primary", utilization: 1, resetsAt: now.addingTimeInterval(600))
        let secondary = AgentRateLimitWindow(id: "codex.secondary", utilization: 1, resetsAt: now.addingTimeInterval(900))
        #expect(resolver.resolve(scope: scope, failure: nil, polled: snapshot([primary, secondary])) == nil)
        #expect(resolver.resolve(scope: scope, failure: .init(status: .rejected, windowID: "codex.secondary"), polled: snapshot([primary, secondary]))?.resetsAt == secondary.resetsAt)
        #expect(resolver.resolve(scope: scope, failure: nil, polled: snapshot([primary,
            .init(id: secondary.id, utilization: 0.2, resetsAt: secondary.resetsAt)]))?.resetsAt == primary.resetsAt)
        #expect(resolver.resolve(scope: scope, failure: nil, polled: snapshot([primary], scope: .init(provider: .codex, accountID: "account-b"))) == nil)
        #expect(resolver.resolve(scope: .init(provider: .claude), failure: nil, polled: snapshot([primary])) == nil)
        #expect(resolver.resolve(scope: .init(provider: .local), failure: .init(status: .rejected, resetsAt: now), polled: snapshot([primary])) == nil)
    }

    @Test func malformedFutureAndRejectedResetEvidenceCannotCauseTightRetryLoops() {
        let clock = UsageResetTestClock(now), resolver = AgentUsageResetResolver(clock: clock.clock)
        for date in [Date(timeIntervalSince1970: -1), Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            #expect(resolver.resolve(scope: scope, failure: .init(status: .rejected, resetsAt: date)) == nil)
        }
        let stale = AgentUsageLimit(status: .rejected, windowID: "codex.primary", resetsAt: now)
        let cache = AgentUsageResetObservation(scope: scope, windowID: "codex.primary", resetsAt: now, observedAt: now)
        #expect(resolver.resolve(scope: scope, failure: stale, cached: [cache], rejectedAt: now) == nil)
        // Recovery preserves an old known reset so the schedule can expire it.
        #expect(resolver.resolve(scope: scope, failure: stale)?.resetsAt == now)
        let future = AgentUsageResetObservation(scope: scope, windowID: "codex.primary", resetsAt: now.addingTimeInterval(600), observedAt: now.addingTimeInterval(1))
        #expect(resolver.resolve(scope: scope, failure: nil, cached: [future]) == nil)
        clock.advance(1)
        #expect(resolver.resolve(scope: scope, failure: nil, cached: [future])?.resetsAt == future.resetsAt)
    }
}
