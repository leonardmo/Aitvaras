import Foundation
import GRDB
import AitvarasCore

extension Stores {
    /// Record the app user UUID before delivery, or an actual top-level SDK
    /// assistant UUID on receipt. Stream-event/result UUIDs are not message IDs.
    public func recordWorkspaceClaudeMessageIdentity(turnID: UUID, externalID: String, role: String) throws {
        guard let uuid = UUID(uuidString: externalID), ["user", "assistant"].contains(role) else {
            throw WorkspaceClaudeError.invalidValue
        }
        let canonicalID = uuid.uuidString
        try db.queue.write { dbc in
            guard let turn = try WorkspaceClaudeTurn.fetchOne(dbc, key: turnID) else { throw WorkspaceClaudeError.turnNotFound }
            if role == "user", uuid != turn.id { throw WorkspaceClaudeError.immutableIdentity }
            if let projected = try Self.claudeProjection(sessionID: turn.sessionID, in: dbc)?.messages.first(where: { $0.id == canonicalID }),
               projected.role != role { throw WorkspaceClaudeError.immutableIdentity }
            if let row = try Row.fetchOne(dbc, sql: "SELECT turnID, role FROM workspaceClaudeMessageIdentity WHERE sessionID = ? AND externalID = ?",
                                         arguments: [turn.sessionID, canonicalID]) {
                guard (row["turnID"] as UUID) == turnID, (row["role"] as String) == role else { throw WorkspaceClaudeError.immutableIdentity }
                return
            }
            guard role == "user" ? turn.state == .prepared : [.running, .cancellationRequested].contains(turn.state) else {
                throw WorkspaceClaudeError.invalidTransition
            }
            try dbc.execute(sql: "INSERT INTO workspaceClaudeMessageIdentity(sessionID, externalID, turnID, role) VALUES (?, ?, ?, ?)",
                            arguments: [turn.sessionID, canonicalID, turnID, role])
        }
    }

    /// Atomic publication of a complete read-only observation. Prior snapshots
    /// remain immutable audit evidence; this never edits the execution journal.
    public func replaceWorkspaceClaudeProjection(sessionID: UUID, expectedProfileNamespace: String,
                                                 snapshot: ClaudeOwnedHistorySnapshot) throws {
        guard snapshot.complete, snapshot.observedAt.timeIntervalSince1970.isFinite,
              snapshot.messages.count <= 5_000, let externalID = UUID(uuidString: snapshot.sessionID),
              snapshot.profileNamespace == expectedProfileNamespace else { throw WorkspaceClaudeError.invalidValue }
        var seen = Set<UUID>(), characters = 0
        let messages = try snapshot.messages.map { message -> ClaudeOwnedHistoryMessage in
            guard let id = UUID(uuidString: message.id), seen.insert(id).inserted,
                  ["user", "assistant"].contains(message.role), !message.text.contains("\0"),
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  message.text.count <= 200_000 else { throw WorkspaceClaudeError.invalidValue }
            characters += message.text.count
            guard characters <= 10_000_000 else { throw WorkspaceClaudeError.invalidValue }
            return .init(id: id.uuidString, role: message.role, text: message.text)
        }
        let normalized = ClaudeOwnedHistorySnapshot(sessionID: externalID.uuidString,
            profileNamespace: snapshot.profileNamespace, messages: messages, complete: true, observedAt: snapshot.observedAt)
        let json = String(decoding: try JSONEncoder().encode(normalized), as: UTF8.self)
        try db.queue.write { dbc in
            guard let session = try WorkspaceClaudeSession.fetchOne(dbc, key: sessionID) else { throw WorkspaceClaudeError.sessionNotFound }
            guard session.profileNamespace == expectedProfileNamespace,
                  session.externalID.flatMap(UUID.init(uuidString:)) == externalID else { throw WorkspaceClaudeError.immutableIdentity }
            if let old = try Self.claudeProjection(sessionID: sessionID, in: dbc) {
                guard normalized.observedAt >= old.observedAt else { throw WorkspaceClaudeError.staleContext }
                // An unchanged foreground check must not append another full
                // transcript. Preserve the last changed observation as evidence.
                if normalized.messages == old.messages { return }
            }
            // A UUID's role cannot change even if it disappeared in an earlier
            // refresh and later returned on the canonical conversation branch.
            let historicalRoles = try Row.fetchAll(dbc, sql: """
                SELECT DISTINCT json_extract(j.value, '$.id') AS externalID, json_extract(j.value, '$.role') AS role
                FROM workspaceClaudeHistoryObservation o, json_each(o.snapshotJSON, '$.messages') j WHERE o.sessionID = ?
                """, arguments: [sessionID])
            let oldRoles = Dictionary(uniqueKeysWithValues: historicalRoles.map { ($0["externalID"] as String, $0["role"] as String) })
            guard messages.allSatisfy({ oldRoles[$0.id] == nil || oldRoles[$0.id] == $0.role }) else { throw WorkspaceClaudeError.immutableIdentity }
            let identities = try Row.fetchAll(dbc, sql: "SELECT externalID, role FROM workspaceClaudeMessageIdentity WHERE sessionID = ?", arguments: [sessionID])
            let roles = Dictionary(uniqueKeysWithValues: identities.map { ($0["externalID"] as String, $0["role"] as String) })
            guard messages.allSatisfy({ roles[$0.id] == nil || roles[$0.id] == $0.role }) else { throw WorkspaceClaudeError.immutableIdentity }
            try dbc.execute(sql: "INSERT INTO workspaceClaudeHistoryObservation(sessionID, observedAt, snapshotJSON) VALUES (?, ?, ?)",
                            arguments: [sessionID, normalized.observedAt, json])
        }
    }

    public func workspaceClaudeProjection(sessionID: UUID) throws -> ClaudeOwnedHistorySnapshot? {
        try db.queue.read { try Self.claudeProjection(sessionID: sessionID, in: $0) }
    }

    static func claudeProjection(sessionID: UUID, in dbc: Database) throws -> ClaudeOwnedHistorySnapshot? {
        guard let json = try String.fetchOne(dbc, sql: "SELECT snapshotJSON FROM workspaceClaudeHistoryObservation WHERE sessionID = ? ORDER BY id DESC LIMIT 1",
                                            arguments: [sessionID]) else { return nil }
        return try JSONDecoder().decode(ClaudeOwnedHistorySnapshot.self, from: Data(json.utf8))
    }

    /// Unattributed text is visible evidence, not a completed turn. Exact
    /// attributed IDs are represented by their existing journal entries instead.
    static func claudeObservedTimeline(chatID: UUID, in dbc: Database) throws -> [WorkspaceChatTimelineEntry] {
        let sessions = try WorkspaceClaudeSession.filter(Column("chatID") == chatID)
            .order(Column("createdAt"), Column("id")).fetchAll(dbc)
        var entries: [WorkspaceChatTimelineEntry] = []
        for session in sessions {
            guard let snapshot = try claudeProjection(sessionID: session.id, in: dbc) else { continue }
            let attributed = Set(try String.fetchAll(dbc, sql: "SELECT externalID FROM workspaceClaudeMessageIdentity WHERE sessionID = ?",
                                                     arguments: [session.id]))
            for message in snapshot.messages where !attributed.contains(message.id) {
                entries.append(.init(id: "claude:message:\(session.id.uuidString):\(message.id)",
                    role: message.role, text: message.text, timestamp: snapshot.observedAt, provider: "claude",
                    state: .outcomeUnknown, sourceThread: WorkspaceThreadKey.claudeSession(session.id), observedAt: snapshot.observedAt))
            }
        }
        return entries
    }
}
