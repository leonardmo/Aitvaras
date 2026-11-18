import Foundation

public enum AgentGitError: Error, Sendable, Equatable {
    case commandFailed, invalidOutput, notRepository, ownershipConflict, creationFailed
    case staleChanges, busy, confirmationRequired, emptyMessage, noChanges
    case authenticationRequired, rejectedNonFastForward, noRemote, network, timedOut
    case detachedHEAD, defaultBranch, unsafeBranch

    public var message: String {
        switch self {
        case .authenticationRequired: "Sign in with your Git credential helper, then try again."
        case .rejectedNonFastForward: "Pull or rebase before pushing again."
        case .noRemote: "Configure an origin remote before pushing."
        case .network: "Could not reach the Git remote. Try again."
        case .timedOut: "Push timed out. Check the remote before trying again."
        case .detachedHEAD: "Switch to a branch before pushing."
        case .defaultBranch: "Switch off the default branch before pushing."
        case .unsafeBranch: "Rename this branch before pushing."
        case .ownershipConflict: "This branch does not belong to this chat."
        case .staleChanges: "Files changed. Review the refreshed diff and try again."
        case .busy: "A Git operation is already running."
        case .confirmationRequired: "Confirm this Git operation first."
        case .emptyMessage: "Enter a commit message."
        case .noChanges: "There are no changes to commit."
        default: "Git operation failed. Refresh and try again."
        }
    }
}

/// Remote URLs are transient process output; only a host may enter UI state.
public struct GitBranchStatus: Sendable, Equatable {
    public let branch: String
    public let detached: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let remoteHost: String?
    public let isDefaultBranch: Bool
    public let hasRemote: Bool

    public func pushRefusal(ownedBranch: String? = nil) -> AgentGitError? {
        if detached { return .detachedHEAD }
        if isDefaultBranch { return .defaultBranch }
        if branch.hasPrefix("+") || branch.hasPrefix("-") || branch.hasPrefix("refs/") || branch.contains(":") { return .unsafeBranch }
        if let ownedBranch, branch != ownedBranch { return .ownershipConflict }
        if !hasRemote { return .noRemote }
        return nil
    }
}

public struct AgentFileChange: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let originalPath: String?
    public let status: String
    public let diff: String
    public let diffUnavailable: Bool
    public var isUntracked: Bool { status == "??" }
    public var statusLabel: String {
        if isUntracked || status.contains("A") { return "New" }
        if status.contains("D") { return "Deleted" }
        if status.contains("R") { return "Renamed" }
        return "Modified"
    }
    public var statusSymbol: String {
        switch statusLabel {
        case "New": "plus.circle"
        case "Deleted": "minus.circle"
        case "Renamed": "arrow.right.circle"
        default: "pencil.circle"
        }
    }
}

public struct ChangesState: Sendable, Equatable {
    public let directory: URL
    public let head: String
    public let files: [AgentFileChange]
    public let fingerprint: String
    public var hasChanges: Bool { !files.isEmpty }
}

public struct AgentWorktree: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case creating, ready, failed }
    public let chatID: UUID
    public let projectID: UUID
    public let repositoryPath: String
    public let worktreePath: String
    public let cwdPath: String
    public let branch: String
    public let additionalRootsJSON: String
    public var state: State
    public var additionalRoots: [URL] {
        ((try? JSONDecoder().decode([String].self, from: Data(additionalRootsJSON.utf8))) ?? []).map { URL(fileURLWithPath: $0) }
    }
    public func directory(for folder: URL) -> URL {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if path == repositoryPath { return URL(fileURLWithPath: worktreePath) }
        if path.hasPrefix(repositoryPath + "/") {
            return URL(fileURLWithPath: worktreePath).appendingPathComponent(String(path.dropFirst(repositoryPath.count + 1)))
        }
        return folder.resolvingSymlinksInPath().standardizedFileURL
    }
    public init(chatID: UUID, projectID: UUID, repository: URL, worktree: URL, branch: String, additionalRoots: [URL], primaryDirectory: URL? = nil) throws {
        self.chatID = chatID; self.projectID = projectID
        repositoryPath = repository.path; worktreePath = worktree.path; self.branch = branch; state = .creating
        let primary = (primaryDirectory ?? repository).resolvingSymlinksInPath().standardizedFileURL.path
        guard primary == repository.path || primary.hasPrefix(repository.path + "/") else { throw AgentGitError.ownershipConflict }
        cwdPath = primary == repository.path ? worktree.path : worktree.appendingPathComponent(String(primary.dropFirst(repository.path.count + 1))).path
        additionalRootsJSON = String(decoding: try JSONEncoder().encode(additionalRoots.map(\.path)), as: UTF8.self)
    }
}

public protocol AgentWorktreePersistence: Sendable {
    func agentGitDirectories(chatID: UUID) throws -> [URL]
    func requiresAgentWorktree(chatID: UUID) throws -> Bool
    func agentWorktree(chatID: UUID) throws -> AgentWorktree?
    func reserveAgentWorktree(_ value: AgentWorktree) throws
    func finishAgentWorktree(chatID: UUID, state: AgentWorktree.State) throws
}

extension AgentWorktreePersistence {
    public func requiresAgentWorktree(chatID: UUID) throws -> Bool { try agentWorktree(chatID: chatID) != nil }
}
