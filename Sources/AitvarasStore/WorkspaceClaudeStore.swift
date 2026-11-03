import Foundation
import GRDB
import AitvarasCore

public enum WorkspaceClaudeError: Error, LocalizedError, Sendable, Equatable {
    case unavailableChat, reviewRequired, staleContext, sessionNotFound, turnNotFound
    case immutableIdentity, importedIdentity, unresolvedTurn, invalidValue, invalidTransition

    public var errorDescription: String? {
        switch self {
        case .unavailableChat: "Choose an active chat in a visible project."
        case .reviewRequired: "Review the current project policy and allow Claude first."
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

/// Claude Code sessions are app-owned and partitioned by the selected profile.
/// Imported history is read-only; account sharing does not imply claude.ai sync.
/// Review covers the exact metadata text, not files, tools, or general cloud use.
public struct WorkspaceClaudeSession: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceClaudeSession"
    public let id: UUID
    public let projectID: UUID
    public let chatID: UUID
    public let profileNamespace: String
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

public struct WorkspaceClaudeTurn: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceClaudeTurn"
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
    public var failureReason: String?
}

extension Stores {
    public static let maximumWorkspaceClaudePromptCharacters = 24_000

    /// Atomic approval CAS. This only records consent; it never calls a provider.
    public func createWorkspaceClaudeSession(chatID: UUID, profileNamespace: String, model: String, effort: String?,
                                               expectedPolicyRevision: Int, reviewedContext: String) throws -> WorkspaceClaudeSession {
        try Self.validateClaudeIdentifier(profileNamespace)
        try Self.validateClaudeIdentifier(model)
        if let effort { try Self.validateClaudeIdentifier(effort) }
        return try db.queue.write { dbc in
            let (chat, policy, packet, generation) = try Self.claudeContext(chatID: chatID, in: dbc)
            guard policy.revision == expectedPolicyRevision, packet.promptText == reviewedContext else {
                throw WorkspaceClaudeError.staleContext
            }
            let id = UUID(), now = Date.now
            try dbc.execute(sql: """
                INSERT INTO workspaceClaudeSession
                (id, projectID, chatID, profileNamespace, reviewedContext, policyRevision, contextRevision,
                 chatContextRevision, model, effort, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, chat.projectID, chatID, profileNamespace, reviewedContext, policy.revision,
                    policy.contextRevision, generation, model, effort, now, now])
            return try WorkspaceClaudeSession.fetchOne(dbc, key: id)!
        }
    }

    public func workspaceClaudeSessions(chatID: UUID, profileNamespace: String) throws -> [WorkspaceClaudeSession] {
        try db.queue.read { try WorkspaceClaudeSession.filter(Column("chatID") == chatID)
            .filter(Column("profileNamespace") == profileNamespace)
            .order(Column("createdAt"), Column("id")).fetchAll($0) }
    }

    public func workspaceClaudeSession(id: UUID) throws -> WorkspaceClaudeSession? {
        try db.queue.read { try WorkspaceClaudeSession.fetchOne($0, key: id) }
    }

    /// Bind only the ID returned by creation of a new provider session. Existing
    /// imported identities are explicitly refused, even in the same chat.
    @discardableResult
    public func bindWorkspaceClaudeSession(id: UUID, externalID: String) throws -> WorkspaceClaudeSession {
        try Self.validateClaudeIdentifier(externalID)
        return try db.queue.write { dbc in
            guard let session = try WorkspaceClaudeSession.fetchOne(dbc, key: id) else { throw WorkspaceClaudeError.sessionNotFound }
            if let existing = session.externalID {
                guard existing == externalID else { throw WorkspaceClaudeError.immutableIdentity }
                return session
            }
            guard try WorkspaceSessionLink.filter(Column("provider") == "claude")
                .filter(Column("externalID") == externalID).fetchOne(dbc) == nil else {
                throw WorkspaceClaudeError.importedIdentity
            }
            guard try WorkspaceClaudeSession.filter(Column("profileNamespace") == session.profileNamespace)
                .filter(Column("externalID") == externalID).fetchOne(dbc) == nil else {
                throw WorkspaceClaudeError.immutableIdentity
            }
            try dbc.execute(sql: "UPDATE workspaceClaudeSession SET externalID = ?, updatedAt = ? WHERE id = ?",
                            arguments: [externalID, Date.now, id])
            return try WorkspaceClaudeSession.fetchOne(dbc, key: id)!
        }
    }

    /// A reservation, not a send. Save running before attempting delivery. A
    /// provider/storage failure must never cause an automatic retry of prompt.
    public func beginWorkspaceClaudeTurn(sessionID: UUID, prompt: String) throws -> WorkspaceClaudeTurn {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= Self.maximumWorkspaceClaudePromptCharacters, !prompt.contains("\0") else {
            throw WorkspaceClaudeError.invalidValue
        }
        return try db.queue.write { dbc in
            guard let session = try WorkspaceClaudeSession.fetchOne(dbc, key: sessionID) else { throw WorkspaceClaudeError.sessionNotFound }
            let (chat, policy, packet, generation) = try Self.claudeContext(chatID: session.chatID, in: dbc)
            guard chat.projectID == session.projectID,
                  policy.revision == session.policyRevision, policy.contextRevision == session.contextRevision,
                  packet.promptText == session.reviewedContext, generation == session.chatContextRevision else {
                throw WorkspaceClaudeError.staleContext
            }
            let unresolved = try Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceClaudeTurn WHERE sessionID = ?
                    AND state NOT IN ('completed', 'failed', 'cancelled'))
                """, arguments: [sessionID]) ?? true
            guard !unresolved else { throw WorkspaceClaudeError.unresolvedTurn }
            let id = UUID(), now = Date.now
            try dbc.execute(sql: """
                INSERT INTO workspaceClaudeTurn(id, sessionID, state, promptText, outputText, startedAt)
                VALUES (?, ?, 'prepared', ?, '', ?)
                """, arguments: [id, sessionID, prompt, now])
            try dbc.execute(sql: "UPDATE workspaceClaudeSession SET updatedAt = ? WHERE id = ?", arguments: [now, sessionID])
            try dbc.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ? AND lastActivityAt < ?", arguments: [now, chat.id, now])
            return try WorkspaceClaudeTurn.fetchOne(dbc, key: id)!
        }
    }

    public func workspaceClaudeTurn(id: UUID) throws -> WorkspaceClaudeTurn? {
        try db.queue.read { try WorkspaceClaudeTurn.fetchOne($0, key: id) }
    }

    public static let maximumClaudeFailureReasonCharacters = 300

    /// Saves why a failed or unconfirmed turn ended. Only a terminal failure
    /// carries a reason; a completed or still-running turn never does.
    public func recordWorkspaceClaudeTurnFailure(id: UUID, reason: String) throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceClaudeError.invalidValue }
        let bounded = String(trimmed.prefix(Self.maximumClaudeFailureReasonCharacters))
        try db.queue.write { dbc in
            guard let turn = try WorkspaceClaudeTurn.fetchOne(dbc, key: id) else { throw WorkspaceClaudeError.turnNotFound }
            guard [.failed, .outcomeUnknown, .interrupted].contains(turn.state) else {
                throw WorkspaceClaudeError.invalidTransition
            }
            try dbc.execute(sql: "UPDATE workspaceClaudeTurn SET failureReason = ? WHERE id = ?",
                            arguments: [bounded, id])
        }
    }

