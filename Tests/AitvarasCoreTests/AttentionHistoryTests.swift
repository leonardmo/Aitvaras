import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AttentionHistoryTests {
    @Test func overflowNavigationConsumesRequestAndClearsEveryUnrelatedFilter() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var filters = ActivityHistoryFilters(now: now.addingTimeInterval(-1000), calendar: calendar)
        filters.search = "Unrelated example search"
        filters.category = .voice
        filters.state = .succeeded
        filters.period = "custom"
        filters.fromDate = .distantPast
        filters.throughDate = .distantFuture
        var request = true // Home's N more route, before History is mounted.
        #expect(filters.consumeAttentionRequest(&request, now: now, calendar: calendar))
        #expect(!request)
        #expect(filters.mode == .attention)
        #expect(filters.search.isEmpty)
        #expect(filters.category == nil && filters.state == nil)
        #expect(filters.period == "all")
        #expect(filters.fromDate == calendar.startOfDay(for: now))
        #expect(filters.throughDate == now)
        let applied = filters
        #expect(!filters.consumeAttentionRequest(&request, now: .distantFuture))
        #expect(filters == applied)
    }

    @Test func flatFilterUsesSameTransitionAndAllHistoryRemainsTheDefault() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var filters = ActivityHistoryFilters(now: now)
        #expect(filters.mode == .all)
        filters.search = "Example"
        filters.category = .capture
        filters.state = .failed
        filters.period = "week"
        let ordinary = filters
        // Choosing All history does not alter its operation filter semantics.
        filters.select(.all)
        #expect(filters == ordinary)
        var route = ordinary
        var request = true
        route.consumeAttentionRequest(&request, now: now)
        filters.select(.attention, now: now)
        #expect(filters == route)
        filters.select(.all)
        #expect(filters.mode == .all)
        #expect(filters.search.isEmpty && filters.category == nil && filters.state == nil)
    }

    @Test(arguments: [1, 5, 50, 200])
    func everyHomeOverflowItemAppearsInUncappedMixedHistoryPages(pageSize: Int) {
        let card = mixedCard()
        #expect(card.rows.count > 100)
        #expect(card.visibleRows.count == 5)
        var request = true
        var filters = ActivityHistoryFilters()
        filters.search = "Does not match any attention row"
        filters.category = .model
        filters.state = .succeeded
        filters.period = "today"
        filters.consumeAttentionRequest(&request)
        #expect(filters.mode == .attention)
        var offset = 0
        var loaded: [HomeAttentionRow] = []
        repeat {
            let page = AttentionHistoryPage(card: card, offset: offset, limit: pageSize)
            #expect(page.totalCount == card.rows.count)
            #expect(page.rows.count <= pageSize)
            loaded += page.rows
            #expect(page.nextOffset > offset)
            offset = page.nextOffset
            if !page.hasMore { break }
        } while offset < card.rows.count
        #expect(loaded == card.rows)
        #expect(Set(loaded.map(\.id)).count == card.rows.count)
        let omitted = Set(card.rows.dropFirst(HomeAttentionCard.rowLimit).map(\.id))
        #expect(omitted.count == card.overflowCount)
        #expect(omitted.isSubset(of: Set(loaded.map(\.id))))
        #expect(AttentionHistoryPage(card: card, limit: card.rows.count).rows == loaded)
    }

    @Test func pagesRetainEveryKindsActionsAndGroupMemberIdentities() throws {
        let card = mixedCard()
        let rows = AttentionHistoryPage(card: card, limit: Int.max).rows
        #expect(rows == card.rows)
        #expect(rows.contains { if case .approval = $0 { true } else { false } })
        #expect(rows.contains { if case .suggestion = $0 { true } else { false } })
        #expect(rows.contains { if case .unsavedCapture = $0 { true } else { false } })
        #expect(rows.contains { $0.dismissal == .problem })
        #expect(rows.contains { $0.dismissal == .unknownOutcome })
        #expect(rows.contains { $0.dismissal == .heldUpdate })
        #expect(rows.contains { $0.dismissal == .monitoring })
        #expect(rows.contains { $0.dismissal == .later })
        for row in rows where row.section == .decisions {
            #expect(row.dismissal == nil)
            #expect(row.dismissalAccessibilityLabel == nil)
        }
        let group = try #require(rows.compactMap { row -> ActivityAttentionGroup? in
            if case .problem(let group) = row, group.id == .job(ActivityJobKey.consolidation) { return group }
            return nil
        }.first)
        #expect(group.runIDs.count == 2)
        #expect(group.totalCount == 201)
    }

    @Test func paginationHandlesEmptyNegativeAndPastEndRequestsWithoutDroppingRows() {
        let empty = AttentionHistoryPage(card: HomeAttentionCard())
        #expect(empty.rows.isEmpty && !empty.hasMore && empty.nextOffset == 0)
        let card = mixedCard()
        let first = AttentionHistoryPage(card: card, offset: -10, limit: 5)
        #expect(first.rows == card.visibleRows)
        #expect(first.nextOffset == 5 && first.hasMore)
        let pastEnd = AttentionHistoryPage(card: card, offset: Int.max, limit: Int.max)
        #expect(pastEnd.rows.isEmpty && !pastEnd.hasMore)
        #expect(pastEnd.nextOffset == card.rows.count)
        let negativeLimit = AttentionHistoryPage(card: card, offset: 10, limit: -1)
        #expect(negativeLimit.rows.isEmpty && negativeLimit.nextOffset == 10)
    }

    @Test func attentionDismissalLeavesOrdinaryHistoryCompleteAndRetainsLegacyEntries() throws {
        let stores = try inMemoryStores()
        let failure = run(.failed)
        let unknown = run(.outcomeUnknown)
        let capture = run(.waiting, category: .capture)
        let succeeded = run(.succeeded)
        let cancelled = run(.cancelled)
        let originalRuns = [failure, unknown, capture, succeeded, cancelled]
        let suggestions = (0..<7).map { _ in suggestion() }
        let updates = (0..<7).map { _ in HeldNotification(title: "Example update", body: "Example notice") }
        let legacy = ActivityEvent(kind: .eventReceived, summary: "Example earlier activity", runID: nil)
        try stores.db.queue.write { db in
            for run in originalRuns { try run.insert(db) }
            for suggestion in suggestions { try suggestion.insert(db) }
            for update in updates { try update.insert(db) }
            try legacy.insert(db)
        }
        let snapshot = try stores.homeAttentionSnapshot()
        let card = HomeAttentionCard(snapshot: snapshot, approvals: [approval(index: 1)])
        #expect(card.overflowCount > 0)
        let page = AttentionHistoryPage(card: card, limit: 50)
        #expect(page.rows == card.rows)
        #expect(Set(suggestions.map(\.id)).isSubset(of: Set(page.rows.compactMap {
            if case .suggestion(let suggestion) = $0 { return suggestion.id }; return nil
        })))
        #expect(Set(updates.map(\.id)).isSubset(of: Set(page.rows.compactMap {
            if case .heldUpdate(let update) = $0 { return update.id }; return nil
        })))
        let group = try #require(page.rows.compactMap { row -> ActivityAttentionGroup? in
            if case .problem(let group) = row, group.latestRun.id == failure.id { return group }; return nil
        }.first)
        _ = try stores.dismissAttentionProblemGroup(group)
        #expect(!(try stores.homeAttentionSnapshot()).problems.runIDs.contains(failure.id))
        let ordinary = try stores.activityRuns()
        #expect(Set(ordinary.map(\.id)) == Set(originalRuns.map(\.id)))
        #expect(ordinary.first { $0.id == failure.id }?.state == .failed)
        #expect(ordinary.first { $0.id == failure.id }?.acknowledgedAt != nil)
        #expect(try stores.legacyActivity().contains { $0.id == legacy.id })
    }

    private func mixedCard() -> HomeAttentionCard {
        let first = run(.failed, key: ActivityJobKey.consolidation, count: 200)
        let latest = run(.interrupted, key: ActivityJobKey.consolidation)
        let group = ActivityAttentionGroup(id: .job(ActivityJobKey.consolidation), latestRun: latest, earlierRuns: [first])
        let unknown = run(.outcomeUnknown)
        let groups = [group, ActivityAttentionGroup(id: .run(unknown.id), latestRun: unknown)]
        return HomeAttentionCard(snapshot: HomeAttentionSnapshot(
            suggestions: (0..<7).map { _ in suggestion() }, unsavedCaptures: [run(.waiting, category: .capture)],
            problems: .init(groups: groups),
            heldUpdates: (0..<132).map { _ in HeldNotification(title: "Example update", body: "Example notice") },
            showsAutomaticWorkPrompt: true), approvals: (0..<7).map { approval(index: $0) },
            monitoring: .init(id: UUID(), message: "Example monitoring failure"))
    }

    private func approval(index: Int) -> AgentApprovalSuggestion {
        .init(chatID: UUID(), request: .init(id: .integer(Int64(index)), scope: .init(runID: UUID()),
            kind: .permission(.init(name: "Example", input: .object([:])))))
    }

    private func suggestion() -> Suggestion {
        Suggestion(title: "Example action", detail: "Example decision", connectorID: "example", toolName: "example", argumentsJSON: "{}")
    }

    private func run(_ state: ActivityRunState, category: ActivityCategory = .system,
                     key: String? = nil, count: Int = 1) -> ActivityRun {
        ActivityRun(parentID: nil, category: category, state: state, title: "Example operation",
            jobKey: key, occurrenceCount: count)
    }
}
