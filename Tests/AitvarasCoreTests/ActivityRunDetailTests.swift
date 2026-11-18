import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct ActivityRunDetailTests {
    @Test func unknownOutcomeSentenceWarnsThatAnActionMayAlreadyHaveHappened() {
        var unknown = run(.outcomeUnknown)
        let sentence = ActivityRunDetailPresentation(run: unknown).summary
        #expect(sentence.contains("an action may already have happened"))
        #expect(sentence.contains("review it before trying again"))
        #expect(sentence.filter { $0 == "." }.count == 1)
        unknown.title = "EXAMPLE_TITLE_MARKER"
        unknown.outcome = "EXAMPLE_RESULT_MARKER"
        #expect(ActivityRunDetailPresentation(run: unknown).summary == sentence)
        let waiting = run(.waiting, category: .capture)
        #expect(ActivityRunDetailPresentation(run: waiting).summary.contains("waiting to be saved"))
    }

    @Test(arguments: ActivityRunState.allCases)
    func deterministicSentenceAndActionsForEveryState(state: ActivityRunState) {
        let value = run(state, category: .chat)
        let destination = ActivityDetailDestination.conversation(UUID())
        let group = problemStates.contains(state) ? ActivityAttentionGroup(id: .run(value.id), latestRun: value) : nil
        let presentation = ActivityRunDetailPresentation(run: value, destination: destination,
            stopSupported: true, dismissalGroup: group)
        #expect(!presentation.summary.isEmpty)
        #expect(presentation.summary.filter { $0 == "." }.count == 1)
        var expected: [ActivityRunDetailPresentation.Action] = [.open(destination)]
        if !state.isTerminal && state != .cancellationRequested { expected.append(.stop) }
        if let group { expected.append(.dismiss(group)) }
        #expect(presentation.actions == expected)
        #expect(!ActivityRunDetailPresentation(run: value).actions.contains(.stop))
        #expect(ActivityRunDetailPresentation(run: value).actions.isEmpty)
    }

    @Test func decisionsCapturesAndReviewedOrRecoveredProblemsHaveNoDismissAction() {
        for value in [run(.awaitingApproval), run(.waiting, category: .capture), run(.succeeded), run(.cancelled)] {
            let unrelated = run(.failed)
            let group = ActivityAttentionGroup(id: .run(unrelated.id), latestRun: unrelated)
            #expect(ActivityRunDetailPresentation(run: value, dismissalGroup: group).actions.isEmpty)
        }
        var reviewed = run(.failed)
        reviewed.acknowledgedAt = date(300)
        let group = ActivityAttentionGroup(id: .run(reviewed.id), latestRun: reviewed)
        #expect(ActivityRunDetailPresentation(run: reviewed, dismissalGroup: group).actions.isEmpty)
        #expect(ActivityRunDetailPresentation(run: run(.failed), dismissalGroup: nil).actions.isEmpty)
    }

    @Test func groupedDetailsKeepRepresentedMembersAndUseTheSameDismissalAndUndoReceipt() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.consolidation
        let older = run(.failed, key: key, start: 10, count: 3)
        let latest = run(.interrupted, key: key, start: 30)
        try insert([older, latest], into: stores)
        let group = try #require(try stores.activityAttentionSnapshot().groups.first)
        let selection = ActivityRunDetailSelection(group: group)
        let arrival = run(.failed, key: key, start: 50)
        try insert([arrival], into: stores)
        let snapshot = try stores.activityRunDetailSnapshot(selection)
        #expect(snapshot.run.id == latest.id)
        #expect(selection.runIDs == [latest.id, older.id])
        #expect(snapshot.representedRuns.map(\.id) == selection.runIDs)
        #expect(snapshot.earlierFailures.map(\.id) == [older.id])
        let dismissal = try #require(snapshot.dismissalGroup)
        #expect(dismissal.runIDs == selection.runIDs)
        #expect(dismissal.totalCount == 4)
        let receipt = try stores.dismissAttentionProblemGroup(dismissal)
        #expect(Set(receipt.runs.map { $0.written.id }) == Set(selection.runIDs))
        #expect(receipt.itemCount == 1)
        #expect(try stores.activityAttentionSnapshot().runIDs == [arrival.id])
        #expect(try stores.activityRunDetailSnapshot(selection).dismissalGroup == nil)
        #expect(Set(try stores.undoAttentionDismissal(receipt).runIDs) == Set(selection.runIDs))
        #expect(try stores.activityRun(id: arrival.id)?.acknowledgedAt == nil)
        #expect(try stores.activityRunDetailSnapshot(selection).dismissalGroup?.runIDs == selection.runIDs)
    }

    @Test func ordinaryHistorySingleRunDoesNotExpandIntoItsWholeJobGroup() throws {
        let stores = try inMemoryStores()
        let older = run(.failed, key: ActivityJobKey.consolidation, start: 10)
        let later = run(.failed, key: ActivityJobKey.consolidation, start: 30)
        try insert([older, later], into: stores)
        let selection = ActivityRunDetailSelection(run: older)
        let snapshot = try stores.activityRunDetailSnapshot(selection)
        #expect(snapshot.run.id == older.id)
        #expect(snapshot.representedRuns.map(\.id) == [older.id])
        #expect(snapshot.earlierFailures.isEmpty)
        let group = try #require(snapshot.dismissalGroup)
        #expect(group.id == .job(ActivityJobKey.consolidation))
        #expect(group.runIDs == [older.id])
        _ = try stores.dismissAttentionProblemGroup(group)
        #expect(try stores.activityRun(id: later.id)?.acknowledgedAt == nil)
    }

    @Test func recoveryAndOtherReviewsNarrowDismissalWithoutExpandingTheSelection() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.consolidation
        let recovered = run(.failed, key: key, start: 10)
        let reviewed = run(.failed, key: key, start: 40)
        let latest = run(.failed, key: key, start: 70)
        try insert([recovered, reviewed, latest], into: stores)
        let selection = ActivityRunDetailSelection(group: try #require(try stores.activityAttentionSnapshot().groups.first))
        try insert([run(.succeeded, key: key, start: 25)], into: stores)
        try stores.acknowledgeActivityRun(id: reviewed.id)
        let snapshot = try stores.activityRunDetailSnapshot(selection)
        #expect(snapshot.earlierFailures.map(\.id) == [reviewed.id, recovered.id])
        #expect(snapshot.dismissalGroup?.runIDs == [latest.id])
        try insert([run(.succeeded, key: key, start: 100)], into: stores)
        #expect(try stores.activityRunDetailSnapshot(selection).dismissalGroup == nil)
        #expect(try stores.activityRun(id: recovered.id)?.acknowledgedAt == nil)
    }

    @Test func keyedUnknownOutcomeStaysAnIndividualReviewEvenAfterSuccess() throws {
        let stores = try inMemoryStores()
        let key = ActivityJobKey.consolidation
        let unknown = run(.outcomeUnknown, key: key, start: 10)
        let other = run(.outcomeUnknown, key: key, start: 30)
        try insert([unknown, other, run(.succeeded, key: key, start: 60)], into: stores)
        let snapshot = try stores.activityRunDetailSnapshot(.init(run: unknown))
        #expect(snapshot.dismissalGroup?.id == .run(unknown.id))
        #expect(snapshot.dismissalGroup?.runIDs == [unknown.id])
        let receipt = try stores.dismissUnknownOutcome(id: unknown.id)
        #expect(receipt.runs.map { $0.written.id } == [unknown.id])
        #expect(try stores.activityRun(id: other.id)?.acknowledgedAt == nil)
    }

    @Test(arguments: [ActivityCategory.chat, .voice, .memory])
    func savedLegacyConversationsResolveWithoutReplacingSheetContent(category: ActivityCategory) throws {
        let stores = try inMemoryStores()
        let conversation = Conversation(title: "Example saved conversation")
        try stores.saveConversation(conversation)
        let value = run(.failed, category: category, reference: conversation.id.uuidString)
        #expect(try stores.activityDetailDestination(for: value) == .conversation(conversation.id))
        #expect(ActivityRunDetailPresentation(run: value, destination: .conversation(conversation.id)).actions == [.open(.conversation(conversation.id))])
        #expect(try stores.recentActivity().isEmpty) // Destination validation is read-only.
    }

    @Test func workspaceAndArchivingReferencesResolveToTheExistingWorkspaceChat() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Example project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Example chat")
        let native = run(.failed, category: .chat, reference: chat.id.uuidString)
        let legacy = run(.failed, category: .chat, reference: chat.localConversationID.uuidString)
        let archive = run(.failed, category: .memory, reference: chat.localConversationID.uuidString)
        for value in [native, legacy, archive] {
            #expect(try stores.activityDetailDestination(for: value) == .workspaceChat(chat.id))
        }
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        #expect(try stores.activityDetailDestination(for: native) == .workspaceChat(chat.id))
        project.isVisible = false
        try stores.saveWorkspaceProject(project)
        for value in [native, legacy, archive] {
            #expect(try stores.activityDetailDestination(for: value) == nil)
        }
    }

    @Test func captureAndConversationDestinationsAreRevalidatedAfterDeletion() throws {
        let stores = try inMemoryStores()
        let capture = CaptureRecord(startedAt: date(100), title: "Example capture", scope: "Audio",
            audio: "none", consentConfirmed: true, transcript: "Example transcript")
        try stores.saveCaptureRecord(capture)
        let value = run(.failed, category: .capture, reference: capture.id.uuidString)
        try insert([value], into: stores)
        let snapshot = try stores.activityRunDetailSnapshot(.init(run: value))
        #expect(snapshot.destination == .capture(capture.id))
        try stores.deleteCaptureRecord(capture.id)
        #expect(try stores.activityDetailDestination(for: value) == nil)
        let missing = try stores.activityRunDetailSnapshot(.init(run: value))
        #expect(missing.destination == nil)
        #expect(!ActivityRunDetailPresentation(run: missing.run, destination: missing.destination).actions.contains { if case .open = $0 { true } else { false } })
        let conversation = Conversation(title: "Example saved conversation")
        try stores.saveConversation(conversation)
        let chatRun = run(.failed, category: .chat, reference: conversation.id.uuidString)
        #expect(try stores.activityDetailDestination(for: chatRun) == .conversation(conversation.id))
        try stores.db.queue.write { try Conversation.deleteOne($0, key: conversation.id) }
        #expect(try stores.activityDetailDestination(for: chatRun) == nil)
    }

    @Test func absentMalformedAndWrongKindReferencesDoNotOfferOpen() throws {
        let stores = try inMemoryStores()
        let conversation = Conversation(title: "Example saved conversation")
        try stores.saveConversation(conversation)
        let examples = [run(.failed, category: .chat), run(.failed, category: .capture),
            run(.failed, category: .chat, reference: "example-invalid-id"),
            run(.failed, category: .capture, reference: conversation.id.uuidString),
            run(.failed, category: .system, reference: conversation.id.uuidString),
            run(.failed, category: .chat, reference: UUID().uuidString)]
        for value in examples {
            let destination = try stores.activityDetailDestination(for: value)
            #expect(destination == nil)
            #expect(ActivityRunDetailPresentation(run: value, destination: destination).actions.isEmpty)
        }
    }

    @Test func snapshotRetainsLatestStepsEventsAndExactEarlierFailures() throws {
        let stores = try inMemoryStores()
        let older = run(.failed, key: ActivityJobKey.consolidation, start: 10)
        let latest = run(.failed, key: ActivityJobKey.consolidation, start: 30)
        let step = ActivityRunStep(runID: latest.id, timestamp: date(35), stage: "Example stage", state: .failed)
        let event = ActivityEvent(kind: .toolExecuted, timestamp: date(36), summary: "Example result",
            detailJSON: "{\"count\":1}", runID: latest.id)
        try stores.db.queue.write { db in
            try older.insert(db); try latest.insert(db); try step.insert(db); try event.insert(db)
        }
        let group = try #require(try stores.activityAttentionSnapshot().groups.first)
        let snapshot = try stores.activityRunDetailSnapshot(.init(group: group))
        #expect(snapshot.steps == [step])
        #expect(snapshot.events == [event])
        #expect(snapshot.earlierFailures == [older])
        #expect(snapshot.run == latest)
        #expect(!ActivityRunDetailPresentation(run: snapshot.run).summary.contains("count"))
    }

    @Test func missingRunOrFailedDestinationReadNeverProducesAnOpenAction() throws {
        let stores = try inMemoryStores()
        #expect(throws: ActivityRunDetailError.runNotFound) { try stores.activityRunDetailSnapshot(.init(run: run(.failed))) }
        let value = run(.failed, category: .capture, reference: UUID().uuidString)
        try stores.db.queue.write { try $0.execute(sql: "DROP TABLE captureRecord") }
        #expect(throws: (any Error).self) { try stores.activityDetailDestination(for: value) }
    }

    private var problemStates: [ActivityRunState] { [.failed, .interrupted, .outcomeUnknown] }
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func run(_ state: ActivityRunState, category: ActivityCategory = .system,
                     key: String? = nil, start: Double = 100, count: Int = 1, reference: String? = nil) -> ActivityRun {
        ActivityRun(parentID: nil, referenceID: reference, category: category, state: state, title: "Example operation",
            startedAt: date(start), updatedAt: date(start + 10), jobKey: key, occurrenceCount: count)
    }
    private func insert(_ runs: [ActivityRun], into stores: Stores) throws {
        try stores.db.queue.write { db in for run in runs { try run.insert(db) } }
    }
}