    public func workspaceClaudeTurnFailureReason(id: UUID) throws -> String? {
        try db.queue.read { try String.fetchOne($0, sql: "SELECT failureReason FROM workspaceClaudeTurn WHERE id = ?", arguments: [id]) }
    }

    public func workspaceClaudeTurns(sessionID: UUID) throws -> [WorkspaceClaudeTurn] {
        try db.queue.read { try WorkspaceClaudeTurn.filter(Column("sessionID") == sessionID)
            .order(Column("startedAt"), Column("id")).fetchAll($0) }
    }

    /// Completion after a requested stop requires an explicit, actual provider
    /// completion acknowledgement; callers must opt in, never infer it from text.
    public func saveWorkspaceClaudeTurn(_ turn: WorkspaceClaudeTurn,
                                         allowCompletedAfterCancellation: Bool = false) throws {
        try db.queue.write { dbc in
            guard let old = try WorkspaceClaudeTurn.fetchOne(dbc, key: turn.id) else { throw WorkspaceClaudeError.turnNotFound }
            guard old.sessionID == turn.sessionID, old.promptText == turn.promptText, old.startedAt == turn.startedAt,
                  old.providerTurnID == nil || old.providerTurnID == turn.providerTurnID else {
                throw WorkspaceClaudeError.immutableIdentity
            }
            if old.isExactly(turn) { return }
            guard !old.state.isTerminal else { throw WorkspaceClaudeError.invalidTransition }
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
            guard allowed.contains(turn.state) else { throw WorkspaceClaudeError.invalidTransition }
            if let providerID = turn.providerTurnID { try Self.validateClaudeIdentifier(providerID) }
            // SQLite Date round-tripping can round the start up by <1 ms.
            // Preserve valid immediate outcomes at that same precision.
            let endedAt = turn.endedAt.map { end in
                end < turn.startedAt && turn.startedAt.timeIntervalSince(end) < 0.001 ? turn.startedAt : end
            }
            guard turn.outputText.count <= 200_000,
                  (turn.inputTokens ?? 0) >= 0, (turn.outputTokens ?? 0) >= 0,
                  turn.state.isTerminal == (turn.endedAt != nil),
                  endedAt.map({ $0 >= turn.startedAt }) ?? true,
                  turn.state != .completed || turn.providerTurnID != nil,
                  turn.failureReason == nil || [.failed, .outcomeUnknown, .interrupted].contains(turn.state),
                  (turn.failureReason?.count ?? 0) <= Self.maximumClaudeFailureReasonCharacters else { throw WorkspaceClaudeError.invalidValue }
            try dbc.execute(sql: """
                UPDATE workspaceClaudeTurn SET state = ?, outputText = ?, providerTurnID = ?,
                    inputTokens = ?, outputTokens = ?, endedAt = ?, failureReason = ? WHERE id = ?
                """, arguments: [turn.state.rawValue, turn.outputText, turn.providerTurnID,
                    turn.inputTokens, turn.outputTokens, endedAt, turn.failureReason, turn.id])
            try dbc.execute(sql: "UPDATE workspaceClaudeSession SET updatedAt = ? WHERE id = ?", arguments: [Date.now, turn.sessionID])
        }
    }

