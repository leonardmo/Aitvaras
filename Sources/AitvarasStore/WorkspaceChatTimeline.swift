import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents
import CryptoKit

/// Read-only chat history. Native imports are deliberately not part of this projection.
public struct WorkspaceChatTimelineEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: String
    public let text: String
    public let timestamp: Date
    public let provider: String
    public let sourceTurnID: UUID?
    public let state: WorkspaceFrontierTurnState?
    /// True only for a failed turn that never reached the provider: nothing
    /// was sent, so it is safe to send the same message again.
    public let notDelivered: Bool
    public let failureReason: String?
    /// The thread that produced this entry (`WorkspaceThreadKey`), so a
    /// handover can tell what a given thread has not seen yet.
    public let sourceThread: String?
    /// SDK history has no message creation time. For observed external rows,
    /// timestamp is this observation time, not a claimed creation time.
    public let observedAt: Date?

    public init(id: String, role: String, text: String, timestamp: Date, provider: String,
                sourceTurnID: UUID? = nil, state: WorkspaceFrontierTurnState? = nil,
                notDelivered: Bool = false, failureReason: String? = nil, sourceThread: String? = nil,
                observedAt: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.provider = provider
        self.sourceTurnID = sourceTurnID
        self.state = state
        self.notDelivered = notDelivered
        self.failureReason = failureReason
        self.sourceThread = sourceThread
        self.observedAt = observedAt
    }
}

extension Stores {
    public func workspaceChatTimeline(chatID: UUID, limit: Int = 200) throws -> [WorkspaceChatTimelineEntry] {
        guard limit > 0 else { return [] }
        let local = try db.queue.read { try Self.chatTimeline(chatID: chatID, limit: limit, completedOnly: false, in: $0) }
        let native = try workspaceCodexNativeTimeline(chatID: chatID)
        let claudeObserved = try db.queue.read { try Self.claudeObservedTimeline(chatID: chatID, in: $0) }
        // A delivered handover sits just before the message it travelled with.
        let handovers = try workspaceHandovers(chatID: chatID).map { handover in
            WorkspaceChatTimelineEntry(id: "handover:\(handover.id.uuidString)", role: "handover", text: handover.text,
                timestamp: handover.anchorTimestamp, provider: WorkspaceThreadKey.provider(handover.threadKey),
                sourceThread: handover.threadKey)
        }
        guard !native.isEmpty || !handovers.isEmpty || !claudeObserved.isEmpty else { return local }
        let ordered = (local + native + handovers + claudeObserved).enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        return Array(ordered.suffix(limit))
    }

    /// Native chronology comes from canonical turn/item order, never lexical IDs.
    /// Keep native imports excluded; only explicitly linked current projections join.
    public func workspaceCodexNativeTimeline(chatID: UUID) throws -> [WorkspaceChatTimelineEntry] {
        try db.queue.read { try Self.nativeChatTimeline(chatID: chatID, in: $0) }
    }

