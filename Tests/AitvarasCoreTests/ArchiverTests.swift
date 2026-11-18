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

@Suite(.timeLimit(.minutes(2))) struct ConversationArchiverTests {

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

/// D35: Retry archives exactly the stored conversation a failed run recorded.
@Suite(.timeLimit(.minutes(2))) struct StoredConversationRetryTests {
    private let substantive = turns([
        ("I usually plan the week on Sunday evening and keep Fridays free for reading.",
         "Noted, I'll keep Fridays clear."),
        ("Can you help me plan the hand-in for the example course? It is due on Thursday.",
         "Sure, I added a reminder.")
    ])

    private func storedConversation(_ stores: Stores, title: String, prefix: String = "") throws -> UUID {
        let conversation = Conversation(title: title)
        try stores.saveConversation(conversation)
        for (index, message) in substantive.enumerated() {
            try stores.appendMessage(StoredMessage(conversationID: conversation.id,
                role: message.role == .user ? "user" : "assistant", content: prefix + message.content,
                createdAt: Date(timeIntervalSince1970: Double(index))))
        }
        return conversation.id
    }

    private func key(_ stores: Stores, _ id: UUID) throws -> String {
        let transcript = ConversationArchiver.transcript(from: try stores.messages(in: id))
        return ActivityJobKey.archiving(conversationID: id,
            fingerprint: ConversationArchiver.fingerprint(of: transcript))
    }

    @Test func retryArchivesOnlyTheRequestedConversationAndClearsItsFailure() async throws {
        let stores = try makeStores()
        let target = try storedConversation(stores, title: "Target")
        let other = try storedConversation(stores, title: "Other", prefix: "Other: ")
        let targetKey = try key(stores, target)
        let failed = ActivityRun(parentID: nil, referenceID: target.uuidString, category: .memory,
            trigger: .automatic, state: .failed, title: "Archive conversation",
            startedAt: Date(timeIntervalSince1970: 100), finishedAt: Date(timeIntervalSince1970: 110),
            outcome: "No archive saved; transcript retained", jobKey: targetKey)
        try await stores.db.queue.write { try failed.insert($0) }
        let engine = ScriptedEngine(responses: [#"{"summary": "Retried.", "facts": []}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores,
            reporter: ActivityReporter(stores: stores))

        #expect(ActivityRetryTarget(run: failed) == .conversationArchive(conversationID: target, jobKey: targetKey))
        let result = try await archiver.retryStoredConversation(id: target, expectedJobKey: targetKey, excluding: [])
        #expect(result == .archived)
        #expect(await engine.callCount() == 1)
        let episodes = try stores.recentActivity().filter { $0.kind == .conversationArchived }
        #expect(episodes.count == 1 && episodes[0].summary.contains("Target archived"))
        #expect(!episodes[0].summary.contains("Other"))
        #expect(try stores.activityAttentionSnapshot().groups.isEmpty)
        #expect(try stores.activityRun(id: failed.id) == failed)
        // A second click on the same failure is not a second archive.
        #expect(try await archiver.retryStoredConversation(id: target, expectedJobKey: targetKey, excluding: [])
            == .unavailable(.alreadyArchived))
        #expect(await engine.callCount() == 1)
        _ = other
    }

    @Test func unavailableRetriesDoNoModelWork() async throws {
        let stores = try makeStores()
        let id = try storedConversation(stores, title: "Example")
        let expected = try key(stores, id)
        let engine = ScriptedEngine(responses: ["must not be used"])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)

        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: [id])
            == .unavailable(.active))
        #expect(try await archiver.retryStoredConversation(id: UUID(), expectedJobKey: expected, excluding: [])
            == .unavailable(.missing))
        try stores.appendMessage(StoredMessage(conversationID: id, role: "user", content: "One more thing."))
        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: [])
            == .unavailable(.changed))

        let short = Conversation(title: "Short")
        try stores.saveConversation(short)
        try stores.appendMessage(StoredMessage(conversationID: short.id, role: "user", content: "hi"))
        #expect(try await archiver.retryStoredConversation(id: short.id, expectedJobKey: try key(stores, short.id),
            excluding: []) == .unavailable(.notSubstantial))
        #expect(await engine.callCount() == 0)
        #expect(try stores.recentActivity().filter { $0.kind == .conversationArchived }.isEmpty)
    }

    @Test func engineFailureAndMalformedOutputKeepTheTranscriptRetryable() async throws {
        let stores = try makeStores()
        let id = try storedConversation(stores, title: "Example")
        let expected = try key(stores, id)
        let engine = ScriptedEngine(responses: ["not json", #"{"summary": "Second try.", "facts": []}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)

        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: []) == .notArchived)
        #expect(try stores.recentActivity().filter { $0.kind == .conversationArchived }.isEmpty)
        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: []) == .archived)

        let noEngine = ConversationArchiver(router: EngineRouter(ranked: []), stores: stores)
        let other = try storedConversation(stores, title: "Other", prefix: "Other: ")
        #expect(try await noEngine.retryStoredConversation(id: other, expectedJobKey: try key(stores, other),
            excluding: []) == .notArchived)
    }

    @Test func duplicateClickWhileRunningIsInProgress() async throws {
        let stores = try makeStores()
        let id = try storedConversation(stores, title: "Example")
        let expected = try key(stores, id)
        let engine = GatedArchiverEngine()
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)

        async let first = archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: [])
        await engine.waitForRequest()
        #expect(try await archiver.retryStoredConversation(id: id, expectedJobKey: expected, excluding: [])
            == .unavailable(.inProgress))
        await engine.finish(with: #"{"summary": "One pass.", "facts": []}"#)
        #expect(try await first == .archived)
        #expect(await engine.callCount() == 1)
    }

    @Test func retryTargetsAreLimitedToTheTwoSupportedJobs() {
        let record = UUID()
        func run(_ category: ActivityCategory, _ state: ActivityRunState, key: String?, reference: String?) -> ActivityRun {
            ActivityRun(parentID: nil, referenceID: reference, category: category, trigger: .automatic,
                        state: state, title: "Example", jobKey: key)
        }
        let summary = ActivityJobKey.captureSummary(recordID: record)
        #expect(ActivityRetryTarget(run: run(.capture, .failed, key: summary, reference: record.uuidString))
            == .captureSummary(recordID: record))
        #expect(ActivityRetryTarget(run: run(.capture, .outcomeUnknown, key: summary, reference: record.uuidString)) == nil)
        #expect(ActivityRetryTarget(run: run(.capture, .failed, key: summary, reference: UUID().uuidString)) == nil)
        #expect(ActivityRetryTarget(run: run(.capture, .failed, key: nil, reference: record.uuidString)) == nil)
        #expect(ActivityRetryTarget(run: run(.knowledge, .failed, key: ActivityJobKey.indexing(sourceIDs: ["a"]),
            reference: record.uuidString)) == nil)
        #expect(ActivityRetryTarget(run: run(.memory, .failed, key: ActivityJobKey.consolidation,
            reference: record.uuidString)) == nil)
        #expect(ActivityRetryTarget(run: run(.memory, .failed, key: ActivityJobKey.archiving(conversationID: record,
            fingerprint: "f"), reference: nil)) == nil)
        var reviewed = run(.capture, .failed, key: summary, reference: record.uuidString)
        reviewed.acknowledgedAt = .now
        #expect(ActivityRetryTarget(run: reviewed) == nil)

        let failed = run(.capture, .failed, key: summary, reference: record.uuidString)
        #expect(ActivityRunDetailPresentation(run: failed).actions.isEmpty)
        #expect(ActivityRunDetailPresentation(run: failed, retrySupported: { _ in true }).actions
            == [.retry(.captureSummary(recordID: record))])
    }
}
