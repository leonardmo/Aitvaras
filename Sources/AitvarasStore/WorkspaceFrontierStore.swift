import Foundation
import GRDB
import AitvarasCore

public enum WorkspaceFrontierError: Error, LocalizedError, Sendable, Equatable {
    case unavailableChat, reviewRequired, staleContext, sessionNotFound, turnNotFound
    case immutableIdentity, importedIdentity, unresolvedTurn, invalidValue, invalidTransition

    public var errorDescription: String? {
        switch self {
        case .unavailableChat: "Choose an active chat in a visible project."
        case .reviewRequired: "Review the current project policy and allow Codex first."
        case .staleContext: "The reviewed context or policy changed. Create a newly reviewed session."
        case .sessionNotFound: "This app-owned session no longer exists."
        case .turnNotFound: "This saved turn no longer exists."
        case .immutableIdentity: "Saved session and turn identities cannot be reassigned."
        case .importedIdentity: "Imported native history is read-only and cannot become an app-owned session."
        case .unresolvedTurn: "A previous turn is active or has an unresolved outcome. It will not be replayed."
        case .invalidValue: "The session or turn contains an invalid value."
        case .invalidTransition: "The provider outcome does not permit this state change."
        }
    }
}

/// Only this store creates owned identities; an imported link is never authority.
/// Review covers the exact metadata text, not files, tools, or general cloud use.
public struct WorkspaceFrontierSession: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceFrontierSession"
    public let id: UUID
    public let projectID: UUID
    public let chatID: UUID
    public let provider: NativeSessionProvider
    public let externalID: String?
    public let reviewedContext: String
    public let policyRevision: Int
    public let contextRevision: Int
    public let chatContextRevision: Int
    public let model: String
    public let effort: String?
    public let createdAt: Date
    public let updatedAt: Date
}

public struct WorkspaceFrontierTurn: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceFrontierTurn"
    public let id: UUID
    public let sessionID: UUID
    public var state: WorkspaceFrontierTurnState
    public let promptText: String
    public var outputText: String
    public var providerTurnID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public let startedAt: Date
    public var endedAt: Date?
}

extension Stores {
    public static let maximumWorkspaceFrontierPromptCharacters = 24_000