    private static func nativeChatTimeline(chatID: UUID, in db: Database) throws -> [WorkspaceChatTimelineEntry] {
        // Native turn identity, not text markers, attributes an envelope to a
        // send we actually acknowledged. Missing evidence leaves the wire intact.
        let evidence = try Row.fetchAll(db, sql: """
            SELECT o.chatLinkID, o.nativeTurnID, o.userMessage, h.text
            FROM workspaceHandover h JOIN workspaceCodexNativeOperation o ON o.id = h.turnID
            WHERE h.chatID = ? AND o.chatID = ? AND o.kind = 'send' AND o.nativeTurnID IS NOT NULL
            """, arguments: [chatID, chatID])
        var envelopes: [String: (block: String, message: String)] = [:]
        for row in evidence {
            let link: UUID = row["chatLinkID"], turn: String = row["nativeTurnID"]
            if let message: String = row["userMessage"] {
                envelopes["\(link):\(turn)"] = (row["text"], message)
            }
        }
        let items = try WorkspaceCodexNativeItem.fetchAll(db, sql: """
            SELECT i.* FROM workspaceCodexNativeItem i JOIN workspaceCodexChatLink c ON c.id = i.chatLinkID
            WHERE c.chatID = ? ORDER BY i.turnOrder, i.itemOrder, i.nativeTurnID, i.nativeItemID
            """, arguments: [chatID])
        var timestamp = Date.distantPast
        return items.compactMap { item in
            guard let role = item.role, ["user", "assistant"].contains(role), !item.text.isEmpty else { return nil }
            timestamp = max(item.timestamp, timestamp.addingTimeInterval(0.000_001))
            let state: WorkspaceFrontierTurnState
            switch item.turnState {
            case .completed: state = .completed
            case .inProgress: state = .running
            case .interrupted: state = .interrupted
            case .failed: state = .failed
            case .unknown: state = .outcomeUnknown
            }
            // A handover block travels inside the native user message; show
            // and hand on only what the user typed.
            let envelope = envelopes["\(item.chatLinkID):\(item.nativeTurnID)"]
            let text = role == "user" ? WorkspaceHandoverText.stripped(item.text,
                recordedHandover: envelope?.block, originalMessage: envelope?.message) : item.text
            return .init(id: item.id, role: role, text: text, timestamp: timestamp,
                provider: "codex", state: state, sourceThread: WorkspaceThreadKey.codexNative(item.chatLinkID))
        }
    }

    /// Visit completed context messages newest-first in the same order as the
    /// transcript, without a UI limit or loading all local message bodies. A
    /// single read snapshot keeps cursor traversal and native evidence coherent.
    func forEachWorkspaceHandoverMessage(chatID: UUID, watermark: (timestamp: Date, entryID: String)?,
                                         visit: (WorkspaceChatTimelineEntry) -> Void) throws {
        try db.queue.read { dbc in
            let cursor = try Self.chatTimelineCursor(chatID: chatID, limit: -1, completedOnly: true, in: dbc)
            var local = try cursor.next().map(Self.chatTimelineEntry)
            let native = try Self.nativeChatTimeline(chatID: chatID, in: dbc)
            let watermarkPresent: Bool
            if let watermark {
                let nativePresent = native.contains { $0.id == watermark.entryID }
                watermarkPresent = try nativePresent || Self.completedChatTimelineContains(watermark.entryID, chatID: chatID, in: dbc)
            } else { watermarkPresent = false }
            var iterator = native.reversed().makeIterator()
            var remote = iterator.next()
            while local != nil || remote != nil {
                let entry: WorkspaceChatTimelineEntry
                // Native follows local on equal timestamps in the ascending
                // transcript, so it precedes local in this reverse traversal.
                if let candidate = remote, local == nil || candidate.timestamp >= local!.timestamp {
                    entry = candidate; remote = iterator.next()
                } else {
                    entry = local!; local = try cursor.next().map(Self.chatTimelineEntry)
                }
                if let watermark {
                    // Native timestamps can be corrected on refresh. Identity
                    // takes precedence; time is only a missing-entry fallback.
                    if entry.id == watermark.entryID || (!watermarkPresent && entry.timestamp < watermark.timestamp) { break }
                }
                guard entry.state == nil || entry.state == .completed, !entry.notDelivered else { continue }
                visit(entry)
            }
        }
    }

