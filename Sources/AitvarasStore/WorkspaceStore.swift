import Foundation
import GRDB

public enum WorkspaceFolderAccess: String, Codable, Sendable, CaseIterable { case readOnly, readWrite }
public enum WorkspaceChatKind: String, Codable, Sendable, CaseIterable { case primary, temporary }
public enum WorkspaceProjectProvider: String, Codable, Sendable, CaseIterable { case claude, codex }
public enum WorkspaceSessionProvider: String, Codable, Sendable, CaseIterable { case claude, codex, local }

public enum WorkspaceStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidValue(String), projectNotFound, chatNotFound, conversationNotFound
    case conversationAlreadyAssigned, immutableIdentity, linkAlreadyAssigned

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let reason): "Workspace was not saved: \(reason)"
        case .projectNotFound: "This project no longer exists."
        case .chatNotFound: "This chat no longer exists."
        case .conversationNotFound: "This conversation no longer exists."
        case .conversationAlreadyAssigned: "This conversation already belongs to a workspace chat."
        case .immutableIdentity: "An existing workspace identity cannot be reassigned."
        case .linkAlreadyAssigned: "This provider identity is already linked elsewhere."
        }
    }
}

public struct WorkspaceProject: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceProject"
    public var id: UUID
    public var title: String
    public var instructions: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isVisible: Bool
    public var allowsCloud: Bool
    public init(id: UUID = UUID(), title: String, instructions: String = "", createdAt: Date = .now,
                updatedAt: Date = .now, isVisible: Bool = true, allowsCloud: Bool = false) {
        self.id = id; self.title = title; self.instructions = instructions
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.isVisible = isVisible; self.allowsCloud = allowsCloud
    }
}

public struct WorkspaceFolderDraft: Codable, Sendable, Equatable {
    public var path: String
    public var access: WorkspaceFolderAccess
    public init(path: String, access: WorkspaceFolderAccess = .readOnly) {
        self.path = path; self.access = access
    }
}

public struct WorkspaceFolder: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public typealias Access = WorkspaceFolderAccess
    public static let databaseTableName = "workspaceFolder"
    public var id: UUID
    public var projectID: UUID
    public var path: String
    public var access: WorkspaceFolderAccess
    public init(id: UUID = UUID(), projectID: UUID, path: String, access: WorkspaceFolderAccess = .readOnly) {
        self.id = id; self.projectID = projectID; self.path = path; self.access = access
    }
}

public struct WorkspaceChat: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public typealias Kind = WorkspaceChatKind
    public static let databaseTableName = "workspaceChat"
    public var id: UUID
    public var projectID: UUID
    public var localConversationID: UUID
    public var title: String
    public var purpose: String
    public var kind: WorkspaceChatKind
    public var createdAt: Date
    public var lastActivityAt: Date
    public var archivedAt: Date?
    public init(id: UUID = UUID(), projectID: UUID, localConversationID: UUID, title: String,
                purpose: String = "", kind: WorkspaceChatKind = .primary, createdAt: Date = .now,
                lastActivityAt: Date = .now, archivedAt: Date? = nil) {
        self.id = id; self.projectID = projectID; self.localConversationID = localConversationID
        self.title = title; self.purpose = purpose; self.kind = kind
        self.createdAt = createdAt; self.lastActivityAt = lastActivityAt; self.archivedAt = archivedAt
    }
}

public struct WorkspaceProjectLink: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceProjectLink"
    public var id: UUID
    public var projectID: UUID
    public var provider: WorkspaceProjectProvider
    public var externalID: String
    public var hostID: String
    public var displayName: String
    public var sourceRoot: String?
    public init(id: UUID = UUID(), projectID: UUID, provider: WorkspaceProjectProvider, externalID: String,
                hostID: String = "local", displayName: String, sourceRoot: String? = nil) {
        self.id = id; self.projectID = projectID; self.provider = provider
        self.externalID = externalID; self.hostID = hostID; self.displayName = displayName; self.sourceRoot = sourceRoot
    }
}

