import Foundation
import GRDB
import AitvarasCore

public enum WorkspacePolicyError: Error, LocalizedError, Sendable, Equatable {
    case staleReview, invalidPolicy, invalidCaptureTarget, captureNotFound, immutableCaptureTarget

    public var errorDescription: String? {
        switch self {
        case .staleReview: "Project instructions or folders changed. Review the current policy again."
        case .invalidPolicy: "The saved workspace policy is invalid. No additional access is allowed."
        case .invalidCaptureTarget: "Choose an unarchived primary chat in a visible project."
        case .captureNotFound: "The capture no longer exists."
        case .immutableCaptureTarget: "A capture's saved workspace target cannot be changed."
        }
    }
}

/// A review snapshot, not a grant. Its revision must be submitted unchanged.
public struct WorkspacePolicyReview: Sendable, Equatable {
    public let projectID: UUID
    public let revision: Int
    public let instructions: String
    public let folders: [WorkspaceFolder]
}

public struct WorkspacePolicyRecord: Sendable, Equatable {
    public let projectID: UUID
    public let revision: Int
    public let contextRevision: Int
    public let reviewedAt: Date
    public let status: WorkspacePolicyStatus
    public let allowedProviders: [WorkspaceSessionProvider]
    public let reviewedFolders: [WorkspaceFolder]
    public let instructions: String
    // The separately saved, revision-bound read grant enables only the app's
    // project-file broker. Native/general tools and execution stay disabled.
    public let allowsFileAccess: Bool
    public let allowsClaudeFileAccess: Bool
    public let allowsTools = false
    public let allowsCloudExecution = false
    public let allowsGlobalRAG = false
}

private struct StoredWorkspacePolicy: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workspacePolicy"
    var projectID: UUID
    var revision: Int
    var contextRevision: Int
    var reviewedAt: Date
    var allowedProvidersJSON: String
    var foldersJSON: String
    var instructions: String
}

public struct WorkspaceCaptureTarget: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCaptureTarget"
    public let recordID: UUID
    public let projectID: UUID
    public let chatID: UUID
    public let linkedAt: Date
}

extension Stores {
    public func workspacePolicyReview(projectID: UUID) throws -> WorkspacePolicyReview {
        try db.queue.read { try Self.policyReview(projectID: projectID, in: $0) }
    }

    public func workspacePolicy(projectID: UUID) throws -> WorkspacePolicyRecord? {
        try db.queue.read { dbc in
            let review = try Self.policyReview(projectID: projectID, in: dbc)
            return try Self.policyRecord(review: review, in: dbc)
        }
    }

    @discardableResult
    public func reviewWorkspacePolicy(projectID: UUID, allowedProviders: [WorkspaceSessionProvider],
                                      expectedRevision: Int) throws -> WorkspacePolicyRecord {
        try db.queue.write { dbc in
            try Self.saveWorkspacePolicy(projectID: projectID, allowedProviders: allowedProviders,
                                         expectedRevision: expectedRevision, in: dbc)
        }
    }

    static func saveWorkspacePolicy(projectID: UUID, allowedProviders: [WorkspaceSessionProvider],
                                    expectedRevision: Int, in dbc: Database) throws -> WorkspacePolicyRecord {
        let review = try Self.policyReview(projectID: projectID, in: dbc)
        guard review.revision == expectedRevision else { throw WorkspacePolicyError.staleReview }
        let previous = try StoredWorkspacePolicy.fetchOne(dbc, key: projectID)
        let providers = WorkspaceSessionProvider.allCases.filter { $0 == .local || allowedProviders.contains($0) }
        let encoder = JSONEncoder()
        let value = StoredWorkspacePolicy(projectID: projectID, revision: (previous?.revision ?? 0) + 1,
            contextRevision: review.revision, reviewedAt: .now,
            allowedProvidersJSON: String(decoding: try encoder.encode(providers), as: UTF8.self),
            foldersJSON: String(decoding: try encoder.encode(review.folders), as: UTF8.self),
            instructions: review.instructions)
        try value.save(dbc)
        return try Self.policyRecord(review: review, in: dbc)!
    }

