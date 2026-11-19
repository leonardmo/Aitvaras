import Foundation
import GRDB
import AitvarasCore

/// Exact persisted marker returned by a soft dismissal, for conditional restore.
/// This contains no notification content and does not own an Undo timer.
public struct HeldNotificationDismissal: Sendable, Equatable {
    public let id: UUID
    public let dismissedAt: Date
    /// Only active rows can be dismissed, so the exact prior marker is nil.
    public var previousDismissedAt: Date? { nil }

    public init(id: UUID, dismissedAt: Date) {
        self.id = id
        self.dismissedAt = dismissedAt
    }
}

extension Notification.Name {
    public static let aitvarasHeldNotificationsChanged = Notification.Name("aitvarasHeldNotificationsChanged")
}

extension Stores {
    public static let heldNotificationLifetime: TimeInterval = 24 * 60 * 60
    public static let heldNotificationUndoWindow: TimeInterval = 8

    /// Queue an update and its existing creation audit together.
    public func holdNotification(_ notification: HeldNotification, recording event: ActivityEvent) throws {
        try Self.authorizeHeldNotificationMutation()
        try db.queue.write { db in
            try notification.insert(db)
            try event.insert(db)
        }
        Self.notifyHeldNotificationsChanged(if: true)
    }

    /// Briefing reads and Home use the same active predicate. Expiry and its
    /// audit commit together before any expired content can enter a briefing.
    public func heldNotifications() throws -> [HeldNotification] {
        let now = heldNotificationClock()
        let (items, expired) = try db.queue.write { db in
            let expired = try Self.expireHeldNotifications(in: db, at: now)
            return (try Self.activeHeldNotificationRequest(at: now)
                .order(Column("createdAt"), Column("id")).fetchAll(db), expired)
        }
        Self.notifyHeldNotificationsChanged(if: expired > 0)
        return items
    }

    /// One ID is a single dismissal; several IDs are the held-update portion
    /// of a bulk dismissal. Already hidden, expired or missing IDs do not change.
    public func softDismissHeldNotifications(ids: [UUID]) throws -> [HeldNotificationDismissal] {
        guard !ids.isEmpty else { return [] }
        let now = heldNotificationClock()
        let (changes, expired) = try db.queue.write { db in
            let expired = try Self.expireHeldNotifications(in: db, at: now)
            let changes = try Self.softDismissHeldNotifications(ids: ids, in: db, at: now)
            return (changes, expired)
        }
        Self.notifyHeldNotificationsChanged(if: !changes.isEmpty || expired > 0)
        return changes
    }

    /// Never recreates deleted rows or restores a changed marker. The store
    /// also enforces expiry and the Undo deadline if a caller retains old proofs.
    @discardableResult
    public func restoreHeldNotifications(ifUnchanged changes: [HeldNotificationDismissal]) throws -> [UUID] {
        guard !changes.isEmpty else { return [] }
        let now = heldNotificationClock()
        let (restored, expired) = try db.queue.write { db in
            let expired = try Self.expireHeldNotifications(in: db, at: now)
            let restored = try Self.restoreHeldNotifications(ifUnchanged: changes, in: db, at: now)
            return (restored, expired)
        }
        Self.notifyHeldNotificationsChanged(if: !restored.isEmpty || expired > 0)
        return restored
    }

    /// Purge markers at or before the cutoff, but never inside the Undo window.
    @discardableResult
    public func purgeDismissedHeldNotifications(olderThan cutoff: Date) throws -> Int {
        let now = heldNotificationClock()
        let boundary = min(cutoff, now.addingTimeInterval(-Self.heldNotificationUndoWindow))
        let count = try db.queue.write { db in
            try Self.removeHeldNotifications(HeldNotification.filter(Column("dismissedAt") <= boundary),
                action: .purged, at: now, in: db)
        }
        Self.notifyHeldNotificationsChanged(if: count > 0)
        return count
    }

    /// Run at startup, foreground and wake, and at the next maintenance deadline.
    /// Recently dismissed rows keep their remaining eight seconds after restart.
    @discardableResult
    public func sweepHeldNotifications() throws -> Int {
        let now = heldNotificationClock()
        let count = try db.queue.write { db in
            let expired = try Self.expireHeldNotifications(in: db, at: now)
            let purged = try Self.removeHeldNotifications(HeldNotification.filter(
                Column("dismissedAt") <= now.addingTimeInterval(-Self.heldNotificationUndoWindow)),
                action: .purged, at: now, in: db)
            return expired + purged
        }
        Self.notifyHeldNotificationsChanged(if: count > 0)
        return count
    }

    /// Consumption includes soft-dismissed rows from the exact briefing snapshot.
    /// New arrivals are never cleared merely because composition took time.
    public func clearHeldNotifications(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let now = heldNotificationClock()
        let count = try db.queue.write { db in
            var count = 0
            for batch in Self.heldNotificationIDBatches(ids) {
                count += try Self.removeHeldNotifications(HeldNotification.filter(batch.contains(Column("id"))),
                    action: .consumed, at: now, in: db)
            }
            return count
        }
        Self.notifyHeldNotificationsChanged(if: count > 0)
    }

