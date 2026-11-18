import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct HomeAttentionCardTests {
    @Test func oneOrderingAndOneCapAcrossEveryKind() throws {
        let approval = approval()
        let suggestion = suggestion()
        let capture = run(.waiting, category: .capture)
        let failure = group(run(.failed, key: ActivityJobKey.consolidation, count: 4))
        let unknown = group(run(.outcomeUnknown))
        let incident = HomeMonitoringIncident(id: UUID(), message: "Example monitoring failure")
        let held = held()
        let snapshot = HomeAttentionSnapshot(suggestions: [suggestion], unsavedCaptures: [capture],
            problems: .init(groups: [failure, unknown]), heldUpdates: [held], showsAutomaticWorkPrompt: true)
        let card = HomeAttentionCard(snapshot: snapshot, approvals: [approval], monitoring: incident)
        #expect(card.rows.map(\.id) == [.approval(approval.id), .suggestion(suggestion.id), .capture(capture.id),
            .problem(failure.id), .problem(unknown.id), .monitoring(incident.id), .held(held.id), .automaticWork])
        #expect(card.rows.map(\.section) == [.decisions, .decisions, .decisions, .problems, .problems, .problems, .notices, .notices])
        #expect(card.visibleRows.map(\.id) == Array(card.rows.prefix(5)).map(\.id))
        #expect(card.overflowCount == 3)
        #expect(card.canDismissAll)
    }

    @Test func fiveDecisionsUseEntireCapButBulkEligibilityIncludesOverflow() throws {
        let approvals = (0..<7).map { approval(index: $0) }
        let snapshot = HomeAttentionSnapshot(suggestions: [suggestion()], unsavedCaptures: [run(.waiting, category: .capture)],
            problems: .init(groups: [group(run(.failed))]), heldUpdates: [held()], showsAutomaticWorkPrompt: true)
        let card = HomeAttentionCard(snapshot: snapshot, approvals: approvals)
        #expect(card.visibleRows.map(\.id) == approvals.prefix(5).map { .approval($0.id) })
        #expect(card.overflowCount == 7) // Twelve logical rows, five displayed.
        #expect(card.visibleRows.allSatisfy { $0.dismissal == nil })
        #expect(card.canDismissAll)
    }

    @Test(arguments: Array(0...12)) func exactOverflowAndEmptyBoundary(count: Int) {
        let snapshot = HomeAttentionSnapshot(heldUpdates: (0..<count).map { _ in held() })
        let card = HomeAttentionCard(snapshot: snapshot)
        #expect(card.rows.count == count)
        #expect(card.visibleRows.count == min(5, count))
        #expect(card.overflowCount == max(0, count - 5))
        #expect(card.canDismissAll == (count > 0))
    }

    @Test func groupedOccurrencesAreOneLogicalRowWithStableIdentity() {
        let key = ActivityJobKey.consolidation
        let first = run(.failed, key: key, count: 100)
        let latest = run(.interrupted, key: key, count: 3)
        let group = ActivityAttentionGroup(id: .job(key), latestRun: latest, earlierRuns: [first])
        let row = HomeAttentionRow.problem(group)
        let snapshot = HomeAttentionSnapshot(problems: .init(groups: [group]),
            heldUpdates: (0..<5).map { _ in held() })
        let card = HomeAttentionCard(snapshot: snapshot)
        #expect(group.totalCount == 103)
        #expect(card.rows.count == 6)
        #expect(card.visibleRows.count == 5)
        #expect(card.overflowCount == 1)
        let earlierRow = HomeAttentionRow.problem(.init(id: .job(key), latestRun: first))
        #expect(row.id == earlierRow.id)
        #expect(row.accessibilityIdentifier == earlierRow.accessibilityIdentifier)
    }

    @Test func decisionsAndCapturesHaveNoDismissalAndUnknownsAndMonitoringAreNotBulkEligible() {
        let decisions: [HomeAttentionRow] = [.approval(approval()), .suggestion(suggestion()),
            .unsavedCapture(run(.waiting, category: .capture))]
        for row in decisions {
            #expect(row.dismissal == nil)
            #expect(row.dismissalAccessibilityLabel == nil)
            #expect(!row.eligibleForDismissAll)
        }
        let unknown = HomeAttentionRow.problem(group(run(.outcomeUnknown, key: ActivityJobKey.consolidation)))
        let incident = HomeAttentionRow.monitoring(.init(id: UUID(), message: "Example failure"))
        #expect(unknown.dismissal == .unknownOutcome)
        #expect(incident.dismissal == .monitoring)
        #expect(!unknown.eligibleForDismissAll)
        #expect(!incident.eligibleForDismissAll)
        #expect(!HomeAttentionCard(snapshot: .init(unsavedCaptures: [run(.waiting, category: .capture)],
            problems: .init(groups: [group(run(.outcomeUnknown))])), approvals: [approval()],
            monitoring: .init(id: UUID(), message: "Example failure")).canDismissAll)
    }

    @Test func everyDismissibleKindHasAnAccessibleLabelAndOpaqueStableIdentifier() throws {
        let longTitle = "Example\n" + String(repeating: "long title ", count: 20)
        var failure = run(.failed)
        failure.title = longTitle
        let rows: [HomeAttentionRow] = [.problem(group(failure)), .problem(group(run(.outcomeUnknown))),
            .monitoring(.init(id: UUID(), message: "Example failure")), .heldUpdate(held()), .automaticWork]
        #expect(Set(rows.map(\.accessibilityIdentifier)).count == rows.count)
        for row in rows {
            let label = try #require(row.dismissalAccessibilityLabel)
            #expect(!label.isEmpty)
            #expect(!label.contains("\n"))
            #expect(label.count < 130)
            #expect(row.accessibilityIdentifier.hasPrefix("home.attention."))
            #expect(!row.accessibilityIdentifier.contains("Example"))
        }
        #expect(rows[0].dismissalAccessibilityLabel?.hasPrefix("Dismiss problem: Example ") == true)
        #expect(rows[1].dismissalAccessibilityLabel?.hasPrefix("Dismiss unknown outcome:") == true)
        #expect(rows[2].dismissalAccessibilityLabel?.hasPrefix("Dismiss monitoring warning:") == true)
        #expect(rows[3].dismissalAccessibilityLabel?.hasPrefix("Dismiss held update:") == true)
        #expect(rows[4].dismissalAccessibilityLabel == "Later: Review automatic work")
        #expect(rows[4].dismissal == .later)
    }

    @Test func onlyRequestsWithExistingApproveRejectResponsesEnterDecisions() {
        let permission = approval(index: 1)
        let permissions = approval(index: 2, kind: .permissions(.object([:])))
        let plan = approval(index: 3, kind: .plan("Example plan"))
        let question = approval(index: 4, kind: .questions([.init(id: "example", prompt: "Example question")]))
        let card = HomeAttentionCard(approvals: [permission, permissions, plan, question])
        #expect(card.rows.map(\.id) == [permission, permissions, plan].map { .approval($0.id) })
        #expect(card.rows.allSatisfy { $0.dismissal == nil })
        #expect(!card.canDismissAll)
    }

    @Test func packageSnapshotIsCompleteAndSharesRecoveryAndHeldLifecyclePredicates() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stores = Stores(db: try AitvarasDatabase(url: nil), heldNotificationClock: { now })
        let suggestions = (0..<6).map { _ in suggestion() }
        let captures = (0..<6).map { _ in run(.waiting, category: .capture) }
        let failures = (0..<275).map { _ in run(.failed, key: ActivityJobKey.consolidation) }
        let unkeyed = run(.interrupted)
        let recovered = run(.failed, key: ActivityJobKey.startup)
        let success = ActivityRun(category: .startup, state: .succeeded, title: "Example recovered job",
            startedAt: Date(timeIntervalSince1970: 200), jobKey: ActivityJobKey.startup)
        let updates = (0..<6).map { _ in held(at: now) }
        let expired = held(at: now.addingTimeInterval(-Stores.heldNotificationLifetime))
        let dismissed = held(at: now)
        try stores.db.queue.write { db in
            for value in suggestions { try value.insert(db) }
            for value in captures + failures + [unkeyed, recovered, success] { try value.insert(db) }
            for value in updates + [expired, dismissed] { try value.insert(db) }
        }
        _ = try stores.softDismissHeldNotifications(ids: [dismissed.id])
        // Today previews are intentionally smaller; they cannot drive this card.
        #expect(try stores.todaySnapshot().pendingSuggestions.count == 3)
        #expect(try stores.todaySnapshot().heldNotifications.count == 3)
        let snapshot = try stores.homeAttentionSnapshot()
        #expect(Set(snapshot.suggestions.map(\.id)) == Set(suggestions.map(\.id)))
        #expect(Set(snapshot.unsavedCaptures.map(\.id)) == Set(captures.map(\.id)))
        #expect(snapshot.problems.groups.count == 2)
        #expect(snapshot.problems.groups.first { $0.id == .job(ActivityJobKey.consolidation) }?.totalCount == 275)
        #expect(Set(snapshot.heldUpdates.map(\.id)) == Set(updates.map(\.id)))
        #expect(snapshot.showsAutomaticWorkPrompt)
        let card = HomeAttentionCard(snapshot: snapshot)
        #expect(card.rows.count == 21)
        #expect(card.overflowCount == 16)
        #expect(card.visibleRows.allSatisfy { if case .suggestion = $0 { true } else { false } })
        #expect(try stores.activityRun(id: recovered.id)?.acknowledgedAt == nil)
    }

    @Test func promptLaterAndUndoAreReflectedWithoutChangingAutomaticWorkPolicy() throws {
        let stores = try inMemoryStores()
        #expect(try stores.homeAttentionSnapshot().showsAutomaticWorkPrompt)
        let receipt = try stores.deferAutomaticWorkPrompt()
        #expect(!(try stores.homeAttentionSnapshot()).showsAutomaticWorkPrompt)
        #expect(!(try stores.backgroundWorkPolicy()).reviewed)
        _ = try stores.undoAttentionDismissal(receipt)
        #expect(try stores.homeAttentionSnapshot().showsAutomaticWorkPrompt)
        try stores.saveBackgroundWorkPolicy(.init(reviewed: true))
        #expect(!(try stores.homeAttentionSnapshot()).showsAutomaticWorkPrompt)
    }

    @Test func failedHomeReadRollsBackExpiryAndItsAudit() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stores = Stores(db: try AitvarasDatabase(url: nil), heldNotificationClock: { now })
        let expired = held(at: now.addingTimeInterval(-Stores.heldNotificationLifetime))
        try stores.db.queue.write { db in
            try expired.insert(db)
            // Expiry has already run when the next snapshot read fails.
            try db.execute(sql: "DROP TABLE suggestion")
        }
        #expect(throws: (any Error).self) { try stores.homeAttentionSnapshot() }
        #expect(try stores.db.queue.read { try HeldNotification.fetchOne($0, key: expired.id) } == expired)
        #expect(try stores.recentActivity().isEmpty)
    }

    private func approval(index: Int = 0, kind: AgentRequest.Kind = .permission(.init(name: "Example", input: .object([:])))) -> AgentApprovalSuggestion {
        .init(chatID: UUID(), request: .init(id: .integer(Int64(index)), scope: .init(runID: UUID()), kind: kind))
    }

    private func suggestion() -> Suggestion {
        Suggestion(title: "Example action", detail: "Example decision", connectorID: "example", toolName: "example", argumentsJSON: "{}")
    }

    private func held(at date: Date = Date(timeIntervalSince1970: 1_000_000)) -> HeldNotification {
        HeldNotification(title: "Example update", body: "Example notice", createdAt: date)
    }

    private func run(_ state: ActivityRunState, category: ActivityCategory = .system,
                     key: String? = nil, count: Int = 1) -> ActivityRun {
        ActivityRun(parentID: nil, category: category, state: state, title: "Example operation",
            startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 110),
            jobKey: key, occurrenceCount: count)
    }

    private func group(_ run: ActivityRun) -> ActivityAttentionGroup {
        .init(id: run.jobKey.map { .job($0) } ?? .run(run.id), latestRun: run)
    }
}
