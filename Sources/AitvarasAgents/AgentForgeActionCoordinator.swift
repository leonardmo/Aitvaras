import Foundation
import AitvarasCore

/// Durable request identity and opt-in watch cursors. Forge snapshots are transient.
public struct AgentPullRequest: Codable, Sendable, Equatable {
    public let chatID: UUID
    public let forge: ForgeKind
    public let host: String
    public let repo: String
    public let number: Int
    public let url: URL
    public var watch: Bool
    public let createdAt: Date
    public var commentWatermark: String?
    public var checkWatermark: String?
    public init(chatID: UUID, request: ForgePullRequest) {
        self.chatID = chatID; forge = request.forge; host = request.host; repo = request.repo
        number = request.number; url = request.url; watch = false; createdAt = .now
    }
}
public protocol AgentPullRequestPersistence: AgentWorktreePersistence {
    func agentPullRequest(chatID: UUID) throws -> AgentPullRequest?
    func bindAgentPullRequest(_ value: AgentPullRequest) throws
}
public struct ForgeRequestDraft: Sendable {
    public let directory: URL
    public let branch: String
    public let base: String
    public let head: String
    public let host: String
    public let repo: String
    public let kind: ForgeKind
    public var title: String
    public var body: String
}
public struct ForgeSnapshot: Sendable {
    public let forge: ForgeKind
    public let request: ForgePullRequest?
    public let checks: [ForgeCheck]
    public let checkError: ForgeError?
    public let signedIn: Bool
}

