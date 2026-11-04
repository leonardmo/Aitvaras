import Foundation
import GRDB
import AitvarasAgents

extension AgentJournalTurn: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentTurn" }
}

public struct AgentTurnStore: Sendable {
    public let db: AitvarasDatabase
    public init(db: AitvarasDatabase) { self.db = db }
    public func turn(id: UUID) throws -> AgentJournalTurn? {
        try db.queue.read { try AgentJournalTurn.fetchOne($0, key: id) }
    }
    public func latest(chatID: UUID) throws -> AgentJournalTurn? {
        try db.queue.read { try AgentJournalTurn.filter(Column("chatID") == chatID)
            .order(Column("startedAt").desc, Column("id")).fetchOne($0) }
    }
    public func prepare(_ turn: AgentJournalTurn) throws {
        guard turn.delivery == .prepared, turn.state == .running, turn.resendCount == 0,
              turn.partialOutput.isEmpty else { throw AgentFailure.invalidTransition }
        try db.queue.write { try turn.insert($0) }
    }
    private func change(_ id: UUID, _ body: (inout AgentJournalTurn) throws -> Void) throws {
        try db.queue.write { dbc in
            guard var turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { throw AgentStoreError.missingTurn }
            try body(&turn)
            try turn.update(dbc)
        }
    }
    public func advanceDelivery(id: UUID, to state: AgentDeliveryState) throws {
        try change(id) { turn in
            guard turn.state == .running else { throw AgentFailure.invalidTransition }
            turn.delivery = try turn.delivery.advancing(to: state)
        }
    }
    public func savePartial(id: UUID, text: String) throws {
        try change(id) { turn in
            guard turn.state == .running else { throw AgentFailure.invalidTransition }
            turn.partialOutput = text
        }
    }
    public func finish(id: UUID, state: AgentJournalState) throws {
        guard state != .running else { throw AgentFailure.invalidTransition }
        try change(id) { turn in
            guard turn.state == .running || turn.state == state else { throw AgentFailure.invalidTransition }
            turn.state = state; turn.endedAt = turn.endedAt ?? .now
        }
    }
    /// Explicit retry only; recovery itself never sends or claims a retry.
    public func claimResend(id: UUID) throws -> AgentJournalTurn {
        try db.queue.write { dbc in
            guard var turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { throw AgentStoreError.missingTurn }
            guard turn.delivery.canAutomaticallyResend, turn.resendCount == 0, turn.state != .running else {
                throw AgentFailure.invalidTransition
            }
            turn.resendCount = 1; turn.state = .running; turn.endedAt = nil
            try turn.update(dbc)
            return turn
        }
    }
    public func recover() throws {
        try db.queue.write { dbc in
            for var turn in try AgentJournalTurn.filter(Column("state") == AgentJournalState.running.rawValue).fetchAll(dbc) {
                turn.state = .interrupted; turn.endedAt = .now
                try turn.update(dbc)
            }
        }
    }
}

extension Stores {
    public func latestAgentTurn(chatID: UUID) throws -> AgentJournalTurn? { try AgentTurnStore(db: db).latest(chatID: chatID) }
    public func prepareAgentTurn(_ turn: AgentJournalTurn) throws { try AgentTurnStore(db: db).prepare(turn) }
    public func agentTurn(id: UUID) throws -> AgentJournalTurn? { try AgentTurnStore(db: db).turn(id: id) }
    public func advanceAgentDelivery(id: UUID, to state: AgentDeliveryState) throws { try AgentTurnStore(db: db).advanceDelivery(id: id, to: state) }
    public func saveAgentPartial(id: UUID, text: String) throws { try AgentTurnStore(db: db).savePartial(id: id, text: text) }
    public func finishAgentTurn(id: UUID, state: AgentJournalState) throws { try AgentTurnStore(db: db).finish(id: id, state: state) }
    public func claimAgentResend(id: UUID) throws -> AgentJournalTurn { try AgentTurnStore(db: db).claimResend(id: id) }
    public func recoverAgentTurns() throws { try AgentTurnStore(db: db).recover() }
}
