import Foundation
import Testing
import GRDB
import AitvarasCore
@testable import AitvarasStore
@testable import AitvarasAgents

@Suite struct AgentNativeIdentityTests {
    @Test func repeatDiscoveryScopesNativeIDsByProviderHostAndProfile() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/tmp/example-project")])
        let values = [summary(), summary(profile: "other"), summary(host: "other-host"), summary(provider: .codex)]
        let first = try stores.discoverAgentNativeSessions(values + values)
        #expect(first.count == 4)
        #expect(try stores.discoverAgentNativeSessions(values.reversed()) == first)
        let chats = try stores.workspaceChats(projectID: project.id)
        #expect(chats.count == 4)
        #expect(try stores.db.queue.read { try AgentChatSession.fetchAll($0).count } == 4)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
        #expect(try stores.db.queue.read { try Conversation.fetchAll($0).count } == 4)
    }

    @Test func existingAppSessionKeepsChatSettingsAndLegacyEvidence() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/tmp/example-project")])
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Renamed here")
        var session = AgentChatSession(chatID: chat.id, provider: .claude, cwd: "/tmp/example-project", model: "chosen", mode: .plan)
        session.sessionID = summary().id
        try stores.saveAgentSession(session)
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let evidence = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "legacy-model", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        let savedChat = try stores.workspaceChat(id: chat.id)
        #expect(try stores.discoverAgentNativeSessions([summary()]) == [chat.id])
        #expect(try stores.workspaceChat(id: chat.id) == savedChat)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude) == session)
        #expect(try stores.workspaceFrontierSession(id: evidence.id) == evidence)
        #expect(try stores.agentEntries(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceChats(projectID: project.id).count == 1)
    }

    @Test func symlinksNestedRootsAndFolderBoundaries() throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("source")
        let nested = root.appendingPathComponent("nested")
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let stores = try inMemoryStores()
        let outer = try stores.createWorkspaceProject(title: "Outer", folders: [.init(path: root.path)])
        let inner = try stores.createWorkspaceProject(title: "Inner", folders: [.init(path: nested.path)])
        let id = try #require(try stores.discoverAgentNativeSessions([summary(cwd: alias.path)]).first)
        #expect(try stores.workspaceChat(id: id)?.projectID == outer.id)
        #expect(try stores.discoverAgentNativeSessions([summary(cwd: root.path)]) == [id])
        let child = try #require(try stores.discoverAgentNativeSessions([summary(id: "child", cwd: alias.appendingPathComponent("nested").path)]).first)
        #expect(try stores.workspaceChat(id: child)?.projectID == inner.id)
        #expect(try stores.discoverAgentNativeSessions([summary(id: "outside", cwd: root.path + "-other")]).isEmpty)
    }

    @Test func ambiguousRootsAndIdentityDriftRollBackEntireBatch() throws {
        let stores = try inMemoryStores()
        let one = try stores.createWorkspaceProject(title: "One", folders: [.init(path: "/tmp/example-project")])
        _ = try stores.createWorkspaceProject(title: "Two", folders: [.init(path: "/tmp/example-project")])
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.discoverAgentNativeSessions([summary()]) }
        #expect(try stores.workspaceChats(projectID: one.id).isEmpty)
        let other = try inMemoryStores()
        _ = try other.createWorkspaceProject(title: "One", folders: [.init(path: "/tmp/example-project")])
        let saved = try other.discoverAgentNativeSessions([summary()])
        #expect(throws: AgentNativeHistoryError.identityConflict) {
            try other.discoverAgentNativeSessions([summary(id: "new"), summary(cwd: "/tmp/outside")])
        }
        #expect(try other.db.queue.read { try WorkspaceChat.fetchAll($0).map(\.id) } == saved)
    }

    @Test func worktreesMapToTheirOwnerAndRejectConflictingOrFailedOwnership() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/tmp/example-project"), .init(path: "/tmp/additional")])
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Owned", requiresWorktree: true)
        let tree = try AgentWorktree(chatID: chat.id, projectID: project.id,
            repository: URL(fileURLWithPath: "/tmp/example-project"), worktree: URL(fileURLWithPath: "/tmp/owned-tree"),
            branch: "fixture", additionalRoots: [URL(fileURLWithPath: "/tmp/additional")])
        try stores.reserveAgentWorktree(tree)
        #expect(throws: AgentNativeHistoryError.identityConflict) {
            try stores.discoverAgentNativeSessions([summary(cwd: tree.worktreePath)])
        }
        try stores.finishAgentWorktree(chatID: chat.id, state: .ready)
        try stores.setValues(["agent.provider.\(chat.id.uuidString)": "local"])
        #expect(try stores.discoverAgentNativeSessions([summary(cwd: tree.worktreePath)]) == [chat.id])
        #expect(try stores.value(forKey: "agent.provider.\(chat.id.uuidString)") == "local")
        #expect(try stores.discoverAgentNativeSessions([summary(cwd: tree.worktreePath)]) == [chat.id])
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.additionalRootsJSON == tree.additionalRootsJSON)
        #expect(throws: AgentNativeHistoryError.identityConflict) {
            try stores.discoverAgentNativeSessions([summary(id: "another", cwd: tree.worktreePath)])
        }
        #expect(try stores.workspaceChats(projectID: project.id).count == 1)
    }

    @Test func managerReadsAllPagesBeforeMappingAndNeverStartsARun() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/tmp/example-project")])
        let backend = NativeDiscoveryBackend()
        let value = summary()
        await backend.setPages([.init(items: [value], nextCursor: "next"), .init(items: [value])])
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(try await manager.discoverNativeSessions(provider: .claude).count == 1)
        #expect(await backend.starts == 0)
        #expect(try stores.workspaceChats(projectID: project.id).count == 1)
        await backend.setPages([.init(items: [summary(id: "uncommitted")], nextCursor: "next")])
        await #expect(throws: AgentFailure.offline) { try await manager.discoverNativeSessions(provider: .claude) }
        #expect(try stores.workspaceChats(projectID: project.id).count == 1)
        await backend.setPages([.init(items: [], nextCursor: "cycle"), .init(items: [], nextCursor: "cycle")])
        await #expect(throws: AgentNativeHistoryError.invalidCursor) { try await manager.discoverNativeSessions(provider: .claude) }
        #expect(await backend.starts == 0)
        try await manager.shutdown()
    }

    @Test func previewIsReadOnlyAndDiscoversEveryRegisteredFolder() async throws {
        let fixture = try NativeHistoryFixture()
        defer { fixture.remove() }
        try fixture.write(records: (0..<55).map { fixture.record("user", text: "Message \($0)", id: "message-\($0)") })
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [
            .init(path: "/tmp/another-project-folder"), .init(path: fixture.root.path)])
        let backend = ClaudeBackend(executable: fixture.root.appendingPathComponent("missing-provider"), environment: ["PATH": ""],
                                    overrides: ["CLAUDE_CONFIG_DIR": fixture.root.path])
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let chatID = try #require(try await manager.discoverNativeSessions(provider: .claude).first)
        #expect(try stores.workspaceChat(id: chatID)?.projectID == project.id)
        let session = try #require(try stores.agentSession(chatID: chatID, provider: .claude))
        #expect(session.cwd == fixture.root.resolvingSymlinksInPath().path)
        #expect(session.configuration.resume == fixture.session)
        let entries = try await manager.nativeHistoryPreview(chatID: chatID, provider: .claude)
        #expect(entries.count == 55)
        #expect(entries.allSatisfy { $0.sessionID == session.id && $0.chatID == chatID })
        #expect(try stores.agentEntries(chatID: chatID).isEmpty)
        #expect(try stores.latestAgentTurn(chatID: chatID) == nil)
        #expect(try stores.agentSession(chatID: chatID, provider: .claude) == session)
        try await manager.shutdown()
    }

    @Test func discoveryCannotBindAWorktreeSessionDuringAnActiveSend() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/tmp/example-project")])
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Owned")
        let tree = try AgentWorktree(chatID: chat.id, projectID: project.id,
            repository: URL(fileURLWithPath: "/tmp/example-project"), worktree: URL(fileURLWithPath: "/tmp/example-tree"),
            branch: "fixture", additionalRoots: [])
        try stores.reserveAgentWorktree(tree)
        try stores.finishAgentWorktree(chatID: chat.id, state: .ready)
        let session = AgentChatSession(chatID: chat.id, provider: .claude, cwd: tree.worktreePath, model: "chosen")
        try stores.saveAgentSession(session)
        let turn = AgentJournalTurn(input: .init(text: "Example"), chatID: chat.id, sessionID: session.id)
        try stores.prepareAgentTurn(turn)
        #expect(throws: AgentNativeHistoryError.identityConflict) {
            try stores.discoverAgentNativeSessions([summary(cwd: tree.worktreePath)])
        }
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.sessionID == nil)
        try stores.finishAgentTurn(id: turn.id, state: .interrupted)
        #expect(try stores.discoverAgentNativeSessions([summary(cwd: tree.worktreePath)]) == [chat.id])
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.id == session.id)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude)?.model == "chosen")
    }

    private func summary(provider: AgentProvider = .claude, profile: String = "default", host: String = "local",
                         id: String = "native", cwd: String = "/tmp/example-project") -> AgentSessionSummary {
        .init(id: .init(provider: provider, host: host, profile: profile, nativeID: id), title: "Native chat", directory: URL(fileURLWithPath: cwd))
    }
}

private actor NativeDiscoveryBackend: AgentBackend {
    var starts = 0
    private var pages: [AgentPage<AgentSessionSummary>] = []
    func setPages(_ pages: [AgentPage<AgentSessionSummary>]) { self.pages = pages }
    func nativeSessions(folder: URL?, cursor: String?, archived: Bool) throws -> AgentPage<AgentSessionSummary> {
        guard !pages.isEmpty else { throw AgentFailure.offline }
        return pages.removeFirst()
    }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: [.history]) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun { starts += 1; throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
