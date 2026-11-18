import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct HomeAttentionMigrationTests {
    @Test func freshDatabaseDefaultsAndRoundTripsAttentionMetadata() throws {
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let oldWriter = PreAttentionActivityRun()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let failed = ActivityRun(parentID: nil, category: .memory, trigger: .automatic,
            state: .failed, title: "Example memory job", startedAt: timestamp,
            acknowledgedAt: timestamp.addingTimeInterval(30),
            jobKey: "fixture.memory", occurrenceCount: 3)
        let succeeded = ActivityRun(parentID: nil, category: .memory, trigger: .automatic,
            state: .succeeded, title: "Example memory job", startedAt: timestamp.addingTimeInterval(60),
            jobKey: "fixture.memory")
        let held = HeldNotification(title: "Example update", body: "An example job finished.",
            createdAt: timestamp, dismissedAt: timestamp.addingTimeInterval(90))
        let pending = HeldNotification(title: "Another update", body: "An example result is available.",
            createdAt: timestamp)

        try stores.db.queue.write { db in
            // Omit the new columns to exercise the database defaults, not the initializer.
            try oldWriter.insert(db)
            try failed.insert(db)
            try succeeded.insert(db)
            try held.insert(db)
            try pending.insert(db)
        }

        let defaulted = try #require(try stores.activityRun(id: oldWriter.id))
        #expect(defaulted.jobKey == nil)
        #expect(defaulted.occurrenceCount == 1)
        #expect(try stores.activityRun(id: failed.id) == failed)
        #expect(try stores.activityRun(id: succeeded.id) == succeeded)
        try stores.db.queue.read { db in
            #expect(try HeldNotification.fetchOne(db, key: held.id) == held)
            #expect(try HeldNotification.fetchOne(db, key: pending.id) == pending)
            #expect(try ActivityRun.filter(Column("jobKey") == "fixture.memory")
                .filter(Column("state") == ActivityRunState.succeeded.rawValue).fetchAll(db) == [succeeded])
            let indexes = try db.indexes(on: "activityRun")
            #expect(indexes.contains {
                $0.name == "activityRunJobSuccess"
                    && $0.columns == ["jobKey", "state", "startedAt"] && !$0.isUnique
            })
        }
    }

    @Test func upgradePreservesHistoryAcknowledgementsAndSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite")
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let reviewed = ActivityRun(parentID: nil, referenceID: "fixture-subject",
            category: .knowledge, trigger: .automatic, state: .failed,
            title: "Index example files", stage: "Embedding", startedAt: timestamp,
            updatedAt: timestamp.addingTimeInterval(10), provider: "Local",
            dataAccess: "Example folder", dataDestination: "Local index",
            outcome: "Provider unavailable", acknowledgedAt: timestamp.addingTimeInterval(20))
        let unresolved = ActivityRun(parentID: reviewed.id, category: .memory,
            trigger: .recovery, state: .interrupted, title: "Example interrupted job",
            startedAt: timestamp.addingTimeInterval(30), outcome: "Nothing replayed")
        let runs = [reviewed, unresolved]
        let event = ActivityEvent(kind: .toolExecuted, timestamp: timestamp,
            summary: "Example job did not finish", runID: reviewed.id)
        let legacyEvent = ActivityEvent(kind: .eventReceived, timestamp: timestamp.addingTimeInterval(1),
            summary: "Earlier example event", causedBy: event.id, runID: nil)
        let step = ActivityRunStep(runID: reviewed.id, timestamp: timestamp,
            stage: "Embedding failed", state: .failed)
        let held = HeldNotification(title: "Saved update", body: "An example result is waiting.",
            createdAt: timestamp)
        let policy = BackgroundWorkPolicy(reviewed: true, allowed: [.indexing])

        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try stores.db.queue.write { db in
                for run in runs { try run.insert(db) }
                try event.insert(db)
                try legacyEvent.insert(db)
                try step.insert(db)
                try held.insert(db)
                // Reconstruct v35 only in this disposable database, preserving its records.
                try db.drop(index: "activityRunJobSuccess")
                try db.execute(sql: "ALTER TABLE activityRun DROP COLUMN jobKey")
                try db.execute(sql: "ALTER TABLE activityRun DROP COLUMN occurrenceCount")
                try db.execute(sql: "ALTER TABLE heldNotification DROP COLUMN dismissedAt")
                try Table<Row>("grdb_migrations")
                    .filter(Column("identifier") == "v36-home-attention").deleteAll(db)
                let columns = try db.columns(in: "activityRun").map(\.name)
                #expect(!columns.contains("jobKey"))
                #expect(!columns.contains("occurrenceCount"))
                #expect(try !db.columns(in: "heldNotification").map(\.name).contains("dismissedAt"))
            }
            try stores.setValue("preserved", forKey: "fixture.unrelated-setting")
            try stores.saveBackgroundWorkPolicy(policy)
            try stores.db.queue.close()
        }

        let migrated = Stores(db: try AitvarasDatabase(url: url))
        #expect(try migrated.activityRuns().count == runs.count)
        for run in runs {
            #expect(try migrated.activityRun(id: run.id) == run)
        }
        #expect(try migrated.activityEvents(runID: reviewed.id) == [event])
        #expect(try migrated.legacyActivity() == [legacyEvent])
        #expect(try migrated.activityRunSteps(runID: reviewed.id) == [step])
        #expect(try migrated.heldNotifications() == [held])
        #expect(try migrated.value(forKey: "fixture.unrelated-setting") == "preserved")
        #expect(try migrated.backgroundWorkPolicy() == policy)

        var updatedRun = reviewed
        updatedRun.jobKey = "fixture.indexing"
        updatedRun.occurrenceCount = 4
        var updatedHeld = held
        updatedHeld.dismissedAt = timestamp.addingTimeInterval(90)
        try migrated.db.queue.write { db in
            try updatedRun.update(db)
            try updatedHeld.update(db)
            #expect(try Table<Row>("grdb_migrations")
                .filter(Column("identifier") == "v36-home-attention").fetchCount(db) == 1)
        }
        try migrated.db.queue.close()

        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.activityRun(id: reviewed.id) == updatedRun)
        #expect(try reopened.activityRun(id: unresolved.id) == unresolved)
        #expect(try reopened.heldNotifications() == [updatedHeld])
        #expect(try reopened.activityEvents(runID: reviewed.id) == [event])
        #expect(try reopened.legacyActivity() == [legacyEvent])
        #expect(try reopened.value(forKey: "fixture.unrelated-setting") == "preserved")
        #expect(try reopened.backgroundWorkPolicy() == policy)
        try reopened.db.queue.close()
    }
}

/// Models an older writer that does not supply either new activity column.
private struct PreAttentionActivityRun: Encodable, PersistableRecord {
    static let databaseTableName = "activityRun"
    let id = UUID()
    let category = ActivityCategory.memory
    let trigger = ActivityTrigger.automatic
    let state = ActivityRunState.running
    let title = "Example background job"
    let startedAt = Date(timeIntervalSince1970: 500)
    let updatedAt = Date(timeIntervalSince1970: 500)
}