public actor AgentForgeActionCoordinator {
    private let git: GitWorkspace
    private let persistence: any AgentPullRequestPersistence
    private let registry: ForgeRegistry
    private let audit: AgentActionCoordinator.Audit
    private let policy: AutonomyPolicy
    private var busy = false
    public init(git: GitWorkspace = GitWorkspace(), persistence: any AgentPullRequestPersistence,
                registry: ForgeRegistry = ForgeRegistry(), policy: AutonomyPolicy = .init(), audit: @escaping AgentActionCoordinator.Audit) {
        self.git = git; self.persistence = persistence; self.registry = registry; self.policy = policy; self.audit = audit
    }
    private func record(_ operation: String, _ chatID: UUID?, _ risk: ActionRisk, _ result: String) async throws {
        try await audit(ActivityEvent(kind: .toolExecuted, connectorID: "agent.forge", summary: "Forge \(operation): \(result)",
            detailJSON: JSONValue.object(["chatID": chatID.map { .string($0.uuidString) } ?? .null, "risk": .string(risk.rawValue), "result": .string(result)]).jsonString))
    }
    private func authorize(_ operation: String, _ chatID: UUID?, _ risk: ActionRisk, confirmed: Bool = false) async throws {
        let tool = ToolDefinition(name: operation, description: "Forge operation", parametersJSON: "{}", risk: risk)
        let verdict = policy.verdict(for: tool, connectorID: "agent.forge")
        guard verdict == .allow || (verdict == .requireConfirmation && confirmed) else { throw AgentGitError.confirmationRequired }
        // A confirmable outbound creation always has an explicit UI confirmation.
        if risk == .confirmable, !confirmed { throw AgentGitError.confirmationRequired }
        try await record(operation, chatID, risk, "authorized")
    }
    public func kind(host: String?) async throws -> ForgeKind {
        try await authorize("host", nil, .read)
        return try await registry.forge(host: host).kind
    }
    public func authStatus(kind: ForgeKind, host: String) async throws -> ForgeAuthStatus {
        try await authorize("authStatus", nil, .read)
        if kind == .github { return try await registry.github.authStatus(host: host) }
        return try await registry.gitlab.authStatus(host: host)
    }
    public func signIn(kind: ForgeKind, host: String, confirmed: Bool,
                       onDeviceCode: @escaping @Sendable (String) async -> Void = { _ in },
                       onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        try await authorize("signIn", nil, .confirmable, confirmed: confirmed)
        let status = try await authStatus(kind: kind, host: host)
        guard status.installed else { throw ForgeError.notInstalled }
        guard !status.isSignedIn(host: host) else { return }
        do {
            if kind == .github { try await registry.github.signIn(host: host, onDeviceCode: onDeviceCode, onBrowserURL: onBrowserURL) }
            else { try await registry.gitlab.signIn(host: host, onDeviceCode: onDeviceCode, onBrowserURL: onBrowserURL) }
            try await record("signIn", nil, .confirmable, "completed")
        } catch {
            try? await record("signIn", nil, .confirmable, "failed"); throw error
        }
    }
    private func target(_ chatID: UUID, _ directory: URL) async throws -> GitBranchStatus {
        if let owned = try persistence.agentWorktree(chatID: chatID) {
            guard directory.path == owned.worktreePath else { throw AgentGitError.ownershipConflict }
            try await git.verify(owned)
        } else {
            guard try !persistence.requiresAgentWorktree(chatID: chatID) else { throw AgentGitError.creationFailed }
            var allowed = false
            for candidate in try persistence.agentGitDirectories(chatID: chatID) {
                if let root = try? await git.repository(at: candidate), root == directory { allowed = true; break }
            }
            guard allowed else { throw AgentGitError.ownershipConflict }
        }
        return try await git.branchStatus(at: directory)
    }
    private func validate(_ request: ForgePullRequest, host: String, forge: any Forge) throws {
        guard request.host == host.lowercased(), request.forge == forge.kind else { throw ForgeError.failed }
    }
    public func draft(chatID: UUID, directory: URL) async throws -> ForgeRequestDraft {
        try await authorize("prepare", chatID, .read)
        let branch = try await target(chatID, directory)
        if let refusal = branch.pushRefusal() { throw refusal }
        guard branch.upstream == "origin/" + branch.branch, branch.ahead == 0, branch.behind == 0,
              let host = branch.remoteHost else { throw ForgeError.failed }
        let forge = try await registry.forge(host: host)
        let auth = try await forge.authStatus(host: host)
        guard auth.installed else { throw ForgeError.notInstalled }
        guard auth.isSignedIn(host: host) else { throw ForgeError.signedOut }
        let identity = try ForgeCLI.repository(try await git.command(["remote", "get-url", "origin"], in: directory))
        guard identity.host == host else { throw AgentGitError.staleChanges }
        let base = try await git.defaultBranch(at: directory)
        let subjects = try await git.command(["log", "--reverse", "--format=%s", "refs/remotes/origin/\(base)..HEAD", "--"], in: directory)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        return ForgeRequestDraft(directory: directory, branch: branch.branch, base: base,
            head: try await git.command(["rev-parse", "HEAD"], in: directory), host: host, repo: identity.repo, kind: forge.kind,
            title: subjects.first ?? branch.branch, body: subjects.map { "- " + $0 }.joined(separator: "\n"))
    }
    public func refresh(chatID: UUID, directory: URL) async throws -> ForgeSnapshot {
        guard !busy else { throw AgentGitError.busy }; busy = true; defer { busy = false }
        try await authorize("status", chatID, .read)
        let branch = try await target(chatID, directory)
        let forge = try await registry.forge(host: branch.remoteHost)
        let binding = try persistence.agentPullRequest(chatID: chatID)
        // Bound requests survive branch switches and merged/deleted branches.
        var request = try await forge.currentPullRequest(directory: directory, branch: branch.branch)
        if request == nil, let binding, binding.host == branch.remoteHost, binding.forge == forge.kind {
            request = try await forge.pullRequest(directory: directory, number: binding.number)
            if let request, request.repo != binding.repo { throw ForgeError.failed }
        }
        if let request {
            try validate(request, host: branch.remoteHost ?? "", forge: forge)
            try await bind(request, chatID)
        }
        var checks: [ForgeCheck] = []
        var checkError: ForgeError?
        if let request {
            do { checks = try await forge.checks(directory: directory, number: request.number) }
            catch is CancellationError { throw CancellationError() }
            catch { checkError = (error as? ForgeError) ?? .failed }
        }
        let signedIn = if let request, let auth = try? await forge.authStatus(host: request.host) {
            auth.isSignedIn(host: request.host)
        } else { false }
        try await record("status", chatID, .read, checkError == nil ? "completed" : "checksUnavailable")
        return ForgeSnapshot(forge: forge.kind, request: request, checks: checks, checkError: checkError, signedIn: signedIn)
    }
    private func bind(_ request: ForgePullRequest, _ chatID: UUID) async throws {
        if let old = try persistence.agentPullRequest(chatID: chatID), old.forge == request.forge,
           old.host == request.host, old.repo == request.repo, old.number == request.number { return }
        try await authorize("bind", chatID, .reversibleWrite)
        try persistence.bindAgentPullRequest(AgentPullRequest(chatID: chatID, request: request))
        try await record("bind", chatID, .reversibleWrite, "completed")
    }
    public func createPullRequest(chatID: UUID, draft: ForgeRequestDraft, isDraft: Bool, confirmed: Bool) async throws -> ForgePullRequest {
        guard !busy else { throw AgentGitError.busy }; busy = true; defer { busy = false }
        do {
            try await authorize("createPullRequest", chatID, .confirmable, confirmed: confirmed)
            let current = try await self.draft(chatID: chatID, directory: draft.directory)
            guard current.branch == draft.branch, current.base == draft.base, current.head == draft.head,
                  current.host == draft.host, current.repo == draft.repo, current.kind == draft.kind else { throw AgentGitError.staleChanges }
            let forge = try await registry.forge(host: draft.host)
            let existing = try await forge.currentPullRequest(directory: draft.directory, branch: draft.branch)
            // Recheck after the network read; do not create for a switched branch.
            let branch = try await target(chatID, draft.directory)
            let identity = try ForgeCLI.repository(try await git.command(["remote", "get-url", "origin"], in: draft.directory))
            guard identity.host == draft.host, identity.repo == draft.repo,
                  branch.branch == draft.branch, branch.remoteHost == draft.host,
                  try await git.command(["rev-parse", "HEAD"], in: draft.directory) == draft.head else { throw AgentGitError.staleChanges }
            let request: ForgePullRequest
            if let existing { request = existing }
            else { request = try await forge.createPullRequest(directory: draft.directory, branch: draft.branch, base: draft.base, title: draft.title, body: draft.body, draft: isDraft) }
            try validate(request, host: draft.host, forge: forge)
            guard request.repo == draft.repo else { throw ForgeError.failed }
            try await bind(request, chatID)
            try await record("createPullRequest", chatID, .confirmable, "completed")
            return request
        } catch {
            try? await record("createPullRequest", chatID, .confirmable, error is CancellationError ? "interrupted" : "failed")
            throw error
        }
    }
}