    /// Explicit startup reconciliation only; never called by initialization.
    /// Reserved input is interrupted; potentially delivered input stays unknown.
    @discardableResult
    public func reconcileUnfinishedWorkspaceClaudeTurns(now: Date = .now) throws -> Int {
        try db.queue.write { dbc in
            try dbc.execute(sql: """
                UPDATE workspaceClaudeTurn SET state = CASE WHEN state = 'prepared' THEN 'interrupted' ELSE 'outcomeUnknown' END,
                    endedAt = MAX(startedAt, ?) WHERE state IN ('prepared', 'running', 'cancellationRequested')
                """, arguments: [now])
            return dbc.changesCount
        }
    }

    private static func validateClaudeIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkspaceClaudeError.invalidValue
        }
    }

    private static func claudeContext(chatID: UUID, in dbc: Database) throws
        -> (WorkspaceChat, WorkspacePolicyRecord, WorkspaceContextPacket, Int) {
        guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.archivedAt == nil,
              let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible else {
            throw WorkspaceClaudeError.unavailableChat
        }
        let review = try policyReview(projectID: project.id, in: dbc)
        guard let policy = try policyRecord(review: review, in: dbc), policy.status == .reviewed,
              policy.allowedProviders.contains(.claude), !policy.allowsTools, !policy.allowsCloudExecution,
              !policy.allowsGlobalRAG else { throw WorkspaceClaudeError.reviewRequired }
        guard let generation = try Int.fetchOne(dbc, sql: "SELECT revision FROM workspaceFrontierContextState WHERE chatID = ?",
                                                arguments: [chatID]), generation >= 0 else { throw WorkspaceClaudeError.staleContext }
        return (chat, policy, try workspaceContextPacket(chatID: chatID, in: dbc), generation)
    }
}

private extension WorkspaceClaudeTurn {
    func isExactly(_ other: Self) -> Bool {
        // GRDB persists Date values to milliseconds. An identical terminal
        // checkpoint must stay idempotent after that precision round trip.
        var normalized = other
        if let saved = endedAt, let supplied = other.endedAt,
           abs(saved.timeIntervalSince(supplied)) < 0.001 { normalized.endedAt = saved }
        return self == normalized
    }
}