    public func workspaceContextPacket(chatID: UUID) throws -> WorkspaceContextPacket {
        try db.queue.read { try Self.workspaceContextPacket(chatID: chatID, in: $0) }
    }

    static func workspaceContextPacket(chatID: UUID, in dbc: Database) throws -> WorkspaceContextPacket {
        guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID) else { throw WorkspaceStoreError.chatNotFound }
        guard let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID) else { throw WorkspaceStoreError.projectNotFound }
        let review = try Self.policyReview(projectID: project.id, in: dbc)
        let policy = try Self.policyRecord(review: review, in: dbc)
        let raw = "Project: \(project.title)\nChat: \(chat.title)\nPurpose:\n\(chat.purpose)\nProject instructions:\n\(project.instructions)"
        let bounded = WorkspaceTextContext.bounded(raw)
        return WorkspaceContextPacket(projectID: project.id, chatID: chat.id, promptText: bounded,
            manifest: WorkspaceContextManifest(originalCharacters: raw.count, includedCharacters: bounded.count),
            policyStatus: policy?.status ?? .unreviewed, policyRevision: policy?.revision)
    }

    /// Must be checked at capture selection/start, before any recorder opens.
    @discardableResult
    public func validateWorkspaceCaptureTarget(chatID: UUID) throws -> WorkspaceChat {
        try db.queue.read { try Self.captureTargetChat(chatID: chatID, in: $0) }
    }

    @discardableResult
    public func linkWorkspaceCapture(recordID: UUID, chatID: UUID) throws -> WorkspaceCaptureTarget {
        let value = try db.queue.write { try Self.linkCapture(recordID: recordID, chatID: chatID, in: $0) }
        NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue)
        return value
    }

    /// Checkpoint and target are one transaction. Once linked, an archive or
    /// hidden project must not prevent further checkpoints of that recording.
    /// A nil target preserves an existing link; it never clears or moves it.
    public func saveCaptureRecord(_ record: CaptureRecord, workspaceChatID: UUID?,
                                  recording event: ActivityEvent? = nil) throws {
        try db.queue.write { dbc in
            try record.save(dbc)
            if let workspaceChatID { _ = try Self.linkCapture(recordID: record.id, chatID: workspaceChatID, in: dbc) }
            if let event { try event.insert(dbc) }
        }
        NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue)
    }

    public func workspaceCaptureTarget(recordID: UUID) throws -> WorkspaceCaptureTarget? {
        try db.queue.read { try WorkspaceCaptureTarget.fetchOne($0, key: recordID) }
    }

    /// Archival changes visibility, not ownership or access to saved evidence.
    public func workspaceCaptures(chatID: UUID) throws -> [CaptureRecord] {
        try db.queue.read { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw WorkspaceStoreError.chatNotFound }
            return try CaptureRecord.fetchAll(dbc, sql: """
                SELECT captureRecord.* FROM captureRecord
                JOIN workspaceCaptureTarget ON workspaceCaptureTarget.recordID = captureRecord.id
                WHERE workspaceCaptureTarget.chatID = ? ORDER BY captureRecord.startedAt DESC, captureRecord.id
                """, arguments: [chatID])
        }
    }

    static func policyReview(projectID: UUID, in dbc: Database) throws -> WorkspacePolicyReview {
        guard let project = try WorkspaceProject.fetchOne(dbc, key: projectID) else { throw WorkspaceStoreError.projectNotFound }
        guard let revision = try Int.fetchOne(dbc, sql: "SELECT revision FROM workspacePolicyState WHERE projectID = ?",
                                             arguments: [projectID]), revision >= 0 else { throw WorkspacePolicyError.invalidPolicy }
        let folders = try WorkspaceFolder.filter(Column("projectID") == projectID)
            .order(Column("path"), Column("id")).fetchAll(dbc)
        return WorkspacePolicyReview(projectID: projectID, revision: revision, instructions: project.instructions, folders: folders)
    }

    static func policyRecord(review: WorkspacePolicyReview, in dbc: Database) throws -> WorkspacePolicyRecord? {
        guard let stored = try StoredWorkspacePolicy.fetchOne(dbc, key: review.projectID) else { return nil }
        let decoder = JSONDecoder()
        let providers: [WorkspaceSessionProvider]
        let folders: [WorkspaceFolder]
        do {
            providers = try decoder.decode([WorkspaceSessionProvider].self, from: Data(stored.allowedProvidersJSON.utf8))
            folders = try decoder.decode([WorkspaceFolder].self, from: Data(stored.foldersJSON.utf8))
        } catch { throw WorkspacePolicyError.invalidPolicy }
        guard providers.contains(.local), Set(providers.map(\.rawValue)).count == providers.count,
              stored.revision > 0, stored.contextRevision >= 0,
              folders.allSatisfy({ $0.projectID == review.projectID }) else { throw WorkspacePolicyError.invalidPolicy }
        let current = stored.contextRevision == review.revision && stored.instructions == review.instructions && folders == review.folders
        let grant = try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?",
            arguments: ["workspace.project.\(stored.projectID.uuidString).codexFileReadRevision"])
        let claudeGrant = try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?",
            arguments: ["workspace.project.\(stored.projectID.uuidString).claudeFileReadRevision"])
        return WorkspacePolicyRecord(projectID: stored.projectID, revision: stored.revision,
            contextRevision: stored.contextRevision, reviewedAt: stored.reviewedAt,
            status: current ? .reviewed : .stale, allowedProviders: providers, reviewedFolders: folders, instructions: stored.instructions,
            allowsFileAccess: current && providers.contains(.codex) && !folders.isEmpty && grant == String(stored.revision),
            allowsClaudeFileAccess: current && providers.contains(.claude) && !folders.isEmpty && claudeGrant == String(stored.revision))
    }

    public func workspaceCodexReadRoots(chatID: UUID, expectedPolicyRevision: Int) throws -> [String] {
        try db.queue.read { dbc in
            guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.archivedAt == nil,
                  let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible,
                  let policy = try Self.policyRecord(review: Self.policyReview(projectID: project.id, in: dbc), in: dbc),
                  policy.status == .reviewed, policy.revision == expectedPolicyRevision,
                  policy.allowedProviders.contains(.codex) else { throw WorkspacePolicyError.staleReview }
            return policy.allowsFileAccess ? policy.reviewedFolders.map(\.path).sorted() : []
        }
    }

    /// Claude uses the same bounded read-only broker, with its own explicit
    /// revision-bound grant. Enabling one provider never grants the other access.
    public func workspaceClaudeReadRoots(chatID: UUID, expectedPolicyRevision: Int) throws -> [String] {
        try db.queue.read { dbc in
            guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.archivedAt == nil,
                  let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible,
                  let policy = try Self.policyRecord(review: Self.policyReview(projectID: project.id, in: dbc), in: dbc),
                  policy.status == .reviewed, policy.revision == expectedPolicyRevision,
                  policy.allowedProviders.contains(.claude) else { throw WorkspacePolicyError.staleReview }
            return policy.allowsClaudeFileAccess ? policy.reviewedFolders.map(\.path).sorted() : []
        }
    }

    private static func captureTargetChat(chatID: UUID, in dbc: Database) throws -> WorkspaceChat {
        guard let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.kind == .primary, chat.archivedAt == nil,
              let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible else {
            throw WorkspacePolicyError.invalidCaptureTarget
        }
        return chat
    }

    private static func linkCapture(recordID: UUID, chatID: UUID, in dbc: Database) throws -> WorkspaceCaptureTarget {
        guard try CaptureRecord.exists(dbc, key: recordID) else { throw WorkspacePolicyError.captureNotFound }
        if let existing = try WorkspaceCaptureTarget.fetchOne(dbc, key: recordID) {
            guard existing.chatID == chatID else { throw WorkspacePolicyError.immutableCaptureTarget }
            return existing
        }
        let chat = try captureTargetChat(chatID: chatID, in: dbc)
        try dbc.execute(sql: "INSERT INTO workspaceCaptureTarget(recordID, projectID, chatID, linkedAt) VALUES(?, ?, ?, ?)",
                        arguments: [recordID, chat.projectID, chatID, Date.now])
        return try WorkspaceCaptureTarget.fetchOne(dbc, key: recordID)!
    }
}
