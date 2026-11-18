import Foundation
import GRDB
import AitvarasAgents

// The backend module owns storage-neutral values; this module adds their SQL mapping.
extension AgentChatSession: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentChatSession" }
}
extension AgentTranscriptEntry: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentTranscriptEntry" }
}

public enum AgentStoreError: Error, Sendable { case missingChat, missingSession, missingTurn, identityConflict, invalidValue }

public struct AgentChatStore: Sendable {
    public let db: AitvarasDatabase
    public init(db: AitvarasDatabase) { self.db = db }

    public func session(chatID: UUID, provider: AgentProvider, profile: String = "default") throws -> AgentChatSession? {
        try db.queue.read { try AgentChatSession.filter(Column("chatID") == chatID)
            .filter(Column("provider") == provider.rawValue).filter(Column("providerProfile") == profile).fetchOne($0) }
    }

    public func saveSession(_ value: AgentChatSession) throws {
        guard (value.provider == .claude || value.providerProfile == "default"),
              value.providerProfile == "default" || UUID(uuidString: value.providerProfile) != nil,
              value.providerProfile == "default" || value.sessionID == nil || value.sessionID?.profile == value.providerProfile,
              value.cwd.hasPrefix("/"), !value.cwd.contains("\0"), !value.model.isEmpty,
              (value.host == nil && value.profile == nil && value.nativeID == nil) || value.sessionID != nil else {
            throw AgentStoreError.invalidValue
        }
        guard let roots = try? JSONDecoder().decode([String].self, from: Data(value.additionalRootsJSON.utf8)),
              roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw AgentStoreError.invalidValue }
        if let origin = value.forkOrigin {
            guard value.provider == .claude, origin.native.provider == .claude,
                  origin.chatID != value.chatID, origin.sessionID != value.id,
                  UUID(uuidString: origin.native.nativeID) != nil,
                  UUID(uuidString: origin.assistantMessageID) != nil,
                  (origin.pending ? value.sessionID == nil : value.sessionID.flatMap({ UUID(uuidString: $0.nativeID) }) != nil
                    && value.sessionID.flatMap({ UUID(uuidString: $0.nativeID) }) != UUID(uuidString: origin.native.nativeID)) else { throw AgentStoreError.invalidValue }
        }
        try db.queue.write { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: value.chatID) != nil else { throw AgentStoreError.missingChat }
            if value.providerProfile != "default" {
                guard let id = UUID(uuidString: value.providerProfile),
                      try AgentProviderProfile.fetchOne(dbc, key: id) != nil else { throw AgentStoreError.invalidValue }
            }
            if let old = try AgentChatSession.fetchOne(dbc, key: value.id) {
                guard old.chatID == value.chatID, old.provider == value.provider, old.providerProfile == value.providerProfile else { throw AgentStoreError.identityConflict }
            }
            try value.save(dbc)
        }
    }

    public func entries(chatID: UUID) throws -> [AgentTranscriptEntry] {
        try db.queue.read { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw AgentStoreError.missingChat }
            let entries = try AgentTranscriptEntry.filter(Column("chatID") == chatID)
                .filter(Column("isActive") == true).order(Column("position")).fetchAll(dbc)
            return try Stores.agentTimeline(chatID: chatID, entries: entries, includeImports: true, in: dbc)
        }
    }

    /// Allocate order transactionally. Repeat native messages update the same row.
    @discardableResult public func saveEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry {
        // Derived legacy rows must never become a second persisted copy.
        guard !entry.isLegacyProjection else { throw AgentStoreError.invalidValue }
        return try db.queue.write { dbc in
            var value = entry
            guard try WorkspaceChat.fetchOne(dbc, key: value.chatID) != nil else { throw AgentStoreError.missingChat }
            if let sessionID = value.sessionID {
                guard let session = try AgentChatSession.fetchOne(dbc, key: sessionID),
                      session.chatID == value.chatID, session.provider == value.provider else { throw AgentStoreError.identityConflict }
            } else if value.nativeMessageID != nil { throw AgentStoreError.invalidValue }
            if let nativeID = value.nativeMessageID, let sessionID = value.sessionID,
               let old = try AgentTranscriptEntry.filter(Column("sessionID") == sessionID)
                .filter(Column("nativeMessageID") == nativeID).fetchOne(dbc) {
                value.id = old.id
            }
            if let old = try AgentTranscriptEntry.fetchOne(dbc, key: value.id) {
                guard old.chatID == value.chatID, old.provider == value.provider, old.sessionID == value.sessionID,
                      old.nativeMessageID == nil || old.nativeMessageID == value.nativeMessageID else { throw AgentStoreError.identityConflict }
                value.position = old.position
            } else {
                let last = try AgentTranscriptEntry.filter(Column("chatID") == value.chatID)
                    .order(Column("position").desc).fetchOne(dbc)
                value.position = (last?.position ?? -1) + 1
            }
            try value.save(dbc)
            return value
        }
    }
}

extension Stores: AgentSessionPersistence {
    public func agentProjectID(chatID: UUID) throws -> UUID? { try workspaceChat(id: chatID)?.projectID }
    public func requireAgentChatAvailable(chatID: UUID) throws {
        try db.queue.read { dbc in
            guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.archivedAt == nil,
                  let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible else {
                throw AgentSessionManagerError.chatUnavailable
            }
        }
    }
    public func renameAgentChat(chatID: UUID, title: String) throws { try renameWorkspaceChat(id: chatID, title: title) }
    public func archiveAgentChat(chatID: UUID, archived: Bool) throws { try setWorkspaceChatArchived(id: chatID, archived: archived) }
    public func agentSession(chatID: UUID, provider: AgentProvider) throws -> AgentChatSession? {
        try AgentChatStore(db: db).session(chatID: chatID, provider: provider,
            profile: provider == .claude ? selectedClaudeProfile(chatID: chatID) : "default")
    }
    public func saveAgentSession(_ session: AgentChatSession) throws { try AgentChatStore(db: db).saveSession(session) }
    /// Reorder the live projection after Claude coalesces queued inputs. IDs
    /// and native identities stay stable; unrelated rows keep their positions.
    public func orderAgentEntries(chatID: UUID, ids: [UUID]) throws {
        let selectedIDs = Set(ids)
        guard selectedIDs.count == ids.count else { throw AgentStoreError.invalidValue }
        try db.queue.write { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw AgentStoreError.missingChat }
            let rows = try AgentTranscriptEntry.filter(Column("chatID") == chatID)
                .filter(Column("isActive") == true).order(Column("position")).fetchAll(dbc)
            let selected = rows.filter { selectedIDs.contains($0.id) }
            guard selected.count == ids.count else { throw AgentStoreError.identityConflict }
            let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            let maximum = try AgentTranscriptEntry.filter(Column("chatID") == chatID)
                .order(Column("position").desc).fetchOne(dbc)?.position ?? 0
            guard maximum < Int.max - selected.count - 1 else { throw AgentStoreError.invalidValue }
            // Move out of the UNIQUE(chatID, position) range before swapping.
            for (offset, row) in selected.enumerated() {
                var temporary = row
                temporary.position = maximum + offset + 1
                try temporary.update(dbc)
            }
            for (id, position) in zip(ids, selected.map(\.position)) {
                var entry = byID[id]!
                entry.position = position
                try entry.update(dbc)
            }
        }
    }
    public func agentEntries(chatID: UUID) throws -> [AgentTranscriptEntry] { try AgentChatStore(db: db).entries(chatID: chatID) }
    public func saveAgentEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry { try AgentChatStore(db: db).saveEntry(entry) }
}
