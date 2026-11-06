import Foundation
import GRDB
import AitvarasAgents

struct AgentHandoverRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentHandover"
    let turnID: UUID
    let contextJSON: String
    init(context: ChatContextProjection, turnID: UUID) throws {
        self.turnID = turnID
        contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    }
    var context: ChatContextProjection {
        get throws { try JSONDecoder().decode(ChatContextProjection.self, from: Data(contextJSON.utf8)) }
    }
}

extension Stores {
    /// The acknowledged journal is the watermark: a prepared or uncertain
    /// send cannot consume context, even across a crash/restart.
    public func agentContext(session: AgentChatSession) throws -> ChatContextProjection? {
        try db.queue.read { dbc in
            let normalized = try AgentTranscriptEntry.filter(Column("chatID") == session.chatID)
                .filter(Column("isActive") == true).order(Column("position")).fetchAll(dbc)
            let entries = try Self.agentTimeline(chatID: session.chatID, entries: normalized, in: dbc)
            let turns = try AgentJournalTurn.filter(Column("chatID") == session.chatID).order(Column("startedAt")).fetchAll(dbc)
            let byID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
            var current: AgentJournalTurn?
            let completed = entries.filter { entry in
                if entry.kind == "user", !entry.isLegacyProjection { current = byID[entry.id] }
                if let payload = entry.payloadJSON.flatMap(JSONValue.parse) {
                    if entry.isLegacyProjection { return payload["completed"]?.boolValue == true }
                    if payload["nativeHistory"] != nil {
                        if let id = payload["journalInputID"]?.stringValue.flatMap(UUID.init(uuidString:)),
                           byID[id]?.state != .completed { return false }
                        return payload["nativeHistory"]?["completed"]?.boolValue == true
                    }
                }
                return current?.state == .completed && entry.sessionID == current?.sessionID
            }.filter { ["user", "assistant"].contains($0.kind) && !$0.text.isEmpty
                && (session.provider == .local || $0.sessionID != session.id) }
            var receipt: [String: String]?
            if session.provider != .local {
                // Preparation order breaks timestamp ties deterministically.
                let record = try AgentHandoverRecord.fetchOne(dbc, sql: """
                    SELECT h.* FROM agentHandover h JOIN agentTurn t ON t.id = h.turnID
                    WHERE t.sessionID = ? AND t.delivery = 'acknowledged'
                    ORDER BY h.rowid DESC LIMIT 1
                    """, arguments: [session.id])
                receipt = try record?.context.sources
            }
            let sources = Dictionary(uniqueKeysWithValues: completed.map { ($0.id.uuidString, ChatContextProjection.digest($0)) })
            let changed = receipt?.contains { sources[$0.key] != $0.value } ?? false
            let missed: [AgentTranscriptEntry]
            if changed || session.provider == .local { missed = completed }
            else if let receipt { missed = completed.filter { receipt[$0.id.uuidString] == nil } }
            else { missed = completed } // Older positional receipts cannot prove legacy coverage.
            var context = ChatContextProjection.make(entries: missed, provider: session.provider, sessionID: session.id, replacingHistory: changed)
            context?.sources = sources
            return context
        }
    }

    public func prepareAgentHandover(_ context: ChatContextProjection, turnID: UUID) throws {
        try db.queue.write { try AgentHandoverRecord(context: context, turnID: turnID).insert($0) }
    }
    public func agentHandover(turnID: UUID) throws -> ChatContextProjection? {
        try db.queue.read { try AgentHandoverRecord.fetchOne($0, key: turnID)?.context }
    }
}
