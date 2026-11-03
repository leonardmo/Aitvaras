import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

@Suite struct ActivityMonitoringTests {
    @Test func stagesWithTheSameTimestampKeepInsertionOrder() throws {
        let stores = try inMemoryStores()
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 100)
        try stores.db.queue.write { db in
            try ActivityRunStep(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, runID: id,
                timestamp: timestamp, stage: "First", state: .running).insert(db)
            try ActivityRunStep(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, runID: id,
                timestamp: timestamp, stage: "Second", state: .succeeded).insert(db)
        }
        #expect(try stores.activityRunSteps(runID: id).map(\.stage) == ["First", "Second"])
    }

    @Test func repeatedProblemsDeduplicateAcrossReporterInstancesUntilReviewed() throws {
        let stores = try inMemoryStores()
        let first = ActivityReporter(stores: stores).problem(title: "Folder check unavailable", outcome: "Retry later")
        let second = ActivityReporter(stores: stores).problem(title: "Folder check unavailable", outcome: "Still unavailable")
        #expect(first == second)
        #expect(try stores.activityAttentionRuns().count == 1)
        #expect(try stores.activityRun(id: first)?.outcome == "Still unavailable")
        try stores.acknowledgeActivityRun(id: first)
        let next = ActivityReporter(stores: stores).problem(title: "Folder check unavailable", outcome: "New incident")
        #expect(next != first)
        #expect(try stores.activityRuns().count == 2)
    }

    @Test func stageTransitionsAreDurableButProgressDoesNotFloodTimeline() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let id = reporter.begin(ActivityRun(category: .knowledge, title: "Index notes", stage: "Scanning"))
        reporter.update(id: id, stage: "Embedding", progressCompleted: 0, progressTotal: 20)
        for value in 1...20 { reporter.update(id: id, stage: "Embedding", progressCompleted: value) }
        reporter.update(id: id, stage: "Waiting for storage", state: .waiting)
        reporter.finish(id: id, state: .succeeded, outcome: "Index saved")
        let steps = try stores.activityRunSteps(runID: id)
        #expect(steps.map(\.stage) == ["Scanning", "Embedding", "Waiting for storage", "Index saved"])
        #expect(steps.map(\.state) == [.running, .running, .waiting, .succeeded])
        #expect(reporter.failureMessage == nil)
    }

    @Test func unresolvedProblemsSurviveNewerHistoryUntilReviewed() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let old = ActivityRun(category: .system, state: .failed, title: "Older failure",
                              startedAt: Date(timeIntervalSince1970: 100))
        reporter.begin(old)
        for _ in 0..<350 { reporter.begin(ActivityRun(category: .chat, state: .succeeded, title: "Newer success")) }
        #expect(try stores.activityAttentionRuns().map(\.id) == [old.id])
        try stores.acknowledgeActivityRun(id: old.id)
        #expect(try stores.activityAttentionRuns().isEmpty)
        #expect(try stores.activityRun(id: old.id)?.state == .failed)
        #expect(try stores.activityRun(id: old.id)?.acknowledgedAt != nil)
    }
    @Test func stableLifecycleAndLateUpdatesNeverReopenTerminalRun() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let run = ActivityRun(category: .knowledge, title: "Index documents")
        #expect(reporter.begin(run) == run.id)
        reporter.update(id: run.id, stage: "Embedding", progressCompleted: 2, progressTotal: 10)
        #expect(try stores.activityRun(id: run.id)?.progressCompleted == 2)
        #expect(try stores.currentActivityRuns().count == 1)
        reporter.finish(id: run.id, state: .succeeded, outcome: "Index updated")
        let completed = try #require(try stores.activityRun(id: run.id))
        #expect(completed.finishedAt != nil)
        reporter.begin(run)
        reporter.update(id: run.id, state: .running)
        reporter.finish(id: run.id, state: .failed)
        #expect(try stores.activityRun(id: run.id) == completed)
        #expect(try stores.currentActivityRuns().isEmpty)
        #expect(reporter.failureMessage == nil)
    }

    @Test func taskContextLinksRunsAndEventsWithoutChangingLegacyDecoding() throws {
        let stores = try inMemoryStores()
        let parent = UUID()
        try ActivityTaskContext.$runID.withValue(parent) {
            try ActivityTaskContext.$trigger.withValue(.automatic) {
                let child = ActivityRun(category: .model, title: "Model request")
                #expect(child.parentID == parent)
                #expect(child.trigger == .automatic)
                try stores.record(ActivityEvent(kind: .toolExecuted, summary: "Tool completed"))
            }
        }
        #expect(try stores.activityEvents(runID: parent).count == 1)
        let legacy = ActivityEvent(kind: .eventReceived, summary: "Legacy event", runID: nil)
        let data = try JSONEncoder().encode(legacy)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "runID")
        let decoded = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.runID == nil)
    }

    @Test func recoveryMarksUnfinishedRowsWithoutReplayingOrChangingCompletedRows() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let local = reporter.begin(ActivityRun(category: .knowledge, title: "Index"))
        let external = reporter.begin(ActivityRun(category: .delivery, title: "Send notification"))
        let queued = reporter.begin(ActivityRun(category: .delivery, state: .queued, title: "Queued delivery"))
        let completed = reporter.begin(ActivityRun(category: .chat, state: .succeeded, title: "Done"))
        let before = try stores.activityRun(id: completed)
        reporter.recoverInterruptedRuns()
        #expect(try stores.activityRun(id: local)?.state == .interrupted)
        #expect(try stores.activityRun(id: external)?.state == .outcomeUnknown)
        #expect(try stores.activityRun(id: queued)?.state == .interrupted)
        #expect(try stores.activityRun(id: completed) == before)
        let recovered = try stores.activityRuns()
        reporter.recoverInterruptedRuns()
        #expect(try stores.activityRuns() == recovered)
        #expect(try stores.currentActivityRuns().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func historyPaginationAndFiltersReachBeyondThreeHundredRows() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<425 {
            reporter.begin(ActivityRun(category: index.isMultiple(of: 2) ? .knowledge : .chat,
                                       state: .succeeded, title: "Batch \(index)",
                                       startedAt: start.addingTimeInterval(Double(index))))
        }
        let old = try stores.activityRuns(limit: 50, offset: 400)
        #expect(old.count == 25)
        #expect(old.last?.title == "Batch 0")
        let filtered = try stores.activityRuns(filter: ActivityRunFilter(
            category: .knowledge, state: .succeeded, search: "batch",
            since: start, until: start.addingTimeInterval(20)), limit: 100)
        #expect(filtered.count == 11)
        #expect(try stores.activityRuns(filter: ActivityRunFilter(search: "%")).isEmpty)
        #expect(try stores.activityRuns(limit: 0).isEmpty)
    }

    @Test func legacyHistoryPaginationDoesNotDuplicateLinkedEvents() throws {
        let stores = try inMemoryStores()
        for index in 0..<325 {
            try stores.record(ActivityEvent(kind: .classification,
                timestamp: Date(timeIntervalSince1970: Double(index)), summary: "Legacy \(index)", runID: nil))
        }
        try stores.record(ActivityEvent(kind: .classification, summary: "Linked", runID: UUID()))
        #expect(try stores.legacyActivity(limit: 50, offset: 300).count == 25)
        #expect(try stores.legacyActivity(search: "Linked").isEmpty)
        #expect(try stores.legacyActivity(search: "Legacy", since: Date(timeIntervalSince1970: 10),
                                          until: Date(timeIntervalSince1970: 20)).count == 11)
    }

    @Test func idleChecksAggregateWithoutHistoryFloodAndUpsertsKeepCounters() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        reporter.service(ServiceStatus(id: "test-service", name: "Test service", configured: true, enabled: true))
        let day = Date(timeIntervalSince1970: 1_728_000_000)
        for _ in 0..<100 { reporter.serviceCheck(id: "test-service", succeeded: true, at: day) }
        reporter.serviceCheck(id: "test-service", succeeded: false, at: day)
        reporter.service(ServiceStatus(id: "test-service", name: "Test service", configured: true, paused: true))
        let status = try #require(try stores.serviceStatuses().first)
        #expect(status.dailyChecks == 101)
        #expect(status.dailySuccesses == 100)
        #expect(status.lastSuccess == day)
        #expect(status.paused)
        #expect(try stores.serviceStatuses().count == 1)
        #expect(try stores.activityRuns().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
        reporter.serviceCheck(id: "test-service", succeeded: false, at: day.addingTimeInterval(86_400))
        #expect(try stores.serviceStatuses().first?.dailyChecks == 1)
        #expect(try stores.serviceStatuses().first?.dailySuccesses == 0)
        let summaries = try stores.serviceCheckSummaries()
        #expect(summaries.count == 2)
        #expect(summaries.first?.checks == 1)
        #expect(summaries.last?.checks == 101)
        #expect(summaries.last?.successes == 100)
        #expect(try stores.serviceCheckSummaries(limit: 1, offset: 1).first?.checks == 101)
        #expect(try stores.serviceCheckSummaries(since: day.addingTimeInterval(1)).count == 1)
        #expect(try stores.activityRuns().isEmpty)
    }

    @Test func policyDefaultsClosedPersistsAndAlwaysAllowsManualWork() throws {
        let stores = try inMemoryStores()
        var policy = try stores.backgroundWorkPolicy()
        for feature in BackgroundFeature.allCases {
            #expect(!policy.permits(feature))
            #expect(policy.permits(feature, trigger: .manual))
        }
        policy.reviewed = true
        policy.allowed = [.mail, .indexing]
        try stores.saveBackgroundWorkPolicy(policy)
        #expect(try stores.backgroundWorkPolicy() == policy)
        #expect(policy.permits(.mail))
        #expect(!policy.permits(.memory))
        policy.paused = true
        #expect(!policy.permits(.mail, trigger: .startup))
        #expect(!policy.permits(.mail, trigger: .recovery))
        #expect(policy.permits(.mail, trigger: .manual))
        policy.version += 1
        #expect(!policy.permits(.mail))
        #expect(throws: ActivityMonitoringError.self) { try stores.saveBackgroundWorkPolicy(policy) }
    }

    @Test func corruptPolicyThrowsAndReporterFailureIsStickyWithoutDatabaseDetails() throws {
        let stores = try inMemoryStores()
        try stores.setValue("not-json", forKey: "backgroundWorkPolicy.v1")
        #expect(throws: (any Error).self) { try stores.backgroundWorkPolicy() }
        let reporter = ActivityReporter(stores: stores)
        try stores.db.queue.write { try $0.execute(sql: "DROP TABLE activityRun") }
        reporter.begin(ActivityRun(category: .system, title: "Sensitive-looking title must not leak"))
        let failure = try #require(reporter.failureMessage)
        #expect(!failure.contains("Sensitive"))
        #expect(!failure.contains("SQL"))
        reporter.service(ServiceStatus(id: "test-service", name: "Test service"))
        #expect(reporter.failureMessage == failure)
    }

    @Test func additiveMigrationPreservesLegacyEventsAndUnrelatedState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("monitoring-test-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let event = ActivityEvent(kind: .eventReceived, timestamp: Date(timeIntervalSince1970: 1_000_000),
                                  summary: "Existing history", runID: nil)
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try stores.record(event)
            try stores.setValue("preserved", forKey: "synthetic-preexisting-setting")
            // Reconstruct the previous schema in this temporary fixture only.
            try stores.db.queue.write { db in
                try db.execute(sql: "DROP TABLE activityRun")
                try db.execute(sql: "DROP TABLE serviceStatus")
                try db.execute(sql: "DROP TABLE serviceCheckSummary")
                for index in try db.indexes(on: "activityEvent") where index.columns.contains("runID") {
                    try db.execute(sql: "DROP INDEX \(index.name.quotedDatabaseIdentifier)")
                }
                try db.execute(sql: "ALTER TABLE activityEvent DROP COLUMN runID")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v13-activity-monitoring'")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v15-activity-review'")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-service-check-summaries'")
            }
        }
        let migrated = Stores(db: try AitvarasDatabase(url: url))
        #expect(try migrated.legacyActivity() == [event])
        #expect(try migrated.value(forKey: "synthetic-preexisting-setting") == "preserved")
        #expect(try migrated.backgroundWorkPolicy() == BackgroundWorkPolicy())
        #expect(try migrated.activityRuns().isEmpty)
    }
}