    /// Atomic approval CAS. This only records consent; it never calls a provider.
    public func createWorkspaceFrontierSession(chatID: UUID, model: String, effort: String?,
                                               expectedPolicyRevision: Int, reviewedContext: String) throws -> WorkspaceFrontierSession {
        try Self.validateFrontierIdentifier(model)
        if let effort { try Self.validateFrontierIdentifier(effort) }
        return try db.queue.write { dbc in
            let (chat, policy, packet, generation) = try Self.frontierContext(chatID: chatID, in: dbc)
            guard policy.revision == expectedPolicyRevision, packet.promptText == reviewedContext else {
                throw WorkspaceFrontierError.staleContext
            }
            let id = UUID(), now = Date.now
            try dbc.execute(sql: """
                INSERT INTO workspaceFrontierSession
                (id, projectID, chatID, provider, reviewedContext, policyRevision, contextRevision,
                 chatContextRevision, model, effort, createdAt, updatedAt)
                VALUES (?, ?, ?, 'codex', ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, chat.projectID, chatID, reviewedContext, policy.revision,
                    policy.contextRevision, generation, model, effort, now, now])
            return try WorkspaceFrontierSession.fetchOne(dbc, key: id)!
        }
    }

    public func workspaceFrontierSessions(chatID: UUID) throws -> [WorkspaceFrontierSession] {
        try db.queue.read { try WorkspaceFrontierSession.filter(Column("chatID") == chatID)
            .order(Column("createdAt"), Column("id")).fetchAll($0) }
    }

    public func workspaceFrontierSession(id: UUID) throws -> WorkspaceFrontierSession? {
        try db.queue.read { try WorkspaceFrontierSession.fetchOne($0, key: id) }
    }

    /// Bind only the ID returned by creation of a new provider session. Existing
    /// imported identities are explicitly refused, even in the same chat.
    @discardableResult
    public func bindWorkspaceFrontierSession(id: UUID, externalID: String) throws -> WorkspaceFrontierSession {
        try Self.validateFrontierIdentifier(externalID)
        return try db.queue.write { dbc in
            guard let session = try WorkspaceFrontierSession.fetchOne(dbc, key: id) else { throw WorkspaceFrontierError.sessionNotFound }
            if let existing = session.externalID {
                guard existing == externalID else { throw WorkspaceFrontierError.immutableIdentity }
                return session
            }
            guard try WorkspaceSessionLink.filter(Column("provider") == "codex")
                .filter(Column("externalID") == externalID).fetchOne(dbc) == nil else {
                throw WorkspaceFrontierError.importedIdentity
            }
            guard try WorkspaceFrontierSession.filter(Column("externalID") == externalID).fetchOne(dbc) == nil else {
                throw WorkspaceFrontierError.immutableIdentity
            }
            try dbc.execute(sql: "UPDATE workspaceFrontierSession SET externalID = ?, updatedAt = ? WHERE id = ?",
                            arguments: [externalID, Date.now, id])
            return try WorkspaceFrontierSession.fetchOne(dbc, key: id)!
        }
    }

    /// A reservation, not a send. Save running before attempting delivery. A
    /// provider/storage failure must never cause an automatic retry of prompt.
    public func beginWorkspaceFrontierTurn(sessionID: UUID, prompt: String) throws -> WorkspaceFrontierTurn {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= Self.maximumWorkspaceFrontierPromptCharacters, !prompt.contains("\0") else {
            throw WorkspaceFrontierError.invalidValue
        }
        return try db.queue.write { dbc in
            guard let session = try WorkspaceFrontierSession.fetchOne(dbc, key: sessionID) else { throw WorkspaceFrontierError.sessionNotFound }
            let (chat, policy, packet, generation) = try Self.frontierContext(chatID: session.chatID, in: dbc)
            guard session.provider == .codex, chat.projectID == session.projectID,
                  policy.revision == session.policyRevision, policy.contextRevision == session.contextRevision,
                  packet.promptText == session.reviewedContext, generation == session.chatContextRevision else {
                throw WorkspaceFrontierError.staleContext
            }
            let unresolved = try Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceFrontierTurn WHERE sessionID = ?
                    AND state NOT IN ('completed', 'failed', 'cancelled'))
                """, arguments: [sessionID]) ?? true
            guard !unresolved else { throw WorkspaceFrontierError.unresolvedTurn }
            let id = UUID(), now = Date.now
            try dbc.execute(sql: """
                INSERT INTO workspaceFrontierTurn(id, sessionID, state, promptText, outputText, startedAt)
                VALUES (?, ?, 'prepared', ?, '', ?)
                """, arguments: [id, sessionID, prompt, now])
            try dbc.execute(sql: "UPDATE workspaceFrontierSession SET updatedAt = ? WHERE id = ?", arguments: [now, sessionID])
            try dbc.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ? AND lastActivityAt < ?", arguments: [now, chat.id, now])
            return try WorkspaceFrontierTurn.fetchOne(dbc, key: id)!
        }
    }

    public func workspaceFrontierTurn(id: UUID) throws -> WorkspaceFrontierTurn? {
        try db.queue.read { try WorkspaceFrontierTurn.fetchOne($0, key: id) }
    }

    public static let maximumFrontierFailureReasonCharacters = 300

