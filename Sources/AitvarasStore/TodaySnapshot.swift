import Foundation
import GRDB
import AitvarasCore

/// One read-consistent overview for the app's Today surface. Lists are
/// intentionally bounded for a glanceable dashboard; totals stay exact so the
/// UI can say when more items are waiting without loading them all.
public struct TodaySnapshot: Sendable, Equatable {
    public var day: String
    public var goals: [Goal]
    public var pendingSuggestions: [Suggestion]
    public var pendingSuggestionCount: Int
    public var openQuestions: [CuriosityQuestion]
    public var openQuestionCount: Int
    public var heldNotifications: [HeldNotification]
    public var heldNotificationCount: Int
    public var latestConsolidation: ActivityEvent?
    /// Scheduler watermark for the latest successful run, including a clean
    /// no-op night that correctly produced no activity event.
    public var lastConsolidationCompletedAt: Date?
    public var activeMemoryCount: Int

    public init(
        day: String,
        goals: [Goal] = [],
        pendingSuggestions: [Suggestion] = [],
        pendingSuggestionCount: Int = 0,
        openQuestions: [CuriosityQuestion] = [],
        openQuestionCount: Int = 0,
        heldNotifications: [HeldNotification] = [],
        heldNotificationCount: Int = 0,
        latestConsolidation: ActivityEvent? = nil,
        lastConsolidationCompletedAt: Date? = nil,
        activeMemoryCount: Int = 0
    ) {
        self.day = day
        self.goals = goals
        self.pendingSuggestions = pendingSuggestions
        self.pendingSuggestionCount = pendingSuggestionCount
        self.openQuestions = openQuestions
        self.openQuestionCount = openQuestionCount
        self.heldNotifications = heldNotifications
        self.heldNotificationCount = heldNotificationCount
        self.latestConsolidation = latestConsolidation
        self.lastConsolidationCompletedAt = lastConsolidationCompletedAt
        self.activeMemoryCount = activeMemoryCount
    }

    /// A failed activity entry stops warning as soon as a later successful
    /// run (including a no-op run) advances the durable scheduler watermark.
    public var consolidationNeedsAttention: Bool {
        guard let event = latestConsolidation,
              event.summary.localizedCaseInsensitiveContains("FAILED") else {
            return false
        }
        guard let completed = lastConsolidationCompletedAt else { return true }
        return completed < event.timestamp
    }
}

public extension Stores {
    /// Assemble every currently-shipped Today card in one database snapshot.
    /// A transient read failure therefore preserves the UI's previous complete
    /// snapshot instead of mixing fresh and stale sections.
    func todaySnapshot(
        day: String = Goal.today(),
        suggestionLimit: Int = 3,
        questionLimit: Int = 3,
        heldNotificationLimit: Int = 3
    ) throws -> TodaySnapshot {
        let suggestionLimit = max(0, min(suggestionLimit, 20))
        let questionLimit = max(0, min(questionLimit, 20))
        let heldNotificationLimit = max(0, min(heldNotificationLimit, 20))

        return try db.queue.read { dbc in
            let pendingSuggestions = Suggestion
                .filter(Column("status") == "pending")
            let openQuestions = CuriosityQuestion
                .filter(Column("status") == CuriosityQuestion.Status.open.rawValue)

            return TodaySnapshot(
                day: day,
                goals: try Goal
                    .filter(Column("day") == day)
                    .order(Column("createdAt"))
                    .fetchAll(dbc),
                pendingSuggestions: try pendingSuggestions
                    .order(Column("createdAt").desc)
                    .limit(suggestionLimit)
                    .fetchAll(dbc),
                pendingSuggestionCount: try pendingSuggestions.fetchCount(dbc),
                openQuestions: try openQuestions
                    .order(Column("expectedValue").desc, Column("createdAt"))
                    .limit(questionLimit)
                    .fetchAll(dbc),
                openQuestionCount: try openQuestions.fetchCount(dbc),
                heldNotifications: try HeldNotification
                    .order(Column("createdAt"))
                    .limit(heldNotificationLimit)
                    .fetchAll(dbc),
                heldNotificationCount: try HeldNotification.fetchCount(dbc),
                latestConsolidation: try ActivityEvent
                    .filter(Column("kind") == ActivityEvent.Kind.consolidationRun.rawValue)
                    .order(Column("timestamp").desc)
                    .fetchOne(dbc),
                lastConsolidationCompletedAt: try String.fetchOne(
                    dbc,
                    sql: "SELECT value FROM kv WHERE key = 'consolidator.lastRun'"
                ).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                activeMemoryCount: try Int.fetchOne(
                    dbc,
                    sql: "SELECT COUNT(*) FROM memoryFact WHERE validTo IS NULL"
                ) ?? 0
            )
        }
    }
}