    /// Includes both retention and dismissal deadlines, even when already due.
    public func nextHeldNotificationMaintenanceAt() throws -> Date? {
        try db.queue.read { db in
            let created = try HeldNotification.all()
                .order(Column("createdAt")).select(Column("createdAt"), as: Date.self).fetchOne(db)
            let dismissed = try HeldNotification.filter(Column("dismissedAt") != nil)
                .order(Column("dismissedAt")).select(Column("dismissedAt"), as: Date.self).fetchOne(db)
            return [created.map { $0.addingTimeInterval(Self.heldNotificationLifetime) },
                    dismissed.map { $0.addingTimeInterval(Self.heldNotificationUndoWindow) }].compactMap { $0 }.min()
        }
    }

    static func activeHeldNotificationRequest(at now: Date) -> QueryInterfaceRequest<HeldNotification> {
        HeldNotification.filter(Column("dismissedAt") == nil).filter(unexpiredHeldNotificationPredicate(at: now))
    }

    // Transaction-taking primitives shared with attention receipts. Callers
    // expire rows first and publish notifications only after commit.
    static func softDismissHeldNotifications(ids: [UUID], in db: Database, at now: Date) throws -> [HeldNotificationDismissal] {
        var changes: [HeldNotificationDismissal] = []
        for batch in Self.heldNotificationIDBatches(ids) {
            let records = try Self.activeHeldNotificationRequest(at: now)
                .filter(batch.contains(Column("id"))).fetchAll(db)
            for var record in records {
                record.dismissedAt = now
                try record.update(db)
                // Return the database's date precision, not a wall-clock
                // value that may differ after GRDB's date encoding.
                if let persisted = try HeldNotification.fetchOne(db, key: record.id),
                   let marker = persisted.dismissedAt {
                    changes.append(HeldNotificationDismissal(id: record.id, dismissedAt: marker))
                }
            }
        }
        try Self.auditHeldNotificationChange(.dismissed, ids: changes.map(\.id), at: now, in: db)
        return changes
    }

    static func restoreHeldNotifications(ifUnchanged changes: [HeldNotificationDismissal], in db: Database, at now: Date) throws -> [UUID] {
        var restored: [UUID] = []
        for change in changes where now < change.dismissedAt.addingTimeInterval(Self.heldNotificationUndoWindow) {
            guard var record = try HeldNotification.filter(Column("id") == change.id)
                .filter(Column("dismissedAt") == change.dismissedAt)
                .filter(Self.unexpiredHeldNotificationPredicate(at: now)).fetchOne(db) else { continue }
            record.dismissedAt = nil
            try record.update(db)
            restored.append(record.id)
        }
        try Self.auditHeldNotificationChange(.restored, ids: restored, at: now, in: db)
        return restored
    }

    static func expireHeldNotifications(in db: Database, at now: Date) throws -> Int {
        try removeHeldNotifications(HeldNotification.filter(
            Column("createdAt") <= now.addingTimeInterval(-heldNotificationLifetime)), action: .expired, at: now, in: db)
    }

    static func notifyHeldNotificationsChanged(if changed: Bool) {
        if changed { NotificationCenter.default.post(name: .aitvarasHeldNotificationsChanged, object: nil) }
    }

    private static func unexpiredHeldNotificationPredicate(at now: Date) -> SQLExpression {
        Column("createdAt") > now.addingTimeInterval(-heldNotificationLifetime)
    }

    private static func heldNotificationIDBatches(_ ids: [UUID]) -> [[UUID]] {
        let ids = Array(Set(ids))
        return stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
    }

    private static func removeHeldNotifications(_ request: QueryInterfaceRequest<HeldNotification>,
                                               action: HeldNotificationChange, at now: Date, in db: Database) throws -> Int {
        let ids = try request.select(Column("id"), as: UUID.self).fetchAll(db)
        guard !ids.isEmpty else { return 0 }
        try request.deleteAll(db)
        try auditHeldNotificationChange(action, ids: ids, at: now, in: db)
        return ids.count
    }

    private static func authorizeHeldNotificationMutation() throws {
        let tool = ToolDefinition(name: "manage_held_updates", description: "Manage locally held updates",
            parametersJSON: "{}", risk: .reversibleWrite)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "notifications") == .allow else {
            throw HeldNotificationMutationError.confirmationRequired
        }
    }

    private static func auditHeldNotificationChange(_ action: HeldNotificationChange, ids: [UUID],
                                                   at now: Date, in db: Database) throws {
        guard !ids.isEmpty else { return }
        // All mutations and this policy/audit boundary share one transaction.
        try authorizeHeldNotificationMutation()
        let payload = HeldNotificationAudit(action: action, count: ids.count, ids: ids)
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try ActivityEvent(kind: .heldNotificationChanged, timestamp: now, connectorID: "notifications",
            summary: "Held updates \(action.rawValue)", detailJSON: json).insert(db)
    }
}

private enum HeldNotificationMutationError: Error { case confirmationRequired }
private enum HeldNotificationChange: String, Encodable { case dismissed, restored, purged, expired, consumed }
private struct HeldNotificationAudit: Encodable {
    let action: HeldNotificationChange
    let count: Int
    let ids: [UUID]
}
