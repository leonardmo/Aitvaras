import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasAgent

@Suite(.timeLimit(.minutes(2))) struct ActivityAttentionTests {
    @Test(arguments: [ActivityRunState.failed, .interrupted])
    func laterSuccessClearsOnlyTheProjectionAndPreservesHistory(state: ActivityRunState) throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.consolidation
        let failure = run(state, key: key, start: 100, finish: 120)
        let success = run(.succeeded, key: key, start: 121, finish: 130)
        try insert([failure, success], into: stores)
        let event = ActivityEvent(kind: .toolExecuted, timestamp: date(110),
            summary: "Example failure", runID: failure.id)
        let step = ActivityRunStep(runID: failure.id, timestamp: date(120), stage: "Example failed stage", state: state)
        try stores.record(event)
        try stores.db.queue.write { try step.insert($0) }

        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityRun(id: failure.id) == failure)
        #expect(try stores.activityRun(id: success.id) == success)
        #expect(try stores.activityEvents(runID: failure.id) == [event])
        #expect(try stores.activityRunSteps(runID: failure.id) == [step])
        #expect(try stores.recentActivity() == [event])
        #expect(try stores.activityRuns().count == 2)
    }

    @Test func otherJobsOverlapsAndAnOlderSuccessFinishingLateDoNotRecover() throws {
        let key = ActivityJobKey.indexing(sourceIDs: ["example-source"])
        let otherKey = ActivityJobKey.indexing(sourceIDs: ["other-source"])
        let cases: [(String?, Double, ActivityRunState)] = [
            (otherKey, 121, .succeeded),
            (key, 110, .succeeded), // Overlap: this attempt started before the failure ended.
            (key, 90, .succeeded),  // An older attempt finishes much later.
            (key, 120, .succeeded), // Strictly after, not at the same instant.
            (key, 121, .cancelled),
            (key, 121, .running),
            (nil, 121, .succeeded)
        ]
        for (successKey, start, state) in cases {
            let stores = try inMemoryStores()
            let failure = run(.failed, key: key, start: 100, finish: 120)
            let other = run(state, key: successKey, start: start, finish: state.isTerminal ? 500 : nil)
            try insert([failure, other], into: stores)
            #expect(try stores.activityAttentionSnapshot().runIDs == [failure.id])
        }
    }

    @Test func successfulNoOpConsolidationIsRecoveryEvidence() async throws {
        let stores = try inMemoryStores()
        let failure = run(.failed, key: ActivityJobKey.consolidation, start: 100, finish: 120)
        try insert([failure], into: stores)
        // No episodes and no engine: this produces a real successful no-op run.
        let consolidator = Consolidator(router: EngineRouter(ranked: []), stores: stores,
            reporter: ActivityReporter(stores: stores))
        let outcome = await consolidator.run(now: date(200))
        #expect(!outcome.ran && !outcome.failed)
        #expect(try stores.activityRuns().contains {
            $0.jobKey == ActivityJobKey.consolidation && $0.state == .succeeded
        })
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityRun(id: failure.id) == failure)
    }

    @Test func unkeyedRunsDoNotGroupOrRecoverAndMissingFinishCannotProveRecovery() throws {
        let stores = try inMemoryStores()
        let first = run(.failed, start: 100, finish: 110)
        let second = run(.interrupted, start: 120, finish: 130)
        let noKeySuccess = run(.succeeded, start: 200, finish: 210)
        let key = ActivityJobKey.consolidation
        let missingFinish = run(.failed, key: key, start: 140, finish: nil)
        let keyedSuccess = run(.succeeded, key: key, start: 200, finish: 210)
        try insert([first, second, noKeySuccess, missingFinish, keyedSuccess], into: stores)
        let snapshot = try stores.activityAttentionSnapshot()
        #expect(Set(snapshot.runIDs) == [first.id, second.id, missingFinish.id])
        #expect(snapshot.groups.count == 3)
        #expect(snapshot.groups.contains { $0.id == .run(first.id) && $0.earlierRuns.isEmpty })
        #expect(snapshot.groups.contains { $0.id == .run(second.id) && $0.earlierRuns.isEmpty })
    }

    @Test func groupingUsesUnresolvedMembersAndSumsCoalescedOccurrences() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.indexing(sourceIDs: ["example-source"])
        let otherKey = ActivityJobKey.indexing(sourceIDs: ["other-source"])
        let recovered = run(.failed, key: key, start: 10, finish: 20, count: 7)
        let success = run(.succeeded, key: key, start: 30, finish: 40)
        let reviewed = run(.failed, key: key, start: 50, finish: 60, acknowledged: 70, count: 9)
        let first = run(.failed, key: key, start: 100, finish: 110, count: 2)
        let latest = run(.interrupted, key: key, start: 150, finish: 160, count: 4)
        let other = run(.failed, key: otherKey, start: 130, finish: 140)
        let unkeyed = run(.failed, start: 170, finish: 180)
        let unknown = run(.outcomeUnknown, key: key, start: 190, finish: 200)
        let anotherUnknown = run(.outcomeUnknown, key: key, start: 195, finish: 205)
        try insert([recovered, success, reviewed, first, latest, other, unkeyed, unknown, anotherUnknown], into: stores)

        let snapshot = try stores.activityAttentionSnapshot()
        #expect(snapshot.groups.map(\.id) == [.run(anotherUnknown.id), .run(unknown.id),
            .run(unkeyed.id), .job(key), .job(otherKey)])
        let group = try #require(snapshot.groups.first { $0.id == .job(key) })
        #expect(group.latestRun == latest)
        #expect(group.earlierRuns == [first])
        #expect(group.totalCount == 6)
        #expect(group.runIDs == [latest.id, first.id])
        #expect(Set(snapshot.bulkDismissibleRunIDs) == [first.id, latest.id, other.id, unkeyed.id])
        #expect(Set(snapshot.runIDs) == [first.id, latest.id, other.id, unkeyed.id, unknown.id, anotherUnknown.id])

        try stores.acknowledgeActivityRun(id: latest.id)
        let remaining = try #require(try stores.activityAttentionSnapshot().groups.first { $0.id == group.id })
        #expect(remaining.latestRun == first)
        #expect(remaining.earlierRuns.isEmpty)
        #expect(remaining.totalCount == 2)
    }

    @Test func orderingPrefersLatestUpdateThenStartAndStableIdentity() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.consolidation
        let first = run(.failed, key: key, start: 100, finish: 110)
        var repeated = run(.failed, key: key, start: 90, finish: 95, count: 3)
        repeated.updatedAt = date(120)
        var tied = run(.interrupted, key: key, start: 100, finish: 120)
        tied.updatedAt = repeated.updatedAt
        try insert([first, repeated, tied], into: stores)
        let before = try stores.activityAttentionSnapshot()
        let group = try #require(before.groups.first)
        #expect(group.latestRun == tied)
        #expect(group.earlierRuns == [repeated, first])
        #expect(try stores.activityAttentionSnapshot() == before)
    }

    @Test func unknownOutcomesStayIndividualUntilAcknowledged() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.queuedDelivery(itemID: UUID())
        let first = run(.outcomeUnknown, key: key, start: 100, finish: 110)
        let second = run(.outcomeUnknown, key: key, start: 120, finish: 130)
        let unkeyed = run(.outcomeUnknown, start: 140, finish: 150)
        let success = run(.succeeded, key: key, start: 200, finish: 210)
        try insert([first, second, unkeyed, success], into: stores)
        let snapshot = try stores.activityAttentionSnapshot()
        #expect(Set(snapshot.runIDs) == [first.id, second.id, unkeyed.id])
        #expect(snapshot.groups.count == 3)
        #expect(snapshot.groups.allSatisfy { $0.id == .run($0.latestRun.id) && $0.earlierRuns.isEmpty })
        #expect(snapshot.bulkDismissibleRunIDs.isEmpty)
        try stores.acknowledgeActivityRun(id: first.id)
        #expect(Set(try stores.activityAttentionSnapshot().runIDs) == [second.id, unkeyed.id])
        #expect(try stores.activityRun(id: second.id) == second)
    }

    @Test func keyedOwnersSuppressTheirUnkeyedFailedHelpers() throws {
        let stores = try inMemoryStores()
        let owner = run(.succeeded, key: ActivityJobKey.consolidation, start: 1, finish: 100)
        let intermediary = run(.succeeded, start: 5, finish: 50, parentID: owner.id)
        let failed = run(.failed, start: 10, finish: 20, parentID: owner.id)
        let interrupted = run(.interrupted, start: 30, finish: 40, parentID: intermediary.id)
        let unknown = run(.outcomeUnknown, start: 60, finish: 70, parentID: owner.id)
        let independent = run(.failed, key: ActivityJobKey.captureSummary(recordID: UUID()),
            start: 20, finish: 30, parentID: owner.id)
        let independentHelper = run(.failed, start: 25, finish: 26, parentID: independent.id)
        let unkeyedOwner = run(.succeeded, start: 1, finish: 100)
        let unkeyedHelper = run(.failed, start: 10, finish: 20, parentID: unkeyedOwner.id)
        let orphan = run(.failed, start: 10, finish: 20, parentID: UUID())
        let noise = (0..<75).map { run(.succeeded, start: Double(1_000 + $0), finish: Double(1_001 + $0)) }
        try insert([owner, intermediary, failed, interrupted, unknown, independent,
            independentHelper, unkeyedOwner, unkeyedHelper, orphan] + noise, into: stores)
        #expect(try stores.activityRuns(limit: 40).allSatisfy { $0.id != owner.id })

        let snapshot = try stores.activityAttentionSnapshot()
        // The failed keyed `independent` owner covers its own helper; only
        // unkeyed owners, orphans and unknown outcomes keep separate rows.
        #expect(Set(snapshot.runIDs) == [unknown.id, independent.id, unkeyedHelper.id, orphan.id])
        #expect(!snapshot.bulkDismissibleRunIDs.contains(unknown.id))
        #expect(try stores.activityRun(id: failed.id) == failed)
        #expect(try stores.activityRun(id: interrupted.id) == interrupted)
    }

    /// A failed summary job and its failed model helper are one Home row, and a
    /// later successful retry of the job clears both.
    @Test func failedOwnerAndHelperAreOneRowAndRecoverTogether() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.captureSummary(recordID: UUID())
        let owner = run(.failed, key: key, start: 10, finish: 20)
        let helper = run(.failed, start: 11, finish: 19, parentID: owner.id)
        try insert([owner, helper], into: stores)
        #expect(try stores.activityAttentionSnapshot().runIDs == [owner.id])
        try insert([run(.succeeded, key: key, start: 30, finish: 40)], into: stores)
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityRun(id: helper.id) == helper)
    }

    @Test func brokenParentCyclesRemainVisibleWithoutHanging() throws {
        let stores = try inMemoryStores()
        var first = run(.failed, start: 100, finish: 110)
        let second = run(.interrupted, start: 100, finish: 110, parentID: first.id)
        first.parentID = second.id
        try insert([first, second], into: stores)
        #expect(Set(try stores.activityAttentionSnapshot().runIDs) == [first.id, second.id])
    }

    @Test func projectionHasNoRecentWindowOrHundredProblemLimit() throws {
        let stores = try inMemoryStores()
        let individual = (0..<125).map { index in
            run(.failed, key: ActivityJobKey.modelPreparation(modelID: "example-model-\(index)"),
                start: Double(100 + index), finish: Double(101 + index))
        }
        let groupKey = ActivityJobKey.captureSummary(recordID: UUID())
        let repeated = (0..<150).map { index in
            run(.interrupted, key: groupKey, start: Double(1_000 + index), finish: Double(1_001 + index))
        }
        let noise = (0..<300).map { run(.succeeded, start: Double(10_000 + $0), finish: Double(10_001 + $0)) }
        try insert(individual + repeated + noise, into: stores)
        #expect(try stores.activityAttentionRuns().count == 100)
        #expect(try stores.activityRuns(limit: 40).allSatisfy { $0.state == .succeeded })
        let snapshot = try stores.activityAttentionSnapshot()
        #expect(snapshot.groups.count == 126)
        #expect(Set(snapshot.runIDs) == Set((individual + repeated).map(\.id)))
        #expect(snapshot.bulkDismissibleRunIDs.count == 275)
        #expect(snapshot.groups.first { $0.id == .job(groupKey) }?.totalCount == 150)

        try insert([run(.succeeded, key: groupKey, start: 5_000, finish: 5_001)], into: stores)
        let recovered = try stores.activityAttentionSnapshot()
        #expect(recovered.groups.count == 125)
        #expect(Set(recovered.runIDs) == Set(individual.map(\.id)))
        #expect(try stores.activityRun(id: repeated[0].id) == repeated[0])
    }

    @Test func codedProblemsNeedManualReviewDespiteSuccessfulServiceChecks() throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let id = reporter.problem(code: .indexing, title: "Example indexing problem", outcome: "Example failure")
        #expect(reporter.problem(code: .indexing, title: "Example indexing problem", outcome: "Repeated failure") == id)
        let problem = try #require(try stores.activityRun(id: id))
        let later = try #require(problem.finishedAt).addingTimeInterval(1)
        reporter.begin(ActivityRun(category: .knowledge, state: .succeeded, title: "Example successful indexing",
            startedAt: later, jobKey: ActivityJobKey.indexing(sourceIDs: ["example-source"])))
        reporter.service(ServiceStatus(id: "indexing", name: "Example indexing", configured: true, enabled: true))
        reporter.serviceCheck(id: "indexing", succeeded: true, at: later)
        let snapshot = try stores.activityAttentionSnapshot()
        #expect(snapshot.runIDs == [id])
        #expect(snapshot.groups.first?.totalCount == 2)
        #expect(try stores.activityRun(id: id) == problem)
        try stores.acknowledgeActivityRun(id: id)
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
    }

    @Test func recoveryGroupingAndUnknownOutcomesSurviveDatabaseReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-query-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite")
        let key = ActivityJobKey.consolidation
        let failure = run(.failed, key: key, start: 100, finish: 110)
        let success = run(.succeeded, key: key, start: 120, finish: 130)
        let unresolved = run(.failed, start: 200, finish: 210)
        let unknown = run(.outcomeUnknown, key: key, start: 140, finish: 150)
        let before: ActivityAttentionSnapshot
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try insert([failure, success, unresolved, unknown], into: stores)
            before = try stores.activityAttentionSnapshot()
            try stores.db.queue.close()
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.activityAttentionSnapshot() == before)
        #expect(Set(before.runIDs) == [unresolved.id, unknown.id])
        #expect(try reopened.activityRun(id: failure.id) == failure)
        try reopened.db.queue.close()
    }

    @Test func unavailableDatabaseThrowsInsteadOfReportingNoProblems() throws {
        let stores = try inMemoryStores()
        try stores.db.queue.write { try $0.execute(sql: "DROP TABLE activityRun") }
        #expect(throws: (any Error).self) { try stores.activityAttentionSnapshot() }
    }

    private func run(_ state: ActivityRunState, key: String? = nil, start: Double, finish: Double?,
                     parentID: UUID? = nil, acknowledged: Double? = nil, count: Int = 1) -> ActivityRun {
        var record = ActivityRun(parentID: parentID, category: .knowledge, trigger: .automatic,
            state: state, title: "Example job", startedAt: date(start), updatedAt: date(finish ?? start),
            acknowledgedAt: acknowledged.map(date), jobKey: key, occurrenceCount: count)
        record.finishedAt = finish.map(date)
        return record
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func insert(_ runs: [ActivityRun], into stores: Stores) throws {
        try stores.db.queue.write { db in
            for run in runs { try run.insert(db) }
        }
    }
}