    /// Saves why a failed or unconfirmed turn ended. Only a terminal failure
    /// carries a reason; a completed or still-running turn never does.
    public func recordWorkspaceFrontierTurnFailure(id: UUID, reason: String) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceFrontierError.invalidValue }
        let bounded = String(trimmed.prefix(Self.maximumFrontierFailureReasonCharacters))
        try db.queue.write { dbc in
            guard let turn = try WorkspaceFrontierTurn.fetchOne(dbc, key: id) else { throw WorkspaceFrontierError.turnNotFound }
            guard [.failed, .outcomeUnknown, .interrupted].contains(turn.state) else {
                throw WorkspaceFrontierError.invalidTransition
            }
            try dbc.execute(sql: "UPDATE workspaceFrontierTurn SET failureReason = ? WHERE id = ?",
                            arguments: [bounded, id])
        }
    }

    public func workspaceFrontierTurnFailureReason(id: UUID) throws -> String? {
        try db.queue.read { try String.fetchOne($0, sql: "SELECT failureReason FROM workspaceFrontierTurn WHERE id = ?", arguments: [id]) }
    }

    public func workspaceFrontierTurns(sessionID: UUID) throws -> [WorkspaceFrontierTurn] {
        try db.queue.read { try WorkspaceFrontierTurn.filter(Column("sessionID") == sessionID)
            .order(Column("startedAt"), Column("id")).fetchAll($0) }
    }

    /// Completion after a requested stop requires an explicit, actual provider
    /// completion acknowledgement; callers must opt in, never infer it from text.
    public func saveWorkspaceFrontierTurn(_ turn: WorkspaceFrontierTurn,
                                         allowCompletedAfterCancellation: Bool = false) throws {
        try db.queue.write { dbc in
            guard let old = try WorkspaceFrontierTurn.fetchOne(dbc, key: turn.id) else { throw WorkspaceFrontierError.turnNotFound }
            guard old.sessionID == turn.sessionID, old.promptText == turn.promptText, old.startedAt == turn.startedAt,
                  old.providerTurnID == nil || old.providerTurnID == turn.providerTurnID else {
                throw WorkspaceFrontierError.immutableIdentity
            }
            if old.isExactly(turn) { return }
            guard !old.state.isTerminal else { throw WorkspaceFrontierError.invalidTransition }
            let allowed: Set<WorkspaceFrontierTurnState>
            switch old.state {
            case .prepared: allowed = [.prepared, .running, .failed, .cancelled, .interrupted]
            case .running: allowed = [.running, .cancellationRequested, .completed, .failed, .cancelled, .outcomeUnknown]
            case .cancellationRequested:
                allowed = allowCompletedAfterCancellation
                    ? [.cancellationRequested, .completed, .failed, .cancelled, .outcomeUnknown]
                    : [.cancellationRequested, .failed, .cancelled, .outcomeUnknown]
            default: allowed = []
            }
            guard allowed.contains(turn.state) else { throw WorkspaceFrontierError.invalidTransition }
            if let providerID = turn.providerTurnID { try Self.validateFrontierIdentifier(providerID) }
            // SQLite Date round-tripping can round the start up by <1 ms.
            // Preserve valid immediate outcomes at that same precision.
            let endedAt = turn.endedAt.map { end in
                end < turn.startedAt && turn.startedAt.timeIntervalSince(end) < 0.001 ? turn.startedAt : end
            }
            guard turn.outputText.count <= 200_000,
                  (turn.inputTokens ?? 0) >= 0, (turn.outputTokens ?? 0) >= 0,
                  turn.state.isTerminal == (turn.endedAt != nil),
                  endedAt.map({ $0 >= turn.startedAt }) ?? true,
                  turn.state != .completed || turn.providerTurnID != nil else { throw WorkspaceFrontierError.invalidValue }
            try dbc.execute(sql: """
                UPDATE workspaceFrontierTurn SET state = ?, outputText = ?, providerTurnID = ?,
                    inputTokens = ?, outputTokens = ?, endedAt = ? WHERE id = ?
                """, arguments: [turn.state.rawValue, turn.outputText, turn.providerTurnID,
                    turn.inputTokens, turn.outputTokens, endedAt, turn.id])
            try dbc.execute(sql: "UPDATE workspaceFrontierSession SET updatedAt = ? WHERE id = ?", arguments: [Date.now, turn.sessionID])
        }
    }

    /// Explicit startup reconciliation only; never called by initialization.
    /// Reserved input is interrupted; potentially delivered input stays unknown.
    @discardableResult
    public func reconcileUnfinishedWorkspaceFrontierTurns(now: Date = .now) throws -> Int {
        try db.queue.write { dbc in
            try dbc.execute(sql: """
                UPDATE workspaceFrontierTurn SET state = CASE WHEN state = 'prepared' THEN 'interrupted' ELSE 'outcomeUnknown' END,
                    endedAt = MAX(startedAt, ?) WHERE state IN ('prepared', 'running', 'cancellationRequested')
                """, arguments: [now])
            return dbc.changesCount
        }
    }

    private static func validateFrontierIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkspaceFrontierError.invalidValue
        }
    }

    private static func frontierContext(chatID: UUID, in dbc: Database) throws
        -> (WorkspaceChat, WorkspacePolicyRecord, WorkspaceContextPacket, Int) {
        guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.archivedAt == nil,
              let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible else {
            throw WorkspaceFrontierError.unavailableChat
        }
        let review = try policyReview(projectID: project.id, in: dbc)
        guard let policy = try policyRecord(review: review, in: dbc), policy.status == .reviewed,
              policy.allowedProviders.contains(.codex), !policy.allowsTools, !policy.allowsCloudExecution,
              !policy.allowsGlobalRAG else { throw WorkspaceFrontierError.reviewRequired }
        guard let generation = try Int.fetchOne(dbc, sql: "SELECT revision FROM workspaceFrontierContextState WHERE chatID = ?",
                                                arguments: [chatID]), generation >= 0 else { throw WorkspaceFrontierError.staleContext }
        return (chat, policy, try workspaceContextPacket(chatID: chatID, in: dbc), generation)
    }
}

private extension WorkspaceFrontierTurn {
    func isExactly(_ other: Self) -> Bool {
        // GRDB persists Date values to milliseconds. An identical terminal
        // checkpoint must stay idempotent after that precision round trip.
        var normalized = other
        if let saved = endedAt, let supplied = other.endedAt,
           abs(saved.timeIntervalSince(supplied)) < 0.001 { normalized.endedAt = saved }
        return self == normalized
    }
}
