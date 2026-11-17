import Foundation
import GRDB
import AitvarasAgents

/// Uses the existing normalized native-identity unique key. Discovery never
/// touches legacy links, revisions, imported evidence or message tables.
public struct AgentNativeSessionStore: Sendable {
    public let db: AitvarasDatabase
    public init(db: AitvarasDatabase) { self.db = db }

    @discardableResult public func discover(_ summaries: [AgentSessionSummary]) throws -> [UUID] {
        try db.queue.write { db in
            let folders = try WorkspaceFolder.fetchAll(db)
            let worktrees = try AgentWorktree.fetchAll(db)
            var result: [UUID] = [], seen: [AgentSessionID: String] = [:]
            for summary in summaries {
                let identity = summary.id
                guard identity.provider != .local, !identity.nativeID.isEmpty, !identity.profile.isEmpty,
                      !identity.host.isEmpty, summary.directory.isFileURL, summary.directory.path.hasPrefix("/"),
                      !summary.directory.path.contains("\0") else { throw AgentStoreError.invalidValue }
                let cwd = Self.path(summary.directory.path)
                if let previous = seen[identity] {
                    guard previous == cwd else { throw AgentNativeHistoryError.identityConflict }
                    continue
                }
                seen[identity] = cwd
                let existing = try AgentChatSession.filter(Column("provider") == identity.provider.rawValue)
                    .filter(Column("host") == identity.host).filter(Column("profile") == identity.profile)
                    .filter(Column("nativeID") == identity.nativeID).fetchOne(db)
                let owned = worktrees.filter { Self.contains(cwd, root: Self.path($0.worktreePath)) }
                guard owned.count <= 1, owned.allSatisfy({ $0.state == .ready }) else {
                    throw AgentNativeHistoryError.identityConflict
                }
                let matches = folders.filter { Self.contains(cwd, root: Self.path($0.path)) }
                let depth = matches.map { Self.path($0.path).count }.max()
                let projects = Set(matches.filter { Self.path($0.path).count == depth }.map(\.projectID))
                guard owned.first != nil || projects.count <= 1 else { throw AgentNativeHistoryError.identityConflict }
                guard let projectID = owned.first?.projectID ?? projects.first else {
                    // An existing identity must not silently drift out of its project.
                    if existing != nil { throw AgentNativeHistoryError.identityConflict }
                    continue
                }
                guard let project = try WorkspaceProject.fetchOne(db, key: projectID) else { throw AgentStoreError.missingChat }
                if let existing {
                    guard let chat = try WorkspaceChat.fetchOne(db, key: existing.chatID), chat.projectID == projectID,
                          owned.first.map({ $0.chatID == chat.id }) ?? true,
                          Self.path(existing.cwd) == cwd else { throw AgentNativeHistoryError.identityConflict }
                    result.append(chat.id); continue
                }
                let chat: WorkspaceChat
                if let owned = owned.first {
                    guard let value = try WorkspaceChat.fetchOne(db, key: owned.chatID), value.projectID == projectID else {
                        throw AgentNativeHistoryError.identityConflict
                    }
                    chat = value
                    if let session = try AgentChatSession.filter(Column("chatID") == chat.id)
                        .filter(Column("provider") == identity.provider.rawValue).fetchOne(db) {
                        guard session.sessionID == nil, Self.path(session.cwd) == cwd,
                              try AgentJournalTurn.filter(Column("sessionID") == session.id)
                                .filter(Column("state") == AgentJournalState.running.rawValue).fetchCount(db) == 0 else {
                            throw AgentNativeHistoryError.identityConflict
                        }
                        var bound = session; bound.sessionID = identity
                        try bound.update(db); result.append(chat.id); continue
                    }
                } else {
                    let title = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let conversation = Conversation(title: title.isEmpty ? "Chat" : String(title.prefix(200)))
                    try conversation.insert(db)
                    chat = WorkspaceChat(projectID: projectID, localConversationID: conversation.id, title: conversation.title)
                    try chat.insert(db)
                }
                var session = AgentChatSession(chatID: chat.id, provider: identity.provider, cwd: cwd,
                                               model: "default", instructions: project.instructions)
                session.sessionID = identity
                session.additionalRootsJSON = try owned.first?.additionalRootsJSON ?? String(decoding: JSONEncoder().encode(
                    folders.filter { $0.projectID == projectID && Self.path($0.path) != cwd }.map(\.path)), as: UTF8.self)
                try session.insert(db)
                // New native chats open on their provider. Existing worktree
                // chats retain the user's selection and other local metadata.
                if owned.isEmpty {
                    try db.execute(sql: "INSERT INTO kv(key, value) VALUES (?, ?)",
                        arguments: ["agent.provider.\(chat.id.uuidString)", identity.provider.rawValue])
                }
                result.append(chat.id)
            }
            return Array(Set(result)).sorted { $0.uuidString < $1.uuidString }
        }
    }
    private static func path(_ value: String) -> String {
        URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

extension Stores: AgentNativeSessionPersistence {
    public func discoverAgentNativeSessions(_ sessions: [AgentSessionSummary]) throws -> [UUID] {
        try AgentNativeSessionStore(db: db).discover(sessions)
    }
}
