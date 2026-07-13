import Foundation
import AitvarasCore
import AitvarasStore
import AitvarasAgent
import Testing
@testable import AitvarasConnectors
@testable import AitvarasRAG

/// Deterministic embedder for memory recall tests: shared topic markers map to
/// the same dimension so cross-wording "semantic" matches are testable without
/// a real model; `failing` simulates an unreachable embedder.
private actor FakeEmbedder: EmbeddingEngine {
    let identifier = "fake"
    let dimensions = 8
    private var failing: Bool
    init(failing: Bool = false) { self.failing = failing }

    func embed(texts: [String]) async throws -> [[Float]] {
        struct Down: Error {}
        guard !failing else { throw Down() }
        return texts.map(Self.vector(for:))
    }

    static func vector(for text: String) -> [Float] {
        let lower = text.lowercased()
        var v = [Float](repeating: 0, count: 8)
        let topics: [[String]] = [
            ["bike", "cycling", "fahrrad"],
            ["proxmox", "homelab", "server"],
            ["coffee", "espresso", "kaffee"]
        ]
        for (dim, markers) in topics.enumerated() where markers.contains(where: lower.contains) {
            v[dim] = 1
        }
        var residual = [Float](repeating: 0, count: 5)
        for byte in lower.utf8 { residual[Int(byte % 5)] += 1 }
        let norm = residual.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for i in 0..<5 { v[3 + i] += 0.3 * residual[i] / norm } }
        return v
    }
}

private func freshStores() throws -> Stores {
    Stores(db: try AitvarasDatabase(url: nil))
}

@Suite struct MemoryFoundationTests {

    // MARK: Store layer

    @Test func factRoundTripsAndKeywordSearches() throws {
        let stores = try freshStores()
        let fact = MemoryFact(text: "Prefers espresso over filter coffee",
                              entitiesText: "coffee", kind: .preference, importance: 7,
                              source: .userStated)
        try stores.saveFact(fact)

        #expect(try stores.activeFacts().count == 1)
        #expect(try stores.fact(id: fact.id)?.text == fact.text)

        let hits = try stores.factKeywordSearch("espresso", limit: 5)
        #expect(hits.contains { $0.factID == fact.id })
        // Entity name is folded into the FTS text.
        #expect(try stores.factKeywordSearch("coffee", limit: 5).contains { $0.factID == fact.id })
    }

    @Test func supersedingInvalidatesButKeepsHistory() throws {
        let stores = try freshStores()
        let old = MemoryFact(text: "Uses Microsoft To Do", kind: .biography, source: .extracted)
        let new = MemoryFact(text: "Uses Apple Reminders", kind: .biography, source: .userStated)
        try stores.saveFact(old)
        try stores.saveFact(new)
        try stores.supersedeFact(old.id, by: new.id)

        let active = try stores.activeFacts()
        #expect(active.count == 1)
        #expect(active.first?.id == new.id)
        // Old fact still exists, marked invalid and pointing at its replacement.
        let stored = try #require(try stores.fact(id: old.id))
        #expect(stored.isCurrentlyValid == false)
        #expect(stored.supersededBy == new.id)
        #expect(try stores.allFacts().count == 2)
    }

    @Test func entitiesLinkToFacts() throws {
        let stores = try freshStores()
        let entity = MemoryEntity(name: "Proxmox", kind: .system, summary: "Home hypervisor")
        try stores.saveEntity(entity)
        let fact = MemoryFact(text: "Runs read-only PVEAuditor token", entitiesText: "Proxmox",
                              kind: .procedure, source: .userStated)
        try stores.saveFact(fact, entityIDs: [entity.id])

        #expect(try stores.entity(named: "proxmox")?.id == entity.id)   // case-insensitive
        let linked = try stores.facts(forEntity: entity.id)
        #expect(linked.map(\.id) == [fact.id])
    }

    @Test func curiosityQueueOrdersAndRetires() throws {
        let stores = try freshStores()
        try stores.saveQuestion(CuriosityQuestion(text: "Do you bike in winter?", expectedValue: 4))
        let important = CuriosityQuestion(text: "Which courses this semester?", expectedValue: 9)
        try stores.saveQuestion(important)

        let open = try stores.openQuestions()
        #expect(open.first?.id == important.id)   // highest expected value first
        #expect(open.count == 2)

        try stores.setQuestionStatus(important.id, to: .answered)
        #expect(try stores.openQuestions().count == 1)
    }

    // MARK: Connector + recall

