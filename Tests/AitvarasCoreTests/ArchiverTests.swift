import Foundation
import AitvarasCore
import AitvarasStore
import Testing
@testable import AitvarasAgent

private func makeStores() throws -> Stores {
    try inMemoryStores()
}

private func turns(_ pairs: [(String, String)]) -> [ChatMessage] {
    pairs.flatMap { user, assistant in
        [ChatMessage(role: .user, content: user),
         ChatMessage(role: .assistant, content: assistant)]
    }
}

@Suite struct ConversationArchiverTests {

    private let substantive = turns([
        ("Ich fahre eigentlich immer mit dem Rad zur Uni, auch im Winter meistens.",
         "Gut zu wissen! Dann plane ich Wege entsprechend."),
        ("Kannst du mir helfen, meine Abgabe für Analysis zu planen? Die ist Donnerstag fällig.",
         "Klar — ich habe dir einen Reminder erstellt.")
    ])

    @Test func archivesSummaryAndFactsWithProvenance() async throws {
        let stores = try makeStores()
        let engine = ScriptedEngine(responses: ["""
            {"summary": "Planned the Analysis hand-in and learned commute habits.",
             "facts": [{"text": "Bikes to university, usually even in winter", "kind": "rhythm", "importance": 6, "entities": "university"}]}
            """])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await archiver.archive(transcript: substantive)
        #expect(outcome.archived)
        #expect(outcome.factsSaved == 1)
        #expect(outcome.factsQuarantined == 0)

        // Episode recorded, fact linked to it, entity created.
        let episodes = try stores.recentActivity().filter { $0.kind == .conversationArchived }
        #expect(episodes.count == 1)
        let fact = try #require(try stores.activeFacts().first)
        #expect(fact.sourceValue == .extracted)
        #expect(fact.sourceEpisodesJSON?.contains(episodes[0].id.uuidString) == true)
        #expect(try stores.entity(named: "university") != nil)
    }

    @Test func trivialConversationIsSkippedWithoutModelCall() async throws {
        let stores = try makeStores()
        let engine = ScriptedEngine(responses: ["should never be used"])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await archiver.archive(transcript: turns([("hi", "Hallo!")]))
        #expect(!outcome.archived)
        #expect(await engine.callCount() == 0)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func sameTranscriptArchivesOnlyOnce() async throws {
        let stores = try makeStores()
        let engine = ScriptedEngine(responses: [
            #"{"summary": "First pass.", "facts": []}"#,
            #"{"summary": "Second pass — must not land.", "facts": []}"#
        ])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        #expect(await archiver.archive(transcript: substantive).archived)
        #expect(!(await archiver.archive(transcript: substantive).archived))
        let episodes = try stores.recentActivity().filter { $0.kind == .conversationArchived }
        #expect(episodes.count == 1)
    }

    @Test func duplicateFactsAreGatedByNovelty() async throws {
        let stores = try makeStores()
        try stores.saveFact(MemoryFact(text: "Bikes to university, usually even in winter",
                                       kind: .rhythm, source: .userStated))
        let engine = ScriptedEngine(responses: ["""
            {"summary": "Commute chat.",
             "facts": [{"text": "Bikes to university — usually even in Winter!", "kind": "rhythm", "importance": 5}]}
            """])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await archiver.archive(transcript: substantive)
        #expect(outcome.archived)
        #expect(outcome.factsSaved == 0)             // normalized dedup caught it
        #expect(try stores.activeFacts().count == 1)
    }

    @Test func sensitiveExtractedFactsAreQuarantined() async throws {
        let stores = try makeStores()
        let engine = ScriptedEngine(responses: ["""
            {"summary": "Vented about the semester.",
             "facts": [{"text": "Finds the lab partner annoying", "kind": "belief", "importance": 4}]}
            """])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = await archiver.archive(transcript: substantive)
        #expect(outcome.factsSaved == 1)
        #expect(outcome.factsQuarantined == 1)
        #expect(try stores.activeFacts().isEmpty)               // not in prompt layer
        #expect(try stores.factsNeedingReview().count == 1)     // waiting in review UI
    }

    @Test func garbageModelOutputArchivesNothingAndStaysRetryable() async throws {
        let stores = try makeStores()
        let engine = ScriptedEngine(responses: [
            "Sorry, I cannot help with that.",
            #"{"summary": "Recovered on retry.", "facts": []}"#
        ])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let first = await archiver.archive(transcript: substantive)
        #expect(!first.archived)
        #expect(try stores.recentActivity().isEmpty)   // no half-written episode

        // Fingerprint was not consumed — the same transcript can retry.
        let second = await archiver.archive(transcript: substantive)
        #expect(second.archived)
        #expect(second.summary == "Recovered on retry.")
    }
}
