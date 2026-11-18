import Foundation
import GRDB
import Synchronization
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

@Suite(.timeLimit(.minutes(2))) struct HeldNotificationLifecycleTests {
    @Test func exactDayBoundaryDeletesWithOneAuditAndMatchesHomeCounts() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let held = try hold(stores, at: clock.now)
        clock.advance(Stores.heldNotificationLifetime - 0.001)
        #expect(try stores.heldNotifications().map(\.id) == [held.id])
        #expect(try stores.todaySnapshot().heldNotificationCount == 1)
        clock.advance(0.001)
        #expect(try stores.todaySnapshot().heldNotifications.isEmpty)
        #expect(try stores.todaySnapshot().heldNotificationCount == 0)
        #expect(try stores.heldNotifications().isEmpty)
        #expect(try stored(held.id, in: stores) == nil)
        let events = try audits(stores)
        #expect(events.count == 1)
        try expectAudit(events[0], action: "expired", ids: [held.id], at: clock.now)
    }

    @Test func singleAndBulkDismissalsShareTheActivePredicateAndRestore() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let first = try hold(stores, at: clock.now)
        let second = try hold(stores, at: clock.now)
        let remaining = try hold(stores, at: clock.now)
        let single = try stores.softDismissHeldNotifications(ids: [first.id])
        let bulk = try stores.softDismissHeldNotifications(ids: [first.id, second.id, second.id, UUID()])
        #expect(single.map(\.id) == [first.id])
        #expect(bulk.map(\.id) == [second.id])
        #expect(try stores.heldNotifications().map(\.id) == [remaining.id])
        let snapshot = try stores.todaySnapshot(heldNotificationLimit: 0)
        #expect(snapshot.heldNotifications.isEmpty)
        #expect(snapshot.heldNotificationCount == 1)
        #expect(try stores.nextHeldNotificationMaintenanceAt() == clock.now.addingTimeInterval(8))
        clock.advance(7)
        #expect(Set(try stores.restoreHeldNotifications(ifUnchanged: single + bulk)) == [first.id, second.id])
        #expect(try stores.todaySnapshot().heldNotificationCount == 3)
        #expect(try stored(first.id, in: stores) == first)
        #expect(try stored(second.id, in: stores) == second)
        let count = try audits(stores).count
        #expect(try stores.restoreHeldNotifications(ifUnchanged: single + bulk).isEmpty)
        #expect(try stores.softDismissHeldNotifications(ids: []).isEmpty)
        #expect(try audits(stores).count == count)
    }

    @Test func expiryRunsBeforeABriefingRead() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let expired = try hold(stores, at: clock.now.addingTimeInterval(-Stores.heldNotificationLifetime))
        let fresh = try hold(stores, at: clock.now.addingTimeInterval(-1))
        let briefing = try stores.heldNotifications()
        #expect(briefing.map(\.id) == [fresh.id])
        #expect(try stored(expired.id, in: stores) == nil)
        try stores.clearHeldNotifications(ids: briefing.map(\.id))
        #expect(try stores.heldNotifications().isEmpty)
        let events = try audits(stores)
        #expect(events.count == 2)
        try expectAudit(try #require(events.first { $0.summary == "Held updates expired" }),
            action: "expired", ids: [expired.id], at: clock.now)
        try expectAudit(try #require(events.first { $0.summary == "Held updates consumed" }),
            action: "consumed", ids: [fresh.id], at: clock.now)
    }

    @Test func consumptionDuringUndoDeletesOnlyTheComposedBriefingIDs() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let first = try hold(stores, at: clock.now)
        let second = try hold(stores, at: clock.now)
        let briefing = try stores.heldNotifications()
        // Composition is suspended: a new item arrives and an old one is dismissed.
        let arrival = try hold(stores, at: clock.now)
        let changes = try stores.softDismissHeldNotifications(ids: [first.id])
        try stores.clearHeldNotifications(ids: briefing.map(\.id) + [first.id, UUID()])
        #expect(try stores.restoreHeldNotifications(ifUnchanged: changes).isEmpty)
        #expect(try stored(first.id, in: stores) == nil)
        #expect(try stored(second.id, in: stores) == nil)
        #expect(try stores.heldNotifications().map(\.id) == [arrival.id])
        let consumed = try #require(try audits(stores).first { $0.summary == "Held updates consumed" })
        try expectAudit(consumed, action: "consumed", ids: [first.id, second.id], at: clock.now)
    }

    @Test func changedMarkersAndElapsedUndoWindowsCannotBeRestored() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let changed = try hold(stores, at: clock.now)
        let expiredUndo = try hold(stores, at: clock.now)
        let changes = try stores.softDismissHeldNotifications(ids: [changed.id, expiredUndo.id])
        clock.advance(1)
        var altered = try #require(try stored(changed.id, in: stores))
        altered.dismissedAt = clock.now
        try stores.db.queue.write { try altered.update($0) }
        let changedProof = changes.filter { $0.id == changed.id }
        #expect(try stores.restoreHeldNotifications(ifUnchanged: changedProof).isEmpty)
        // An overly generous caller cutoff cannot purge inside the eight seconds.
        #expect(try stores.purgeDismissedHeldNotifications(olderThan: .distantFuture) == 0)
        clock.advance(7)
        #expect(try stores.restoreHeldNotifications(ifUnchanged: changes).isEmpty)
        #expect(try stores.purgeDismissedHeldNotifications(olderThan: clock.now) == 1)
        #expect(try stored(expiredUndo.id, in: stores) == nil)
        #expect(try stored(changed.id, in: stores) != nil)
        clock.advance(1)
        #expect(try stores.purgeDismissedHeldNotifications(olderThan: clock.now) == 1)
        #expect(try stores.nextHeldNotificationMaintenanceAt() == nil)
    }

    @Test func storedDatePrecisionIsUsedByConditionalRestore() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let held = try hold(stores, at: clock.now)
        clock.advance(0.123456)
        let changes = try stores.softDismissHeldNotifications(ids: [held.id])
        let proof = try #require(changes.first)
        #expect(try stored(held.id, in: stores)?.dismissedAt == proof.dismissedAt)
        clock.set(proof.dismissedAt.addingTimeInterval(1))
        #expect(try stores.restoreHeldNotifications(ifUnchanged: changes) == [held.id])
    }

    @Test func retentionExpiryWinsOverAnOutstandingUndoMarker() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let held = try hold(stores, at: clock.now.addingTimeInterval(-Stores.heldNotificationLifetime + 2))
        let changes = try stores.softDismissHeldNotifications(ids: [held.id])
        #expect(try stores.nextHeldNotificationMaintenanceAt() == clock.now.addingTimeInterval(2))
        clock.advance(2)
        #expect(try stores.restoreHeldNotifications(ifUnchanged: changes).isEmpty)
        #expect(try stored(held.id, in: stores) == nil)
        #expect(try stores.todaySnapshot().heldNotificationCount == 0)
    }

    @Test func restartSweepPurgesDueRowsAndSchedulesTheRemainingWindow() throws {
        let clock = HeldUpdateClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("held-sweep-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite")
        let oldID: UUID, youngID: UUID, expiredID: UUID, activeID: UUID
        let next: Date
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url), heldNotificationClock: { clock.now })
            oldID = try hold(stores, at: clock.now).id
            _ = try stores.softDismissHeldNotifications(ids: [oldID])
            clock.advance(6)
            youngID = try hold(stores, at: clock.now).id
            _ = try stores.softDismissHeldNotifications(ids: [youngID])
            next = clock.now.addingTimeInterval(8)
            activeID = try hold(stores, at: clock.now).id
            expiredID = try hold(stores, at: clock.now.addingTimeInterval(-Stores.heldNotificationLifetime)).id
            try stores.db.queue.close()
        }
        clock.advance(2)
        let reopened = Stores(db: try AitvarasDatabase(url: url), heldNotificationClock: { clock.now })
        #expect(try reopened.sweepHeldNotifications() == 2)
        #expect(try stored(oldID, in: reopened) == nil)
        #expect(try stored(expiredID, in: reopened) == nil)
        #expect(try stored(youngID, in: reopened) != nil)
        #expect(try reopened.heldNotifications().map(\.id) == [activeID])
        #expect(try reopened.nextHeldNotificationMaintenanceAt() == next)
        clock.set(next)
        #expect(try reopened.sweepHeldNotifications() == 1)
        let count = try audits(reopened).count
        #expect(try reopened.sweepHeldNotifications() == 0)
        #expect(try audits(reopened).count == count)
        #expect(try reopened.todaySnapshot().heldNotificationCount == 1)
        try reopened.db.queue.close()
    }

    @Test func bulkIDsCrossBatchBoundariesWithoutClearingNewArrivals() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let original = try (0..<501).map { _ in try hold(stores, at: clock.now).id }
        let arrival = try hold(stores, at: clock.now)
        let changes = try stores.softDismissHeldNotifications(ids: original + original)
        #expect(Set(changes.map(\.id)) == Set(original))
        #expect(try stores.todaySnapshot().heldNotificationCount == 1)
        #expect(try stores.heldNotifications().map(\.id) == [arrival.id])
        #expect(Set(try stores.restoreHeldNotifications(ifUnchanged: changes)) == Set(original))
        #expect(try stores.todaySnapshot(heldNotificationLimit: 0).heldNotificationCount == 502)
    }

    @Test func lifecycleAuditsNeverContainContentOrBecomeMemoryEvidence() throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let held = HeldNotification(title: "EXAMPLE_TITLE_MARKER", body: "EXAMPLE_BODY_MARKER", createdAt: clock.now)
        try stores.holdNotification(held, recording: ActivityEvent(kind: .notificationQueued, summary: "Example update held"))
        let changes = try stores.softDismissHeldNotifications(ids: [held.id])
        _ = try stores.restoreHeldNotifications(ifUnchanged: changes)
        try stores.clearHeldNotifications(ids: [held.id])
        let events = try audits(stores)
        #expect(events.count == 3)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!json.contains(held.title))
        #expect(!json.contains(held.body))
        #expect(!Consolidator.isMemoryEvidence(.heldNotificationChanged))
        for event in events {
            let data = try #require(event.detailJSON?.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(payload.keys) == ["action", "count", "ids"])
        }
    }

    @Test(arguments: ["dismissed", "restored", "purged", "expired", "consumed", "snapshot", "sweep"])
    func failedAuditRollsBackTheEntireMutation(action: String) throws {
        let clock = HeldUpdateClock()
        let stores = try makeStores(clock)
        let created = ["expired", "snapshot", "sweep"].contains(action)
            ? clock.now.addingTimeInterval(-Stores.heldNotificationLifetime) : clock.now
        let held = try hold(stores, at: created)
        let changes = ["restored", "purged"].contains(action)
            ? try stores.softDismissHeldNotifications(ids: [held.id]) : []
        if action == "purged" { clock.advance(8) }
        let before = try stored(held.id, in: stores)
        let eventCount = try stores.recentActivity().count
        try stores.db.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_held_lifecycle_audit BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'heldNotificationChanged'
                BEGIN SELECT RAISE(ABORT, 'injected lifecycle audit failure'); END
                """)
        }
        #expect(throws: (any Error).self) {
            switch action {
            case "dismissed": _ = try stores.softDismissHeldNotifications(ids: [held.id])
            case "restored": _ = try stores.restoreHeldNotifications(ifUnchanged: changes)
            case "purged": _ = try stores.purgeDismissedHeldNotifications(olderThan: clock.now)
            case "expired": _ = try stores.heldNotifications()
            case "consumed": try stores.clearHeldNotifications(ids: [held.id])
            case "snapshot": _ = try stores.todaySnapshot()
            default: _ = try stores.sweepHeldNotifications()
            }
        }
        #expect(try stored(held.id, in: stores) == before)
        #expect(try stores.recentActivity().count == eventCount)
    }

    private func makeStores(_ clock: HeldUpdateClock) throws -> Stores {
        Stores(db: try AitvarasDatabase(url: nil), heldNotificationClock: { clock.now })
    }

    private func hold(_ stores: Stores, at date: Date) throws -> HeldNotification {
        let held = HeldNotification(title: "Example update", body: "Example content", createdAt: date)
        try stores.holdNotification(held, recording: ActivityEvent(kind: .notificationQueued,
            timestamp: date, summary: "Example update held"))
        return held
    }

    private func stored(_ id: UUID, in stores: Stores) throws -> HeldNotification? {
        try stores.db.queue.read { try HeldNotification.fetchOne($0, key: id) }
    }

    private func audits(_ stores: Stores) throws -> [ActivityEvent] {
        try stores.recentActivity().filter { $0.kind == .heldNotificationChanged }
    }

    private func expectAudit(_ event: ActivityEvent, action: String, ids: Set<UUID>, at date: Date) throws {
        let data = try #require(event.detailJSON?.data(using: .utf8))
        let payload = try JSONDecoder().decode(HeldAuditPayload.self, from: data)
        #expect(payload.action == action)
        #expect(payload.count == ids.count)
        #expect(Set(payload.ids) == ids)
        #expect(event.timestamp == date)
    }
}

private final class HeldUpdateClock: Sendable {
    private let instant = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { instant.withLock { $0 } }
    func set(_ date: Date) { instant.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { instant.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

private struct HeldAuditPayload: Decodable {
    let action: String
    let count: Int
    let ids: [UUID]
}
