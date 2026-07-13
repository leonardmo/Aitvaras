import Foundation
import AitvarasCore
import AitvarasStore

/// Aitvaras's structured memory about the user (D12 v2, MASTERPLAN §9–§11),
/// exposed to the model as tools. Reads recall facts and the curiosity queue;
/// writes are the hot-path lane only — explicit "remember this" and
/// corrections — everything heavier (extraction, reflection, consolidation)
/// is the nightly job (K2), not this connector.
///
/// A retrieval-protocol line in the system prompt tells the model to call
/// `memory.search` before answering non-trivial personal questions.
public actor MemoryConnector: Connector {
    public nonisolated let id = "memory"
    public nonisolated let displayName = "Memory"

    private let stores: Stores
    private let recall: MemoryRecall

    public init(stores: Stores, embedder: any EmbeddingEngine) {
        self.stores = stores
        self.recall = MemoryRecall(stores: stores, embedder: embedder)
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "search",
            description: "Search what you know about the user — their preferences, life, projects, people, habits. Call this before answering non-trivial personal questions instead of guessing. Returns the most relevant remembered facts.",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}"#,
            risk: .read),
        ToolDefinition(
            name: "about",
            description: "Everything currently known about one person, place, course or system, by name (e.g. 'Proxmox', a lecturer, a friend).",
            parametersJSON: #"{"type":"object","properties":{"entity":{"type":"string"}},"required":["entity"]}"#,
            risk: .read),
        ToolDefinition(
            name: "remember",
            description: "Store a durable fact the user explicitly asked you to remember, or clearly stated about themselves. Not for transient chit-chat. kind ∈ preference|biography|event|procedure|belief|rhythm. entities = comma-separated names the fact is about.",
            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"},"kind":{"type":"string"},"importance":{"type":"integer"},"entities":{"type":"string"}},"required":["text"]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "revise",
            description: "Correct or update something you remembered: supersede the old fact (id from search) with a corrected statement. The old fact is kept as history, not deleted.",
            parametersJSON: #"{"type":"object","properties":{"old_id":{"type":"string"},"text":{"type":"string"}},"required":["old_id","text"]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "list_open_questions",
            description: "The questions you'd like the user to answer to understand them better (the curiosity queue). Use when the user asks what you want to know, or to run a short Q&A.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .read),
        ToolDefinition(
            name: "answer_question",
            description: "Record the user's answer to one of your open questions (id from list_open_questions). Stores it as a known fact and retires the question.",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"},"answer":{"type":"string"}},"required":["id","answer"]}"#,
            risk: .reversibleWrite)
    ]

    public func health() async -> ConnectorHealth { .ready }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        let args = try ToolArgs(json: argumentsJSON)
        switch toolName {
        case "search":
            let query = try args.requiredString("query")
            let limit = max(1, min(20, args.int("limit") ?? 6))
            let facts = await recall.recall(query: query, limit: limit)
            if facts.isEmpty { return "No matching facts remembered yet." }
            return facts.map(Self.render).joined(separator: "\n")

        case "about":
            let name = try args.requiredString("entity")
            guard let entity = try stores.entity(named: name) else {
                return "Nothing remembered about \"\(name)\" yet."
            }
            let facts = try stores.facts(forEntity: entity.id)
            var lines = [JSONText.object([
                ("entity", .string(entity.name)),
                ("kind", .string(entity.kindValue.rawValue)),
                ("summary", entity.summary.isEmpty ? nil : .string(entity.summary))
            ])]
            lines += facts.map(Self.render)
            return lines.joined(separator: "\n")

        case "remember":
            let fact = try await store(
                text: try args.requiredString("text"),
                kindRaw: args.string("kind"),
                importance: args.int("importance"),
                entityNames: args.string("entities"),
                source: .userStated)
            return JSONText.object([("remembered", .bool(true)), ("id", .string(fact.id.uuidString))])

        case "revise":
            guard let oldID = UUID(uuidString: try args.requiredString("old_id")) else {
                throw ConnectorError("Invalid old_id — use search to get real fact ids.")
            }
            guard let old = try stores.fact(id: oldID) else {
                throw ConnectorError("No fact with id \(oldID.uuidString).")
            }
            let replacement = try await store(
                text: try args.requiredString("text"),
                kindRaw: old.kind,
                importance: old.importance,
                entityNames: old.entitiesText,
                source: .userStated)
            try stores.supersedeFact(oldID, by: replacement.id)
            return JSONText.object([
                ("revised", .bool(true)),
                ("new_id", .string(replacement.id.uuidString)),
                ("superseded", .string(oldID.uuidString))])

        case "list_open_questions":
            let questions = try stores.openQuestions(limit: 10)
            if questions.isEmpty { return "No open questions right now." }
            return questions.map { q in
                JSONText.object([
                    ("id", .string(q.id.uuidString)),
                    ("question", .string(q.text)),
                    ("why", q.motivation.isEmpty ? nil : .string(q.motivation))])
            }.joined(separator: "\n")

        case "answer_question":
            guard let id = UUID(uuidString: try args.requiredString("id")) else {
                throw ConnectorError("Invalid question id — use list_open_questions.")
            }
            let answer = try args.requiredString("answer")
            let questions = try stores.openQuestions()
            guard let question = questions.first(where: { $0.id == id }) else {
                throw ConnectorError("No open question with id \(id.uuidString).")
            }
            let fact = try await store(
                text: "\(question.text) — \(answer)",
                kindRaw: nil, importance: 6, entityNames: nil, source: .userAnswered)
            try stores.setQuestionStatus(id, to: .answered)
            return JSONText.object([("recorded", .bool(true)), ("fact_id", .string(fact.id.uuidString))])

        default:
            throw ConnectorError("Unknown tool \(toolName)")
        }
    }

    // MARK: Writes

    /// Create a fact: resolve/attach entities, embed best-effort, persist.
    private func store(text: String, kindRaw: String?, importance: Int?,
                       entityNames: String?, source: MemoryFact.Source) async throws -> MemoryFact {
        let entities = try stores.upsertEntities(names: entityNames)
        let entitiesText = entities.map(\.name).joined(separator: ", ")
        let kind = kindRaw.flatMap(MemoryFact.Kind.init(rawValue:)) ?? .biography
        var fact = MemoryFact(
            text: text, entitiesText: entitiesText, kind: kind,
            importance: importance ?? 5, confidence: source == .extracted ? 0.8 : 1.0,
            source: source)
        fact.embedding = await recall.embedding(for: fact.searchText)
        try stores.saveFact(fact, entityIDs: entities.map(\.id))
        return fact
    }

    private static func render(_ fact: MemoryFact) -> String {
        JSONText.object([
            ("id", .string(fact.id.uuidString)),
            ("fact", .string(fact.text)),
            ("kind", .string(fact.kindValue.rawValue)),
            ("about", fact.entitiesText.isEmpty ? nil : .string(fact.entitiesText))])
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }
    }
}
