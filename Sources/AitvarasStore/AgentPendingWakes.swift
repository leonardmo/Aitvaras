import Foundation
import GRDB
import AitvarasAgents
import AitvarasCore

extension AgentPendingWake: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentPendingWake" }
}

extension Stores: AgentWakePersistence {
    public func pendingAgentWakes(chatID: UUID? = nil) throws -> [AgentPendingWake] {
        try db.queue.read { db in
            var query = AgentPendingWake.filter(Column("firedAt") == nil)
            if let chatID { query = query.filter(Column("chatID") == chatID) }
            return try query.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }
    public func saveAgentWake(_ wake: AgentPendingWake) throws {
        try db.queue.write { db in
            guard let session = try AgentChatSession.fetchOne(db, key: wake.sessionID), session.chatID == wake.chatID,
                  let chat = try WorkspaceChat.fetchOne(db, key: wake.chatID), chat.archivedAt == nil else { return }
            guard wake.prompt?.count ?? 0 <= 16_384 else { throw AgentStoreError.invalidValue }
            try wake.save(db)
        }
    }
    public func deleteAgentWake(id: UUID) throws {
        _ = try db.queue.write { try AgentPendingWake.deleteOne($0, key: id) }
    }
    public func cancelAppOwnedAgentWake(id: UUID) throws {
        let tool = ToolDefinition(name: "cancelWake", description: "Cancel chat wake-up", parametersJSON: "{}", risk: .reversibleWrite)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.wakeups") == .allow else { throw AgentFailure.invalidRequest }
        try db.queue.write { db in
            guard let wake = try AgentPendingWake.fetchOne(db, key: id), wake.transportID == nil,
                  wake.claimedAt == nil, wake.firedAt == nil else { throw AgentFailure.invalidTransition }
            try wake.delete(db)
            try ActivityEvent(kind: .toolExecuted, connectorID: "agent.wakeups", summary: "Cancelled chat wake-up",
                detailJSON: JSONValue.object(["risk": .string(ActionRisk.reversibleWrite.rawValue),
                    "chatID": .string(wake.chatID.uuidString), "decision": .string("explicit user action")]).jsonString,
                sourceID: "chat:" + wake.chatID.uuidString).insert(db)
        }
    }
    public func claimAgentWake(id: UUID, now: Date) throws -> AgentPendingWake? {
        try db.queue.write { db in
            guard var wake = try AgentPendingWake.fetchOne(db, key: id), wake.claimedAt == nil, wake.firedAt == nil,
                  wake.survivesTransport, wake.isAppOwned(at: now), let due = wake.fireAt, due <= now,
                  let chat = try WorkspaceChat.fetchOne(db, key: wake.chatID), chat.archivedAt == nil,
                  try AgentJournalTurn.filter(Column("chatID") == wake.chatID && Column("state") == "running").fetchCount(db) == 0
            else { return nil }
            wake.claimedAt = now; wake.claimedTurnID = UUID(); wake.transportID = nil
            try wake.update(db); return wake
        }
    }
    public func finishAgentWake(id: UUID, now: Date) throws {
        try db.queue.write { db in
            guard var wake = try AgentPendingWake.fetchOne(db, key: id) else { return }
            if wake.kind == .cron, wake.recurring, let spec = wake.cronSpec {
                wake.fireAt = AgentWakeCron.next(spec, after: now); wake.claimedAt = nil; wake.claimedTurnID = nil
            } else { wake.firedAt = now }
            try wake.update(db)
        }
    }
    public func releaseAgentWakeClaim(id: UUID) throws {
        try db.queue.write { db in
            guard var wake = try AgentPendingWake.fetchOne(db, key: id), wake.firedAt == nil else { return }
            wake.claimedAt = nil; wake.claimedTurnID = nil; try wake.update(db)
        }
    }
    /// nil means app startup: all old process generations have ended. Claims
    /// already committed before a crash are consumed, never blindly replayed.
    public func releaseAgentWakeTransport(_ transportID: UUID?) throws {
        try db.queue.write { db in
            var query = AgentPendingWake.filter(Column("firedAt") == nil)
            if let transportID { query = query.filter(Column("transportID") == transportID) }
            for var wake in try query.fetchAll(db) {
                if !wake.survivesTransport {
                    try wake.delete(db)
                    var run = ActivityRun(referenceID: wake.chatID.uuidString, category: .chat, trigger: .automatic,
                        title: "Background task stopped when Aitvaras quit")
                    run.state = .succeeded; run.finishedAt = .now; try run.insert(db)
                } else {
                    wake.transportID = nil
                    if wake.claimedAt != nil {
                        let turn = try wake.claimedTurnID.flatMap { try AgentJournalTurn.fetchOne(db, key: $0) }
                        if turn == nil || turn?.delivery == .prepared {
                            wake.claimedAt = nil; wake.claimedTurnID = nil
                        } else if wake.kind == .cron, wake.recurring, let spec = wake.cronSpec {
                            wake.fireAt = AgentWakeCron.next(spec, after: .now); wake.claimedAt = nil; wake.claimedTurnID = nil
                        } else { wake.firedAt = .now }
                    }
                    try wake.update(db)
                }
            }
        }
    }
}
