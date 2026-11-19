import Foundation
import GRDB
import AitvarasCore
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
    public func prepare(_ turn: AgentJournalTurn, context: ChatContextProjection? = nil) throws {
        guard turn.delivery == .prepared, turn.state == .running, turn.resendCount == 0,
              turn.partialOutput.isEmpty else { throw AgentFailure.invalidTransition }
        try db.queue.write { dbc in
            try turn.insert(dbc)
            try Self.monitor(turn, in: dbc)
            if let context { try AgentHandoverRecord(context: context, turnID: turn.id).insert(dbc) }
            try Self.touchChat(turn.chatID, at: turn.startedAt, in: dbc)
        }
        Self.notifyMonitoring()
    }

    public func prepareRecovery(_ turn: AgentJournalTurn, context: ChatContextProjection?, entry: AgentTranscriptEntry,
                                stoppedEntryID: UUID, action: AgentRecoveryAction, session: AgentChatSession) throws {
        try db.queue.write { dbc in
            guard var stopped = try AgentTranscriptEntry.fetchOne(dbc, key: stoppedEntryID),
                  var stop = stopped.stoppedTurn, stop.actions.contains(action),
                  [.continueTurn, .retry].contains(action), stopped.chatID == turn.chatID,
                  stopped.sessionID == session.id, stop.choice == session.choice,
                  let original = try AgentJournalTurn.fetchOne(dbc, key: stop.inputID),
                  original.state != .running, original.resendCount == stop.attempt,
                  original.sessionID == session.id, original.chatID == turn.chatID,
                  try AgentJournalTurn.filter(Column("chatID") == turn.chatID)
                    .order(Column("startedAt").desc, Column("id")).fetchOne(dbc)?.id == original.id,
                  try AgentChatSession.fetchOne(dbc, key: session.id) == session,
                  turn.id != original.id, turn.sessionID == session.id, turn.parentInputID == nil,
                  turn.delivery == .prepared, turn.state == .running, turn.resendCount == 0, turn.partialOutput.isEmpty,
                  entry.id == turn.id, entry.sessionID == session.id, entry.chatID == turn.chatID,
                  entry.provider == session.provider, entry.nativeMessageID == nil else { throw AgentFailure.invalidTransition }
            if session.providerProfile != "default" {
                guard let id = UUID(uuidString: session.providerProfile),
                      try AgentProviderProfile.fetchOne(dbc, key: id)?.isDeleted == false else { throw AgentFailure.invalidTransition }
            }
            if action == .continueTurn {
                guard session.usesThreadContext, stop.canContinue, let native = stop.nativeSession, session.sessionID == native,
                      entry.kind == "continued", entry.text == AgentStoppedTurn.continuationText,
                      turn.prompt == AgentStoppedTurn.continuationText, context == nil else { throw AgentFailure.invalidTransition }
            } else {
                guard stop.delivery != .acknowledged, session.sessionID == stop.nativeSession,
                      ["user", "continued"].contains(entry.kind), turn.prompt == original.prompt else { throw AgentFailure.invalidTransition }
                if entry.kind == "continued" {
                    guard entry.text == AgentStoppedTurn.continuationText, turn.prompt == entry.text,
                          try AgentTranscriptEntry.fetchOne(dbc, key: original.id)?.kind == "continued" else { throw AgentFailure.invalidTransition }
                }
            }
            // Claim and journal the new attempt before any provider write. A
            // repeated click, including after restart, cannot claim this row.
            stop.recoveryInputID = turn.id
            stopped.payloadJSON = try stop.payload()
            try stopped.update(dbc, columns: ["payloadJSON"])
            try turn.insert(dbc)
            try Self.monitor(turn, in: dbc)
            if let context { try AgentHandoverRecord(context: context, turnID: turn.id).insert(dbc) }
            var input = entry
            input.position = (try AgentTranscriptEntry.filter(Column("chatID") == turn.chatID)
                .order(Column("position").desc).fetchOne(dbc)?.position ?? -1) + 1
            try input.insert(dbc)
            try ActivityEvent(kind: .toolExecuted, connectorID: "agent", summary: "Chat recovery requested",
                detailJSON: JSONValue.object(["chatID": .string(turn.chatID.uuidString), "action": .string(action.rawValue),
                    "originalInputID": .string(original.id.uuidString)]).jsonString, runID: turn.id).insert(dbc)
            try Self.touchChat(turn.chatID, at: turn.startedAt, in: dbc)
        }
        Self.notifyMonitoring()
    }
    private func change(_ id: UUID, monitoring: Bool = false, _ body: (inout AgentJournalTurn) throws -> Void) throws {
        try db.queue.write { dbc in
            guard var turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { throw AgentStoreError.missingTurn }
            try body(&turn)
            try turn.update(dbc)
            if monitoring { try Self.monitor(turn, in: dbc) }
        }
        if monitoring { Self.notifyMonitoring() }
    }
    public func advanceDelivery(id: UUID, to state: AgentDeliveryState) throws {
        try change(id, monitoring: true) { turn in
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
    @discardableResult
    public func finish(id: UUID, state: AgentJournalState, stop: AgentStopReason? = nil) throws -> AgentTranscriptEntry? {
        guard state != .running else { throw AgentFailure.invalidTransition }
        let row = try db.queue.write { dbc -> AgentTranscriptEntry? in
            guard var turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { throw AgentStoreError.missingTurn }
            if turn.state != .running, let stop, stop.kind == .internalError {
                return try Self.stoppedEntry(turn, reason: stop, in: dbc)
            }
            guard turn.state == .running || turn.state == state else { throw AgentFailure.invalidTransition }
            let endedAt = turn.endedAt ?? .now
            turn.state = state; turn.endedAt = endedAt
            try turn.update(dbc)
            try Self.touchChat(turn.chatID, at: endedAt, in: dbc)
            try Self.monitor(turn, in: dbc)
            guard state != .completed else { return nil }
            return try Self.stoppedEntry(turn, reason: stop ?? (state == .failed ? .failure(.unknown) : .interrupted), in: dbc)
        }
        Self.notifyMonitoring()
        return row
    }

    private static func stoppedEntry(_ turn: AgentJournalTurn, reason: AgentStopReason, in dbc: Database) throws -> AgentTranscriptEntry {
        let rows = try AgentTranscriptEntry.filter(Column("chatID") == turn.chatID)
            .filter(Column("kind") == "stopped").order(Column("position")).fetchAll(dbc)
        if var existing = rows.last(where: { $0.stoppedTurn?.inputID == turn.id && $0.stoppedTurn?.attempt == turn.resendCount }) {
            if reason.kind == .internalError, existing.stoppedTurn?.reason.kind != .internalError,
               let session = try AgentChatSession.fetchOne(dbc, key: turn.sessionID) {
                var replacement = AgentStoppedTurn(turn: turn, session: session, reason: reason)
                replacement.recoveryInputID = existing.stoppedTurn?.recoveryInputID
                existing.payloadJSON = try replacement.payload()
                try existing.update(dbc, columns: ["payloadJSON"])
            }
            return existing
        }
        guard let session = try AgentChatSession.fetchOne(dbc, key: turn.sessionID) else { throw AgentStoreError.missingSession }
        let stop = AgentStoppedTurn(turn: turn, session: session, reason: reason)
        let position = (try AgentTranscriptEntry.filter(Column("chatID") == turn.chatID)
            .order(Column("position").desc).fetchOne(dbc)?.position ?? -1) + 1
        let entry = AgentTranscriptEntry(chatID: turn.chatID, provider: session.provider, kind: "stopped",
            payloadJSON: try stop.payload(), sessionID: session.id, position: position)
        try entry.insert(dbc)
        return entry
    }
    /// The journal and its Activity identity commit together before delivery.
    /// Metadata only: no prompt, output, path or native account/session identity.
    private static func monitor(_ turn: AgentJournalTurn, in dbc: Database, retry: Bool = false) throws {
        guard let session = try AgentChatSession.fetchOne(dbc, key: turn.sessionID) else { throw AgentStoreError.missingSession }
        let state: ActivityRunState
        let stage: String
        switch turn.state {
        case .completed: state = .succeeded; stage = "Response completed"
        case .failed: state = .failed; stage = "Response failed"
        case .interrupted: state = .interrupted; stage = "Response interrupted"
        case .running:
            state = turn.parentInputID != nil && turn.delivery != .acknowledged ? .queued : .running
            stage = retry ? "Retrying undelivered input" : state == .queued ? "Follow-up queued" : "Responding"
        }
        let previous = try ActivityRun.fetchOne(dbc, key: turn.id)
        if let previous {
            guard previous.category == .chat, previous.referenceID == turn.chatID.uuidString,
                  previous.provider == session.provider.rawValue, previous.parentID == turn.parentInputID else {
                throw AgentStoreError.identityConflict
            }
        }
        var run = previous ?? ActivityRun(
            id: turn.id, parentID: turn.parentInputID, referenceID: turn.chatID.uuidString, category: .chat,
            title: { if case .autonomous(let reason) = turn.origin { return reason.activityTitle }; return "Chat response" }(), startedAt: turn.startedAt, provider: session.provider.rawValue,
            executionLocation: session.provider == .local ? "This Mac" : "Official CLI",
            dataAccess: "Selected project and this chat", dataDestination: session.provider == .local ? "This Mac" : "Selected provider")
        run.state = state; run.stage = stage; run.updatedAt = turn.endedAt ?? .now
        run.finishedAt = state.isTerminal ? run.updatedAt : nil
        run.outcome = state.isTerminal ? stage : nil
        if retry { run.acknowledgedAt = nil }
        guard previous?.state != state || previous?.stage != stage else { return }
        try run.save(dbc)
        try ActivityRunStep(runID: run.id, timestamp: run.updatedAt, stage: stage, state: state).insert(dbc)
    }
    private static func notifyMonitoring() {
        NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
    }

    private static func touchChat(_ id: UUID, at date: Date, in dbc: Database) throws {
        guard var chat = try WorkspaceChat.fetchOne(dbc, key: id) else { throw AgentStoreError.missingChat }
        chat.lastActivityAt = max(chat.lastActivityAt, date)
        try chat.update(dbc)
    }
    /// Explicit retry only; recovery itself never sends or claims a retry.
    public func claimResend(id: UUID) throws -> AgentJournalTurn {
        let result = try db.queue.write { dbc in
            guard var turn = try AgentJournalTurn.fetchOne(dbc, key: id) else { throw AgentStoreError.missingTurn }
            guard turn.origin == .user, turn.prompt != nil else { throw AgentFailure.invalidTransition }
            guard try AgentJournalTurn.filter(Column("chatID") == turn.chatID && Column("state") == "running")
                .fetchCount(dbc) == 0, turn.delivery.canAutomaticallyResend, turn.resendCount == 0, turn.state != .running else {
                throw AgentFailure.invalidTransition
            }
            let stoppedRows = try AgentTranscriptEntry.filter(Column("chatID") == turn.chatID)
                .filter(Column("kind") == "stopped").fetchAll(dbc)
            guard !stoppedRows.contains(where: { row in
                guard let stop = row.stoppedTurn, stop.inputID == turn.id, stop.attempt == turn.resendCount else { return false }
                return stop.reason.kind == .internalError || stop.recoveryInputID != nil
            }) else { throw AgentFailure.invalidTransition }
            turn.resendCount = 1; turn.state = .running; turn.endedAt = nil
            for var row in stoppedRows {
                if var stop = row.stoppedTurn, stop.inputID == turn.id, stop.recoveryInputID == nil {
                    stop.recoveryInputID = turn.id; row.payloadJSON = try stop.payload()
                    try row.update(dbc, columns: ["payloadJSON"])
                }
            }
            try turn.update(dbc)
            try Self.monitor(turn, in: dbc, retry: true)
            return turn
        }
        Self.notifyMonitoring()
        return result
    }
    public func recover() throws {
        try db.queue.write { dbc in
            for var turn in try AgentJournalTurn.filter(Column("state") == AgentJournalState.running.rawValue).fetchAll(dbc) {
                turn.state = .interrupted; turn.endedAt = .now
                try turn.update(dbc)
                try Self.monitor(turn, in: dbc)
                _ = try Self.stoppedEntry(turn, reason: .connectionClosed, in: dbc)
            }
        }
        Self.notifyMonitoring()
    }
}

extension Stores {
    public func latestAgentTurn(chatID: UUID) throws -> AgentJournalTurn? { try AgentTurnStore(db: db).latest(chatID: chatID) }
    public func prepareAgentTurn(_ turn: AgentJournalTurn) throws { try AgentTurnStore(db: db).prepare(turn) }
    public func prepareAgentTurn(_ turn: AgentJournalTurn, context: ChatContextProjection?) throws {
        try AgentTurnStore(db: db).prepare(turn, context: context)
    }
    public func agentTurn(id: UUID) throws -> AgentJournalTurn? { try AgentTurnStore(db: db).turn(id: id) }
    public func advanceAgentDelivery(id: UUID, to state: AgentDeliveryState) throws { try AgentTurnStore(db: db).advanceDelivery(id: id, to: state) }
    public func saveAgentPartial(id: UUID, text: String) throws { try AgentTurnStore(db: db).savePartial(id: id, text: text) }
    public func finishAgentTurn(id: UUID, state: AgentJournalState) throws { _ = try AgentTurnStore(db: db).finish(id: id, state: state) }
    public func finishAgentTurn(id: UUID, state: AgentJournalState, stop: AgentStopReason?) throws -> AgentTranscriptEntry? {
        try AgentTurnStore(db: db).finish(id: id, state: state, stop: stop)
    }
    public func prepareAgentRecovery(_ turn: AgentJournalTurn, context: ChatContextProjection?, entry: AgentTranscriptEntry,
                                     stoppedEntryID: UUID, action: AgentRecoveryAction, session: AgentChatSession) throws {
        try AgentTurnStore(db: db).prepareRecovery(turn, context: context, entry: entry,
            stoppedEntryID: stoppedEntryID, action: action, session: session)
    }
    public func claimAgentResend(id: UUID) throws -> AgentJournalTurn { try AgentTurnStore(db: db).claimResend(id: id) }
    public func recoverAgentTurns() throws { try AgentTurnStore(db: db).recover() }
}
