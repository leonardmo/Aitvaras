import Foundation

/// Both wall time and waiting are injectable; pure schedule methods never sleep.
public struct AgentAutoContinueClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleepUntil: @Sendable (Date) async throws -> Void
    public init(now: @escaping @Sendable () -> Date,
                sleepUntil: @escaping @Sendable (Date) async throws -> Void) {
        self.now = now; self.sleepUntil = sleepUntil
    }
    public static let live = Self(now: { .now }, sleepUntil: { date in
        try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
    })
}

public struct AgentAutoContinuePlan: Sendable, Equatable {
    public enum State: Sendable, Equatable { case inactive, claimed, waiting, ready, expired }
    public let state: State
    public let continuationAt: Date?
    public let pollAt: Date?
    public let expiresAt: Date?
    public var nextWakeAt: Date? { [continuationAt, pollAt, expiresAt].compactMap { $0 }.min() }

    init(_ state: State, continuationAt: Date? = nil, pollAt: Date? = nil, expiresAt: Date? = nil) {
        self.state = state; self.continuationAt = continuationAt; self.pollAt = pollAt; self.expiresAt = expiresAt
    }
}

public struct AgentAutoContinueSchedule: Sendable {
    public static let fallbackLifetime: TimeInterval = 12 * 3600
    public static let resetLifetime: TimeInterval = 24 * 3600
    public static let pollingInterval: TimeInterval = 10 * 60
    private let clock: AgentAutoContinueClock
    public init(clock: AgentAutoContinueClock = .live) { self.clock = clock }

    public func firstCheck(startedAt: Date, reset: AgentUsageResetResolution?) -> Date {
        if let reset, reset.resetsAt.isUsageResetDate { return max(clock.now(), reset.resetsAt) }
        return startedAt.addingTimeInterval(5 * 60)
    }

    /// rejectedAttempts is 1 after the first rejected continuation, not the original turn.
    /// At most one future attempt is returned, even after a long sleep.
    public func nextFallbackAttempt(startedAt: Date, rejectedAttempts: Int, rejectedAt: Date) -> Date? {
        guard rejectedAttempts > 0, startedAt.isUsageResetDate, rejectedAt.isUsageResetDate,
              rejectedAt >= startedAt else { return nil }
        let interval: TimeInterval = rejectedAttempts == 1 ? 10 * 60 : rejectedAttempts == 2 ? 20 * 60 : 30 * 60
        let date = rejectedAt.addingTimeInterval(interval)
        return date < startedAt.addingTimeInterval(Self.fallbackLifetime) ? date : nil
    }

    public func nextPoll(provider: AgentProvider) -> Date? {
        provider == .codex ? clock.now().addingTimeInterval(Self.pollingInterval) : nil
    }

    public func plan(_ value: AgentAutoContinue) -> AgentAutoContinuePlan {
        guard value.enabled, value.scope.provider != .local,
              value.state == .pending || value.state == .claimed else { return .init(.inactive) }
        // Recovery must use delivery evidence, never schedule another claim here.
        guard value.state != .claimed else { return .init(.claimed) }
        let now = clock.now()
        guard now.isUsageResetDate, value.createdAt.isUsageResetDate,
              value.nextCheckAt.isUsageResetDate, value.fallbackStartedAt.isUsageResetDate,
              value.retryCount >= 0 else { return .init(.expired) }
        let knownReset = value.resetsAt.flatMap { $0.isUsageResetDate ? $0 : nil }
        let expires = knownReset?.addingTimeInterval(Self.resetLifetime)
            ?? value.fallbackStartedAt.addingTimeInterval(Self.fallbackLifetime)
        guard now < expires else { return .init(.expired) }
        let next = knownReset.map { max($0, value.nextCheckAt) }
            ?? max(value.nextCheckAt, value.fallbackStartedAt.addingTimeInterval(5 * 60))
        let continuation = next < expires ? max(now, next) : nil
        let poll: Date?
        if value.scope.provider == .codex {
            let saved = value.nextPollAt.flatMap { $0.isUsageResetDate ? $0 : nil }
                ?? value.createdAt.addingTimeInterval(Self.pollingInterval)
            let date = max(now, saved)
            poll = date < expires ? date : nil
        } else { poll = nil }
        return .init(continuation == now ? .ready : .waiting, continuationAt: continuation, pollAt: poll, expiresAt: expires)
    }
}
