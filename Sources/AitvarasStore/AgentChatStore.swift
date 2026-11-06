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

    public func session(chatID: UUID, provider: AgentProvider) throws -> AgentChatSession? {
        try db.queue.read { try AgentChatSession.filter(Column("chatID") == chatID)
            .filter(Column("provider") == provider.rawValue).fetchOne($0) }
    }

    public func saveSession(_ value: AgentChatSession) throws {
        guard value.cwd.hasPrefix("/"), !value.cwd.contains("\0"), !value.model.isEmpty,
              (value.host == nil && value.profile == nil && value.nativeID == nil) || value.sessionID != nil else {
            throw AgentStoreError.invalidValue
        }
        guard let roots = try? JSONDecoder().decode([String].self, from: Data(value.additionalRootsJSON.utf8)),
              roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw AgentStoreError.invalidValue }
        try db.queue.write { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: value.chatID) != nil else { throw AgentStoreError.missingChat }
            if let old = try AgentChatSession.fetchOne(dbc, key: value.id) {
                guard old.chatID == value.chatID, old.provider == value.provider else { throw AgentStoreError.identityConflict }
            }
            try value.save(dbc)
        }
    }

    public func entries(chatID: UUID) throws -> [AgentTranscriptEntry] {
        try db.queue.read { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw AgentStoreError.missingChat }
            return try AgentTranscriptEntry.filter(Column("chatID") == chatID).order(Column("position")).fetchAll(dbc)
        }
    }

    /// Allocate order transactionally. Repeat native messages update the same row.
    @discardableResult public func saveEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry {
        try db.queue.write { dbc in
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
    public func agentSession(chatID: UUID, provider: AgentProvider) throws -> AgentChatSession? {
        try AgentChatStore(db: db).session(chatID: chatID, provider: provider)
    }
    public func saveAgentSession(_ session: AgentChatSession) throws { try AgentChatStore(db: db).saveSession(session) }
    public func agentEntries(chatID: UUID) throws -> [AgentTranscriptEntry] { try AgentChatStore(db: db).entries(chatID: chatID) }
    public func saveAgentEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry { try AgentChatStore(db: db).saveEntry(entry) }
}
