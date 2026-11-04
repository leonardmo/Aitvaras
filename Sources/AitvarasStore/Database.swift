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
        // Isolated profiles must never inspect or mutate the user's real state.
        if !AitvarasPaths.isIsolated {
            let result = try LegacyStateMigrator.migrateIfNeeded()
            if result == .conflict {
                throw LegacyStateMigrationError.conflictingProfiles
            }
        }
        return AitvarasPaths.databaseURL
    }

    public convenience init() throws {
        try self.init(url: Self.defaultURL())
    }

    /// Pass `nil` for an in-memory database (tests).
    public init(url: URL?) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let url {
            queue = try DatabaseQueue(path: url.path, configuration: config)
        } else {
            queue = try DatabaseQueue(configuration: config)
        }
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
                t.column("source", .text).notNull().indexed()   // e.g. "studium", "projects"
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
        m.registerMigration("v6-held-notifications") { db in
            try db.create(table: "heldNotification") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }
        m.registerMigration("v7-phone-notification-outbox") { db in
            try db.create(table: "phoneNotificationOutbox") { t in
                t.primaryKey("id", .text)
                t.column("text", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .datetime).notNull().indexed()
                t.column("causedBy", .text).notNull()
                t.column("sourceID", .text)
                t.column("queueEventID", .text).notNull()
                    .references("activityEvent", onDelete: .cascade)
            }
        }
        m.registerMigration("v8-message-trust") { db in
            try db.create(table: "trustedMessageSource") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                // Empty for email rules; required for notification labels.
                t.column("applicationID", .text).notNull().defaults(to: "")
                t.column("label", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
                t.uniqueKey(["kind", "value", "applicationID"])
            }
            try db.create(table: "messageSourceObservation") { t in
                t.primaryKey("id", .text)
                t.column("connectorID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("value", .text).notNull()
                t.column("applicationID", .text).notNull().defaults(to: "")
                t.column("displayName", .text).notNull()
                t.column("domain", .text)
                t.column("canApproveExactSender", .boolean).notNull()
                t.column("firstSeenAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime).notNull().indexed()
                t.column("messageCount", .integer).notNull().defaults(to: 1)
                t.column("dismissedAt", .datetime)
                t.uniqueKey(["kind", "value", "applicationID"])
            }
        }
        // News is deliberately isolated from activity, conversations, memory
        // and RAG. External article text can therefore never become a user
        // fact through nightly consolidation merely because it appeared in a
        // feed. Topics cascade only into their own bounded article cache.
        m.registerMigration("v9-news-feed") { db in
            try db.create(table: "newsTopic") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("query", .text).notNull()
                t.column("importance", .integer).notNull().defaults(to: 3)
                t.column("refreshIntervalMinutes", .integer).notNull().defaults(to: 1440)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastFetchedAt", .datetime).indexed()
            }
            try db.create(table: "newsArticle") { t in
                t.primaryKey("id", .text)
                t.column("topicID", .text).notNull().indexed()
                    .references("newsTopic", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("sourceName", .text).notNull()
                t.column("sourceDomain", .text).notNull()
                t.column("url", .text).notNull()
                t.column("summary", .text).notNull().defaults(to: "")
                t.column("imageURL", .text)
                t.column("publishedAt", .datetime).notNull().indexed()
                t.column("fetchedAt", .datetime).notNull()
                t.column("qualityScore", .double).notNull()
                t.column("corroborationCount", .integer).notNull().defaults(to: 1)
                t.column("supportingSourcesJSON", .text).notNull().defaults(to: "[]")
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["topicID", "url"])
            }
        }
        // Deterministic command shortcuts and approval-gated schedules. Raw
        // observations stay local, are bounded to 90 days by the store, and
        // contain only the user's command plus the fixed tool path—not model
        // reasoning or connector output.
        m.registerMigration("v10-command-routines") { db in
            try db.create(table: "commandObservation") { t in
                t.primaryKey("id", .text)
                t.column("occurredAt", .datetime).notNull().indexed()
                t.column("phrase", .text).notNull()
                t.column("normalizedPhrase", .text).notNull().indexed()
                t.column("channel", .text).notNull()
                t.column("executionMode", .text).notNull()
                t.column("stepsJSON", .text).notNull()
                t.column("workflowSignature", .text).notNull().indexed()
            }
            try db.create(table: "commandRoutine") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("triggerKind", .text).notNull().indexed()
                t.column("phrasesJSON", .text).notNull().defaults(to: "[]")
                t.column("scheduleMinuteOfDay", .integer)
                t.column("scheduleWeekdayMask", .integer)
                t.column("stepsJSON", .text).notNull()
                t.column("status", .text).notNull().indexed()
                t.column("evidenceCount", .integer).notNull().defaults(to: 0)
                t.column("explanation", .text).notNull().defaults(to: "")
                t.column("dedupeKey", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("lastRunAt", .datetime)
                t.column("lastRunSlot", .text)
                t.column("runCount", .integer).notNull().defaults(to: 0)
            }
        }
        // Provider-neutral cloud CLI accounting plus optional review metadata
        // for deterministic shortcut and automation candidates. No prompt,
        // response, memory text or connector argument is persisted here.
        m.registerMigration("v11-cloud-agents") { db in
            try db.create(table: "cloudUsage") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("feature", .text).notNull().indexed()
                t.column("provider", .text).notNull().indexed()
                t.column("durationMilliseconds", .integer).notNull()
                t.column("inputCharacters", .integer).notNull()
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
                t.column("reportedCostUSD", .double)
                t.column("succeeded", .boolean).notNull().indexed()
                t.column("dataCategoriesJSON", .text).notNull()
                t.column("policyVersion", .text).notNull()
                t.column("failureKind", .text)
            }
            try db.alter(table: "commandRoutine") { t in
                t.add(column: "reviewProvider", .text)
                t.add(column: "reviewedAt", .datetime)
                t.add(column: "reviewSummary", .text)
            }
        }
        // Metadata-only accounting for on-device MLX/Ollama/Apple inference.
        // Token counts are exact when the engine exposes them and explicitly
        // marked estimated otherwise.
        m.registerMigration("v12-local-model-usage") { db in
            try db.create(table: "localModelUsage") { t in
                t.primaryKey("id", .text)
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("engine", .text).notNull().indexed()
                t.column("tier", .text).notNull().indexed()
                t.column("durationMilliseconds", .integer).notNull()
                t.column("inputTokens", .integer).notNull()
                t.column("outputTokens", .integer).notNull()
                t.column("isEstimated", .boolean).notNull()
                t.column("succeeded", .boolean).notNull().indexed()
                t.column("failureKind", .text)
            }
        }
        // Operational metadata is additive: existing audit history and all
        // installation settings remain untouched, and no work is replayed.
        m.registerMigration("v13-activity-monitoring") { db in
            try db.alter(table: "activityEvent") { t in
                t.add(column: "runID", .text).indexed()
            }
            try db.create(table: "activityRun") { t in
                t.primaryKey("id", .text)
                t.column("parentID", .text).indexed()
                t.column("referenceID", .text).indexed()
                t.column("category", .text).notNull().indexed()
                t.column("trigger", .text).notNull()
                t.column("state", .text).notNull().indexed()
                t.column("title", .text).notNull()
                t.column("stage", .text)
                t.column("progressCompleted", .integer)
                t.column("progressTotal", .integer)
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("provider", .text)
                t.column("executionLocation", .text)
                t.column("dataAccess", .text)
                t.column("dataDestination", .text)
                t.column("outcome", .text)
            }
            try db.create(table: "serviceStatus") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("configured", .boolean).notNull()
                t.column("enabled", .boolean).notNull()
                t.column("paused", .boolean).notNull()
                t.column("stage", .text)
                t.column("lastAttempt", .datetime)
                t.column("lastSuccess", .datetime)
                t.column("nextOpportunity", .datetime)
                t.column("problem", .text)
                t.column("counterDay", .text)
                t.column("dailyChecks", .integer).notNull().defaults(to: 0)
                t.column("dailySuccesses", .integer).notNull().defaults(to: 0)
            }
        }
        m.registerMigration("v14-service-check-summaries") { db in
            try db.create(table: "serviceCheckSummary") { t in
                t.primaryKey("id", .text)
                t.column("serviceID", .text).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("day", .text).notNull().indexed()
                t.column("checks", .integer).notNull()
                t.column("successes", .integer).notNull()
                t.column("lastAttempt", .datetime).notNull().indexed()
                t.column("lastSuccess", .datetime)
                t.uniqueKey(["serviceID", "day"])
            }
        }
        m.registerMigration("v15-activity-review") { db in
            try db.alter(table: "activityRun") { t in
                t.add(column: "acknowledgedAt", .datetime)
            }
        }
        m.registerMigration("v16-activity-stages") { db in
            try db.create(table: "activityRunStep") { t in
                t.primaryKey("id", .text)
                t.column("runID", .text).notNull().indexed()
                t.column("timestamp", .datetime).notNull()
                t.column("stage", .text).notNull()
                t.column("state", .text).notNull()
            }
        }
        // Additive workspace metadata. Existing conversations, settings and
        // knowledge are deliberately neither assigned nor rewritten.
        m.registerMigration("v17-workspaces") { db in
            try db.create(table: "workspaceProject") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("instructions", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("allowsCloud", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "workspaceFolder") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().indexed().references("workspaceProject", onDelete: .restrict)
                t.column("path", .text).notNull()
                t.column("access", .text).notNull().check { $0 == "readOnly" || $0 == "readWrite" }
                t.uniqueKey(["projectID", "path"])
            }
            try db.create(table: "workspaceChat") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().indexed().references("workspaceProject", onDelete: .restrict)
                t.column("localConversationID", .text).notNull().unique().references("conversation", onDelete: .restrict)
                t.column("title", .text).notNull()
                t.column("purpose", .text).notNull().defaults(to: "")
                t.column("kind", .text).notNull().check { $0 == "primary" || $0 == "temporary" }
                t.column("createdAt", .datetime).notNull()
                t.column("lastActivityAt", .datetime).notNull().indexed()
                t.column("archivedAt", .datetime)
            }
            try db.create(table: "workspaceProjectLink") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().indexed().references("workspaceProject", onDelete: .restrict)
                t.column("provider", .text).notNull().check { $0 == "claude" || $0 == "codex" }
                t.column("externalID", .text).notNull()
                t.column("hostID", .text).notNull().defaults(to: "local")
                t.column("displayName", .text).notNull()
                t.column("sourceRoot", .text)
                t.uniqueKey(["provider", "hostID", "externalID"])
            }
            try db.create(table: "workspaceSessionLink") { t in
                t.primaryKey("id", .text)
                t.column("chatID", .text).notNull().indexed().references("workspaceChat", onDelete: .restrict)
                t.column("provider", .text).notNull().check { $0 == "claude" || $0 == "codex" || $0 == "local" }
                t.column("externalID", .text).notNull()
                t.column("hostID", .text).notNull().defaults(to: "local")
                t.column("displayName", .text).notNull()
                t.column("lastSyncedAt", .datetime)
                t.uniqueKey(["provider", "hostID", "externalID"])
            }
        }
        m.registerMigration("v18-native-history") { db in
            try db.create(table: "workspaceNativeSnapshot") { t in
                t.primaryKey("sessionLinkID", .text).references("workspaceSessionLink", onDelete: .restrict)
                t.column("directory", .text)
                t.column("parentExternalID", .text)
                t.column("providerUpdatedAt", .datetime)
                t.column("approvedAt", .datetime).notNull()
                t.column("lastSyncedAt", .datetime).notNull()
                t.column("coverage", .text).notNull()
                t.column("nextCursor", .text)
                t.column("direction", .text).notNull().check { $0 == "older" || $0 == "newer" }
            }
            try db.create(table: "workspaceNativeMessage") { t in
                t.primaryKey("id", .text)
                t.column("sessionLinkID", .text).notNull().indexed().references("workspaceSessionLink", onDelete: .restrict)
                t.column("externalID", .text).notNull()
                t.column("role", .text).notNull().check { $0 == "user" || $0 == "assistant" }
                t.column("text", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("firstObservedAt", .datetime).notNull()
                t.column("lastObservedAt", .datetime).notNull()
                t.column("revision", .integer).notNull()
                t.uniqueKey(["sessionLinkID", "externalID"])
            }
            try db.create(table: "workspaceNativeRevision") { t in
                t.primaryKey("id", .text)
                t.column("messageID", .text).notNull().indexed().references("workspaceNativeMessage", onDelete: .restrict)
                t.column("revision", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("observedAt", .datetime).notNull()
                t.uniqueKey(["messageID", "revision"])
            }
        }
        m.registerMigration("v19-native-history-refresh") { db in
            try db.alter(table: "workspaceNativeSnapshot") { t in
                // Existing lastSyncedAt values only prove that a page was read.
                t.add(column: "lastCompleteRefreshAt", .datetime)
                // Legacy parent IDs do not establish a fork/spawn relationship.
                t.add(column: "parentRelationship", .text)
            }
        }
        // Review ceilings and capture references only. No legacy row is
        // assigned, exported, indexed, or granted execution capabilities.
        m.registerMigration("v20-workspace-policy-capture-targets") { db in
            try db.create(table: "workspacePolicyState") { t in
                t.primaryKey("projectID", .text).references("workspaceProject", onDelete: .cascade)
                t.column("revision", .integer).notNull().defaults(to: 0).check { $0 >= 0 }
            }
            try db.execute(sql: "INSERT INTO workspacePolicyState(projectID, revision) SELECT id, 0 FROM workspaceProject")
            try db.create(table: "workspacePolicy") { t in
                t.primaryKey("projectID", .text).references("workspaceProject", onDelete: .cascade)
                t.column("revision", .integer).notNull().check { $0 > 0 }
                t.column("contextRevision", .integer).notNull().check { $0 >= 0 }
                t.column("reviewedAt", .datetime).notNull()
                t.column("allowedProvidersJSON", .text).notNull()
                t.column("foldersJSON", .text).notNull()
                t.column("instructions", .text).notNull()
            }
            try db.execute(sql: """
                CREATE TRIGGER workspacePolicyProjectInsert AFTER INSERT ON workspaceProject
                BEGIN INSERT INTO workspacePolicyState(projectID, revision) VALUES(NEW.id, 0); END;
                CREATE TRIGGER workspacePolicyInstructionsUpdate AFTER UPDATE OF instructions ON workspaceProject
                WHEN OLD.instructions IS NOT NEW.instructions
                BEGIN UPDATE workspacePolicyState SET revision = revision + 1 WHERE projectID = NEW.id; END;
                CREATE TRIGGER workspacePolicyFolderInsert AFTER INSERT ON workspaceFolder
                BEGIN UPDATE workspacePolicyState SET revision = revision + 1 WHERE projectID = NEW.projectID; END;
                CREATE TRIGGER workspacePolicyFolderDelete AFTER DELETE ON workspaceFolder
                BEGIN UPDATE workspacePolicyState SET revision = revision + 1 WHERE projectID = OLD.projectID; END;
                CREATE TRIGGER workspacePolicyFolderUpdate AFTER UPDATE OF id, projectID, path, access ON workspaceFolder
                WHEN OLD.id IS NOT NEW.id OR OLD.projectID IS NOT NEW.projectID OR OLD.path IS NOT NEW.path OR OLD.access IS NOT NEW.access
                BEGIN UPDATE workspacePolicyState SET revision = revision + 1 WHERE projectID IN (OLD.projectID, NEW.projectID); END;
                """)
            // Composite FK prevents a capture's project and chat disagreeing,
            // including direct writes. Existing chat identities remain stable.
            try db.create(index: "workspaceChatIdentityProject", on: "workspaceChat", columns: ["id", "projectID"], unique: true)
            try db.create(table: "workspaceCaptureTarget") { t in
                t.primaryKey("recordID", .text).references("captureRecord", onDelete: .cascade)
                t.column("projectID", .text).notNull().indexed().references("workspaceProject", onDelete: .restrict)
                t.column("chatID", .text).notNull().indexed()
                t.column("linkedAt", .datetime).notNull()
                t.foreignKey(["chatID", "projectID"], references: "workspaceChat", columns: ["id", "projectID"], onDelete: .restrict)
            }
            try db.execute(sql: """
                CREATE TRIGGER workspaceCaptureTargetImmutable BEFORE UPDATE ON workspaceCaptureTarget
                WHEN OLD.recordID IS NOT NEW.recordID OR OLD.chatID IS NOT NEW.chatID OR OLD.projectID IS NOT NEW.projectID
                BEGIN SELECT RAISE(ABORT, 'Workspace capture target is immutable'); END;
                """)
        }
        // Owned provider sessions are separate from local conversations and
        // imported evidence. No existing identity becomes controllable.
        m.registerMigration("v21-workspace-frontier-sessions") { db in
            try db.create(table: "workspaceFrontierContextState") { t in
                t.primaryKey("chatID", .text).references("workspaceChat", onDelete: .cascade)
                t.column("revision", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "INSERT INTO workspaceFrontierContextState(chatID, revision) SELECT id, 0 FROM workspaceChat")
            try db.execute(sql: """
                CREATE TRIGGER workspaceFrontierChatInsert AFTER INSERT ON workspaceChat
                BEGIN INSERT INTO workspaceFrontierContextState(chatID, revision) VALUES(NEW.id, 0); END;
                CREATE TRIGGER workspaceFrontierChatContextUpdate AFTER UPDATE OF title, purpose, archivedAt ON workspaceChat
                WHEN OLD.title IS NOT NEW.title OR OLD.purpose IS NOT NEW.purpose OR OLD.archivedAt IS NOT NEW.archivedAt
                BEGIN UPDATE workspaceFrontierContextState SET revision = revision + 1 WHERE chatID = NEW.id; END;
                CREATE TRIGGER workspaceFrontierProjectContextUpdate AFTER UPDATE OF title, isVisible, allowsCloud ON workspaceProject
                WHEN OLD.title IS NOT NEW.title OR OLD.isVisible IS NOT NEW.isVisible OR OLD.allowsCloud IS NOT NEW.allowsCloud
                BEGIN UPDATE workspaceFrontierContextState SET revision = revision + 1 WHERE chatID IN (SELECT id FROM workspaceChat WHERE projectID = NEW.id); END;
                """)
            try db.create(table: "workspaceFrontierSession") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().references("workspaceProject", onDelete: .restrict)
                t.column("chatID", .text).notNull().indexed()
                t.foreignKey(["chatID", "projectID"], references: "workspaceChat", columns: ["id", "projectID"], onDelete: .restrict)
                t.column("provider", .text).notNull().check { $0 == "codex" }
                t.column("externalID", .text).unique()
                t.column("reviewedContext", .text).notNull()
                t.column("policyRevision", .integer).notNull()
                t.column("contextRevision", .integer).notNull()
                t.column("chatContextRevision", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("effort", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "workspaceFrontierTurn") { t in
                t.primaryKey("id", .text)
                t.column("sessionID", .text).notNull().indexed().references("workspaceFrontierSession", onDelete: .restrict)
                t.column("state", .text).notNull().check { ["prepared", "running", "cancellationRequested", "completed", "failed", "cancelled", "outcomeUnknown", "interrupted"].contains($0) }
                t.column("promptText", .text).notNull()
                t.column("outputText", .text).notNull()
                t.column("providerTurnID", .text)
                t.column("inputTokens", .integer).check { $0 >= 0 }
                t.column("outputTokens", .integer).check { $0 >= 0 }
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX workspaceFrontierUnresolvedTurn ON workspaceFrontierTurn(sessionID)
                WHERE state NOT IN ('completed', 'failed', 'cancelled');
                CREATE TRIGGER workspaceFrontierSessionImmutable BEFORE UPDATE ON workspaceFrontierSession
                WHEN OLD.id IS NOT NEW.id OR OLD.projectID IS NOT NEW.projectID OR OLD.chatID IS NOT NEW.chatID
                  OR OLD.provider IS NOT NEW.provider OR (OLD.externalID IS NOT NULL AND OLD.externalID IS NOT NEW.externalID)
                  OR OLD.reviewedContext IS NOT NEW.reviewedContext OR OLD.policyRevision IS NOT NEW.policyRevision
                  OR OLD.contextRevision IS NOT NEW.contextRevision OR OLD.chatContextRevision IS NOT NEW.chatContextRevision
                  OR OLD.model IS NOT NEW.model OR OLD.effort IS NOT NEW.effort OR OLD.createdAt IS NOT NEW.createdAt
                BEGIN SELECT RAISE(ABORT, 'Owned frontier session identity and review are immutable'); END;
                CREATE TRIGGER workspaceFrontierImportedIdentity BEFORE UPDATE OF externalID ON workspaceFrontierSession
                WHEN NEW.externalID IS NOT NULL AND EXISTS (SELECT 1 FROM workspaceSessionLink
                    WHERE provider = 'codex' AND externalID = NEW.externalID)
                BEGIN SELECT RAISE(ABORT, 'Imported sessions cannot become owned sessions'); END;
                CREATE TRIGGER workspaceFrontierTurnImmutable BEFORE UPDATE ON workspaceFrontierTurn
                WHEN OLD.id IS NOT NEW.id OR OLD.sessionID IS NOT NEW.sessionID OR OLD.promptText IS NOT NEW.promptText
                  OR OLD.startedAt IS NOT NEW.startedAt OR (OLD.providerTurnID IS NOT NULL AND OLD.providerTurnID IS NOT NEW.providerTurnID)
                BEGIN SELECT RAISE(ABORT, 'Frontier turn identity and input are immutable'); END;
                """)
        }
        // Native relationships are intentionally separate from imported history,
        // isolated owned sessions and their folder/tool grants. No backfill.
        m.registerMigration("v22-workspace-codex-links") { db in
            try db.execute(sql: """
                CREATE TABLE workspaceCodexProjectLink (
                    id TEXT PRIMARY KEY NOT NULL,
                    projectID TEXT NOT NULL UNIQUE REFERENCES workspaceProject(id) ON DELETE RESTRICT,
                    hostID TEXT NOT NULL, profileNamespace TEXT NOT NULL, externalID TEXT NOT NULL,
                    approvedSnapshotJSON TEXT NOT NULL, observedSnapshotJSON TEXT NOT NULL,
                    approvedRootsJSON TEXT NOT NULL, observedRootsJSON TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('linked','conflict','reviewRequired')),
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL,
                    UNIQUE(hostID, profileNamespace, externalID), UNIQUE(id, projectID, hostID, profileNamespace)
                );
                CREATE TABLE workspaceCodexChatLink (
                    id TEXT PRIMARY KEY NOT NULL,
                    projectLinkID TEXT NOT NULL,
                    projectID TEXT NOT NULL,
                    chatID TEXT NOT NULL UNIQUE,
                    hostID TEXT NOT NULL, profileNamespace TEXT NOT NULL, externalID TEXT NOT NULL,
                    workingDirectory TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    createdAt DATETIME NOT NULL,
                    FOREIGN KEY(projectLinkID, projectID, hostID, profileNamespace)
                        REFERENCES workspaceCodexProjectLink(id, projectID, hostID, profileNamespace) ON DELETE CASCADE,
                    FOREIGN KEY(chatID, projectID) REFERENCES workspaceChat(id, projectID) ON DELETE RESTRICT,
                    UNIQUE(hostID, profileNamespace, externalID)
                );
                CREATE TABLE workspaceCodexNativeAuthorization (
                    chatLinkID TEXT PRIMARY KEY NOT NULL REFERENCES workspaceCodexChatLink(id) ON DELETE CASCADE,
                    projectRevision INTEGER NOT NULL, chatRevision INTEGER NOT NULL,
                    mode TEXT NOT NULL CHECK(mode = 'nativeCodex'),
                    effectiveConfigurationFingerprint TEXT NOT NULL,
                    reviewedPolicySummary TEXT NOT NULL,
                    approvedAt DATETIME NOT NULL
                );
                CREATE TRIGGER workspaceCodexProjectIdentityImmutable BEFORE UPDATE ON workspaceCodexProjectLink
                WHEN OLD.id IS NOT NEW.id OR OLD.projectID IS NOT NEW.projectID OR OLD.hostID IS NOT NEW.hostID
                  OR OLD.profileNamespace IS NOT NEW.profileNamespace OR OLD.externalID IS NOT NEW.externalID
                  OR OLD.createdAt IS NOT NEW.createdAt
                BEGIN SELECT RAISE(ABORT, 'Native project relationship identity is immutable'); END;
                CREATE TRIGGER workspaceCodexChatIdentityImmutable BEFORE UPDATE ON workspaceCodexChatLink
                BEGIN SELECT RAISE(ABORT, 'Native chat relationship is immutable; unlink and review again'); END;
                CREATE TRIGGER workspaceCodexProjectHidden AFTER UPDATE OF isVisible ON workspaceProject
                WHEN OLD.isVisible IS NOT NEW.isVisible
                BEGIN DELETE FROM workspaceCodexNativeAuthorization WHERE chatLinkID IN
                    (SELECT id FROM workspaceCodexChatLink WHERE projectID = NEW.id); END;
                CREATE TRIGGER workspaceCodexChatArchived AFTER UPDATE OF archivedAt ON workspaceChat
                WHEN OLD.archivedAt IS NOT NEW.archivedAt
                BEGIN DELETE FROM workspaceCodexNativeAuthorization WHERE chatLinkID IN
                    (SELECT id FROM workspaceCodexChatLink WHERE chatID = NEW.id); END;
                """)
        }
        // The canonical native cache is not an import or an owned session. An
        // observation refresh replaces only this projection, never local turns.
        m.registerMigration("v23-workspace-codex-native") { db in
            try db.execute(sql: """
                CREATE TABLE workspaceCodexNativeProjection (
                    chatLinkID TEXT PRIMARY KEY NOT NULL REFERENCES workspaceCodexChatLink(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    snapshotJSON TEXT NOT NULL, observedAt DATETIME NOT NULL
                );
                CREATE TABLE workspaceCodexNativeObservation (
                    id TEXT PRIMARY KEY NOT NULL, chatLinkID TEXT NOT NULL,
                    hostID TEXT NOT NULL, profileNamespace TEXT NOT NULL, nativeThreadID TEXT NOT NULL,
                    projectionRevision INTEGER NOT NULL, snapshotJSON TEXT NOT NULL, observedAt DATETIME NOT NULL,
                    UNIQUE(chatLinkID, projectionRevision)
                );
                CREATE INDEX workspaceCodexNativeObservationLink ON workspaceCodexNativeObservation(chatLinkID, projectionRevision);
                CREATE TABLE workspaceCodexNativeItem (
                    chatLinkID TEXT NOT NULL REFERENCES workspaceCodexNativeProjection(chatLinkID) ON DELETE CASCADE,
                    nativeTurnID TEXT NOT NULL, nativeItemID TEXT NOT NULL,
                    turnOrder INTEGER NOT NULL CHECK(turnOrder >= 0), itemOrder INTEGER NOT NULL CHECK(itemOrder >= 0),
                    kind TEXT NOT NULL, role TEXT CHECK(role IN ('user','assistant')),
                    text TEXT NOT NULL, turnState TEXT NOT NULL, itemState TEXT NOT NULL,
                    rawJSON TEXT NOT NULL, timestamp DATETIME NOT NULL, firstObservedAt DATETIME NOT NULL,
                    PRIMARY KEY(chatLinkID, nativeTurnID, nativeItemID)
                );
                CREATE INDEX workspaceCodexNativeItemOrder ON workspaceCodexNativeItem(chatLinkID, turnOrder, itemOrder);
                CREATE TABLE workspaceCodexNativeOperation (
                    id TEXT PRIMARY KEY NOT NULL, chatLinkID TEXT NOT NULL,
                    projectID TEXT NOT NULL, chatID TEXT NOT NULL,
                    hostID TEXT NOT NULL, profileNamespace TEXT NOT NULL, nativeThreadID TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('send','rename','archive','restore','move')),
                    state TEXT NOT NULL CHECK(state IN ('requested','prepared','deliveryUnknown','acknowledged','completed','failed','interrupted','cancelled')),
                    projectRevision INTEGER NOT NULL, chatRevision INTEGER NOT NULL,
                    projectionRevision INTEGER NOT NULL,
                    effectiveConfigurationFingerprint TEXT, userMessage TEXT, requestedValue TEXT,
                    nativeTurnID TEXT, cancellationRequestedAt DATETIME, failureCode TEXT,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, endedAt DATETIME
                );
                CREATE UNIQUE INDEX workspaceCodexNativeUnresolvedOperation ON workspaceCodexNativeOperation(chatLinkID)
                    WHERE state NOT IN ('completed','failed','interrupted','cancelled');
                CREATE UNIQUE INDEX workspaceCodexNativeUnresolvedIdentity ON workspaceCodexNativeOperation(hostID, profileNamespace, nativeThreadID)
                    WHERE state NOT IN ('completed','failed','interrupted','cancelled');
                CREATE TABLE workspaceCodexNativeOperationEvent (
                    operationID TEXT NOT NULL REFERENCES workspaceCodexNativeOperation(id) ON DELETE RESTRICT,
                    revision INTEGER NOT NULL, state TEXT NOT NULL, timestamp DATETIME NOT NULL,
                    PRIMARY KEY(operationID, revision)
                );
                CREATE TRIGGER workspaceCodexNativeOperationImmutable BEFORE UPDATE ON workspaceCodexNativeOperation
                WHEN OLD.id IS NOT NEW.id OR OLD.chatLinkID IS NOT NEW.chatLinkID
                  OR OLD.projectID IS NOT NEW.projectID OR OLD.chatID IS NOT NEW.chatID
                  OR OLD.hostID IS NOT NEW.hostID OR OLD.profileNamespace IS NOT NEW.profileNamespace
                  OR OLD.nativeThreadID IS NOT NEW.nativeThreadID OR OLD.kind IS NOT NEW.kind
                  OR OLD.projectRevision IS NOT NEW.projectRevision OR OLD.chatRevision IS NOT NEW.chatRevision
                  OR OLD.projectionRevision IS NOT NEW.projectionRevision
                  OR OLD.effectiveConfigurationFingerprint IS NOT NEW.effectiveConfigurationFingerprint
                  OR OLD.userMessage IS NOT NEW.userMessage OR OLD.requestedValue IS NOT NEW.requestedValue
                  OR OLD.createdAt IS NOT NEW.createdAt
                  OR (OLD.nativeTurnID IS NOT NULL AND OLD.nativeTurnID IS NOT NEW.nativeTurnID)
                  OR (OLD.cancellationRequestedAt IS NOT NULL AND OLD.cancellationRequestedAt IS NOT NEW.cancellationRequestedAt)
                BEGIN SELECT RAISE(ABORT, 'Native operation identity and delivery evidence are immutable'); END;
                """)
        }
        m.registerMigration("v24-frontier-turn-failure-reason") { db in
            // Why a turn failed, so a stopped or undelivered message can be
            // explained later. Additive; earlier turns keep a null reason.
            try db.alter(table: "workspaceFrontierTurn") { t in t.add(column: "failureReason", .text) }
        }
        m.registerMigration("v25-workspace-handover") { db in
            // D30: the exact chat history that travelled with an acknowledged
            // turn, and the watermark of what each provider thread has seen.
            try db.create(table: "workspaceHandover") { t in
                t.primaryKey("id", .text)
                t.column("chatID", .text).notNull().indexed().references("workspaceChat", onDelete: .restrict)
                t.column("threadKey", .text).notNull()
                t.column("turnID", .text).notNull()
                t.column("entryCount", .integer).notNull().check { $0 > 0 }
                t.column("omittedCount", .integer).notNull().check { $0 >= 0 }
                t.column("providers", .text).notNull()
                t.column("text", .text).notNull()
                t.column("throughTimestamp", .datetime).notNull()
                t.column("throughEntryID", .text).notNull()
                t.column("anchorTimestamp", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["threadKey", "turnID"])
            }
            try db.create(index: "workspaceHandoverThread", on: "workspaceHandover", columns: ["threadKey", "throughTimestamp"])
        }
        // Additive Claude Code persistence. Existing Codex/native/local history
        // and handover evidence remain untouched; no imported ID is adopted.
        m.registerMigration("v26-workspace-claude-sessions") { db in
            try db.create(table: "workspaceClaudeSession") { t in
                t.primaryKey("id", .text)
                t.column("projectID", .text).notNull().references("workspaceProject", onDelete: .restrict)
                t.column("chatID", .text).notNull().indexed()
                t.foreignKey(["chatID", "projectID"], references: "workspaceChat", columns: ["id", "projectID"], onDelete: .restrict)
                t.column("profileNamespace", .text).notNull()
                t.column("externalID", .text)
                t.column("reviewedContext", .text).notNull()
                t.column("policyRevision", .integer).notNull()
                t.column("contextRevision", .integer).notNull()
                t.column("chatContextRevision", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("effort", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["profileNamespace", "externalID"])
            }
            try db.create(table: "workspaceClaudeTurn") { t in
                t.primaryKey("id", .text)
                t.column("sessionID", .text).notNull().indexed().references("workspaceClaudeSession", onDelete: .restrict)
                t.column("state", .text).notNull().check { ["prepared", "running", "cancellationRequested", "completed", "failed", "cancelled", "outcomeUnknown", "interrupted"].contains($0) }
                t.column("promptText", .text).notNull()
                t.column("outputText", .text).notNull()
                t.column("providerTurnID", .text)
                t.column("inputTokens", .integer).check { $0 >= 0 }
                t.column("outputTokens", .integer).check { $0 >= 0 }
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("failureReason", .text)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX workspaceClaudeUnresolvedTurn ON workspaceClaudeTurn(sessionID)
                WHERE state NOT IN ('completed', 'failed', 'cancelled');
                CREATE TRIGGER workspaceClaudeSessionImmutable BEFORE UPDATE ON workspaceClaudeSession
                WHEN OLD.id IS NOT NEW.id OR OLD.projectID IS NOT NEW.projectID OR OLD.chatID IS NOT NEW.chatID
                  OR OLD.profileNamespace IS NOT NEW.profileNamespace OR (OLD.externalID IS NOT NULL AND OLD.externalID IS NOT NEW.externalID)
                  OR OLD.reviewedContext IS NOT NEW.reviewedContext OR OLD.policyRevision IS NOT NEW.policyRevision
                  OR OLD.contextRevision IS NOT NEW.contextRevision OR OLD.chatContextRevision IS NOT NEW.chatContextRevision
                  OR OLD.model IS NOT NEW.model OR OLD.effort IS NOT NEW.effort OR OLD.createdAt IS NOT NEW.createdAt
                BEGIN SELECT RAISE(ABORT, 'Owned Claude session identity and review are immutable'); END;
                CREATE TRIGGER workspaceClaudeImportedIdentity BEFORE UPDATE OF externalID ON workspaceClaudeSession
                WHEN NEW.externalID IS NOT NULL AND EXISTS (SELECT 1 FROM workspaceSessionLink
                    WHERE provider = 'claude' AND externalID = NEW.externalID)
                BEGIN SELECT RAISE(ABORT, 'Imported sessions cannot become owned sessions'); END;
                CREATE TRIGGER workspaceClaudeTurnImmutable BEFORE UPDATE ON workspaceClaudeTurn
                WHEN OLD.id IS NOT NEW.id OR OLD.sessionID IS NOT NEW.sessionID OR OLD.promptText IS NOT NEW.promptText
                  OR OLD.startedAt IS NOT NEW.startedAt OR (OLD.providerTurnID IS NOT NULL AND OLD.providerTurnID IS NOT NEW.providerTurnID)
                BEGIN SELECT RAISE(ABORT, 'Claude turn identity and input are immutable'); END;
                """)
        }
        m.registerMigration("v27-workspace-claude-owned-history") { db in
            try db.create(table: "workspaceClaudeMessageIdentity") { t in
                t.column("sessionID", .text).notNull().references("workspaceClaudeSession", onDelete: .restrict)
                t.column("externalID", .text).notNull()
                t.column("turnID", .text).notNull().indexed().references("workspaceClaudeTurn", onDelete: .restrict)
                t.column("role", .text).notNull().check { ["user", "assistant"].contains($0) }
                t.primaryKey(["sessionID", "externalID"])
            }
            try db.create(table: "workspaceClaudeHistoryObservation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionID", .text).notNull().indexed().references("workspaceClaudeSession", onDelete: .restrict)
                t.column("observedAt", .datetime).notNull()
                t.column("snapshotJSON", .text).notNull()
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX workspaceClaudeUserIdentity ON workspaceClaudeMessageIdentity(turnID) WHERE role = 'user';
                CREATE TRIGGER workspaceClaudeMessageIdentityImmutable BEFORE UPDATE ON workspaceClaudeMessageIdentity
                BEGIN SELECT RAISE(ABORT, 'Claude message attribution is immutable'); END;
                CREATE TRIGGER workspaceClaudeMessageIdentitySession BEFORE INSERT ON workspaceClaudeMessageIdentity
                WHEN NOT EXISTS (SELECT 1 FROM workspaceClaudeTurn WHERE id = NEW.turnID AND sessionID = NEW.sessionID)
                BEGIN SELECT RAISE(ABORT, 'Claude message attribution must belong to the turn session'); END;
                CREATE TRIGGER workspaceClaudeHistoryObservationImmutable BEFORE UPDATE ON workspaceClaudeHistoryObservation
                BEGIN SELECT RAISE(ABORT, 'Claude history observations are immutable'); END;
                """)
        }
        m.registerMigration("v28-agent-chat-journal") { db in
            try db.create(table: "agentChatSession") { t in
                t.primaryKey("id", .text)
                t.column("chatID", .text).notNull().references("workspaceChat", onDelete: .restrict)
                t.column("provider", .text).notNull()
                t.column("host", .text)
                t.column("profile", .text)
                t.column("nativeID", .text)
                t.column("cwd", .text).notNull()
                t.column("model", .text).notNull()
                t.column("effort", .text)
                t.column("mode", .text).notNull()
                t.uniqueKey(["chatID", "provider"])
                t.uniqueKey(["provider", "host", "profile", "nativeID"])
                t.uniqueKey(["id", "chatID", "provider"])
                t.check(sql: "(host IS NULL AND profile IS NULL AND nativeID IS NULL) OR (host IS NOT NULL AND profile IS NOT NULL AND nativeID IS NOT NULL)")
            }
            try db.create(table: "agentTranscriptEntry") { t in
                t.primaryKey("id", .text)
                t.column("chatID", .text).notNull().references("workspaceChat", onDelete: .restrict)
                t.column("provider", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("text", .text).notNull()
                t.column("payloadJSON", .text)
                t.column("sessionID", .text)
                t.column("nativeMessageID", .text)
                t.column("position", .integer).notNull().check { $0 >= 0 }
                t.uniqueKey(["chatID", "position"])
                t.uniqueKey(["sessionID", "nativeMessageID"])
                t.foreignKey(["sessionID", "chatID", "provider"], references: "agentChatSession", columns: ["id", "chatID", "provider"], onDelete: .restrict)
                t.check(sql: "nativeMessageID IS NULL OR sessionID IS NOT NULL")
            }
            try db.create(table: "agentTurn") { t in
                t.primaryKey("id", .text)
                t.column("chatID", .text).notNull().references("workspaceChat", onDelete: .restrict)
                t.column("sessionID", .text).notNull().references("agentChatSession", onDelete: .restrict)
                t.column("prompt", .text).notNull()
                t.column("delivery", .text).notNull().check { ["prepared", "deliveryUnknown", "acknowledged"].contains($0) }
                t.column("state", .text).notNull().check { ["running", "completed", "interrupted", "failed"].contains($0) }
                t.column("resendCount", .integer).notNull().check { (0...1).contains($0) }
                t.column("partialOutput", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX agentRunningTurn ON agentTurn(chatID) WHERE state = 'running';
                CREATE TRIGGER agentTurnChat BEFORE INSERT ON agentTurn
                WHEN NOT EXISTS (SELECT 1 FROM agentChatSession WHERE id = NEW.sessionID AND chatID = NEW.chatID)
                BEGIN SELECT RAISE(ABORT, 'Turn must belong to its chat session'); END;
                """)
        }
        return m
    }
}
