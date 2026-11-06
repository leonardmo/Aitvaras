import Foundation
import GRDB
import AitvarasAgents

extension AgentWorktree: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentWorktree" }
}

extension Stores: AgentWorktreePersistence {
    public func agentGitDirectories(chatID: UUID) throws -> [URL] {
        guard let chat = try workspaceChat(id: chatID) else { throw AgentStoreError.missingChat }
        let folders = try workspaceFolders(projectID: chat.projectID).map { URL(fileURLWithPath: $0.path) }
        let sessions = try db.queue.read { try AgentChatSession.filter(Column("chatID") == chatID).fetchAll($0) }
        return folders + sessions.map { URL(fileURLWithPath: $0.cwd) }
    }
    public func requiresAgentWorktree(chatID: UUID) throws -> Bool {
        try value(forKey: "agent.worktreeRequested.\(chatID.uuidString)") == "true" || agentWorktree(chatID: chatID) != nil
    }
    public func agentWorktree(chatID: UUID) throws -> AgentWorktree? {
        try db.queue.read { try AgentWorktree.fetchOne($0, key: chatID) }
    }
    public func reserveAgentWorktree(_ value: AgentWorktree) throws {
        guard value.state == .creating else { throw AgentStoreError.invalidValue }
        try db.queue.write { db in
            guard let chat = try WorkspaceChat.fetchOne(db, key: value.chatID), chat.projectID == value.projectID else {
                throw AgentStoreError.identityConflict
            }
            // No replace/upsert: a reservation survives failures and restarts.
            try value.insert(db)
        }
    }
    public func finishAgentWorktree(chatID: UUID, state: AgentWorktree.State) throws {
        try db.queue.write { db in
            guard var value = try AgentWorktree.fetchOne(db, key: chatID), value.state == .creating else {
                throw AgentStoreError.identityConflict
            }
            value.state = state; try value.update(db)
        }
    }
}
