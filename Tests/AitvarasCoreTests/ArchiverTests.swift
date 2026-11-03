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
        #expect(await engine.callCount() == 1)
    }

    @Test func concurrentDuplicateTranscriptUsesOneModelPass() async throws {
        let stores = try makeStores()
        let engine = GatedArchiverEngine()
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        async let first = archiver.archive(transcript: substantive)
        await engine.waitForRequest()
        let duplicate = await archiver.archive(transcript: substantive)

        #expect(!duplicate.archived)
        #expect(await engine.callCount() == 1)
        await engine.finish(with: #"{"summary": "One pass.", "facts": []}"#)
        #expect(await first.archived)
        #expect(await engine.callCount() == 1)
    }

    @Test func storedVoiceConversationArchivesWithoutToolNotes() async throws {
        let stores = try makeStores()
        let conversation = Conversation(title: "Voice")
        try stores.saveConversation(conversation)
        for (index, message) in substantive.enumerated() {
            try stores.appendMessage(StoredMessage(
                conversationID: conversation.id,
                role: message.role == .user ? "user" : "assistant",
                content: message.content,
                createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        try stores.appendMessage(StoredMessage(
            conversationID: conversation.id, role: "tool", content: "→ calendar.read"))
        let engine = ScriptedEngine(responses: [
            #"{"summary": "Archived a voice session.", "facts": []}"#
        ])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        let outcome = try await archiver.archiveStoredConversation(id: conversation.id)

        #expect(outcome.archived)
        let episode = try #require(try stores.recentActivity().first)
        #expect(episode.summary.contains("Voice archived"))
        #expect(episode.detailJSON?.contains(#""messages":4"#) == true)
    }

    @Test func storedConversationBacklogExcludesLiveAndSkipsCompletedWork() async throws {
        let stores = try makeStores()
        let live = try stores.persistentConversationID(
            forKey: "chat.conversationID", title: "Live Chat")
        let old = Conversation(title: "Recovered Chat")
        try stores.saveConversation(old)
        for (index, message) in substantive.enumerated() {
            try stores.appendMessage(StoredMessage(
                conversationID: old.id,
                role: message.role == .user ? "user" : "assistant",
                content: message.content,
                createdAt: Date(timeIntervalSince1970: Double(index))))
            try stores.appendMessage(StoredMessage(
                conversationID: live,
                role: message.role == .user ? "user" : "assistant",
                content: "Live: \(message.content)",
                createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        let engine = ScriptedEngine(responses: [
            #"{"summary": "Recovered after restart.", "facts": []}"#
        ])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)

        #expect(try await archiver.retryStoredConversations(excluding: [live]) == 1)
        #expect(try await archiver.retryStoredConversations(excluding: [live]) == 0)
        #expect(await engine.callCount() == 1)
        let episodes = try stores.recentActivity().filter { $0.kind == .conversationArchived }
        #expect(episodes.count == 1)
        #expect(episodes[0].summary.contains("Recovered Chat archived"))
        #expect(!episodes[0].summary.contains("Live Chat"))
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

    @Test func modelDraftCountAndFieldSizesAreBounded() throws {
        let drafts = (0..<25).map { index in
            ["text": "Fact \(index)", "kind": "biography"]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "Bounded archive",
            "facts": drafts
        ])
        let parsed = try #require(ConversationArchiver.parse(
            String(decoding: data, as: UTF8.self)))
        #expect(parsed.facts.count == 20)

        let oversized = String(
            repeating: "x", count: MemoryFact.maximumTextCharacters + 1)
        let oversizedData = try JSONSerialization.data(withJSONObject: [
            "summary": "Ignore one bad draft",
            "facts": [["text": oversized], ["text": "Keep this fact"]]
        ])
        let filtered = try #require(ConversationArchiver.parse(
            String(decoding: oversizedData, as: UTF8.self)))
        #expect(filtered.facts.map(\.text) == ["Keep this fact"])
    }

    @Test func failedFactWriteRollsBackArchiveAndRemainsRetryable() async throws {
        let stores = try makeStores()
        let response = """
            {"summary": "Learned a commute preference.",
             "facts": [{"text": "Takes the quiet route to campus", "kind": "rhythm", "importance": 6, "entities": "campus"}]}
            """
        let engine = ScriptedEngine(responses: [response, response])
        let archiver = ConversationArchiver(
            router: EngineRouter(ranked: [engine]), stores: stores)
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_archived_fact
                BEFORE INSERT ON memoryFact
                BEGIN
                    SELECT RAISE(ABORT, 'injected archive write failure');
                END
                """)
        }

        let first = await archiver.archive(transcript: substantive)
        #expect(!first.archived)
        #expect(try stores.recentActivity().isEmpty)
        #expect(try stores.activeFacts().isEmpty)
        #expect(try stores.entity(named: "campus") == nil)

        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: "DROP TRIGGER reject_archived_fact")
        }
        let second = await archiver.archive(transcript: substantive)
        #expect(second.archived)
        #expect(second.factsSaved == 1)
        #expect(try stores.recentActivity().count == 1)
        #expect(try stores.activeFacts().count == 1)
        #expect(try stores.entity(named: "campus") != nil)
        #expect(await engine.callCount() == 2)
    }
}

private actor GatedArchiverEngine: InferenceEngine {
    nonisolated let identifier = "gated-archiver"
    private var streamContinuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var calls = 0

    func isAvailable(for tier: ModelTier) async -> Bool { true }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        calls += 1
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        streamContinuation = continuation
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        return stream
    }

    func callCount() -> Int { calls }

    func waitForRequest() async {
        if streamContinuation != nil { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(with text: String) {
        streamContinuation?.yield(.text(text))
        streamContinuation?.yield(.done(stopReason: .endOfTurn))
        streamContinuation?.finish()
        streamContinuation = nil
    }
}
