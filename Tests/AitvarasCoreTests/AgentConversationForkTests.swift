import Foundation
import Testing
import GRDB
import AitvarasCore
@testable import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct AgentConversationForkTests {
    @Test func forkCopiesOnlyTheSelectedPrefixAndKeepsASeparatePendingIdentity() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
expected=json.load(open('expected-argv.json'))
assert sys.argv[1:]==expected
claude_init()
r=read(); assert r['message']['content']=='Continue'
emit({'type':'system','subtype':'init','session_id':'00000000-0000-4000-8000-000000000002','apiKeySource':'none'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let source = try conversationFixture(stores, directory: fixture.directory)
        let original = try stores.agentEntries(chatID: source.chatID)
        let actions = conversationActions(stores, storage: fixture.directory.appendingPathComponent("worktrees"))
        let result = try await actions.fork(chatID: source.chatID, messageID: source.entries[1].id)
        let session = try #require(try stores.agentSession(chatID: result.chatID, provider: .claude))
        #expect(try stores.workspaceChat(id: result.chatID)?.projectID == source.projectID)
        #expect(session.sessionID == nil)
        #expect(session.forkOrigin?.pending == true)
        #expect(session.configuration.resume == source.session.sessionID)
        #expect(session.configuration.forkSession)
        #expect(try stores.agentEntries(chatID: result.chatID).map(\.text) == ["First question", "First answer"])
        #expect(try stores.agentContext(session: session) == nil)
        let expected = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-prompt-tool", "stdio", "--permission-mode", "default",
            "--model", "test-model", "--resume", source.session.nativeID!, "--fork-session", "--resume-session-at", source.entries[1].nativeMessageID!,
            "--settings", "{\"disabledMcpjsonServers\":[]}", "--include-hook-events"]
        try JSONEncoder().encode(expected).write(to: fixture.directory.appendingPathComponent("expected-argv.json"))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.send(chatID: result.chatID, provider: .claude, input: .init(text: "Continue"))
        try await conversationWait { try await manager.state(chatID: result.chatID).outcome == .completed }
        let bound = try #require(try stores.agentSession(chatID: result.chatID, provider: .claude))
        #expect(bound.nativeID == "00000000-0000-4000-8000-000000000002")
        #expect(bound.forkOrigin?.pending == false)
        #expect(!bound.configuration.forkSession)
        #expect(bound.configuration.resume == bound.sessionID)
        #expect(try stores.agentEntries(chatID: source.chatID) == original)
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test func editCutsBeforeTheUserAndFirstMessageStartsFresh() async throws {
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: URL(fileURLWithPath: "/tmp"))
        let actions = conversationActions(stores, storage: URL(fileURLWithPath: "/tmp/unused-worktrees"))
        let edited = try await actions.fork(chatID: source.chatID, messageID: source.entries[2].id, editedText: "Edited question")
        let session = try #require(try stores.agentSession(chatID: edited.chatID, provider: .claude))
        #expect(session.forkOrigin?.assistantMessageID == source.entries[1].nativeMessageID)
        #expect(edited.input?.text == "Edited question")
        #expect(edited.input?.id != source.entries[2].id)
        #expect(try stores.agentEntries(chatID: edited.chatID).count == 2)
        let first = try await actions.fork(chatID: source.chatID, messageID: source.entries[0].id, editedText: "Fresh question")
        let fresh = try #require(try stores.agentSession(chatID: first.chatID, provider: .claude))
        #expect(fresh.forkOrigin == nil && fresh.sessionID == nil)
        #expect(!fresh.configuration.forkSession && fresh.configuration.resume == nil)
        #expect(try stores.agentEntries(chatID: first.chatID).isEmpty)
        #expect(first.input?.text == "Fresh question")
    }

    @Test func unsupportedIncompleteStaleAndBusyMessagesFailBeforeCreatingAChat() async throws {
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: URL(fileURLWithPath: "/tmp"))
        let actions = conversationActions(stores, storage: URL(fileURLWithPath: "/tmp/unused-worktrees"))
        let count = try stores.workspaceChats(projectID: source.projectID).count
        await #expect(throws: AgentConversationError.invalidMessage) { try await actions.fork(chatID: source.chatID, messageID: UUID()) }
        await #expect(throws: AgentConversationError.unavailable) { try await actions.fork(chatID: source.chatID, messageID: source.entries[0].id) }
        await #expect(throws: AgentFailure.invalidRequest) { try await actions.fork(chatID: source.chatID, messageID: source.entries[0].id, editedText: " ") }
        let plan = try AgentConversationForkPlan.make(source: stores.conversationSource(chatID: source.chatID), messageID: source.entries[1].id, editing: false)
        var changed = source.entries[1]; changed.text = "Changed answer"; _ = try stores.saveAgentEntry(changed)
        #expect(throws: AgentConversationError.invalidMessage) { try stores.createConversationFork(plan, chatID: UUID(), directory: URL(fileURLWithPath: "/tmp"), additionalRoots: []) }
        try stores.prepareAgentTurn(.init(input: .init(text: "Active"), chatID: source.chatID, sessionID: source.session.id))
        await #expect(throws: AgentConversationError.busy) { try await actions.fork(chatID: source.chatID, messageID: source.entries[1].id) }
        #expect(try stores.workspaceChats(projectID: source.projectID).count == count)
    }

    @Test func forkAuditFailureRollsBackRecordsAndNeverLogsConversationText() async throws {
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: URL(fileURLWithPath: "/tmp"))
        let plan = try AgentConversationForkPlan.make(source: stores.conversationSource(chatID: source.chatID), messageID: source.entries[1].id, editing: false)
        try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER forkAuditFailure BEFORE INSERT ON activityEvent WHEN NEW.connectorID = 'agent.conversation' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        let child = UUID()
        #expect(throws: (any Error).self) { try stores.createConversationFork(plan, chatID: child, directory: URL(fileURLWithPath: "/tmp"), additionalRoots: []) }
        #expect(try stores.workspaceChat(id: child) == nil)
        #expect(try stores.agentSession(chatID: child, provider: .claude) == nil)
        #expect(try stores.activity(since: .distantPast).allSatisfy { !($0.detailJSON ?? "").contains("First question") })
    }

    @Test func forkOfAWorktreeUsesItsOwnCheckoutAtTheSourceBranchTip() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let root = fixture.directory.resolvingSymlinksInPath()
        let git = GitWorkspace(environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        try await git.command(["init", "-b", "main"], in: root)
        try await git.command(["config", "user.name", "Example"], in: root)
        try await git.command(["config", "user.email", "person@example.org"], in: root)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("example.txt"))
        try await git.command(["add", "example.txt"], in: root)
        try await git.command(["commit", "-m", "Initial fixture"], in: root)
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: root)
        let storage = root.appendingPathComponent("worktrees")
        let coordinator = AgentGitActionCoordinator(git: git, persistence: stores, audit: { _ = try stores.record($0) })
        let owned = try await coordinator.create(chatID: source.chatID, projectID: source.projectID, folders: [root], storage: storage)
        var session = source.session; session.cwd = owned.cwdPath; try stores.saveAgentSession(session)
        let sourceDirectory = URL(fileURLWithPath: owned.worktreePath)
        try Data("committed source\n".utf8).write(to: sourceDirectory.appendingPathComponent("example.txt"))
        try await git.command(["add", "example.txt"], in: sourceDirectory)
        try await git.command(["commit", "-m", "Advance source branch"], in: sourceDirectory)
        let sourceTip = try await git.command(["rev-parse", "HEAD"], in: sourceDirectory)
        #expect(try await git.command(["rev-parse", "HEAD"], in: root) != sourceTip)
        try Data("uncommitted\n".utf8).write(to: sourceDirectory.appendingPathComponent("example.txt"))
        let actions = AgentConversationActions(persistence: stores, git: coordinator, worktreeStorage: storage,
            backend: { _ in throw AgentFailure.unsupported }, audit: { _ = try stores.record($0) })
        let child = try await actions.fork(chatID: source.chatID, messageID: source.entries[1].id)
        let fork = try #require(try stores.agentWorktree(chatID: child.chatID))
        #expect(fork.worktreePath != owned.worktreePath)
        #expect(try await git.command(["rev-parse", "HEAD"], in: URL(fileURLWithPath: fork.worktreePath)) == sourceTip)
        #expect(try String(contentsOf: URL(fileURLWithPath: fork.worktreePath).appendingPathComponent("example.txt"), encoding: .utf8) == "committed source\n")
        #expect(try stores.agentSession(chatID: child.chatID, provider: .claude)?.cwd == fork.cwdPath)
        #expect(try stores.agentWorktree(chatID: source.chatID) == owned)
    }

    @Test func v33UpgradePreservesExistingSessionsAndEntries() throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("state.sqlite")
        let source: AgentConversationSource
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            source = try conversationFixture(stores, directory: fixture.directory)
            try stores.db.queue.write { db in
                try db.execute(sql: "ALTER TABLE agentChatSession DROP COLUMN forkOrigin")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v34-agent-conversation-forks"])
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.conversationSource(chatID: source.chatID) == source)
        #expect(try stores.agentSession(chatID: source.chatID, provider: .claude)?.forkOrigin == nil)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func aForkCannotBindTheOriginalNativeIdentity() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
