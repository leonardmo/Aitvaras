import Foundation
import GRDB
import AitvarasCore

/// Typed access layer over AitvarasDatabase. One instance per app, shared.
public struct Stores: Sendable {
    public let db: AitvarasDatabase

    public init(db: AitvarasDatabase) {
        self.db = db
    }

    // MARK: Activity log

    @discardableResult
    public func record(_ event: ActivityEvent) throws -> ActivityEvent {
        try db.queue.write { try event.insert($0) }
        return event
    }

    public func recentActivity(limit: Int = 200) throws -> [ActivityEvent] {
        try db.queue.read {
            try ActivityEvent
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll($0)
        }
    }

    /// Episodes for the nightly consolidator: everything since its last run,
    /// oldest first, capped so one busy day can't blow up the prompt.
    public func activity(since: Date, limit: Int = 300) throws -> [ActivityEvent] {
        try db.queue.read {
            try ActivityEvent
                .filter(Column("timestamp") > since)
                .order(Column("timestamp"))
                .limit(limit)
                .fetchAll($0)
        }
    }

    /// Walk the provenance chain from an event back to its root cause.
    public func provenance(of eventID: UUID) throws -> [ActivityEvent] {
        try db.queue.read { dbc in
            var chain: [ActivityEvent] = []
            var current = try ActivityEvent.fetchOne(dbc, key: eventID)
            while let event = current {
                chain.append(event)
                current = try event.causedBy.flatMap { try ActivityEvent.fetchOne(dbc, key: $0) }
                if chain.count > 50 { break }   // cycle guard
            }
            return chain
        }
    }

    // MARK: Memories

    public func saveMemory(_ memory: Memory) throws {
        try db.queue.write { try memory.save($0) }
    }

    public func activeMemories() throws -> [Memory] {
        try db.queue.read {
            try Memory.filter(Column("archived") == false)
                .order(Column("updatedAt").desc)
                .fetchAll($0)
        }
    }

    // MARK: Knowledge — facts (D12 v2, MASTERPLAN §9)

    /// Upsert a fact, keep its FTS row and entity links in sync. Passing
    /// `entityIDs` replaces the fact's links (nil leaves them untouched).
    /// The FTS table keys on `factID` as text (self-consistent); the join
    /// table goes through a GRDB record so its UUID encoding matches the
    /// referenced primary keys (raw `.uuidString` SQL would break the FK).
    public func saveFact(_ fact: MemoryFact, entityIDs: [UUID]? = nil) throws {
        try db.queue.write { dbc in
            try fact.save(dbc)
            try dbc.execute(sql: "DELETE FROM factFTS WHERE factID = ?", arguments: [fact.id.uuidString])
            try dbc.execute(sql: "INSERT INTO factFTS(factID, text) VALUES(?, ?)",
                            arguments: [fact.id.uuidString, fact.searchText])
            if let entityIDs {
                try FactEntityLink.filter(Column("factID") == fact.id).deleteAll(dbc)
                for entityID in Set(entityIDs) {
                    try FactEntityLink(factID: fact.id, entityID: entityID).insert(dbc)
                }
            }
        }
    }