public struct WorkspaceSessionLink: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceSessionLink"
    public var id: UUID
    public var chatID: UUID
    public var provider: WorkspaceSessionProvider
    public var externalID: String
    public var hostID: String
    public var displayName: String
    public var lastSyncedAt: Date?
    public init(id: UUID = UUID(), chatID: UUID, provider: WorkspaceSessionProvider, externalID: String,
                hostID: String = "local", displayName: String, lastSyncedAt: Date? = nil) {
        self.id = id; self.chatID = chatID; self.provider = provider
        self.externalID = externalID; self.hostID = hostID; self.displayName = displayName; self.lastSyncedAt = lastSyncedAt
    }
}

/// One recent chat together with the project that owns it.
public struct RecentWorkspaceChat: Sendable, Equatable, Identifiable {
    public var chat: WorkspaceChat
    public var project: WorkspaceProject
    public var id: UUID { chat.id }
}

extension Stores {
    public static let maximumWorkspaceTitleCharacters = 200
    public static let maximumWorkspaceInstructionsCharacters = 20_000
    public static let workspaceTemporaryChatLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Metadata only: saving folders or instructions grants no filesystem,
    /// tool, model, indexing, or cloud permission.
    @discardableResult
    public func createWorkspaceProject(title: String, instructions: String = "",
                                       folders: [WorkspaceFolderDraft] = []) throws -> WorkspaceProject {
        let project = WorkspaceProject(title: try Self.workspaceName(title), instructions: instructions)
        try Self.validateWorkspaceText(instructions, maximum: Self.maximumWorkspaceInstructionsCharacters)
        let normalized = try Self.validatedWorkspaceFolders(folders, projectID: project.id)
        return try db.queue.write { dbc in
            try project.insert(dbc)
            for folder in normalized { try folder.insert(dbc) }
            return project
        }
    }

    public func workspaceProjects(includeHidden: Bool = true) throws -> [WorkspaceProject] {
        try db.queue.read { dbc in
            var query = WorkspaceProject.all()
            if !includeHidden { query = query.filter(Column("isVisible") == true) }
            return try query.order(Column("createdAt"), Column("id")).fetchAll(dbc)
        }
    }

    public func workspaceProject(id: UUID) throws -> WorkspaceProject? {
        try db.queue.read { try WorkspaceProject.fetchOne($0, key: id) }
    }

    public func saveWorkspaceProject(_ project: WorkspaceProject) throws {
        var value = project
        value.title = try Self.workspaceName(value.title)
        try Self.validateWorkspaceText(value.instructions, maximum: Self.maximumWorkspaceInstructionsCharacters)
        try db.queue.write { dbc in
            guard let existing = try WorkspaceProject.fetchOne(dbc, key: value.id) else { throw WorkspaceStoreError.projectNotFound }
            value.createdAt = existing.createdAt
            value.updatedAt = .now
            try value.update(dbc)
        }
    }

    public func workspaceFolders(projectID: UUID) throws -> [WorkspaceFolder] {
        try db.queue.read { dbc in
            try Self.requireWorkspaceProject(projectID, in: dbc)
            return try WorkspaceFolder.filter(Column("projectID") == projectID).order(Column("path")).fetchAll(dbc)
        }
    }

