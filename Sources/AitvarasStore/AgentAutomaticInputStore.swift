import Foundation
import GRDB
import AitvarasAgents

extension AgentAutomaticInput: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentAutomaticInput" }
}

extension AgentQuotaStop: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentQuotaStop" }
}

extension Stores {
    public func recordQuotaStop(_ stop: AgentQuotaStop) throws {
        try db.queue.write { dbc in
            guard stop.evidence.status == .rejected, let turn = try AgentJournalTurn.fetchOne(dbc, key: stop.id),
                  turn.state == .failed, turn.chatID == stop.chatID, turn.sessionID == stop.sessionID,
                  let session = try AgentChatSession.fetchOne(dbc, key: stop.sessionID), session.sessionID == stop.native,
                  session.providerProfile == stop.providerProfile else { throw AgentFailure.invalidTransition }
            if try AgentQuotaStop.fetchOne(dbc, key: stop.id) == nil { try stop.insert(dbc) }
        }
    }
    public func quotaStops() throws -> [AgentQuotaStop] {
        try db.queue.read { try AgentQuotaStop.order(Column("stoppedAt")).fetchAll($0) }
    }
    public func prepareAutomaticTurn(_ turn: AgentJournalTurn, authorization: AgentAutoContinue) throws {
        try AgentTurnStore(db: db).prepare(turn, automatic: authorization)
    }
    public func beginAutomaticDelivery(id: UUID, authorization: AgentAutoContinue, now: Date) throws {
        try AgentTurnStore(db: db).advanceDelivery(id: id, to: .deliveryUnknown, authorization: authorization, now: now)
    }
    public func automaticInput(id: UUID) throws -> AgentAutomaticInput? {
        try db.queue.read { try AgentAutomaticInput.fetchOne($0, key: id) }
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
    public func finishAutomaticTurn(id: UUID, outcome: AgentTurnOutcome) throws {
        let state: AgentJournalState
        switch outcome { case .completed: state = .completed; case .interrupted: state = .interrupted; case .failed: state = .failed }
        try AgentTurnStore(db: db).finish(id: id, state: state, outcome: outcome)
    }
}
