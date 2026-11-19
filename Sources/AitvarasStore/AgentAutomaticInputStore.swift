import Foundation
import GRDB
import AitvarasAgents

extension AgentAutomaticInput: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentAutomaticInput" }
}

extension Stores {
    public func quotaStops() throws -> [AgentQuotaStop] {
        try db.queue.read { dbc in
            try AgentTranscriptEntry.filter(Column("kind") == "stopped").fetchAll(dbc).compactMap { row in
                guard let stopped = row.stoppedTurn, stopped.reason.kind == .quota,
                      let context = stopped.quotaContext, let native = stopped.nativeSession,
                      let sessionID = row.sessionID else { return nil }
                return AgentQuotaStop(id: stopped.inputID, chatID: row.chatID, sessionID: sessionID, native: native,
                    providerProfile: stopped.providerProfile,
                    evidence: .init(status: .rejected, windowID: context.windowID, resetsAt: stopped.reason.resetsAt),
                    stoppedAt: context.stoppedAt, inputRevision: context.inputRevision, accountID: context.accountID)
            }.sorted { $0.stoppedAt < $1.stoppedAt }
        }
    }
    static func stoppedRow(for turn: AgentJournalTurn, in dbc: Database) throws -> AgentTranscriptEntry? {
        try AgentTranscriptEntry.filter(Column("chatID") == turn.chatID && Column("kind") == "stopped")
            .order(Column("position").desc).fetchAll(dbc).first {
                $0.stoppedTurn?.inputID == turn.id && $0.stoppedTurn?.attempt == turn.resendCount
            }
    }
    public func prepareAutomaticTurn(_ turn: AgentJournalTurn, authorization: AgentAutoContinue) throws {
        try AgentTurnStore(db: db).prepare(turn, automatic: authorization)
    }
    public func beginAutomaticDelivery(id: UUID, authorization: AgentAutoContinue, now: Date) throws {
        try AgentTurnStore(db: db).advanceDelivery(id: id, to: .deliveryUnknown, authorization: authorization, now: now)
    }
    public func automaticInput(id: UUID) throws -> AgentAutomaticInput? {
        try db.queue.read { dbc in
            guard var receipt = try AgentAutomaticInput.fetchOne(dbc, key: id),
                  let turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { return nil }
            let reason = try Self.stoppedRow(for: turn, in: dbc)?.stoppedTurn?.reason
            switch turn.state {
            case .running: break
            case .completed: receipt.outcome = "completed"
            case .interrupted:
                if reason?.kind == .interrupted { receipt.outcome = "interrupted" }
            case .failed:
                receipt.outcome = reason?.kind == .quota ? "quota" : "failed"
                receipt.resetsAt = reason?.resetsAt
            }
            return receipt
        }
    }
    public func bindAutomaticInput(id: UUID, messageID: String?, turnID: String?) throws {
        try db.queue.write { dbc in
            guard var receipt = try AgentAutomaticInput.fetchOne(dbc, key: id) else { throw AgentFailure.invalidRequest }
            if let messageID {
                guard receipt.nativeMessageID == nil || receipt.nativeMessageID == messageID else { throw AgentNativeHistoryError.identityConflict }
                receipt.nativeMessageID = messageID
            }
            if let turnID {
                guard receipt.nativeTurnID == nil || receipt.nativeTurnID == turnID else { throw AgentNativeHistoryError.identityConflict }
                receipt.nativeTurnID = turnID
            }
            try receipt.update(dbc)
        }
    }
}
