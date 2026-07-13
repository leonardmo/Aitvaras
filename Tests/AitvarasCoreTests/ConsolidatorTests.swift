import Foundation
import AitvarasCore
import AitvarasStore
import Testing
@testable import AitvarasAgent

@Suite struct ConsolidatorTests {

    /// A `now` safely past the due hour on the local calendar.
    private var evening: Date {
        Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: .now)!
    }

    private func seedEpisode(_ stores: Stores, _ summary: String, minutesAgo: Double = 60) throws {
        try stores.record(ActivityEvent(
            kind: .conversationArchived,
            timestamp: evening.addingTimeInterval(-minutesAgo * 60),
            connectorID: "memory",
            summary: summary))
    }

    @Test func fullRunAppliesAddSupersedeInsightAndQuestion() async throws {
        let stores = try inMemoryStores()
        let outdated = MemoryFact(text: "Uses Microsoft To Do", kind: .biography, source: .extracted)
        try stores.saveFact(outdated)
        try seedEpisode(stores, "Chat archived: moved task management to Apple Reminders")
        try seedEpisode(stores, "Chat archived: planned thesis writing sessions for mornings")

        let engine = ScriptedEngine(responses: ["""
            {"digest": "You switched to Apple Reminders and like planning mornings.",
             "operations": [
               {"op": "supersede", "old_id": "\(outdated.id.uuidString)", "text": "Uses Apple Reminders for tasks", "kind": "biography", "importance": 6},
               {"op": "add", "text": "Prefers deep work in the morning", "kind": "rhythm", "importance": 7}],
             "insights": [{"text": "Tends to reorganize tools at semester start", "kind": "rhythm", "importance": 5}],
             "questions": [{"text": "Which calendar should study blocks default to?", "motivation": "Scheduling needs a target calendar", "value": 8}]}
            """])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await consolidator.run(now: evening)
        #expect(outcome.ran && !outcome.failed)
        #expect(outcome.factsAdded == 1)
        #expect(outcome.factsSuperseded == 1)
        #expect(outcome.insights == 1)
        #expect(outcome.questionsQueued == 1)

        // Old fact invalidated with pointer; replacement + insight active.
        let old = try #require(try stores.fact(id: outdated.id))
        #expect(!old.isCurrentlyValid && old.supersededBy != nil)
        let activeTexts = try stores.activeFacts().map(\.text)
        #expect(activeTexts.contains("Uses Apple Reminders for tasks"))
        #expect(activeTexts.contains("Prefers deep work in the morning"))
        let insight = try stores.activeFacts().first { $0.sourceValue == .reflected }
        #expect(insight != nil)

        // Digest event exists, watermark advanced → immediately re-running is a no-op.
        let digests = try stores.recentActivity().filter { $0.kind == .consolidationRun }
        #expect(digests.count == 1)
        #expect(digests[0].summary.contains("Apple Reminders"))
        let again = await consolidator.runIfDue(now: evening.addingTimeInterval(60))
        #expect(!again.ran)
        #expect(await engine.callCount() == 1)
    }

    @Test func engineFailureIsLoudAndRetryable() async throws {
        let stores = try inMemoryStores()
        try seedEpisode(stores, "Chat archived: something learnable")
        let engine = ScriptedEngine(responses: [
            ScriptedEngine.throwMarker,
            #"{"digest": "Second night worked.", "operations": [], "insights": [], "questions": []}"#
        ])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let first = await consolidator.run(now: evening)
        #expect(first.failed)
        let failures = try stores.recentActivity().filter {
            $0.kind == .consolidationRun && $0.summary.contains("FAILED")
        }
        #expect(failures.count == 1)                       // loud, in the audit trail

        // Watermark NOT advanced → still due, and the retry consumes the episodes.
        #expect(await consolidator.isDue(now: evening.addingTimeInterval(120)))
        let second = await consolidator.run(now: evening.addingTimeInterval(120))
        #expect(second.ran && !second.failed)
        #expect(second.digest == "Second night worked.")
    }

    @Test func unparseableOutputCountsAsFailure() async throws {
        let stores = try inMemoryStores()
        try seedEpisode(stores, "Chat archived: notes")
        let engine = ScriptedEngine(responses: ["I could not produce JSON, sorry."])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await consolidator.run(now: evening)
        #expect(outcome.failed)
        #expect(await consolidator.isDue(now: evening.addingTimeInterval(60)))
    }

    @Test func bogusSupersedeIDIsSkippedRestApplies() async throws {
        let stores = try inMemoryStores()
        try seedEpisode(stores, "Chat archived: mixed quality plan")
        let engine = ScriptedEngine(responses: ["""
            {"digest": "Partially valid plan.",
             "operations": [
               {"op": "supersede", "old_id": "\(UUID().uuidString)", "text": "Ghost update", "kind": "biography", "importance": 5},
               {"op": "add", "text": "Enjoys bouldering on Fridays", "kind": "rhythm", "importance": 6}],
             "insights": [], "questions": []}
            """])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await consolidator.run(now: evening)
        #expect(!outcome.failed)
        #expect(outcome.factsSuperseded == 0)
        #expect(outcome.factsAdded == 1)
        #expect(try stores.activeFacts().map(\.text) == ["Enjoys bouldering on Fridays"])
    }

    @Test func questionsDedupCapAndDecay() async throws {
        let stores = try inMemoryStores()
        // A stale question decays; a duplicate is not re-queued.
        let stale = CuriosityQuestion(text: "Old unanswered question?",
                                      createdAt: evening.addingTimeInterval(-15 * 24 * 3600))
        try stores.saveQuestion(stale)
        try stores.saveQuestion(CuriosityQuestion(text: "Which calendar for study blocks?"))
        try seedEpisode(stores, "Chat archived: planning again")

        let engine = ScriptedEngine(responses: ["""
            {"digest": "Planning patterns again.",
             "operations": [], "insights": [],
             "questions": [
               {"text": "Which calendar for study blocks?", "motivation": "dup", "value": 5},
               {"text": "Do you want weekend reminders silenced?", "motivation": "notification tuning", "value": 6}]}
            """])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await consolidator.run(now: evening)
        #expect(outcome.questionsQueued == 1)   // dup filtered, fresh one queued

        let open = try stores.openQuestions()
        #expect(!open.contains { $0.id == stale.id })          // decayed
        #expect(open.contains { $0.text.contains("weekend reminders") })
    }

    @Test func noEpisodesMeansCleanSkipWithoutModelCall() async throws {
        let stores = try inMemoryStores()
        // Only the consolidator's own past trail — must not self-consolidate.
        try stores.record(ActivityEvent(
            kind: .consolidationRun,
            timestamp: evening.addingTimeInterval(-3600),
            connectorID: "memory", summary: "Nightly consolidation: old digest"))
        let engine = ScriptedEngine(responses: ["should not be called"])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await consolidator.run(now: evening)
        #expect(!outcome.ran)
        #expect(await engine.callCount() == 0)
        // Watermark still advanced — a quiet day is not a failure.
        #expect(!(await consolidator.isDue(now: evening.addingTimeInterval(60))))
    }

    @Test func dueLogicRespectsHourAndWatermark() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: [])
        let consolidator = Consolidator(router: EngineRouter(ranked: [engine]), stores: stores)
        let calendar = Calendar.current

        let threeAM = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: .now)!
        #expect(!(await consolidator.isDue(now: threeAM)))            // before due hour

        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!
        #expect(await consolidator.isDue(now: nineAM))                // never ran → due

        try stores.setValue(String(nineAM.timeIntervalSince1970), forKey: Consolidator.lastRunKey)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        #expect(!(await consolidator.isDue(now: noon)))               // already ran today
    }
}
