import Foundation
import GRDB
import AitvarasCore

extension Stores {
    /// Read every unresolved terminal problem in one database snapshot, before
    /// any UI limit or pagination. Recovery never acknowledges or changes a run.
    /// Coded problems remain manual-only today: their producers record no
    /// successful run with the same problem key. Service counters and successful
    /// runs with other keys are deliberately not recovery evidence.
    public func activityAttentionSnapshot() throws -> ActivityAttentionSnapshot {
        try db.queue.read { db in
            let problem = TableAlias<ActivityRun>(name: "attentionProblem")
            let success = TableAlias<ActivityRun>(name: "attentionSuccess")
            let laterSuccess = ActivityRun.aliased(success)
                .filter(success["state"] == ActivityRunState.succeeded.rawValue)
                .filter(success["jobKey"] == problem["jobKey"])
                .filter(success["id"] != problem["id"])
                .filter(success["startedAt"] > problem["finishedAt"])
            // SQL NULL comparisons cannot establish recovery for an unkeyed
            // run or a failure whose finish was never recorded.
            let candidates = try ActivityRun.aliased(problem)
                .filter([ActivityRunState.failed.rawValue, ActivityRunState.interrupted.rawValue,
                         ActivityRunState.outcomeUnknown.rawValue].contains(problem["state"]))
                .filter(problem["acknowledgedAt"] == nil)
                .filter(problem["state"] == ActivityRunState.outcomeUnknown.rawValue || !laterSuccess.exists())
                .order(problem["updatedAt"].desc, problem["startedAt"].desc, problem["id"].desc)
                .fetchAll(db)

            let ancestors = try ActivityAttentionQuery.ancestors(of: candidates, in: db)
            let visible = candidates.filter { !ActivityAttentionQuery.isCompletedHelper($0, ancestors: ancestors) }
            let members = Dictionary(grouping: visible, by: ActivityAttentionQuery.groupID)
            var emitted: Set<ActivityAttentionGroup.ID> = []
            let groups: [ActivityAttentionGroup] = visible.compactMap { run in
                let id = ActivityAttentionQuery.groupID(run)
                guard emitted.insert(id).inserted else { return nil }
                return ActivityAttentionGroup(id: id, latestRun: run,
                    earlierRuns: Array(members[id, default: []].dropFirst()))
            }
            return ActivityAttentionSnapshot(groups: groups)
        }
    }
}

private enum ActivityAttentionQuery {
    static func groupID(_ run: ActivityRun) -> ActivityAttentionGroup.ID {
        if (run.state == .failed || run.state == .interrupted), let key = run.jobKey {
            return .job(key)
        }
        return .run(run.id)
    }

    /// Fetch only the referenced ancestry, including owners outside recent
    /// history. Batches avoid SQLite's bound-variable limit; visited IDs also
    /// keep missing references and malformed cycles finite.
    static func ancestors(of runs: [ActivityRun], in db: Database) throws -> [UUID: ActivityRun] {
        var records = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var visited = Set(records.keys)
        var pending = Set(runs.compactMap(\.parentID)).subtracting(visited)
        while !pending.isEmpty {
            let ids = Array(pending)
            visited.formUnion(pending)
            var parents: [ActivityRun] = []
            for offset in stride(from: 0, to: ids.count, by: 500) {
                let batch = Array(ids[offset..<min(offset + 500, ids.count)])
                parents += try ActivityRun.filter(batch.contains(Column("id"))).fetchAll(db)
            }
            for parent in parents { records[parent.id] = parent }
            pending = Set(parents.compactMap(\.parentID)).subtracting(visited)
        }
        return records
    }

    static func isCompletedHelper(_ run: ActivityRun, ancestors: [UUID: ActivityRun]) -> Bool {
        // A key identifies an independent owner, not a model/provider helper.
        guard run.jobKey == nil, run.state == .failed || run.state == .interrupted else { return false }
        var parentID = run.parentID
        var visited: Set<UUID> = [run.id]
        while let id = parentID, visited.insert(id).inserted, let parent = ancestors[id] {
            // A failed inner owner must not be masked by an outer success.
            if parent.jobKey != nil { return parent.state == .succeeded }
            parentID = parent.parentID
        }
        return false
    }
}
