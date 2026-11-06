import Foundation
import AitvarasCore

/// Serial policy/audit boundary for application-owned git operations. Native
/// hooks run normally. Audit never includes paths, file contents or messages.
public actor AgentGitActionCoordinator {
    private let git: GitWorkspace
    private let persistence: any AgentWorktreePersistence
    private let policy: AutonomyPolicy
    private let audit: AgentActionCoordinator.Audit
    private var busy = false
    public init(git: GitWorkspace = GitWorkspace(), persistence: any AgentWorktreePersistence,
                policy: AutonomyPolicy = .init(), audit: @escaping AgentActionCoordinator.Audit) {
        self.git = git; self.persistence = persistence; self.policy = policy; self.audit = audit
    }
    public func create(chatID: UUID, projectID: UUID, folders: [URL], storage: URL) async throws -> AgentWorktree {
        guard !busy else { throw AgentGitError.busy }; busy = true; defer { busy = false }
        if let old = try persistence.agentWorktree(chatID: chatID) {
            guard old.projectID == projectID else { throw AgentGitError.ownershipConflict }
            try await git.verify(old); return old
        }
        guard let first = folders.first else { throw AgentGitError.notRepository }
        let root: URL
        do { root = try await git.repository(at: first) }
        catch {
            // The user's isolation intent must survive even a failed preflight.
            let failed = try AgentWorktree(chatID: chatID, projectID: projectID,
                repository: first.resolvingSymlinksInPath(),
                worktree: storage.resolvingSymlinksInPath().appendingPathComponent(chatID.uuidString),
                branch: "aitvaras/chat-\(chatID.uuidString.lowercased())", additionalRoots: [])
            try await authorize("createWorktree", chatID: chatID, risk: .reversibleWrite, confirmed: false)
            try persistence.reserveAgentWorktree(failed)
            try persistence.finishAgentWorktree(chatID: chatID, state: .failed)
            try await record("createWorktree", chatID: chatID, result: "failed", risk: .reversibleWrite)
            throw error
        }
        let parent = storage.resolvingSymlinksInPath().standardizedFileURL
        let destination = parent.appendingPathComponent(chatID.uuidString)
        let value = try AgentWorktree(chatID: chatID, projectID: projectID, repository: root,
            worktree: destination, branch: "aitvaras/chat-\(chatID.uuidString.lowercased())",
            additionalRoots: folders.dropFirst().map { folder in
                let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
                if path == root.path { return destination }
                if path.hasPrefix(root.path + "/") {
                    return destination.appendingPathComponent(String(path.dropFirst(root.path.count + 1)))
                }
                return URL(fileURLWithPath: path)
            }.filter { $0 != destination }, primaryDirectory: first)
        try await authorize("createWorktree", chatID: chatID, risk: .reversibleWrite, confirmed: false)
        try persistence.reserveAgentWorktree(value)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try await git.create(value)
            var ready = value; ready.state = .ready
            try await git.verify(ready)
            try persistence.finishAgentWorktree(chatID: chatID, state: .ready)
            try await record("createWorktree", chatID: chatID, result: "completed", risk: .reversibleWrite)
            return ready
        } catch {
            // Keep failed ownership, including a partially created worktree.
            // Never force-remove or redirect into the original checkout.
            try? persistence.finishAgentWorktree(chatID: chatID, state: .failed)
            try? await record("createWorktree", chatID: chatID, result: "failed", risk: .reversibleWrite)
            throw error
        }
    }
    public func mapping(chatID: UUID) async throws -> AgentWorktree? {
        guard let value = try persistence.agentWorktree(chatID: chatID) else {
            if try persistence.requiresAgentWorktree(chatID: chatID) { throw AgentGitError.creationFailed }
            return nil
        }
        try await git.verify(value); return value
    }
    public func changes(in directory: URL) async throws -> ChangesState { try await git.changes(in: directory) }

    public func commit(chatID: UUID, expected: ChangesState, message: String, confirmed: Bool) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0"), message.utf8.count <= 8192 else {
            throw AgentGitError.emptyMessage
        }
        try await perform("commit", chatID: chatID, expected: expected, confirmed: confirmed) {
            let paths = expected.files.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            _ = try await self.git.command(["add", "-A", "--"] + paths, in: expected.directory)
            try Task.checkCancellation()
            // --only leaves unrelated index entries alone; no generated trailers.
            _ = try await self.git.command(["commit", "--only", "-m", message, "--"] + paths, in: expected.directory)
        }
    }
    public func discard(chatID: UUID, expected: ChangesState, confirmed: Bool) async throws {
        try await perform("discard", chatID: chatID, expected: expected, confirmed: confirmed) {
            guard let value = try self.persistence.agentWorktree(chatID: chatID),
                  value.worktreePath == expected.directory.path else { throw AgentGitError.ownershipConflict }
            try await self.git.verify(value)
            // Refuse submodules and nested repositories rather than recurse into
            // foreign ownership. clean has one -f, never the double-force form.
            for file in expected.files {
                var isDirectory: ObjCBool = false
                let path = expected.directory.appendingPathComponent(file.path).path
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw AgentGitError.ownershipConflict
                }
            }
            let tracked = expected.files.filter { !$0.isUntracked }.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
            if !tracked.isEmpty {
                _ = try await self.git.command(["restore", "--source=HEAD", "--staged", "--worktree", "--"] + tracked, in: expected.directory)
            }
            try Task.checkCancellation()
            let untracked = expected.files.filter(\.isUntracked).map(\.path)
            if !untracked.isEmpty { _ = try await self.git.command(["clean", "-f", "--"] + untracked, in: expected.directory) }
        }
    }
    private func perform(_ operation: String, chatID: UUID, expected: ChangesState, confirmed: Bool,
                         action: () async throws -> Void) async throws {
        guard !busy else { throw AgentGitError.busy }; busy = true; defer { busy = false }
        guard expected.hasChanges else { throw AgentGitError.noChanges }
        // A bound worktree must match; a normal checkout permits commit only.
        if try persistence.requiresAgentWorktree(chatID: chatID), try persistence.agentWorktree(chatID: chatID) == nil {
            throw AgentGitError.creationFailed
        }
        if let owned = try persistence.agentWorktree(chatID: chatID) {
            guard owned.worktreePath == expected.directory.path else { throw AgentGitError.ownershipConflict }
            try await git.verify(owned)
        } else {
            var allowed = false
            for directory in try persistence.agentGitDirectories(chatID: chatID) {
                if let root = try? await git.repository(at: directory), root.path == expected.directory.path { allowed = true; break }
            }
            guard allowed else { throw AgentGitError.ownershipConflict }
        }
        let current = try await git.changes(in: expected.directory)
        guard current.fingerprint == expected.fingerprint else { throw AgentGitError.staleChanges }
        try await authorize(operation, chatID: chatID, risk: .confirmable, confirmed: confirmed)
        do {
            try Task.checkCancellation()
            // Authorization can yield to storage; catch edits made during it.
            guard try await git.changes(in: expected.directory).fingerprint == expected.fingerprint else {
                throw AgentGitError.staleChanges
            }
            try await action()
            try await record(operation, chatID: chatID, result: "completed", risk: .confirmable)
        } catch {
            try? await record(operation, chatID: chatID, result: error is CancellationError ? "interrupted" : "failed", risk: .confirmable)
            throw error
        }
    }
    private func authorize(_ operation: String, chatID: UUID, risk: ActionRisk, confirmed: Bool) async throws {
        let tool = ToolDefinition(name: operation, description: "Git operation", parametersJSON: "{}", risk: risk)
        if policy.verdict(for: tool, connectorID: "git") == .requireConfirmation, !confirmed {
            throw AgentGitError.confirmationRequired
        }
        try await record(operation, chatID: chatID, result: "authorized", risk: risk)
    }
    private func record(_ operation: String, chatID: UUID, result: String, risk: ActionRisk) async throws {
        try await audit(ActivityEvent(kind: .toolExecuted, connectorID: "git", summary: "Git \(operation): \(result)",
            detailJSON: JSONValue.object(["chatID": .string(chatID.uuidString), "risk": .string(risk.rawValue),
                                           "result": .string(result)]).jsonString))
    }
}
