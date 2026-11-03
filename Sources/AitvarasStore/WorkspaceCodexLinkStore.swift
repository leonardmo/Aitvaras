import Foundation
import GRDB
import AitvarasCore

public enum WorkspaceCodexLinkError: Error, LocalizedError, Sendable, Equatable {
    case invalidValue, reviewRequired, unavailableProject, unavailableChat, linkNotFound
    case alreadyLinked, identityMismatch, isolatedIdentity, staleRevision, staleReview, invalidWorkingDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidValue: "The native relationship contains an invalid value."
        case .reviewRequired: "Review the native project folders and effective native settings first."
        case .unavailableProject: "Choose a visible Aitvaras project."
        case .unavailableChat: "Choose an active chat in the linked Aitvaras project."
        case .linkNotFound: "This native relationship no longer exists."
        case .alreadyLinked: "This project or chat already has a native relationship."
        case .identityMismatch: "The native host, profile or identity does not match this relationship."
        case .isolatedIdentity: "An isolated app-owned session cannot be converted to a native relationship."
        case .staleRevision: "The relationship changed. Reload it before saving."
        case .staleReview: "The reviewed native folders changed. Review the current observation."
        case .invalidWorkingDirectory: "Choose an explicit working directory inside the reviewed native roots."
        }
    }
}

public enum WorkspaceCodexLinkState: String, Codable, Sendable { case linked, conflict, reviewRequired }

/// A separate local observation, never presented as provider-supplied evidence.
/// The ordered project roots are not an implicit working-directory selection.
public struct WorkspaceCodexRootReview: Codable, Sendable, Equatable {
    public enum Availability: String, Codable, Sendable { case available, missing, unverified }
    public let path: String
    public let canonicalPath: String?
    public let filesystemIdentity: String?
    public let availability: Availability

    public init(path: String, canonicalPath: String? = nil, filesystemIdentity: String? = nil,
                availability: Availability = .unverified) {
        self.path = path; self.canonicalPath = canonicalPath
        self.filesystemIdentity = filesystemIdentity; self.availability = availability
    }
}

public struct WorkspaceCodexProjectLink: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public let approvedSnapshot: NativeProjectSnapshot
    public let observedSnapshot: NativeProjectSnapshot
    public let approvedRoots: [WorkspaceCodexRootReview]
    public let observedRoots: [WorkspaceCodexRootReview]
    public let state: WorkspaceCodexLinkState
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
}

public struct WorkspaceCodexChatLink: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCodexChatLink"
    public let id: UUID
    public let projectLinkID: UUID
    public let projectID: UUID
    public let chatID: UUID
    public let hostID: String
    public let profileNamespace: String
    public let externalID: String
    public let workingDirectory: String
    public let revision: Int
    public let createdAt: Date
}

/// Consent to normal native tools under the reviewed native configuration.
/// This is NOT an auto-approval, a full-access grant, or execution capability.
public struct WorkspaceCodexNativeAuthorization: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCodexNativeAuthorization"
    public let chatLinkID: UUID
    public let projectRevision: Int
    public let chatRevision: Int
    public let mode: String
    public let effectiveConfigurationFingerprint: String
    public let reviewedPolicySummary: String
    public let approvedAt: Date
}

