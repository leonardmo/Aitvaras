import Foundation
import AitvarasCore

/// View-independent History filter/navigation state. Attention is a complete
/// cross-kind list; operation-only filters must not silently hide its notices
/// or decisions when Home sends the user here.
public struct ActivityHistoryFilters: Sendable, Equatable {
    public enum Mode: Sendable, Hashable { case all, attention }
    public var mode: Mode = .all
    public var search = ""
    public var category: ActivityCategory?
    public var state: ActivityRunState?
    public var period = "all"
    public var fromDate: Date
    public var throughDate: Date

    public init(now: Date = .now, calendar: Calendar = .current) {
        fromDate = calendar.startOfDay(for: now)
        throughDate = now
    }

    /// The visible filter and Home's overflow route use exactly this transition.
    public mutating func select(_ mode: Mode, now: Date = .now, calendar: Calendar = .current) {
        if mode == .attention { self = ActivityHistoryFilters(now: now, calendar: calendar) }
        self.mode = mode
    }

    @discardableResult
    public mutating func consumeAttentionRequest(_ pending: inout Bool, now: Date = .now,
                                                calendar: Calendar = .current) -> Bool {
        guard pending else { return false }
        select(.attention, now: now, calendar: calendar)
        pending = false
        return true
    }
}

/// Pages logical rows from the same full projection that Home caps at five.
/// This never consults visibleRows or imposes a total row limit.
public struct AttentionHistoryPage: Sendable, Equatable {
    public let rows: [HomeAttentionRow]
    public let totalCount: Int
    public let nextOffset: Int
    public var hasMore: Bool { nextOffset < totalCount }

    public init(card: HomeAttentionCard, offset: Int = 0, limit: Int = 50) {
        totalCount = card.rows.count
        let start = min(max(0, offset), totalCount)
        let count = min(max(0, limit), totalCount - start)
        nextOffset = start + count
        rows = Array(card.rows[start..<nextOffset])
    }
}
