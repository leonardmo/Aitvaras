import Foundation
import GRDB
import AitvarasCore

/// Single SQLite database for everything Aitvaras persists: activity log,
/// memories, chats, RAG index, suggestions, connector state.
/// Column names match Swift property names exactly — no mapping layer.
public final class AitvarasDatabase: Sendable {
    public let queue: DatabaseQueue

    /// Default on-disk location: `<state dir>/aitvaras.sqlite` — the state dir
    /// is `~/Library/Application Support/Aitvaras` unless `AITVARAS_STATE_DIR`
    /// relocates the whole profile (testing seam, see AitvarasPaths).
    public static func defaultURL() throws -> URL {
        AitvarasPaths.databaseURL
    }

    public convenience init() throws {
        try self.init(url: Self.defaultURL())
    }

    /// Pass `nil` for an in-memory database (tests).
    public init(url: URL?) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        queue = url.map { try! DatabaseQueue(path: $0.path, configuration: config) }
            ?? (try! DatabaseQueue(configuration: config))
        try migrator.migrate(queue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "activityEvent") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("connectorID", .text)
                t.column("summary", .text).notNull()
                t.column("detailJSON", .text)
                t.column("causedBy", .text).indexed()
                t.column("sourceID", .text).indexed()
            }
            try db.create(table: "memory") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("content", .text).notNull()
                t.column("category", .text).notNull()
                t.column("archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "kv") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "conversation") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "storedMessage") { t in
                t.primaryKey("id", .text)
                t.column("conversationID", .text).notNull().indexed()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("metadataJSON", .text)
            }
            try db.create(table: "ragDocument") { t in
                t.primaryKey("id", .text)
                t.column("source", .text).notNull().indexed()   // e.g. "studium", "cealonet"
                t.column("path", .text).notNull().unique()
                t.column("mtime", .double).notNull()
                t.column("contentHash", .text).notNull()
            }
            try db.create(table: "ragChunk") { t in
                t.primaryKey("id", .text)
                t.column("documentID", .text).notNull().indexed()
                    .references("ragDocument", onDelete: .cascade)
                t.column("ord", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("context", .text)                      // e.g. heading path / symbol
                t.column("embedding", .blob)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ragFTS USING fts5(chunkID UNINDEXED, text)
                """)
            try db.create(table: "seenItem") { t in
                t.column("connectorID", .text).notNull()
                t.column("itemID", .text).notNull()
                t.column("seenAt", .datetime).notNull()
                t.primaryKey(["connectorID", "itemID"])
            }
            try db.create(table: "suggestion") { t in
                t.primaryKey("id", .text)
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("connectorID", .text).notNull()
                t.column("toolName", .text).notNull()
                t.column("argumentsJSON", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending") // pending/accepted/rejected/executed/failed
                t.column("causedBy", .text)                                 // activity event id
            }
        }
        m.registerMigration("v2-goals") { db in
            try db.create(table: "goal") { t in
                t.primaryKey("id", .text)
                t.column("day", .text).notNull().indexed()   // "2026-07-06" local
                t.column("text", .text).notNull()
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
        }
        // D12 v2 — structured, bi-temporal memory (MASTERPLAN §9). Facts +
        // entities + a curiosity queue. The flat `memory` table (v1) stays for
        // backward compat; PromptBuilder prefers facts and falls back to it.
        m.registerMigration("v3-knowledge") { db in
            try db.create(table: "memoryFact") { t in
                t.primaryKey("id", .text)
                t.column("text", .text).notNull()
                t.column("entitiesText", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull()
                t.column("importance", .integer).notNull().defaults(to: 5)
                t.column("confidence", .double).notNull().defaults(to: 0.8)
                t.column("source", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("validFrom", .datetime).notNull()
                t.column("validTo", .datetime).indexed()      // NULL = currently valid
                t.column("supersededBy", .text)
                t.column("lastAccessed", .datetime).notNull()
                t.column("sourceEpisodesJSON", .text)
                t.column("embedding", .blob)
            }
            try db.create(table: "memoryEntity") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "memoryFactEntity") { t in
                t.column("factID", .text).notNull()
                    .references("memoryFact", onDelete: .cascade)
                t.column("entityID", .text).notNull()
                    .references("memoryEntity", onDelete: .cascade)
                t.primaryKey(["factID", "entityID"])
            }
            try db.create(table: "curiosityQuestion") { t in
                t.primaryKey("id", .text)
                t.column("text", .text).notNull()
                t.column("motivation", .text).notNull().defaults(to: "")
                t.column("expectedValue", .integer).notNull().defaults(to: 5)
                t.column("status", .text).notNull().defaults(to: "open").indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("answeredAt", .datetime)
            }
            try db.execute(sql: """
                CREATE VIRTUAL TABLE factFTS USING fts5(factID UNINDEXED, text)
                """)
        }
        // O7 quarantine column + one-time import of legacy flat memories into
        // the fact layer (without this, existing memories silently stop
        // appearing the moment the first fact exists — see AgentLoop fallback).
        m.registerMigration("v4-memory-import") { db in
            try db.alter(table: "memoryFact") { t in
                t.add(column: "needsReview", .boolean).notNull().defaults(to: false)
            }
            let legacy = try Row.fetchAll(
                db, sql: "SELECT content, category, createdAt, updatedAt FROM memory WHERE archived = 0")
            for row in legacy {
                let content: String = row["content"]
                let category: String = row["category"]
                let createdAt: Date = row["createdAt"]
                let updatedAt: Date = row["updatedAt"]
                let kind = switch category {
                case "preference": "preference"
                case "person": "biography"
                default: "biography"
                }
                let id = UUID()
                // UUIDs bind as GRDB's native encoding here (never .uuidString
                // in a value position); the FTS mirror keys on text on purpose.
                try db.execute(sql: """
                    INSERT INTO memoryFact
                        (id, text, entitiesText, kind, importance, confidence, source,
                         createdAt, validFrom, validTo, supersededBy, lastAccessed,
                         sourceEpisodesJSON, embedding, needsReview)
                    VALUES (?, ?, '', ?, 6, 0.9, 'extracted', ?, ?, NULL, NULL, ?, NULL, NULL, 0)
                    """, arguments: [id, content, kind, createdAt, createdAt, updatedAt])
                try db.execute(sql: "INSERT INTO factFTS(factID, text) VALUES(?, ?)",
                               arguments: [id.uuidString, content])
            }
            // Legacy rows stay for rollback safety but leave the prompt path.
            try db.execute(sql: "UPDATE memory SET archived = 1")
        }
        // F12 capture sessions: text only, never media.
        m.registerMigration("v5-capture") { db in
            try db.create(table: "captureRecord") { t in
                t.primaryKey("id", .text)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("scope", .text).notNull()
                t.column("audio", .text).notNull()
                t.column("consentConfirmed", .boolean).notNull()
                t.column("transcript", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("summaryPending", .boolean).notNull().defaults(to: false)
            }
        }
        return m
    }
}