extension Stores {
    /// Read-only filesystem observation. Remote paths are never resolved locally.
    public static func workspaceCodexRootReviews(for snapshot: NativeProjectSnapshot) -> [WorkspaceCodexRootReview] {
        snapshot.roots.map { root in
            guard snapshot.identity.hostID == "local" else { return .init(path: root.path) }
            let url = URL(fileURLWithPath: root.path).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                return .init(path: root.path, canonicalPath: url.path, availability: .missing)
            }
            return .init(path: root.path, canonicalPath: url.path,
                         filesystemIdentity: "\(device.stringValue):\(inode.stringValue)", availability: .available)
        }
    }

    public func workspaceCodexProjectLink(projectID: UUID) throws -> WorkspaceCodexProjectLink? {
        try db.queue.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM workspaceCodexProjectLink WHERE projectID = ?", arguments: [projectID])
                .map(Self.decodeCodexProjectLink)
        }
    }

    /// Local relationship only: does not edit native projects, import history,
    /// change isolated grants, approve tools, or select a thread cwd.
    public func linkWorkspaceCodexProject(projectID: UUID, snapshot: NativeProjectSnapshot,
                                         reviewedRoots: [WorkspaceCodexRootReview], reviewed: Bool,
                                         now: Date = .now) throws -> WorkspaceCodexProjectLink {
        guard reviewed else { throw WorkspaceCodexLinkError.reviewRequired }
        try Self.validateCodexSnapshot(snapshot, roots: reviewedRoots)
        try Self.validateCurrentCodexRoots(snapshot, roots: reviewedRoots)
        return try db.queue.write { dbc in
            guard let project = try WorkspaceProject.fetchOne(dbc, key: projectID), project.isVisible else {
                throw WorkspaceCodexLinkError.unavailableProject
            }
            let identity = snapshot.identity
            guard try !Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceCodexProjectLink WHERE projectID = ?
                    OR (hostID = ? AND profileNamespace = ? AND externalID = ?))
                """, arguments: [projectID, identity.hostID, identity.profileNamespace, identity.externalID])! else {
                throw WorkspaceCodexLinkError.alreadyLinked
            }
            let id = UUID(), snapshotJSON = try Self.codexJSON(snapshot), rootsJSON = try Self.codexJSON(reviewedRoots)
            let state = Self.codexRootsAvailable(reviewedRoots) ? "linked" : "reviewRequired"
            try dbc.execute(sql: """
                INSERT INTO workspaceCodexProjectLink
                (id, projectID, hostID, profileNamespace, externalID, approvedSnapshotJSON, observedSnapshotJSON,
                 approvedRootsJSON, observedRootsJSON, state, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id, projectID, identity.hostID, identity.profileNamespace, identity.externalID,
                    snapshotJSON, snapshotJSON, rootsJSON, rootsJSON, state, now, now])
            return try Self.codexProjectLink(id: id, in: dbc)
        }
    }

    /// Preserve the approved baseline and the new native observation on conflict.
    /// This local CAS is not an atomic provider project-update guarantee.
    @discardableResult
    public func observeWorkspaceCodexProject(linkID: UUID, snapshot: NativeProjectSnapshot,
                                            observedRoots: [WorkspaceCodexRootReview], expectedRevision: Int,
                                            now: Date = .now) throws -> WorkspaceCodexProjectLink {
        try Self.validateCodexSnapshot(snapshot, roots: observedRoots)
        return try db.queue.write { dbc in
            let old = try Self.codexProjectLink(id: linkID, in: dbc)
            try Self.requireCodexRevision(old, expectedRevision)
            guard old.approvedSnapshot.identity == snapshot.identity else { throw WorkspaceCodexLinkError.identityMismatch }
            if old.observedSnapshot == snapshot && old.observedRoots == observedRoots { return old }
            // A changed-and-reverted observation does not revive consent.
            let state = old.state == .reviewRequired ? "reviewRequired" : "conflict"
            try dbc.execute(sql: """
                UPDATE workspaceCodexProjectLink SET observedSnapshotJSON = ?, observedRootsJSON = ?,
                    state = ?, revision = revision + 1, updatedAt = ? WHERE id = ?
                """, arguments: [try Self.codexJSON(snapshot), try Self.codexJSON(observedRoots), state, now, linkID])
            try Self.clearCodexAuthorizations(projectLinkID: linkID, in: dbc)
            return try Self.codexProjectLink(id: linkID, in: dbc)
        }
    }

    @discardableResult
    public func reviewWorkspaceCodexProject(linkID: UUID, expectedRevision: Int,
                                           reviewedSnapshot: NativeProjectSnapshot,
                                           reviewedRoots: [WorkspaceCodexRootReview], now: Date = .now) throws -> WorkspaceCodexProjectLink {
        try Self.validateCodexSnapshot(reviewedSnapshot, roots: reviewedRoots)
        try Self.validateCurrentCodexRoots(reviewedSnapshot, roots: reviewedRoots)
        return try db.queue.write { dbc in
            let old = try Self.codexProjectLink(id: linkID, in: dbc)
            try Self.requireCodexRevision(old, expectedRevision)
            guard old.observedSnapshot == reviewedSnapshot, old.observedRoots == reviewedRoots else {
                throw WorkspaceCodexLinkError.staleReview
            }
            guard Self.codexRootsAvailable(reviewedRoots) else { throw WorkspaceCodexLinkError.reviewRequired }
            try dbc.execute(sql: """
                UPDATE workspaceCodexProjectLink SET approvedSnapshotJSON = observedSnapshotJSON,
                    approvedRootsJSON = observedRootsJSON, state = 'linked', revision = revision + 1, updatedAt = ? WHERE id = ?
                """, arguments: [now, linkID])
            try Self.clearCodexAuthorizations(projectLinkID: linkID, in: dbc)
            return try Self.codexProjectLink(id: linkID, in: dbc)
        }
    }

    /// Use when profile/account verification is lost. No account secrets stored.
    @discardableResult
    public func invalidateWorkspaceCodexProject(linkID: UUID, expectedRevision: Int,
                                               now: Date = .now) throws -> WorkspaceCodexProjectLink {
        try db.queue.write { dbc in
            let old = try Self.codexProjectLink(id: linkID, in: dbc)
            try Self.requireCodexRevision(old, expectedRevision)
            try dbc.execute(sql: "UPDATE workspaceCodexProjectLink SET state = 'reviewRequired', revision = revision + 1, updatedAt = ? WHERE id = ?",
                            arguments: [now, linkID])
            try Self.clearCodexAuthorizations(projectLinkID: linkID, in: dbc)
            return try Self.codexProjectLink(id: linkID, in: dbc)
        }
    }

    /// Only the relationship and its local consent records are removed.
    public func unlinkWorkspaceCodexProject(linkID: UUID, expectedRevision: Int) throws {
        try db.queue.write { dbc in
            try Self.requireCodexRevision(Self.codexProjectLink(id: linkID, in: dbc), expectedRevision)
            try dbc.execute(sql: "DELETE FROM workspaceCodexProjectLink WHERE id = ?", arguments: [linkID])
        }
    }

    public func workspaceCodexChatLink(chatID: UUID) throws -> WorkspaceCodexChatLink? {
        try db.queue.read { try WorkspaceCodexChatLink.filter(Column("chatID") == chatID).fetchOne($0) }
    }

    /// Requires explicit native membership and cwd; never infers either from title,
    /// folder order, imported transcript IDs or an isolated owned-session registry.
    public func linkWorkspaceCodexChat(chatID: UUID, projectLinkID: UUID, nativeProjectIdentity: NativeProjectIdentity,
                                      nativeThreadID: String, workingDirectory: String, expectedProjectRevision: Int,
                                      reviewed: Bool, now: Date = .now) throws -> WorkspaceCodexChatLink {
        guard reviewed else { throw WorkspaceCodexLinkError.reviewRequired }
        try Self.validateCodexValue(nativeThreadID)
        try Self.validateCodexPath(workingDirectory)
        return try db.queue.write { dbc in
            let project = try Self.codexProjectLink(id: projectLinkID, in: dbc)
            try Self.requireCodexRevision(project, expectedProjectRevision)
            guard project.state == .linked else { throw WorkspaceCodexLinkError.reviewRequired }
            guard project.approvedSnapshot.identity == nativeProjectIdentity else { throw WorkspaceCodexLinkError.identityMismatch }
            try Self.validateCurrentCodexRoots(project.approvedSnapshot, roots: project.approvedRoots)
            guard let localProject = try WorkspaceProject.fetchOne(dbc, key: project.projectID), localProject.isVisible,
                  let chat = try WorkspaceChat.fetchOne(dbc, key: chatID), chat.projectID == project.projectID,
                  chat.archivedAt == nil else { throw WorkspaceCodexLinkError.unavailableChat }
            guard try WorkspaceFrontierSession.filter(Column("externalID") == nativeThreadID).fetchOne(dbc) == nil else {
                throw WorkspaceCodexLinkError.isolatedIdentity
            }
            let canonicalCwd = try Self.codexCanonicalCwd(workingDirectory, hostID: nativeProjectIdentity.hostID)
            guard Self.codexContains(canonicalCwd, roots: project.approvedRoots) else {
                throw WorkspaceCodexLinkError.invalidWorkingDirectory
            }
            guard try !Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceCodexChatLink WHERE chatID = ?
                    OR (hostID = ? AND profileNamespace = ? AND externalID = ?))
                """, arguments: [chatID, nativeProjectIdentity.hostID, nativeProjectIdentity.profileNamespace, nativeThreadID])! else {
                throw WorkspaceCodexLinkError.alreadyLinked
            }
            let id = UUID()
            try dbc.execute(sql: """
                INSERT INTO workspaceCodexChatLink
                (id, projectLinkID, projectID, chatID, hostID, profileNamespace, externalID, workingDirectory, revision, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                """, arguments: [id, projectLinkID, project.projectID, chatID, nativeProjectIdentity.hostID,
                    nativeProjectIdentity.profileNamespace, nativeThreadID, workingDirectory, now])
            return try WorkspaceCodexChatLink.fetchOne(dbc, key: id)!
        }
    }

    public func unlinkWorkspaceCodexChat(linkID: UUID, expectedRevision: Int) throws {
        try db.queue.write { dbc in
            guard let link = try WorkspaceCodexChatLink.fetchOne(dbc, key: linkID) else { throw WorkspaceCodexLinkError.linkNotFound }
            guard link.revision == expectedRevision else { throw WorkspaceCodexLinkError.staleRevision }
            try dbc.execute(sql: "DELETE FROM workspaceCodexChatLink WHERE id = ?", arguments: [linkID])
        }
    }

    /// Stores exact reviewed native configuration evidence, separate from isolated
    /// tool grants. Callers must not fabricate this from project membership.
    @discardableResult
    public func authorizeWorkspaceCodexNativeTools(chatLinkID: UUID, expectedProjectRevision: Int,
                                                   expectedChatRevision: Int, effectiveConfigurationFingerprint: String,
                                                   reviewedPolicySummary: String, reviewed: Bool,
                                                   now: Date = .now) throws -> WorkspaceCodexNativeAuthorization {
        guard reviewed else { throw WorkspaceCodexLinkError.reviewRequired }
        try Self.validateCodexValue(effectiveConfigurationFingerprint)
        try Self.validateCodexValue(reviewedPolicySummary, limit: 16_000)
        return try db.queue.write { dbc in
            guard let chat = try WorkspaceCodexChatLink.fetchOne(dbc, key: chatLinkID) else { throw WorkspaceCodexLinkError.linkNotFound }
            let project = try Self.codexProjectLink(id: chat.projectLinkID, in: dbc)
            try Self.requireCodexRevision(project, expectedProjectRevision)
            guard chat.revision == expectedChatRevision else { throw WorkspaceCodexLinkError.staleRevision }
            try Self.validateCurrentCodexRoots(project.approvedSnapshot, roots: project.approvedRoots)
            let canonicalCwd = try Self.codexCanonicalCwd(chat.workingDirectory, hostID: chat.hostID)
            guard project.state == .linked, Self.codexContains(canonicalCwd, roots: project.approvedRoots),
                  let localProject = try WorkspaceProject.fetchOne(dbc, key: project.projectID), localProject.isVisible,
                  let localChat = try WorkspaceChat.fetchOne(dbc, key: chat.chatID), localChat.archivedAt == nil else {
                throw WorkspaceCodexLinkError.reviewRequired
            }
            try dbc.execute(sql: """
                INSERT OR REPLACE INTO workspaceCodexNativeAuthorization
                (chatLinkID, projectRevision, chatRevision, mode, effectiveConfigurationFingerprint, reviewedPolicySummary, approvedAt)
                VALUES (?, ?, ?, 'nativeCodex', ?, ?, ?)
                """, arguments: [chatLinkID, project.revision, chat.revision, effectiveConfigurationFingerprint, reviewedPolicySummary, now])
            return try WorkspaceCodexNativeAuthorization.fetchOne(dbc, key: chatLinkID)!
        }
    }

    /// Stored consent only. The native execution adapter is not implemented here.
    public func workspaceCodexNativeAuthorization(chatLinkID: UUID) throws -> WorkspaceCodexNativeAuthorization? {
        try db.queue.read { try WorkspaceCodexNativeAuthorization.fetchOne($0, key: chatLinkID) }
    }

    public func revokeWorkspaceCodexNativeTools(chatLinkID: UUID) throws {
        try db.queue.write { try $0.execute(sql: "DELETE FROM workspaceCodexNativeAuthorization WHERE chatLinkID = ?", arguments: [chatLinkID]) }
    }

    private static func codexProjectLink(id: UUID, in db: Database) throws -> WorkspaceCodexProjectLink {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM workspaceCodexProjectLink WHERE id = ?", arguments: [id]) else {
            throw WorkspaceCodexLinkError.linkNotFound
        }
        return try decodeCodexProjectLink(row)
    }

    private static func decodeCodexProjectLink(_ row: Row) throws -> WorkspaceCodexProjectLink {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ column: String, _ type: T.Type) throws -> T {
            let value: String = row[column]
            return try decoder.decode(type, from: Data(value.utf8))
        }
        guard let state = WorkspaceCodexLinkState(rawValue: row["state"]) else { throw WorkspaceCodexLinkError.invalidValue }
        return try .init(id: row["id"], projectID: row["projectID"],
            approvedSnapshot: decode("approvedSnapshotJSON", NativeProjectSnapshot.self),
            observedSnapshot: decode("observedSnapshotJSON", NativeProjectSnapshot.self),
            approvedRoots: decode("approvedRootsJSON", [WorkspaceCodexRootReview].self),
            observedRoots: decode("observedRootsJSON", [WorkspaceCodexRootReview].self),
            state: state, revision: row["revision"], createdAt: row["createdAt"], updatedAt: row["updatedAt"])
    }

    private static func codexJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func requireCodexRevision(_ link: WorkspaceCodexProjectLink, _ expected: Int) throws {
        guard link.revision == expected else { throw WorkspaceCodexLinkError.staleRevision }
    }

    private static func clearCodexAuthorizations(projectLinkID: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM workspaceCodexNativeAuthorization WHERE chatLinkID IN (SELECT id FROM workspaceCodexChatLink WHERE projectLinkID = ?)", arguments: [projectLinkID])
    }

    private static func validateCodexValue(_ value: String, limit: Int = 4096) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkspaceCodexLinkError.invalidValue
        }
    }

    private static func validateCodexPath(_ path: String) throws {
        try validateCodexValue(path)
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw WorkspaceCodexLinkError.invalidValue }
    }

    private static func validateCodexSnapshot(_ snapshot: NativeProjectSnapshot, roots: [WorkspaceCodexRootReview]) throws {
        guard snapshot.identity.provider == .codex, !snapshot.roots.isEmpty, snapshot.roots.count <= 128,
              snapshot.roots.map(\.path) == roots.map(\.path), Set(roots.map(\.path)).count == roots.count else {
            throw WorkspaceCodexLinkError.invalidValue
        }
        for value in [snapshot.identity.hostID, snapshot.identity.profileNamespace, snapshot.identity.externalID, snapshot.name] {
            try validateCodexValue(value)
        }
        for root in roots {
            try validateCodexPath(root.path)
            if let path = root.canonicalPath { try validateCodexPath(path) }
            if let identity = root.filesystemIdentity { try validateCodexValue(identity) }
            if root.availability == .available && (root.canonicalPath == nil || root.filesystemIdentity == nil) {
                throw WorkspaceCodexLinkError.invalidValue
            }
        }
    }

    private static func codexRootsAvailable(_ roots: [WorkspaceCodexRootReview]) -> Bool {
        !roots.isEmpty && roots.allSatisfy { $0.availability == .available }
    }

    private static func validateCurrentCodexRoots(_ snapshot: NativeProjectSnapshot, roots: [WorkspaceCodexRootReview]) throws {
        if snapshot.identity.hostID == "local", workspaceCodexRootReviews(for: snapshot) != roots {
            throw WorkspaceCodexLinkError.staleReview
        }
    }

    private static func codexCanonicalCwd(_ cwd: String, hostID: String) throws -> String {
        guard hostID == "local" else { return URL(fileURLWithPath: cwd).standardizedFileURL.path }
        let url = URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw WorkspaceCodexLinkError.invalidWorkingDirectory
        }
        return url.path
    }

    private static func codexContains(_ cwd: String, roots: [WorkspaceCodexRootReview]) -> Bool {
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        return roots.contains { root in
            guard root.availability == .available, let approved = root.canonicalPath else { return false }
            let base = URL(fileURLWithPath: approved).standardizedFileURL.path
            return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
        }
    }
}