    @Test func rememberThenSearchFindsIt() async throws {
        let stores = try freshStores()
        let memory = MemoryConnector(stores: stores, embedder: FakeEmbedder())

        let out = try await memory.execute(
            toolName: "remember",
            argumentsJSON: #"{"text":"Commutes to campus by bike","kind":"rhythm","entities":"campus"}"#)
        #expect(out.contains("\"remembered\":true"))

        let search = try await memory.execute(
            toolName: "search", argumentsJSON: #"{"query":"how does the user get to university"}"#)
        #expect(search.contains("bike"))
        // The remembered fact is embedded and entity-linked.
        #expect(try stores.factStats().embedded == 1)
        #expect(try stores.entity(named: "campus") != nil)
    }

    @Test func reviseSupersedesViaConnector() async throws {
        let stores = try freshStores()
        let memory = MemoryConnector(stores: stores, embedder: FakeEmbedder())
        _ = try await memory.execute(
            toolName: "remember", argumentsJSON: #"{"text":"Lives in Garching"}"#)
        let fact = try #require(try stores.activeFacts().first)

        let revised = try await memory.execute(
            toolName: "revise",
            argumentsJSON: #"{"old_id":"\#(fact.id.uuidString)","text":"Lives in Munich Maxvorstadt"}"#)
        #expect(revised.contains("\"revised\":true"))

        let active = try stores.activeFacts()
        #expect(active.count == 1)
        #expect(active.first?.text == "Lives in Munich Maxvorstadt")
        #expect(try stores.fact(id: fact.id)?.isCurrentlyValid == false)
    }

    @Test func answeringQuestionCreatesFactAndRetiresIt() async throws {
        let stores = try freshStores()
        let question = CuriosityQuestion(text: "What's your thesis topic?", expectedValue: 8)
        try stores.saveQuestion(question)
        let memory = MemoryConnector(stores: stores, embedder: FakeEmbedder())

        let out = try await memory.execute(
            toolName: "answer_question",
            argumentsJSON: #"{"id":"\#(question.id.uuidString)","answer":"Local-first agent memory"}"#)
        #expect(out.contains("\"recorded\":true"))
        #expect(try stores.openQuestions().isEmpty)

        let fact = try #require(try stores.activeFacts().first)
        #expect(fact.sourceValue == .userAnswered)
        #expect(fact.text.contains("Local-first agent memory"))
    }

    // MARK: v4 migration + quarantine + backfill + prompt budget

    @Test func migrationImportsLegacyMemoriesIntoFacts() throws {
        // End-to-end migration test: build a fully-migrated file-backed DB,
        // plant a legacy memory, then un-record v4 in GRDB's migration table
        // and re-open — the migrator re-runs exactly the import migration.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("aitvaras.sqlite")

        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try stores.saveMemory(Memory(content: "Prefers dark roast espresso", category: "preference"))
            try stores.db.queue.write { dbc in
                try dbc.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-memory-import'")
                // v4 also adds needsReview — drop it so the re-run is clean.
                try dbc.execute(sql: "ALTER TABLE memoryFact DROP COLUMN needsReview")
            }
        }

        let migrated = Stores(db: try AitvarasDatabase(url: url))
        let facts = try migrated.activeFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.text == "Prefers dark roast espresso")
        #expect(facts.first?.kindValue == .preference)
        // Legacy row is archived (leaves the prompt path) but not deleted.
        #expect(try migrated.activeMemories().isEmpty)
        // Imported fact is keyword-searchable immediately.
        #expect(try migrated.factKeywordSearch("espresso", limit: 5).count == 1)
    }

    @Test func quarantinedFactsStayOutOfPromptAndRecall() async throws {
        let stores = try freshStores()
        var sensitive = MemoryFact(text: "Believes X about a colleague",
                                   kind: .belief, source: .extracted, needsReview: true)
        sensitive.embeddingVector = FakeEmbedder.vector(for: "colleague belief")
        try stores.saveFact(sensitive)
        try stores.saveFact(MemoryFact(text: "Drinks espresso", kind: .preference, source: .userStated))

        #expect(try stores.activeFacts().count == 1)                 // prompt layer
        #expect(try stores.factsNeedingReview().count == 1)          // review UI sees it
        let recall = MemoryRecall(stores: stores, embedder: FakeEmbedder())
        let recalled = await recall.recall(query: "colleague belief", limit: 5)
        #expect(!recalled.contains { $0.id == sensitive.id })        // recall excluded

        try stores.approveFact(sensitive.id)
        #expect(try stores.activeFacts().count == 2)                 // released after review
    }

    @Test func backfillEmbedsFactsSavedWhileEmbedderWasDown() async throws {
        let stores = try freshStores()
        try stores.saveFact(MemoryFact(text: "Rides a bike to campus", kind: .rhythm))   // no embedding
        #expect(try stores.factStats().embedded == 0)

        let indexer = Indexer(stores: stores, embedder: FakeEmbedder())
        try await indexer.embedMissingFacts()
        #expect(try stores.factStats().embedded == 1)

        // And the vector arm now finds it semantically.
        let recall = MemoryRecall(stores: stores, embedder: FakeEmbedder())
        let recalled = await recall.recall(query: "cycling", limit: 3)
        #expect(recalled.contains { $0.text.contains("bike") })
    }

    @Test func promptBudgetIsLeanerInVoiceMode() {
        let facts = (0..<40).map { MemoryFact(text: "Fact number \($0)", kind: .biography) }
        let chat = PromptBuilder.systemPrompt(memories: [], facts: facts, retrieved: [], voiceMode: false)
        let voice = PromptBuilder.systemPrompt(memories: [], facts: facts, retrieved: [], voiceMode: true)
        #expect(chat.contains("Fact number 39"))
        #expect(voice.contains("Fact number 11"))
        #expect(!voice.contains("Fact number 12"))
    }

    @Test func recallDegradesToKeywordWhenEmbedderFails() async throws {
        let stores = try freshStores()
        // Store directly (no embedding) to isolate the keyword arm.
        try stores.saveFact(MemoryFact(text: "Homelab runs Proxmox and TrueNAS",
                                       entitiesText: "Proxmox", kind: .biography, source: .userStated))
        let recall = MemoryRecall(stores: stores, embedder: FakeEmbedder(failing: true))
        let facts = await recall.recall(query: "proxmox", limit: 5)
        #expect(facts.count == 1)
        #expect(facts.first?.text.contains("Proxmox") == true)
    }
}