sid=sys.argv[sys.argv.index('--resume')+1].lower()
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':sid})
for _ in range(10): time.sleep(1)
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores(), initial = try conversationFixture(stores, directory: fixture.directory)
        var original = initial.session; original.nativeID = "A0000000-0000-4000-8000-000000000001"
        try stores.saveAgentSession(original)
        let source = try stores.conversationSource(chatID: initial.chatID)
        let actions = conversationActions(stores, storage: fixture.directory.appendingPathComponent("worktrees"))
        let child = try await actions.fork(chatID: source.chatID, messageID: source.entries[1].id)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try? await manager.send(chatID: child.chatID, provider: .claude, input: .init(text: "Example"))
        try await conversationWait { if case .failed = try await manager.state(chatID: child.chatID).outcome { true } else { false } }
        let stored = try #require(try stores.agentSession(chatID: child.chatID, provider: .claude))
        #expect(stored.sessionID == nil && stored.forkOrigin?.pending == true)
        #expect(try stores.agentSession(chatID: source.chatID, provider: .claude)?.sessionID == source.session.sessionID)
        try await manager.shutdown()
    }

    @Test func otherProvidersRejectForkFlagsBeforeStartingAnything() async throws {
        let configuration = AgentSessionConfiguration(directory: URL(fileURLWithPath: "/tmp"), model: "default",
            forkSession: true, resumeSessionAt: UUID().uuidString)
        let codex = CodexBackend(environment: ["PATH": ""])
        let local = LocalBackend { _, _ in Issue.record("Must not run Local"); throw AgentFailure.unsupported }
        await #expect(throws: AgentFailure.unsupported) { try await codex.start(configuration) }
        await #expect(throws: AgentFailure.unsupported) { try await local.start(configuration) }
    }

    @Test func nativeRefreshOfAForkOfAForkKeepsAcknowledgedHandoverTextHidden() async throws {
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: URL(fileURLWithPath: "/tmp"))
        let wire = "Synthetic context envelope\nFirst question"
        let input = AgentInput(id: source.entries[0].id, text: wire)
        try stores.prepareAgentTurn(.init(input: input, chatID: source.chatID, sessionID: source.session.id))
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
        try stores.finishAgentTurn(id: input.id, state: .completed)
        let actions = conversationActions(stores, storage: URL(fileURLWithPath: "/tmp/unused-worktrees"))
        let child = try await actions.fork(chatID: source.chatID, messageID: source.entries[1].id)
        var childSession = try #require(try stores.agentSession(chatID: child.chatID, provider: .claude))
        childSession.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
        childSession.forkOrigin?.pending = false; try stores.saveAgentSession(childSession)
        let childEntries = try stores.agentEntries(chatID: child.chatID)
        let grandchild = try await actions.fork(chatID: child.chatID, messageID: childEntries[1].id)
        var session = try #require(try stores.agentSession(chatID: grandchild.chatID, provider: .claude))
        session.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
        session.forkOrigin?.pending = false; try stores.saveAgentSession(session)
        let before = try stores.agentEntries(chatID: grandchild.chatID)
        let observed = before.enumerated().map { index, entry in
            AgentTranscriptEntry(chatID: grandchild.chatID, provider: .claude, kind: entry.kind,
                text: index == 0 ? wire : entry.text, payloadJSON: #"{"nativeHistory":{"completed":true}}"#,
                sessionID: session.id, nativeMessageID: entry.nativeMessageID)
        }
        try stores.reconcileAgentHistory(session: session, entries: observed)
        #expect(try stores.agentEntries(chatID: grandchild.chatID).map(\.text) == ["First question", "First answer"])
    }
}

func conversationFixture(_ stores: Stores, directory: URL) throws -> AgentConversationSource {
    let (chat, original) = try agentStoreChat(stores, cwd: directory.path)
    var session = original
    session.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
    try stores.saveAgentSession(session)
    for (index, text) in ["First question", "First answer", "Second question", "Second answer"].enumerated() {
        _ = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: index.isMultiple(of: 2) ? "user" : "assistant", text: text,
            payloadJSON: #"{"nativeHistory":{"completed":true}}"#, sessionID: session.id, nativeMessageID: UUID().uuidString))
    }
    return try stores.conversationSource(chatID: chat.id)
}
func conversationActions(_ stores: Stores, storage: URL, backend: (any AgentBackend)? = nil) -> AgentConversationActions {
    .init(persistence: stores, git: AgentGitActionCoordinator(persistence: stores, audit: { _ = try stores.record($0) }),
        worktreeStorage: storage, backend: { _ in guard let backend else { throw AgentFailure.unsupported }; return backend }, audit: { _ = try stores.record($0) })
}
func conversationWait(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(10))
    }
}