    /// One explicit Save approves exactly the displayed project settings. The
    /// metadata and policy share a transaction; a stale editor changes nothing.
    @discardableResult
    public func saveWorkspaceProjectSettings(projectID: UUID, title: String, instructions: String,
        folders: [WorkspaceFolderDraft], allowedProviders: [WorkspaceSessionProvider],
        expectedContextRevision: Int, expectedPolicyRevision: Int?, expectedProjectTitle: String,
        allowCodexFileRead: Bool = false, allowClaudeFileRead: Bool = false) throws -> WorkspacePolicyRecord {
        let title = try Self.workspaceName(title)
        try Self.validateWorkspaceText(instructions, maximum: Self.maximumWorkspaceInstructionsCharacters)
        var values = try Self.validatedWorkspaceFolders(folders, projectID: projectID)
        return try db.queue.write { dbc in
            let before = try Self.policyReview(projectID: projectID, in: dbc)
            guard before.revision == expectedContextRevision,
                  try Self.policyRecord(review: before, in: dbc)?.revision == expectedPolicyRevision else {
                throw WorkspacePolicyError.staleReview
            }
            guard var project = try WorkspaceProject.fetchOne(dbc, key: projectID) else { throw WorkspaceStoreError.projectNotFound }
            guard project.title == expectedProjectTitle else { throw WorkspacePolicyError.staleReview }
            project.title = title; project.instructions = instructions; project.updatedAt = .now
            try project.update(dbc)
            for index in values.indices {
                if let old = before.folders.first(where: { $0.path == values[index].path }) { values[index].id = old.id }
            }
            if values.sorted(by: { $0.path < $1.path }) != before.folders.sorted(by: { $0.path < $1.path }) {
                try WorkspaceFolder.filter(Column("projectID") == projectID).deleteAll(dbc)
                for value in values { try value.insert(dbc) }
            }
            let updated = try Self.policyReview(projectID: projectID, in: dbc)
            let policy = try Self.saveWorkspacePolicy(projectID: projectID, allowedProviders: allowedProviders,
                expectedRevision: updated.revision, in: dbc)
            let key = "workspace.project.\(projectID.uuidString).codexFileReadRevision"
            if allowCodexFileRead && allowedProviders.contains(.codex) && !updated.folders.isEmpty {
                try dbc.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [key, String(policy.revision)])
            } else {
                try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
            let claudeKey = "workspace.project.\(projectID.uuidString).claudeFileReadRevision"
            if allowClaudeFileRead && allowedProviders.contains(.claude) && !updated.folders.isEmpty {
                try dbc.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: [claudeKey, String(policy.revision)])
            } else {
                try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [claudeKey])
            }
            return try Self.policyRecord(review: updated, in: dbc)!
        }
    }

    public func replaceWorkspaceFolders(projectID: UUID, folders: [WorkspaceFolderDraft], expectedPolicyRevision: Int? = nil) throws {
        var values = try Self.validatedWorkspaceFolders(folders, projectID: projectID)
        try db.queue.write { dbc in
            try Self.requireWorkspaceProject(projectID, in: dbc)
            if let expectedPolicyRevision {
                let current = try Int.fetchOne(dbc, sql: "SELECT revision FROM workspacePolicyState WHERE projectID = ?", arguments: [projectID])
                guard current == expectedPolicyRevision else { throw WorkspacePolicyError.staleReview }
            }
            let existing = try WorkspaceFolder.filter(Column("projectID") == projectID).fetchAll(dbc)
            for index in values.indices {
                if let old = existing.first(where: { $0.path == values[index].path }) { values[index].id = old.id }
            }
            try WorkspaceFolder.filter(Column("projectID") == projectID).deleteAll(dbc)
            for value in values { try value.insert(dbc) }
        }
    }

    @discardableResult
    public func createWorkspaceChat(projectID: UUID, title: String, kind: WorkspaceChatKind = .primary,
                                    purpose: String = "", existingConversationID: UUID? = nil) throws -> WorkspaceChat {
        let title = try Self.workspaceName(title)
        try Self.validateWorkspaceText(purpose, maximum: 2_000)
        return try db.queue.write { dbc in
            try Self.requireWorkspaceProject(projectID, in: dbc)
            let conversationID: UUID
            if let existingConversationID {
                guard try Conversation.fetchOne(dbc, key: existingConversationID) != nil else { throw WorkspaceStoreError.conversationNotFound }
                guard try WorkspaceChat.filter(Column("localConversationID") == existingConversationID).fetchOne(dbc) == nil else {
                    throw WorkspaceStoreError.conversationAlreadyAssigned
                }
                conversationID = existingConversationID
            } else {
                let conversation = Conversation(title: title)
                try conversation.insert(dbc)
                conversationID = conversation.id
            }
            let chat = WorkspaceChat(projectID: projectID, localConversationID: conversationID,
                                     title: title, purpose: purpose, kind: kind)
            try chat.insert(dbc)
            return chat
        }
    }

    public func workspaceChats(projectID: UUID, includeArchived: Bool = false) throws -> [WorkspaceChat] {
        try db.queue.read { dbc in
            try Self.requireWorkspaceProject(projectID, in: dbc)
            var query = WorkspaceChat.filter(Column("projectID") == projectID)
            if !includeArchived { query = query.filter(Column("archivedAt") == nil) }
            return try query.order(Column("lastActivityAt").desc, Column("id")).fetchAll(dbc)
        }
    }

    /// The most recently active chats across every visible project, so the
    /// rail can show work from several projects at once. Each chat keeps its
    /// own project; hidden projects and archived chats stay out.
    public func recentWorkspaceChats(limit: Int = 25) throws -> [RecentWorkspaceChat] {
        guard (1...200).contains(limit) else { throw WorkspaceStoreError.invalidValue("limit") }
        return try db.queue.read { dbc in
            let projects = try WorkspaceProject.filter(Column("isVisible") == true).fetchAll(dbc)
            guard !projects.isEmpty else { return [] }
            let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
            // Record APIs keep GRDB's own UUID encoding; never string compares.
            let chats = try WorkspaceChat
                .filter(projects.map(\.id).contains(Column("projectID")))
                .filter(Column("archivedAt") == nil)
                .order(Column("lastActivityAt").desc, Column("id"))
                .limit(limit)
                .fetchAll(dbc)
            return chats.compactMap { chat in
                byID[chat.projectID].map { RecentWorkspaceChat(chat: chat, project: $0) }
            }
        }
    }

    public func workspaceChat(id: UUID) throws -> WorkspaceChat? {
        try db.queue.read { try WorkspaceChat.fetchOne($0, key: id) }
    }

    public func workspaceChat(forConversationID id: UUID) throws -> WorkspaceChat? {
        try db.queue.read { try WorkspaceChat.filter(Column("localConversationID") == id).fetchOne($0) }
    }

    public func saveWorkspaceChat(_ chat: WorkspaceChat) throws {
        var value = chat
        value.title = try Self.workspaceName(value.title)
        try Self.validateWorkspaceText(value.purpose, maximum: 2_000)
        try db.queue.write { dbc in
            guard let existing = try WorkspaceChat.fetchOne(dbc, key: value.id) else { throw WorkspaceStoreError.chatNotFound }
            guard existing.projectID == value.projectID, existing.localConversationID == value.localConversationID else {
                throw WorkspaceStoreError.immutableIdentity
            }
            // Editing metadata is not activity and must not postpone expiry.
            value.createdAt = existing.createdAt
            value.lastActivityAt = existing.lastActivityAt
            try value.update(dbc)
        }
    }

    public func setWorkspaceChatArchived(id: UUID, archived: Bool, now: Date = .now) throws {
        try db.queue.write { dbc in
            guard var chat = try WorkspaceChat.fetchOne(dbc, key: id) else { throw WorkspaceStoreError.chatNotFound }
            if !archived, chat.archivedAt != nil {
                // Explicit restoration is renewed user activity, unlike editing
                // metadata. Give temporary chats a full inactivity window.
                chat.lastActivityAt = max(chat.lastActivityAt, now)
            }
            chat.archivedAt = archived ? (chat.archivedAt ?? now) : nil
            try chat.update(dbc)
        }
    }

    public func unassignedConversations() throws -> [Conversation] {
        try db.queue.read { dbc in
            try Conversation.fetchAll(dbc, sql: """
                SELECT conversation.* FROM conversation
                WHERE NOT EXISTS (SELECT 1 FROM workspaceChat WHERE localConversationID = conversation.id)
                ORDER BY updatedAt DESC, id
                """)
        }
    }

    public func touchWorkspaceChat(conversationID: UUID, at: Date = .now) throws {
        try db.queue.write { dbc in
            guard try Conversation.fetchOne(dbc, key: conversationID) != nil else { throw WorkspaceStoreError.conversationNotFound }
            try dbc.execute(sql: """
                UPDATE workspaceChat SET lastActivityAt = ?
                WHERE localConversationID = ? AND lastActivityAt < ?
                """, arguments: [at, conversationID, at])
        }
    }

    /// Archives metadata only; no conversation, message, or provider session
    /// is deleted. Unknown activity states conservatively block expiry too.
    @discardableResult
    public func archiveExpiredWorkspaceChats(now: Date = .now, protectedChatIDs: Set<UUID> = []) throws -> Int {
        try db.queue.write { dbc in
            let candidates = try WorkspaceChat.filter(Column("kind") == WorkspaceChatKind.temporary.rawValue)
                .filter(Column("archivedAt") == nil)
                .filter(Column("lastActivityAt") <= now.addingTimeInterval(-Self.workspaceTemporaryChatLifetime)).fetchAll(dbc)
            var count = 0
            for var chat in candidates where !protectedChatIDs.contains(chat.id) {
                let pending = try Bool.fetchOne(dbc, sql: """
                    SELECT EXISTS(SELECT 1 FROM activityRun
                    WHERE (lower(referenceID) = lower(?) OR lower(referenceID) = lower(?))
                    AND (state NOT IN ('succeeded', 'cancelled', 'failed', 'interrupted', 'outcomeUnknown')
                         OR (state IN ('failed', 'interrupted', 'outcomeUnknown') AND acknowledgedAt IS NULL)))
                    """, arguments: [chat.id.uuidString, chat.localConversationID.uuidString]) ?? false
                guard !pending else { continue }
                let frontierPending = try Bool.fetchOne(dbc, sql: """
                    SELECT EXISTS(SELECT 1 FROM workspaceFrontierTurn AS turn
                    JOIN workspaceFrontierSession AS session ON session.id = turn.sessionID
                    WHERE session.chatID = ? AND turn.state NOT IN ('completed', 'failed', 'cancelled'))
                    """, arguments: [chat.id]) ?? true
                guard !frontierPending else { continue }
                let claudePending = try Bool.fetchOne(dbc, sql: """
                    SELECT EXISTS(SELECT 1 FROM workspaceClaudeTurn AS turn
                    JOIN workspaceClaudeSession AS session ON session.id = turn.sessionID
                    WHERE session.chatID = ? AND turn.state NOT IN ('completed', 'failed', 'cancelled'))
                    """, arguments: [chat.id]) ?? true
                guard !claudePending else { continue }
                chat.archivedAt = now
                try chat.update(dbc)
                count += 1
            }
            return count
        }
    }

    @discardableResult
    public func saveWorkspaceProjectLink(_ link: WorkspaceProjectLink) throws -> WorkspaceProjectLink {
        var value = link
        value.displayName = try Self.workspaceName(value.displayName)
        try Self.validateWorkspaceIdentity(value.externalID)
        try Self.validateWorkspaceIdentity(value.hostID)
        if let root = value.sourceRoot { value.sourceRoot = try Self.workspacePath(root) }
        return try db.queue.write { dbc in
            try Self.requireWorkspaceProject(value.projectID, in: dbc)
            if let byID = try WorkspaceProjectLink.fetchOne(dbc, key: value.id) {
                guard byID.projectID == value.projectID, byID.provider == value.provider,
                      byID.hostID == value.hostID, byID.externalID == value.externalID else { throw WorkspaceStoreError.immutableIdentity }
            }
            if let existing = try WorkspaceProjectLink.filter(Column("provider") == value.provider.rawValue)
                .filter(Column("hostID") == value.hostID).filter(Column("externalID") == value.externalID).fetchOne(dbc) {
                guard existing.projectID == value.projectID else { throw WorkspaceStoreError.linkAlreadyAssigned }
                value.id = existing.id
            }
            try value.save(dbc)
            return value
        }
    }

    public func workspaceProjectLinks(projectID: UUID) throws -> [WorkspaceProjectLink] {
        try db.queue.read { dbc in
            try Self.requireWorkspaceProject(projectID, in: dbc)
            return try WorkspaceProjectLink.filter(Column("projectID") == projectID)
                .order(Column("provider"), Column("hostID"), Column("externalID")).fetchAll(dbc)
        }
    }

    @discardableResult
    public func saveWorkspaceSessionLink(_ link: WorkspaceSessionLink) throws -> WorkspaceSessionLink {
        var value = link
        value.displayName = try Self.workspaceName(value.displayName)
        try Self.validateWorkspaceIdentity(value.externalID)
        try Self.validateWorkspaceIdentity(value.hostID)
        return try db.queue.write { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: value.chatID) != nil else { throw WorkspaceStoreError.chatNotFound }
            if let byID = try WorkspaceSessionLink.fetchOne(dbc, key: value.id) {
                guard byID.chatID == value.chatID, byID.provider == value.provider,
                      byID.hostID == value.hostID, byID.externalID == value.externalID else { throw WorkspaceStoreError.immutableIdentity }
            }
            if let existing = try WorkspaceSessionLink.filter(Column("provider") == value.provider.rawValue)
                .filter(Column("hostID") == value.hostID).filter(Column("externalID") == value.externalID).fetchOne(dbc) {
                guard existing.chatID == value.chatID else { throw WorkspaceStoreError.linkAlreadyAssigned }
                value.id = existing.id
            }
            try value.save(dbc)
            return value
        }
    }

    public func workspaceSessionLinks(chatID: UUID) throws -> [WorkspaceSessionLink] {
        try db.queue.read { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw WorkspaceStoreError.chatNotFound }
            return try WorkspaceSessionLink.filter(Column("chatID") == chatID)
                .order(Column("provider"), Column("hostID"), Column("externalID")).fetchAll(dbc)
        }
    }

    private static func requireWorkspaceProject(_ id: UUID, in db: Database) throws {
        guard try WorkspaceProject.fetchOne(db, key: id) != nil else { throw WorkspaceStoreError.projectNotFound }
    }

    private static func workspaceName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WorkspaceStoreError.invalidValue("Enter a nonempty name.") }
        try validateWorkspaceText(name, maximum: maximumWorkspaceTitleCharacters)
        return name
    }

    private static func validateWorkspaceText(_ value: String, maximum: Int) throws {
        guard value.count <= maximum, !value.contains("\0") else { throw WorkspaceStoreError.invalidValue("Text is too long or contains an invalid character.") }
    }

    private static func validateWorkspaceIdentity(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceStoreError.invalidValue("Provider identities must not be blank.") }
        try validateWorkspaceText(value, maximum: 2_000)
    }

    private static func workspacePath(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.contains("\0"), !value.contains("\n"), !value.contains("\r"), value.count <= 4_096 else {
            throw WorkspaceStoreError.invalidValue("Folders require an absolute path.")
        }
        // Lexical normalization only: never reads the folder or resolves symlinks.
        return (value as NSString).standardizingPath
    }

    private static func validatedWorkspaceFolders(_ drafts: [WorkspaceFolderDraft], projectID: UUID) throws -> [WorkspaceFolder] {
        guard drafts.count <= 100 else { throw WorkspaceStoreError.invalidValue("Too many folders.") }
        var paths = Set<String>()
        return try drafts.map { draft in
            let path = try workspacePath(draft.path)
            guard paths.insert(path).inserted else { throw WorkspaceStoreError.invalidValue("A folder is listed more than once.") }
            return WorkspaceFolder(projectID: projectID, path: path, access: draft.access)
        }
    }
}
