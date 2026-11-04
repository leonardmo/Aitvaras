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
            let entries = try AgentTranscriptEntry.filter(Column("chatID") == session.chatID)
                .order(Column("position")).fetchAll(dbc)
            let turns = try AgentJournalTurn.filter(Column("chatID") == session.chatID).fetchAll(dbc)
            let byID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
            var current: AgentJournalTurn?
            let completed = entries.filter { entry in
                if entry.kind == "user" { current = byID[entry.id] }
                return current?.state == .completed && entry.sessionID == current?.sessionID
            }
            var watermark = -1
            if session.provider != .local {
                for turn in turns where turn.sessionID == session.id && turn.delivery == .acknowledged {
                    if let record = try AgentHandoverRecord.fetchOne(dbc, key: turn.id) {
                        watermark = max(watermark, try record.context.throughPosition)
                    }
                }
            }
            return ChatContextProjection.make(entries: completed, provider: session.provider, after: watermark)
        }
    }

    public func prepareAgentHandover(_ context: ChatContextProjection, turnID: UUID) throws {
        try db.queue.write { try AgentHandoverRecord(context: context, turnID: turnID).insert($0) }
    }
    public func agentHandover(turnID: UUID) throws -> ChatContextProjection? {
        try db.queue.read { try AgentHandoverRecord.fetchOne($0, key: turnID)?.context }
    }
}