    private static func completedChatTimelineContains(_ id: String, chatID: UUID, in db: Database) throws -> Bool {
        let parts = id.split(separator: ":")
        guard parts.count >= 2, let sourceID = UUID(uuidString: String(parts[1])) else { return false }
        if parts[0] == "local", parts.count == 2 {
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM storedMessage m JOIN workspaceChat c ON c.localConversationID = m.conversationID
                WHERE c.id = ? AND m.id = ? AND m.role IN ('user', 'assistant')
                AND length(trim(m.content, char(9) || char(10) || char(13) || ' ')) > 0)
                """, arguments: [chatID, sourceID]) ?? false
        }
        guard ["codex", "claude"].contains(parts[0]), parts.count == 3, ["user", "assistant"].contains(parts[2]) else { return false }
        if parts[0] == "claude", parts[2] == "assistant" {
            return try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceClaudeTurn t JOIN workspaceClaudeSession s ON s.id = t.sessionID
                WHERE s.chatID = ? AND t.id = ? AND t.state = 'completed' AND (
                    length(trim(t.outputText, char(9) || char(10) || char(13) || ' ')) > 0 OR (
                        (SELECT count(*) FROM workspaceClaudeMessageIdentity i WHERE i.turnID = t.id AND i.role = 'assistant') > 0
                        AND (SELECT count(*) FROM workspaceClaudeMessageIdentity i WHERE i.turnID = t.id AND i.role = 'assistant') =
                        (SELECT count(*) FROM workspaceClaudeMessageIdentity i
                            JOIN workspaceClaudeHistoryObservation o ON o.sessionID = i.sessionID,
                            json_each(o.snapshotJSON, '$.messages') j
                         WHERE i.turnID = t.id AND i.role = 'assistant'
                           AND json_extract(j.value, '$.id') = i.externalID AND json_extract(j.value, '$.role') = 'assistant'
                           AND o.id = (SELECT max(latest.id) FROM workspaceClaudeHistoryObservation latest WHERE latest.sessionID = i.sessionID))
                    )))
                """, arguments: [chatID, sourceID]) ?? false
        }
        // The table names come only from these fixed provider cases, never an ID.
        let turnTable = parts[0] == "claude" ? "workspaceClaudeTurn" : "workspaceFrontierTurn"
        let sessionTable = parts[0] == "claude" ? "workspaceClaudeSession" : "workspaceFrontierSession"
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM \(turnTable) t JOIN \(sessionTable) s ON s.id = t.sessionID
            WHERE s.chatID = ? AND t.id = ? AND t.state = 'completed'
            AND length(trim(CASE ? WHEN 'user' THEN t.promptText ELSE t.outputText END,
                char(9) || char(10) || char(13) || ' ')) > 0)
            """, arguments: [chatID, sourceID, String(parts[2])]) ?? false
    }

    /// Only completed owned turns are eligible for model context. Partial or
    /// uncertain work remains visible in the timeline, never implied completed.
    /// How much of a chat's completed history a cloud backend receives per
    /// message. The consent text quotes this same value.
    public static let workspaceSharedHistoryCharacters = 16_000

    public func workspaceChatHistoryText(chatID: UUID,
                                         maximumCharacters: Int = Stores.workspaceSharedHistoryCharacters) throws -> String {
        guard maximumCharacters > 0 else { return "" }
        let entries = try db.queue.read {
            try Self.chatTimeline(chatID: chatID, limit: maximumCharacters, completedOnly: true, in: $0)
        }
        var blocks: [String] = []
        var remaining = maximumCharacters
        for entry in entries.reversed() {
            let label = "[\(entry.role) / \(entry.provider)]\n"
            let separator = blocks.isEmpty ? 0 : 2
            let available = remaining - separator - label.count
            guard available > 0 else { break }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = text.count > available
                ? String(text.prefix(max(0, available - 1))) + "…" : text
            let block = label + clipped
            blocks.append(block)
            remaining -= separator + block.count
            if clipped != text { break }
        }
        return blocks.reversed().joined(separator: "\n\n")
    }

    private static func chatTimeline(chatID: UUID, limit: Int, completedOnly: Bool,
                                     in db: Database) throws -> [WorkspaceChatTimelineEntry] {
        let cursor = try chatTimelineCursor(chatID: chatID, limit: limit, completedOnly: completedOnly, in: db)
        var entries: [WorkspaceChatTimelineEntry] = []
        while let row = try cursor.next() { entries.append(chatTimelineEntry(row)) }
        return entries.reversed()
    }

    private static func chatTimelineCursor(chatID: UUID, limit: Int, completedOnly: Bool,
                                           in db: Database) throws -> RowCursor {
        // Bound each source before merging. Frontier rows are expanded before
        // limiting so partial answers cannot displace newer user messages.
        return try Row.fetchCursor(db, sql: """
            WITH local AS (
                SELECT 'local:' || CASE m.role WHEN 'user' THEN '0-user' ELSE '1-assistant' END || ':' || hex(m.id) AS entryID,
                       m.role, m.content AS text, m.createdAt AS timestamp,
                       'local' AS provider, m.id AS sourceID, NULL AS sourceTurnID, NULL AS state,
                       0 AS notDelivered, NULL AS failureReason, NULL AS sourceSession
                FROM storedMessage m JOIN workspaceChat c ON c.localConversationID = m.conversationID
                WHERE c.id = ? AND m.role IN ('user', 'assistant') AND length(trim(m.content, char(9) || char(10) || char(13) || ' ')) > 0
                ORDER BY timestamp DESC, entryID DESC LIMIT ?
            ), owned AS (
                SELECT t.* FROM workspaceFrontierTurn t
                JOIN workspaceFrontierSession s ON s.id = t.sessionID
                WHERE s.chatID = ? AND s.provider = 'codex' AND (? = 0 OR t.state = 'completed')
                ORDER BY t.startedAt DESC, t.id DESC LIMIT ?
            ), frontier AS (
                SELECT * FROM (
                    SELECT 'codex:0-user:' || hex(id) AS entryID, 'user' AS role,
                           promptText AS text, startedAt AS timestamp, 'codex' AS provider,
                           id AS sourceID, id AS sourceTurnID, state,
                           (state = 'failed' AND providerTurnID IS NULL) AS notDelivered, failureReason,
                           sessionID AS sourceSession FROM owned
                    UNION ALL
                    SELECT 'codex:1-assistant:' || hex(id), 'assistant', outputText,
                           coalesce(endedAt, startedAt), 'codex', id, id, state,
                           (state = 'failed' AND providerTurnID IS NULL), failureReason, sessionID FROM owned
                ) WHERE length(trim(text, char(9) || char(10) || char(13) || ' ')) > 0
                ORDER BY timestamp DESC, entryID DESC LIMIT ?
            ), claudeHistory AS (
                SELECT o.sessionID, CAST(j.key AS INTEGER) AS position,
                    json_extract(j.value, '$.id') AS externalID,
                    json_extract(j.value, '$.role') AS role, json_extract(j.value, '$.text') AS text
                FROM workspaceClaudeHistoryObservation o
                JOIN workspaceClaudeSession s ON s.id = o.sessionID,
                    json_each(o.snapshotJSON, '$.messages') j
                WHERE s.chatID = ? AND o.id = (SELECT max(latest.id) FROM workspaceClaudeHistoryObservation latest WHERE latest.sessionID = o.sessionID)
            ), claudeCanonicalUser AS (
                SELECT i.turnID, CASE WHEN h.text IS NOT NULL AND c.text = h.text || char(10) || t.promptText
                    THEN t.promptText ELSE c.text END AS text
                FROM claudeHistory c JOIN workspaceClaudeMessageIdentity i
                    ON i.sessionID = c.sessionID AND i.externalID = c.externalID AND i.role = 'user'
                JOIN workspaceClaudeTurn t ON t.id = i.turnID
                LEFT JOIN workspaceHandover h ON h.turnID = t.id AND h.threadKey LIKE 'claude:session:%'
                WHERE c.role = 'user'
            ), claudeCanonicalAssistant AS (
                SELECT turnID, group_concat(text, char(10)) AS text, count(*) AS messageCount FROM (
                    SELECT i.turnID, c.text FROM claudeHistory c JOIN workspaceClaudeMessageIdentity i
                        ON i.sessionID = c.sessionID AND i.externalID = c.externalID AND i.role = 'assistant'
                    WHERE c.role = 'assistant' ORDER BY c.position
                ) GROUP BY turnID
            ), claudeOwned AS (
                SELECT t.*, coalesce(u.text, t.promptText) AS canonicalPrompt,
                    CASE WHEN t.state = 'completed' AND a.messageCount > 0 AND a.messageCount =
                        (SELECT count(*) FROM workspaceClaudeMessageIdentity i WHERE i.turnID = t.id AND i.role = 'assistant')
                        THEN a.text ELSE t.outputText END AS canonicalOutput
                FROM workspaceClaudeTurn t
                JOIN workspaceClaudeSession s ON s.id = t.sessionID
                LEFT JOIN claudeCanonicalUser u ON u.turnID = t.id
                LEFT JOIN claudeCanonicalAssistant a ON a.turnID = t.id
                WHERE s.chatID = ? AND (? = 0 OR t.state = 'completed')
                ORDER BY t.startedAt DESC, t.id DESC LIMIT ?
            ), claude AS (
                SELECT * FROM (
                    SELECT 'claude:0-user:' || hex(id) AS entryID, 'user' AS role,
                           canonicalPrompt AS text, startedAt AS timestamp, 'claude' AS provider,
                           id AS sourceID, id AS sourceTurnID, state,
                           (state = 'failed' AND providerTurnID IS NULL) AS notDelivered, failureReason,
                           sessionID AS sourceSession FROM claudeOwned
                    UNION ALL
                    SELECT 'claude:1-assistant:' || hex(id), 'assistant', canonicalOutput,
                           coalesce(endedAt, startedAt), 'claude', id, id, state,
                           (state = 'failed' AND providerTurnID IS NULL), failureReason, sessionID FROM claudeOwned
                ) WHERE length(trim(text, char(9) || char(10) || char(13) || ' ')) > 0
                ORDER BY timestamp DESC, entryID DESC LIMIT ?
            )
            SELECT * FROM (SELECT * FROM local UNION ALL SELECT * FROM frontier UNION ALL SELECT * FROM claude)
            ORDER BY timestamp DESC, entryID DESC LIMIT ?
            """, arguments: [chatID, limit, chatID, completedOnly ? 1 : 0, limit, limit,
                              chatID, chatID, completedOnly ? 1 : 0, limit, limit, limit])
    }

    private static func chatTimelineEntry(_ row: Row) -> WorkspaceChatTimelineEntry {
        let rawState: String? = row["state"]
        let sourceID: UUID = row["sourceID"]
        let provider: String = row["provider"]
        let role: String = row["role"]
        let id = provider == "local" ? "local:\(sourceID.uuidString)" : "\(provider):\(sourceID.uuidString):\(role)"
        let sourceThread = (row["sourceSession"] as UUID?).map {
            provider == "claude" ? WorkspaceThreadKey.claudeSession($0) : WorkspaceThreadKey.codexSession($0)
        } ?? WorkspaceThreadKey.local
        return WorkspaceChatTimelineEntry(id: id, role: role, text: row["text"],
            timestamp: row["timestamp"], provider: provider, sourceTurnID: row["sourceTurnID"],
            state: rawState.flatMap(WorkspaceFrontierTurnState.init(rawValue:)),
            notDelivered: row["notDelivered"] ?? false, failureReason: row["failureReason"],
            sourceThread: sourceThread)
    }
}

extension Stores {
    /// Compatibility bridge over the same legacy sources as the old chat. No
    /// imports, captures, memories or other chats enter this projection.
    static func agentTimeline(chatID: UUID, entries: [AgentTranscriptEntry], in db: Database) throws -> [AgentTranscriptEntry] {
        let local = try chatTimeline(chatID: chatID, limit: -1, completedOnly: false, in: db)
        let native = try nativeChatTimeline(chatID: chatID, in: db)
        let observed = try claudeObservedTimeline(chatID: chatID, in: db)
        let handovers = try WorkspaceHandover.filter(Column("chatID") == chatID).fetchAll(db).map {
            WorkspaceChatTimelineEntry(id: "handover:\($0.id)", role: "handover", text: $0.text,
                timestamp: $0.anchorTimestamp, provider: WorkspaceThreadKey.provider($0.threadKey))
        }
        let legacy = (local + native + observed + handovers).enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        var result = legacy.compactMap { item -> AgentTranscriptEntry? in
            guard let provider = AgentProvider(rawValue: item.provider) else { return nil }
            let digest = Array(SHA256.hash(data: Data(("legacy:" + item.id).utf8)).prefix(16))
            let id = digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            let payload = JSONValue.object(["legacyID": .string(item.id),
                "completed": .bool((item.state == nil || item.state == .completed) && !item.notDelivered),
                "sourceThread": .string(item.sourceThread ?? "")]).jsonString
            return .init(id: id, chatID: chatID, provider: provider, kind: item.role, text: item.text, payloadJSON: payload)
        }
        result += entries
        for index in result.indices { result[index].position = index }
        return result
    }
}
