import Foundation
import GRDB
import Synchronization
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

@Suite(.timeLimit(.minutes(2))) struct AttentionDismissalTests {
    @Test func bulkUsesAllRowsAndSkipsDecisionsCapturesUnknownsAndMonitoring() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let failures = (0..<275).map { run(.failed, start: Double($0)) }
        let interrupted = run(.interrupted, key: ActivityJobKey.consolidation)
        let unknown = run(.outcomeUnknown, key: ActivityJobKey.consolidation)
        let waitingCapture = run(.waiting, category: .capture)
        let approval = run(.awaitingApproval)
        let success = run(.succeeded)
        try insert(failures + [interrupted, unknown, waitingCapture, approval, success], into: stores)
        let held = try hold(stores, at: clock.wall)
        let suggestion = Suggestion(createdAt: clock.wall, title: "Example suggestion", detail: "Example decision",
            connectorID: "example", toolName: "example", argumentsJSON: "{}")
        try stores.db.queue.write { try suggestion.insert($0) }
        try stores.setValue("retained", forKey: "example.setting")
        let policy = try stores.backgroundWorkPolicy()

        let receipt = try stores.dismissAllAttention()
        #expect(Set(receipt.runs.map { $0.written.id }) == Set(failures.map(\.id) + [interrupted.id]))
        #expect(receipt.itemCount == 278) // 276 problem rows, update, prompt.
        #expect(receipt.heldUpdates.map(\.id) == [held.id])
        #expect(receipt.monitoringIncidentID == nil)
        #expect(try stores.activityAttentionSnapshot().runIDs == [unknown.id])
        for unchanged in [unknown, waitingCapture, approval, success] {
            #expect(try stores.activityRun(id: unchanged.id) == unchanged)
        }
        #expect(try stores.db.queue.read { try Suggestion.fetchOne($0, key: suggestion.id) } == suggestion)
        #expect(try stores.heldNotifications().isEmpty)
        #expect(try stores.automaticWorkPromptDeferred())
        #expect(try stores.backgroundWorkPolicy() == policy)
        #expect(!policy.permits(.memory))
        #expect(try stores.value(forKey: "example.setting") == "retained")
        #expect(try stores.activityRuns(limit: 1000).count == failures.count + 5)

        let restored = try stores.undoAttentionDismissal(receipt)
        #expect(Set(restored.runIDs) == Set(receipt.runs.map { $0.written.id }))
        #expect(restored.heldUpdateIDs == [held.id])
        #expect(restored.restoredPrompt)
        #expect(!(try stores.automaticWorkPromptDeferred()))
        #expect(try stores.activityAttentionSnapshot().runIDs.count == 277)
        #expect(try stores.heldNotifications() == [held])
    }

    @Test func groupUsesExactRepresentedMembersAndCountsOneLogicalItem() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let key = ActivityJobKey.consolidation
        let first = run(.failed, key: key, count: 3)
        let second = run(.interrupted, key: key, start: 120)
        try insert([first, second], into: stores)
        let group = try #require(try stores.activityAttentionSnapshot().groups.first)
        let arrival = run(.failed, key: key, start: 150)
        try insert([arrival], into: stores)
        let receipt = try stores.dismissAttentionProblemGroup(group)
        #expect(receipt.itemCount == 1)
        #expect(Set(receipt.runs.map { $0.written.id }) == [first.id, second.id])
        #expect(try stores.activityAttentionSnapshot().runIDs == [arrival.id])
        let newerFailure = run(.failed, key: key, start: 170)
        try insert([newerFailure], into: stores)
        let restored = try stores.undoAttentionDismissal(receipt)
        #expect(Set(restored.runIDs) == [first.id, second.id])
        #expect(try stores.activityRun(id: arrival.id) == arrival)
        #expect(try stores.activityRun(id: newerFailure.id) == newerFailure)
        #expect(try stores.activityAttentionSnapshot().groups.first?.totalCount == 6)
    }

    @Test func staleCoalescedRowDoesNotAcknowledgeANewerOccurrence() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let problem = run(.failed, key: ActivityJobKey.consolidation)
        try insert([problem], into: stores)
        let group = try #require(try stores.activityAttentionSnapshot().groups.first)
        var repeated = problem
        repeated.occurrenceCount += 1
        try stores.db.queue.write { try repeated.update($0) }
        #expect(try stores.dismissAttentionProblemGroup(group).isEmpty)
        #expect(try stores.activityRun(id: problem.id) == repeated)
    }

    @Test func individualUnknownAcknowledgesAndUndoesEvenAfterSameKeySuccess() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let unknown = run(.outcomeUnknown, key: ActivityJobKey.consolidation)
        try insert([unknown], into: stores)
        let receipt = try stores.dismissUnknownOutcome(id: unknown.id)
        #expect(receipt.itemCount == 1)
        #expect(try stores.activityRun(id: unknown.id)?.acknowledgedAt != nil)
        try insert([run(.succeeded, key: unknown.jobKey, start: 200)], into: stores)
        #expect(try stores.undoAttentionDismissal(receipt).runIDs == [unknown.id])
        #expect(try stores.activityAttentionSnapshot().runIDs == [unknown.id])
    }

    @Test func undoSkipsRecoveredChangedDeletedAndCompletedHelperRuns() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let recovered = run(.failed, key: ActivityJobKey.consolidation)
        let changed = run(.interrupted)
        let deleted = run(.failed)
        let owner = run(.running, key: ActivityJobKey.startup)
        let helper = run(.failed, parentID: owner.id)
        try insert([recovered, changed, deleted, owner, helper], into: stores)
        let receipt = try stores.dismissAllAttention()
        try insert([run(.succeeded, key: recovered.jobKey, start: 200)], into: stores)
        var altered = try #require(try stores.activityRun(id: changed.id))
        altered.acknowledgedAt = clock.wall.addingTimeInterval(1)
        var completedOwner = owner
        completedOwner.state = .succeeded
        completedOwner.finishedAt = clock.wall
        try stores.db.queue.write { db in
            try altered.update(db)
            try completedOwner.update(db)
            try ActivityRun.deleteOne(db, key: deleted.id)
        }
        let result = try stores.undoAttentionDismissal(receipt)
        #expect(result.runIDs.isEmpty)
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityRun(id: recovered.id)?.acknowledgedAt != nil)
        #expect(try stores.activityRun(id: changed.id) == altered)
        #expect(try stores.activityRun(id: deleted.id) == nil)
        // The keyed owner covers its failed helper, so the helper never had its
        // own row to dismiss and Undo has nothing of it to restore.
        #expect(try stores.activityRun(id: helper.id)?.acknowledgedAt == nil)
        #expect(!receipt.runs.contains { $0.written.id == helper.id })
    }

    @Test func overlappingOrOlderSuccessDoesNotPreventUndo() throws {
        for start in [50.0, 100, 110] {
            let clock = DismissalTestClock()
            let stores = try makeStores(clock)
            let failure = run(.failed, key: ActivityJobKey.consolidation)
            try insert([failure], into: stores)
            let group = try #require(try stores.activityAttentionSnapshot().groups.first)
            let receipt = try stores.dismissAttentionProblemGroup(group)
            try insert([run(.succeeded, key: failure.jobKey, start: start)], into: stores)
            #expect(try stores.undoAttentionDismissal(receipt).runIDs == [failure.id])
        }
    }

    @Test func heldUndoNeverRestoresConsumedExpiredOrChangedRowsOrTouchesArrivals() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let consumed = try hold(stores, at: clock.wall)
        let expired = try hold(stores, at: clock.wall.addingTimeInterval(-Stores.heldNotificationLifetime + 1))
        let changed = try hold(stores, at: clock.wall)
        let original = try hold(stores, at: clock.wall)
        let receipt = try stores.dismissHeldUpdates(ids: [consumed.id, expired.id, changed.id, original.id])
        #expect(receipt.itemCount == 4)
        try stores.clearHeldNotifications(ids: [consumed.id])
        clock.advance(2)
        var modified = try #require(try storedHeld(changed.id, in: stores))
        modified.dismissedAt = clock.wall
        try stores.db.queue.write { try modified.update($0) }
        let arrival = try hold(stores, at: clock.wall)
        let result = try stores.undoAttentionDismissal(receipt)
        #expect(result.heldUpdateIDs == [original.id])
        #expect(try storedHeld(consumed.id, in: stores) == nil)
        #expect(try storedHeld(expired.id, in: stores) == nil)
        #expect(try storedHeld(changed.id, in: stores) == modified)
        #expect(Set(try stores.heldNotifications().map(\.id)) == [original.id, arrival.id])
    }

    @Test func promptDeferralPersistsWithoutReviewingOrEnablingPolicyAndUndoIsConditional() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let receipt = try stores.deferAutomaticWorkPrompt()
        #expect(try Stores(db: stores.db).automaticWorkPromptDeferred())
        #expect(!(try stores.backgroundWorkPolicy()).reviewed)
        #expect(!(try stores.backgroundWorkPolicy()).permits(.memory))
        #expect(try stores.deferAutomaticWorkPrompt().isEmpty)
        try stores.setValue("new-marker", forKey: Stores.automaticWorkPromptDeferredKey)
        #expect(!(try stores.undoAttentionDismissal(receipt)).restoredPrompt)
        #expect(try stores.value(forKey: Stores.automaticWorkPromptDeferredKey) == "new-marker")
        let other = try makeStores(clock)
        let deferred = try other.deferAutomaticWorkPrompt()
        let reviewed = BackgroundWorkPolicy(reviewed: true, allowed: [.memory])
        try other.saveBackgroundWorkPolicy(reviewed)
        #expect(!(try other.undoAttentionDismissal(deferred)).restoredPrompt)
        #expect(try other.backgroundWorkPolicy() == reviewed)
        #expect(try other.deferAutomaticWorkPrompt().isEmpty)
    }

    @Test func invalidAndDuplicateActionsAreNoOpsAndReceiptsAreSingleUse() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let problem = run(.failed)
        let waiting = run(.waiting, category: .capture)
        try insert([problem, waiting], into: stores)
        #expect(try stores.dismissUnknownOutcome(id: UUID()).isEmpty)
        #expect(try stores.dismissUnknownOutcome(id: problem.id).isEmpty)
        #expect(try stores.dismissHeldUpdates(ids: [UUID(), UUID()]).isEmpty)
        let invalid = ActivityAttentionGroup(id: .run(waiting.id), latestRun: waiting)
        #expect(try stores.dismissAttentionProblemGroup(invalid).isEmpty)
        let group = try #require(try stores.activityAttentionSnapshot().groups.first)
        let receipt = try stores.dismissAttentionProblemGroup(group)
        #expect(try stores.dismissAttentionProblemGroup(group).isEmpty)
        #expect(try stores.undoAttentionDismissal(receipt).runIDs == [problem.id])
        let next = try stores.dismissAttentionProblemGroup(group)
        #expect(!next.isEmpty) // Same fake wall-clock marker as the first action.
        #expect(try stores.undoAttentionDismissal(receipt).runIDs.isEmpty)
        #expect(try stores.activityRun(id: problem.id)?.acknowledgedAt != nil)
        #expect(try stores.undoAttentionDismissal(next).runIDs == [problem.id])
    }

    @Test func expiredReceiptCannotRestoreAnythingEvenWhenWallClockMovesBack() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let failure = run(.failed)
        try insert([failure], into: stores)
        let held = try hold(stores, at: clock.wall)
        let receipt = try stores.dismissAllAttention()
        clock.advanceMonotonic(8)
        clock.advanceWall(-500)
        #expect(try stores.undoAttentionDismissal(receipt) == AttentionUndoResult())
        #expect(try stores.activityRun(id: failure.id)?.acknowledgedAt != nil)
        #expect(try storedHeld(held.id, in: stores)?.dismissedAt != nil)
        #expect(try stores.automaticWorkPromptDeferred())
    }

    @Test(arguments: ["attention-audit", "held-audit", "prompt-write"])
    func dismissAllFailureRollsBackEveryMutationAndAudit(failure: String) throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let problem = run(.failed)
        try insert([problem], into: stores)
        let held = try hold(stores, at: clock.wall)
        let events = try stores.recentActivity()
        try rejectMutation(failure, in: stores)
        #expect(throws: (any Error).self) { try stores.dismissAllAttention() }
        #expect(try stores.activityRun(id: problem.id) == problem)
        #expect(try storedHeld(held.id, in: stores) == held)
        #expect(!(try stores.automaticWorkPromptDeferred()))
        #expect(try stores.recentActivity() == events)
    }

    @Test(arguments: ["attention-audit", "held-audit"])
    func undoFailureRollsBackEveryRestoreAndCanBeRetried(failure: String) throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let problem = run(.failed)
        try insert([problem], into: stores)
        let held = try hold(stores, at: clock.wall)
        let receipt = try stores.dismissAllAttention()
        let beforeRun = try stores.activityRun(id: problem.id)
        let beforeHeld = try storedHeld(held.id, in: stores)
        let events = try stores.recentActivity()
        try rejectMutation(failure, in: stores)
        #expect(throws: (any Error).self) { try stores.undoAttentionDismissal(receipt) }
        #expect(try stores.activityRun(id: problem.id) == beforeRun)
        #expect(try storedHeld(held.id, in: stores) == beforeHeld)
        #expect(try stores.automaticWorkPromptDeferred())
        #expect(try stores.recentActivity() == events)
        try stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER reject_attention_mutation") }
        #expect(try stores.undoAttentionDismissal(receipt).runIDs == [problem.id])
        #expect(try stores.heldNotifications() == [held])
    }

    @Test func dismissalAuditContainsOnlyMetadataUsesPolicyAndIsNotMemoryEvidence() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let problem = run(.failed)
        try insert([problem], into: stores)
        _ = try hold(stores, at: clock.wall)
        let receipt = try stores.dismissAllAttention()
        _ = try stores.undoAttentionDismissal(receipt)
        let events = try stores.recentActivity().filter { $0.kind == .attentionChanged }
        #expect(events.count == 2)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!json.contains("EXAMPLE_PRIVATE_TITLE"))
        #expect(!json.contains("EXAMPLE_PRIVATE_BODY"))
        #expect(!Consolidator.isMemoryEvidence(.attentionChanged))
        #expect(Stores.attentionDismissalTool.risk == .reversibleWrite)
        #expect(AutonomyPolicy().verdict(for: Stores.attentionDismissalTool, connectorID: "attention") == .allow)
        for event in events {
            let data = try #require(event.detailJSON?.data(using: .utf8))
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(payload.keys) == ["action", "receiptID", "runIDs", "heldUpdateIDs", "prompt", "count"])
        }
    }

    private func rejectMutation(_ failure: String, in stores: Stores) throws {
        let table = failure == "prompt-write" ? "kv" : "activityEvent"
        let condition: String
        switch failure {
        case "prompt-write": condition = "NEW.key = 'home.automaticWorkPromptDeferred'"
        case "held-audit": condition = "NEW.kind = 'heldNotificationChanged'"
        default: condition = "NEW.kind = 'attentionChanged'"
        }
        try stores.db.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_attention_mutation BEFORE INSERT ON \(table)
                WHEN \(condition)
                BEGIN SELECT RAISE(ABORT, 'injected attention failure'); END
                """)
        }
    }
}

@Suite(.timeLimit(.minutes(2))) @MainActor struct AttentionDismissalHolderTests {
    @Test func holdsLatestNonemptyReceiptAndExpiresAtExactMonotonicBoundary() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let holder = AttentionDismissalHolder(clock: clock.clock)
        let first = try stores.deferAutomaticWorkPrompt()
        holder.present(first)
        #expect(holder.canUndo)
        holder.present(try stores.deferAutomaticWorkPrompt())
        #expect(holder.receipt == first)
        clock.advance(1)
        let held = try hold(stores, at: clock.wall)
        let second = try stores.dismissHeldUpdates(ids: [held.id])
        holder.present(second)
        clock.advanceMonotonic(7)
        clock.advanceWall(-400)
        holder.expireIfNeeded() // First deadline must not clear the second receipt.
        #expect(holder.receipt == second)
        #expect(holder.canUndo)
        clock.advanceMonotonic(1)
        holder.expireIfNeeded()
        #expect(holder.receipt == nil)
        #expect(!holder.canUndo)
        #expect(try holder.undo(using: stores) == nil)
    }

    @Test func scheduledExpiryClearsReceiptWithoutAUserAction() async throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let (ticks, continuation) = AsyncStream<Void>.makeStream()
        let undoClock = AttentionUndoClock(now: { clock.clock.now() }, sleepUntil: { _ in
            for await _ in ticks { return }
        })
        let holder = AttentionDismissalHolder(clock: undoClock)
        holder.present(try stores.deferAutomaticWorkPrompt())
        clock.advanceMonotonic(8)
        continuation.yield()
        for _ in 0..<100 where holder.receipt != nil { await Task.yield() }
        #expect(holder.receipt == nil)
        continuation.finish()
    }

    @Test func hidingIncidentRetainsOperationalFailureAndBulkDoesNotTouchIt() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let holder = AttentionDismissalHolder(clock: clock.clock)
        holder.updateMonitoringError("Example monitoring failure")
        let incident = holder.monitoringIncidentID
        let hidden = try #require(try holder.hideMonitoringIncident(using: stores))
        #expect(hidden.monitoringIncidentID == incident)
        #expect(holder.visibleMonitoringError == nil)
        #expect(holder.monitoringError == "Example monitoring failure")
        holder.updateMonitoringError("Example monitoring failure")
        #expect(holder.monitoringIncidentID == incident)
        #expect(holder.visibleMonitoringError == nil)
        #expect(try holder.hideMonitoringIncident(using: stores) == nil)
        #expect(holder.receipt == hidden)
        #expect(try holder.undo(using: stores)?.monitoringIncidentID == incident)
        #expect(holder.visibleMonitoringError == "Example monitoring failure")
        let bulk = try stores.dismissAllAttention()
        holder.present(bulk)
        #expect(bulk.monitoringIncidentID == nil)
        #expect(holder.visibleMonitoringError != nil)
        _ = try holder.hideMonitoringIncident(using: stores)
        holder.updateMonitoringError(nil)
        holder.updateMonitoringError("Example monitoring failure")
        #expect(holder.monitoringIncidentID != incident)
        #expect(try holder.undo(using: stores)?.monitoringIncidentID == nil)
        #expect(holder.visibleMonitoringError == "Example monitoring failure")
        #expect(holder.monitoringError != nil)
    }

    @Test func failedMonitoringAuditDoesNotHideIncidentOrReplaceReceipt() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        let holder = AttentionDismissalHolder(clock: clock.clock)
        holder.updateMonitoringError("Example monitoring failure")
        let first = try stores.deferAutomaticWorkPrompt()
        holder.present(first)
        try stores.db.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_monitoring_audit BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'attentionChanged'
                BEGIN SELECT RAISE(ABORT, 'injected monitoring audit failure'); END
                """)
        }
        #expect(throws: (any Error).self) { try holder.hideMonitoringIncident(using: stores) }
        #expect(holder.visibleMonitoringError == "Example monitoring failure")
        #expect(holder.receipt == first)
    }

    @Test func hidingMonitoringWarningDoesNotClearReporterFailure() throws {
        let clock = DismissalTestClock()
        let stores = try makeStores(clock)
        try stores.db.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_example_run BEFORE INSERT ON activityRun
                BEGIN SELECT RAISE(ABORT, 'injected run failure'); END
                """)
        }
        let reporter = ActivityReporter(stores: stores)
        _ = reporter.begin(ActivityRun(category: .system, title: "Example operation"))
        let failure = try #require(reporter.failureMessage)
        let monitoringRefreshes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .aitvarasMonitoringChanged,
            object: nil, queue: nil) { _ in monitoringRefreshes.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let holder = AttentionDismissalHolder(clock: clock.clock)
        holder.updateMonitoringError(failure)
        _ = try holder.hideMonitoringIncident(using: stores)
        #expect(holder.visibleMonitoringError == nil)
        #expect(holder.monitoringError == failure)
        #expect(reporter.failureMessage == failure)
        _ = try holder.undo(using: stores)
        #expect(holder.visibleMonitoringError == failure)
        #expect(reporter.failureMessage == failure)
        #expect(!(try stores.backgroundWorkPolicy()).reviewed)
        #expect(monitoringRefreshes.withLock { $0 } == 0)
    }
}

private func makeStores(_ clock: DismissalTestClock) throws -> Stores {
    Stores(db: try AitvarasDatabase(url: nil), heldNotificationClock: { clock.wall }, attentionUndoClock: clock.clock)
}

private func run(_ state: ActivityRunState, key: String? = nil, start: Double = 100, count: Int = 1,
                 category: ActivityCategory = .system, parentID: UUID? = nil) -> ActivityRun {
    ActivityRun(parentID: parentID, category: category, state: state, title: "EXAMPLE_PRIVATE_TITLE",
        startedAt: Date(timeIntervalSince1970: start), updatedAt: Date(timeIntervalSince1970: start + 10),
        jobKey: key, occurrenceCount: count)
}

private func insert(_ runs: [ActivityRun], into stores: Stores) throws {
    try stores.db.queue.write { db in for run in runs { try run.insert(db) } }
}

private func hold(_ stores: Stores, at date: Date) throws -> HeldNotification {
    let held = HeldNotification(title: "EXAMPLE_PRIVATE_TITLE", body: "EXAMPLE_PRIVATE_BODY", createdAt: date)
    try stores.holdNotification(held, recording: ActivityEvent(kind: .notificationQueued, summary: "Example update held"))
    return held
}

private func storedHeld(_ id: UUID, in stores: Stores) throws -> HeldNotification? {
    try stores.db.queue.read { try HeldNotification.fetchOne($0, key: id) }
}

private final class DismissalTestClock: Sendable {
    private struct State: Sendable {
        var wall = Date(timeIntervalSince1970: 1_000_000)
        var monotonic = ContinuousClock.now
    }
    private let state = Mutex(State())
    var wall: Date { state.withLock { $0.wall } }
    var clock: AttentionUndoClock {
        AttentionUndoClock(now: { self.state.withLock { $0.monotonic } }, sleepUntil: { _ in
            try await Task.sleep(for: .seconds(3600))
        })
    }
    func advance(_ seconds: Double) { advanceWall(seconds); advanceMonotonic(seconds) }
    func advanceWall(_ seconds: Double) { state.withLock { $0.wall = $0.wall.addingTimeInterval(seconds) } }
    func advanceMonotonic(_ seconds: Double) { state.withLock { $0.monotonic = $0.monotonic.advanced(by: .seconds(seconds)) } }
}