    /// Currently-valid, user-visible facts (validTo IS NULL, not quarantined),
    /// strongest first. The always-in-context profile layer and recall
    /// candidate set.
    public func activeFacts(limit: Int? = nil) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            var q = MemoryFact.filter(Column("validTo") == nil)
                .filter(Column("needsReview") == false)
                .order(Column("importance").desc, Column("lastAccessed").desc)
            if let limit { q = q.limit(limit) }
            return try q.fetchAll(dbc)
        }
    }

    /// Quarantined sensitive facts (O7) awaiting user approval in the memory UI.
    public func factsNeedingReview() throws -> [MemoryFact] {
        try db.queue.read {
            try MemoryFact.filter(Column("needsReview") == true)
                .order(Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    /// User approved (or edited) a quarantined fact — release it into use.
    public func approveFact(_ id: UUID) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { return }
            fact.needsReview = false
            try fact.update(dbc)
        }
    }

    public func fact(id: UUID) throws -> MemoryFact? {
        try db.queue.read { try MemoryFact.fetchOne($0, key: id) }
    }

    public func allFacts(includeSuperseded: Bool = true) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            let q = includeSuperseded ? MemoryFact.all() : MemoryFact.filter(Column("validTo") == nil)
            return try q.order(Column("createdAt").desc).fetchAll(dbc)
        }
    }

    /// Invalidate `oldID` as of `at`, pointing it at the fact that replaced it.
    /// The old fact is kept (queryable history), never deleted (MASTERPLAN §8).
    public func supersedeFact(_ oldID: UUID, by newID: UUID?, at: Date = .now) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: oldID) else { return }
            fact.validTo = at
            fact.supersededBy = newID
            try fact.update(dbc)
        }
    }

    /// Hard-delete a fact — user action only (never automatic).
    public func deleteFact(_ id: UUID) throws {
        try db.queue.write { dbc in
            try dbc.execute(sql: "DELETE FROM factFTS WHERE factID = ?", arguments: [id.uuidString])
            _ = try MemoryFact.deleteOne(dbc, key: id)   // cascades join rows
        }
    }

    /// Bump recency on retrieved facts (decay is on access, not creation).
    public func touchFacts(ids: [UUID], at: Date = .now) throws {
        guard !ids.isEmpty else { return }
        try db.queue.write { dbc in
            for id in ids {
                guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { continue }
                fact.lastAccessed = at
                try fact.update(dbc)
            }
        }
    }

    /// Keyword arm of hybrid recall: BM25 over the fact FTS index.
    public func factKeywordSearch(_ query: String, limit: Int) throws -> [(factID: UUID, score: Double)] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try db.queue.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT factID, bm25(factFTS) AS score FROM factFTS
                WHERE factFTS MATCH ? ORDER BY score LIMIT ?
                """, arguments: [match, limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["factID"]) else { return nil }
                return (id, row["score"] as Double? ?? 0)
            }
        }
    }

    /// Facts carrying an embedding, for the vector arm (brute-force cosine —
    /// fine at personal scale, D11). `activeOnly` also excludes quarantined facts.
    public func factsWithEmbeddings(activeOnly: Bool = true) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            var q = MemoryFact.filter(Column("embedding") != nil)
            if activeOnly {
                q = q.filter(Column("validTo") == nil).filter(Column("needsReview") == false)
            }
            return try q.fetchAll(dbc)
        }
    }

    /// Facts saved while the embedder was down (embedding IS NULL) — the
    /// backfill set for `Indexer.embedMissingFacts()`.
    public func factsMissingEmbedding(limit: Int = 500) throws -> [MemoryFact] {
        try db.queue.read {
            try MemoryFact.filter(Column("embedding") == nil).limit(limit).fetchAll($0)
        }
    }

    public func saveFactEmbedding(_ id: UUID, vector: [Float]) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { return }
            fact.embeddingVector = vector
            try fact.update(dbc)
        }
    }

    public func facts(ids: [UUID]) throws -> [MemoryFact] {
        try db.queue.read { try MemoryFact.filter(ids.contains(Column("id"))).fetchAll($0) }
    }

    public func factStats() throws -> (total: Int, active: Int, embedded: Int) {
        try db.queue.read { dbc in
            let total = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact") ?? 0
            let active = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact WHERE validTo IS NULL") ?? 0
            let embedded = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact WHERE embedding IS NOT NULL") ?? 0
            return (total, active, embedded)
        }
    }

    // MARK: Knowledge — entities

    public func saveEntity(_ entity: MemoryEntity) throws {
        try db.queue.write { try entity.save($0) }
    }

    public func entities() throws -> [MemoryEntity] {
        try db.queue.read { try MemoryEntity.order(Column("name")).fetchAll($0) }
    }

    public func entity(named name: String) throws -> MemoryEntity? {
        try db.queue.read {
            try MemoryEntity.filter(Column("name").like(name)).fetchOne($0)
        }
    }

    /// Resolve a comma-separated name list to entities, creating missing ones.
    /// Shared by the memory connector, archiver and consolidator so entity
    /// identity stays case-insensitively unique.
    public func upsertEntities(names: String?) throws -> [MemoryEntity] {
        guard let names else { return [] }
        var result: [MemoryEntity] = []
        for raw in names.split(separator: ",") {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let existing = try entity(named: name) {
                result.append(existing)
            } else {
                let entity = MemoryEntity(name: name)
                try saveEntity(entity)
                result.append(entity)
            }
        }
        return result
    }

    public func facts(forEntity entityID: UUID, includeSuperseded: Bool = false) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            let ids = try FactEntityLink.filter(Column("entityID") == entityID)
                .fetchAll(dbc).map(\.factID)
            guard !ids.isEmpty else { return [] }
            var q = MemoryFact.filter(ids.contains(Column("id")))
            if !includeSuperseded { q = q.filter(Column("validTo") == nil) }
            return try q.order(Column("importance").desc).fetchAll(dbc)
        }
    }

    // MARK: Capture sessions (F12)

    public func saveCaptureRecord(_ record: CaptureRecord) throws {
        try db.queue.write { try record.save($0) }
    }

    public func captureRecords(limit: Int = 50) throws -> [CaptureRecord] {
        try db.queue.read {
            try CaptureRecord.order(Column("startedAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func deleteCaptureRecord(_ id: UUID) throws {
        _ = try db.queue.write { try CaptureRecord.deleteOne($0, key: id) }
    }

    // MARK: Knowledge — curiosity queue (MASTERPLAN §11)

    public func saveQuestion(_ question: CuriosityQuestion) throws {
        try db.queue.write { try question.save($0) }
    }

    public func openQuestions(limit: Int? = nil) throws -> [CuriosityQuestion] {
        try db.queue.read { dbc in
            var q = CuriosityQuestion.filter(Column("status") == "open")
                .order(Column("expectedValue").desc, Column("createdAt"))
            if let limit { q = q.limit(limit) }
            return try q.fetchAll(dbc)
        }
    }

    public func setQuestionStatus(_ id: UUID, to status: CuriosityQuestion.Status, at: Date = .now) throws {
        try db.queue.write { dbc in
            guard var question = try CuriosityQuestion.fetchOne(dbc, key: id) else { return }
            question.status = status.rawValue
            question.answeredAt = status == .answered ? at : nil
            try question.update(dbc)
        }
    }

    // MARK: Key-value settings (non-secret; secrets go to KeychainStore)

    public func setValue(_ value: String, forKey key: String) throws {
        try db.queue.write {
            try $0.execute(sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }

    public func value(forKey key: String) throws -> String? {
        try db.queue.read {
            try String.fetchOne($0, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    // MARK: Conversations

    public func saveConversation(_ c: Conversation) throws {
        try db.queue.write { try c.save($0) }
    }

    public func conversations() throws -> [Conversation] {
        try db.queue.read {
            try Conversation.order(Column("updatedAt").desc).fetchAll($0)
        }
    }

    public func appendMessage(_ m: StoredMessage) throws {
        try db.queue.write { dbc in
            try m.insert(dbc)
            try dbc.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?",
                            arguments: [Date.now, m.conversationID])
        }
    }

    public func messages(in conversationID: UUID) throws -> [StoredMessage] {
        try db.queue.read {
            try StoredMessage.filter(Column("conversationID") == conversationID)
                .order(Column("createdAt"))
                .fetchAll($0)
        }
    }

    public func deleteConversation(_ id: UUID) throws {
        _ = try db.queue.write { try Conversation.deleteOne($0, key: id) }
    }

    // MARK: Seen items (dedup for mail/moodle polling)

    /// Returns true if the item was newly marked (i.e. not seen before).
    public func markSeen(connectorID: String, itemID: String) throws -> Bool {
        try db.queue.write { dbc in
            let existing = try Bool.fetchOne(
                dbc,
                sql: "SELECT 1 FROM seenItem WHERE connectorID = ? AND itemID = ?",
                arguments: [connectorID, itemID]) ?? false
            if existing { return false }
            try dbc.execute(sql: "INSERT INTO seenItem(connectorID, itemID, seenAt) VALUES(?, ?, ?)",
                            arguments: [connectorID, itemID, Date.now])
            return true
        }
    }

    // MARK: Goals

    public func goals(day: String) throws -> [Goal] {
        try db.queue.read {
            try Goal.filter(Column("day") == day).order(Column("createdAt")).fetchAll($0)
        }
    }

    public func saveGoal(_ goal: Goal) throws {
        try db.queue.write { try goal.save($0) }
    }

    public func setGoalDone(_ id: UUID, done: Bool) throws {
        try db.queue.write {
            try $0.execute(sql: "UPDATE goal SET done = ? WHERE id = ?", arguments: [done, id])
        }
    }

    public func deleteGoal(_ id: UUID) throws {
        _ = try db.queue.write { try Goal.deleteOne($0, key: id) }
    }

    // MARK: Suggestions

    public func saveSuggestion(_ s: Suggestion) throws {
        try db.queue.write { try s.save($0) }
    }

    public func pendingSuggestions() throws -> [Suggestion] {
        try db.queue.read {
            try Suggestion.filter(Column("status") == "pending")
                .order(Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    public func updateSuggestionStatus(_ id: UUID, to status: String) throws {
        try db.queue.write {
            try $0.execute(sql: "UPDATE suggestion SET status = ? WHERE id = ?", arguments: [status, id])
        }
    }

    // MARK: RAG

    public func upsertDocument(_ doc: RAGDocument, chunks: [RAGChunk]) throws {
        try db.queue.write { dbc in
            // Replace any previous version of this path entirely.
            if let old = try RAGDocument.filter(Column("path") == doc.path).fetchOne(dbc) {
                let oldChunkIDs = try String.fetchAll(
                    dbc, sql: "SELECT id FROM ragChunk WHERE documentID = ?", arguments: [old.id.uuidString])
                for cid in oldChunkIDs {
                    try dbc.execute(sql: "DELETE FROM ragFTS WHERE chunkID = ?", arguments: [cid])
                }
                try old.delete(dbc)   // cascades to chunks
            }
            try doc.insert(dbc)
            for chunk in chunks {
                try chunk.insert(dbc)
                try dbc.execute(sql: "INSERT INTO ragFTS(chunkID, text) VALUES(?, ?)",
                                arguments: [chunk.id.uuidString, chunk.text])
            }
        }
    }

    public func removeDocument(path: String) throws {
        try db.queue.write { dbc in
            guard let doc = try RAGDocument.filter(Column("path") == path).fetchOne(dbc) else { return }
            let chunkIDs = try String.fetchAll(
                dbc, sql: "SELECT id FROM ragChunk WHERE documentID = ?", arguments: [doc.id.uuidString])
            for cid in chunkIDs {
                try dbc.execute(sql: "DELETE FROM ragFTS WHERE chunkID = ?", arguments: [cid])
            }
            try doc.delete(dbc)
        }
    }

    public func document(path: String) throws -> RAGDocument? {
        try db.queue.read { try RAGDocument.filter(Column("path") == path).fetchOne($0) }
    }

    public func allDocuments(source: String? = nil) throws -> [RAGDocument] {
        try db.queue.read {
            var q = RAGDocument.all()
            if let source { q = q.filter(Column("source") == source) }
            return try q.fetchAll($0)
        }
    }

    /// Keyword arm of hybrid retrieval: BM25 over FTS5.
    public func keywordSearch(_ query: String, limit: Int) throws -> [(chunkID: UUID, score: Double)] {
        try db.queue.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT chunkID, bm25(ragFTS) AS score FROM ragFTS
                WHERE ragFTS MATCH ? ORDER BY score LIMIT ?
                """, arguments: [Self.ftsQuery(query), limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["chunkID"]) else { return nil }
                return (id, row["score"] as Double? ?? 0)
            }
        }
    }

    /// All chunks with embeddings, for the vector arm (brute-force cosine —
    /// fine for personal corpus sizes; see D11).
    public func chunksWithEmbeddings() throws -> [RAGChunk] {
        try db.queue.read {
            try RAGChunk.filter(Column("embedding") != nil).fetchAll($0)
        }
    }

    public func chunks(ids: [UUID]) throws -> [RAGChunk] {
        try db.queue.read { try RAGChunk.filter(ids.contains(Column("id"))).fetchAll($0) }
    }

    public func chunkStats() throws -> (documents: Int, chunks: Int, embedded: Int) {
        try db.queue.read { dbc in
            let d = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragDocument") ?? 0
            let c = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragChunk") ?? 0
            let e = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragChunk WHERE embedding IS NOT NULL") ?? 0
            return (d, c, e)
        }
    }

    /// FTS5 treats many characters as syntax; quote each term.
    static func ftsQuery(_ raw: String) -> String {
        raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }
}
