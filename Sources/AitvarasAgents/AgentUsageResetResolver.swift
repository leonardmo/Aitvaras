import Foundation

public struct AgentUsageResetResolution: Sendable, Equatable {
    public let resetsAt: Date
    public let windowID: String?
    public let source: AgentUsageResetSource
    public init(resetsAt: Date, windowID: String?, source: AgentUsageResetSource) {
        self.resetsAt = resetsAt; self.windowID = windowID; self.source = source
    }
}

/// A poll is useful only for the account/profile that produced it.
public struct AgentUsageLimitSnapshot: Sendable {
    public let scope: AgentUsageLimitScope
    public let windows: [AgentRateLimitWindow]
    public let observedAt: Date
    public init(scope: AgentUsageLimitScope, windows: [AgentRateLimitWindow], observedAt: Date) {
        self.scope = scope; self.windows = windows; self.observedAt = observedAt
    }
}

/// Selection only: callers obtain snapshots through the policy boundary.
public struct AgentUsageResetResolver: Sendable {
    private let clock: AgentAutoContinueClock
    public init(clock: AgentAutoContinueClock = .live) { self.clock = clock }

    /// After another rejection, evidence at/before that attempt is stale.
    /// Recovery leaves rejectedAt nil so the schedule can enforce the 24 h cutoff.
    public func resolve(scope: AgentUsageLimitScope, failure: AgentUsageLimit?,
                        cached: [AgentUsageResetObservation] = [], polled: AgentUsageLimitSnapshot? = nil,
                        rejectedAt: Date? = nil) -> AgentUsageResetResolution? {
        guard scope.provider != .local else { return nil }
        let now = clock.now()
        func usable(_ date: Date) -> Bool {
            guard date.isUsageResetDate else { return false }
            if let rejectedAt { return date > rejectedAt }
            return true
        }
        let hit = failure?.status == .rejected ? failure : nil
        if let reset = hit?.resetsAt, usable(reset) {
            return .init(resetsAt: reset, windowID: hit?.windowID, source: .request)
        }
        let matching = cached.filter {
            $0.scope == scope && $0.observedAt <= now && $0.observedAt.timeIntervalSince1970.isFinite
                && (hit?.windowID == nil || $0.windowID == hit?.windowID) && usable($0.resetsAt)
        }
        if let newest = matching.map(\.observedAt).max() {
            let latest = matching.filter { $0.observedAt == newest }
            // A simultaneous multi-window observation does not identify the hit window.
            if Set(latest.map(\.windowID)).count == 1, let value = latest.first {
                return .init(resetsAt: value.resetsAt, windowID: value.windowID, source: .cached)
            }
        }
        guard scope.provider == .codex, let polled, polled.scope == scope,
              polled.observedAt <= now, polled.observedAt.timeIntervalSince1970.isFinite else { return nil }
        let candidates = polled.windows.filter {
            (hit?.windowID == nil || $0.id == hit?.windowID) && $0.resetsAt.map(usable) == true
        }
        let exhausted = candidates.filter { $0.utilization == 1 }
        let selected = hit?.windowID != nil ? candidates : exhausted.isEmpty ? candidates : exhausted
        guard selected.count == 1, let value = selected.first, let reset = value.resetsAt else { return nil }
        return .init(resetsAt: reset, windowID: value.id, source: .poll)
    }
}

extension Date {
    var isUsageResetDate: Bool {
        let seconds = timeIntervalSince1970
        return seconds.isFinite && seconds > 0 && seconds < 253_402_300_800
    }
}
