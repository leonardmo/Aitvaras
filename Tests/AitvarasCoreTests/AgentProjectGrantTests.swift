import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentProjectGrantTests {
    @Test func aitvarasPolicyForcesNativeAskAndPersistentGrantSuppressesOnlyTheExactTool() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--setting-sources' not in sys.argv
claude_init()
read()
sid=str(uuid.uuid4())
emit({'type':'system','subtype':'init','session_id':sid,'apiKeySource':'none'})
for n in range(2):
    tool='mcp__echo__echo'
    emit({'type':'control_request','request_id':'hook-'+str(n),'request':{'subtype':'hook_callback','callback_id':'pre','tool_use_id':'tool-'+str(n),'input':{'hook_event_name':'PreToolUse','tool_name':tool,'tool_input':{'query':'synthetic-private-query'}}}})
    reply=read()['response']['response']
    assert reply['hookSpecificOutput']=={'hookEventName':'PreToolUse','permissionDecision':'ask'}
    emit({'type':'control_request','request_id':'permission-'+str(n),'request':{'subtype':'can_use_tool','tool_use_id':'tool-'+str(n),'tool_name':tool,'input':{'query':'synthetic-private-query'}}})
    assert read()['response']['response']['behavior']=='allow'
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        var setup = WorkspaceAgentSetup(projectID: chat.projectID); setup.permissionSource = .aitvaras
        setup.extraServersJSON = try AgentMCPConfiguration.encode(["echo": AgentMCPServer(command: "echo")])
        let grant = "claude.mcp__echo__echo@" + (try AgentMCPServer(command: "echo").fingerprint())
        try stores.saveWorkspaceAgentSetup(setup)
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
            overrides: ["CLAUDE_CONFIG_DIR": fixture.directory.appendingPathComponent("user").path], mcpPolicy: policy)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) }, mcpPolicy: policy)
        try await manager.send(chatID: chat.id, provider: .claude, input: .init(text: "Example"))
        try await waitGrant { try await manager.state(chatID: chat.id).pendingCards.count == 1 }
        let request = try #require(try await manager.state(chatID: chat.id).pendingCards.first)
        #expect(request.canAlwaysAllowInProject)
        try await manager.alwaysAllow(chatID: chat.id, request: request)
        try await waitGrant { try await manager.state(chatID: chat.id).outcome == .completed }
        #expect(try stores.agentAlwaysAllowedTools(chatID: chat.id) == [grant])
        let sibling = try stores.createWorkspaceChat(projectID: chat.projectID, title: "Sibling")
        #expect(try stores.agentAlwaysAllowedTools(chatID: sibling.id) == [grant])
        let other = try agentStoreChat(stores).0
        #expect(try stores.agentAlwaysAllowedTools(chatID: other.id).isEmpty)
        let activity = try stores.activity(since: .distantPast)
        #expect(activity.filter { $0.kind == .suggestionOffered }.count == 1)
        #expect(activity.filter { $0.summary == "Allow agent tool in project" }.count == 1)
        #expect(activity.allSatisfy { !($0.detailJSON ?? "").contains("synthetic-private-query") })
        await #expect(throws: (any Error).self) { try await manager.alwaysAllow(chatID: chat.id, request: request) }
        try fixture.assertComplete(); try await manager.shutdown()
    }

    @Test(arguments: [AgentMode.ask, .acceptEdits, .plan, .auto])
    func forbiddenNamesRemainFirstEvenWithInjectedProjectGrants(mode: AgentMode) async throws {
        let raw = GrantRun(provider: .claude)
        let names = ["mcp__mail__send", "mcp__calendar__update", "mcp__reminders__delete"]
        let keys = Set(names.map { "claude." + $0 })
        let coordinator = AgentActionCoordinator(run: raw, mode: mode, provenance: .init(chatID: UUID()),
            permissionSource: .aitvaras, projectGrants: { keys }, audit: { _ in })
        let input = AgentInput(text: "Example")
        try await coordinator.send(input, willDeliver: {})
        for (index, name) in names.enumerated() {
            let request = await raw.offer(.permission(.init(name: name, input: .object([:]))))
            #expect(!request.canAlwaysAllowInProject)
            try await waitGrant { await raw.responses.count == index + 1 }
            await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.alwaysAllow(to: request, persist: {}) }
        }
        #expect(await raw.responses == [.deny, .deny, .deny])
        #expect(await coordinator.pendingRequests().isEmpty)
        try await coordinator.shutdown()
    }

    @Test func grantsAreProviderSpecificNeverWildcardsAndReadsDoNotForceAsk() async throws {
        let grants: Set<String> = ["claude.mcp__echo__echo", "codex.*", "claude.mcp__docs__*"]
        let raw = GrantRun(provider: .codex)
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()),
            projectGrants: { grants }, audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let permission = await raw.offer(.permission(.init(name: "mcp__echo__echo", input: .null)))
        try await waitGrant { await coordinator.pendingRequests().count == 1 }
        try await coordinator.respond(to: permission, with: .deny)
        #expect(await raw.responses == [.deny])
        #expect(throws: AgentFailure.invalidRequest) { try AgentToolPolicy.grantKey(provider: .claude, tool: "mcp__echo__*") }
        #expect(AgentToolPolicy.risk(.init(name: "ToolSearch", input: .null)) == .read)
        #expect(AgentToolPolicy.risk(.init(name: "mcp__echo__ToolSearch", input: .null)) == .confirmable)
        #expect(AgentToolPolicy.risk(.init(name: "toolsearch", input: .null)) == .confirmable)
        try await coordinator.shutdown()
        let hooks = GrantRun(provider: .claude)
        let policy = AgentActionCoordinator(run: hooks, mode: .auto, provenance: .init(chatID: UUID()), permissionSource: .aitvaras, audit: { _ in })
        try await policy.send(.init(text: "Example"), willDeliver: {})
        _ = await hooks.offer(.preToolUse(.init(name: "ToolSearch", input: .null)))
        _ = await hooks.offer(.preToolUse(.init(name: "Read", input: .null)))
        _ = await hooks.offer(.preToolUse(.init(name: "Write", input: .null)))
        try await waitGrant { await hooks.responses.count == 3 }
        #expect(await hooks.responses == [.continueHook, .continueHook, .continueHook])
        try await policy.shutdown()
    }

    @Test(arguments: [AgentMode.ask, .acceptEdits, .plan, .auto], [AgentPermissionSource.aitvaras, .repo])
    func preToolUseRespectsModeForEachRiskClassAndKeepsRepoBehavior(mode: AgentMode, source: AgentPermissionSource) async throws {
        let raw = GrantRun(provider: .claude)
        let coordinator = AgentActionCoordinator(run: raw, mode: mode, provenance: .init(chatID: UUID()),
            permissionSource: source, projectGrants: { ["claude.mcp__echo__echo", "claude.mcp__mail__send"] }, audit: { _ in })
        let tools: [(String, ActionRisk)] = [("Read", .read), ("Write", .reversibleWrite), ("mcp__echo__echo", .confirmable)]
        let expected: [AgentResponse] = switch (source, mode) {
        case (.repo, _), (.aitvaras, .auto): [.continueHook, .continueHook, .continueHook]
        case (.aitvaras, .acceptEdits): [.continueHook, .continueHook, .askHook]
        case (.aitvaras, .ask), (.aitvaras, .plan): [.continueHook, .askHook, .askHook]
        }
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        for (name, risk) in tools {
            let tool = AgentTool(name: name, input: .null)
            #expect(AgentToolPolicy.risk(tool) == risk)
            _ = await raw.offer(.preToolUse(tool))
        }
        _ = await raw.offer(.preToolUse(.init(name: "mcp__mail__send", input: .null)))
        try await waitGrant { await raw.responses.count == 4 }
        #expect(await raw.responses == expected + [.deny])
        #expect(await coordinator.pendingRequests().isEmpty)
        try await coordinator.shutdown()
    }

    @Test func preToolUseUsesAcknowledgedModeChangesOnTheSameRun() async throws {
        let raw = GrantRun(provider: .claude)
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()),
            permissionSource: .aitvaras, audit: { _ in })
        var events = coordinator.events.makeAsyncIterator()
        let cases: [(AgentMode, [AgentResponse])] = [
            (.acceptEdits, [.continueHook, .askHook]), (.plan, [.askHook, .askHook]),
            (.auto, [.continueHook, .continueHook]), (.ask, [.askHook, .askHook])
        ]
        var expected: [AgentResponse] = []
        for (mode, responses) in cases {
            try await coordinator.setMode(mode)
            try await coordinator.send(.init(text: "Example"), willDeliver: {})
            for name in ["Write", "Bash"] { _ = await raw.offer(.preToolUse(.init(name: name, input: .null))) }
            expected += responses
            let count = expected.count
            try await waitGrant { await raw.responses.count == count }
            #expect(await raw.responses == expected)
            await raw.complete()
            while let event = try await events.next() { if case .turnEnded = event.kind { break } }
        }
        try await coordinator.shutdown()
    }

    @Test(arguments: [AgentPermissionSource.aitvaras, .repo])
    func autoStillOffersNativeConfirmablePermissionRequests(source: AgentPermissionSource) async throws {
        let raw = GrantRun(provider: .claude)
        let coordinator = AgentActionCoordinator(run: raw, mode: .auto, provenance: .init(chatID: UUID()),
            permissionSource: source, audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let tool = AgentTool(name: "Bash", input: .object(["command": .string("echo example")]))
        _ = await raw.offer(.preToolUse(tool))
        try await waitGrant { await raw.responses.count == 1 }
        #expect(await raw.responses == [.continueHook])
        let request = await raw.offer(.permission(tool))
        try await waitGrant { await coordinator.pendingRequests() == [request] }
        #expect(await raw.responses == [.continueHook])
        try await coordinator.respond(to: request, with: .deny)
        #expect(await raw.responses == [.continueHook, .deny])
        try await coordinator.shutdown()
    }

    @Test func failedGrantPersistenceDeniesAndRepeatedRepliesCannotPersistTwice() async throws {
        let raw = GrantRun(provider: .claude)
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let request = await raw.offer(.permission(.init(name: "Write", input: .null)))
        try await waitGrant { await coordinator.pendingRequests().count == 1 }
        await #expect(throws: GrantFailure.self) { try await coordinator.alwaysAllow(to: request, persist: { throw GrantFailure() }) }
        #expect(await raw.responses == [.deny])
        #expect(await coordinator.pendingRequests().isEmpty)
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.alwaysAllow(to: request, persist: {}) }
    }

    @Test func concurrentGrantClicksReserveOneRequestBeforeTheAuditYields() async throws {
        let raw = GrantRun(provider: .claude), gate = GrantAuditGate()
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), audit: { event in
            if event.summary == "Provider action: approved and allowed in project" { await gate.wait() }
        })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let request = await raw.offer(.permission(.init(name: "Write", input: .null)))
        try await waitGrant { await coordinator.pendingRequests().count == 1 }
        let first = Task { try await coordinator.alwaysAllow(to: request, persist: {}) }
        try await waitGrant { await gate.waiting }
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.alwaysAllow(to: request, persist: { throw GrantFailure() }) }
        await gate.release()
        try await first.value
        #expect(await raw.responses == [.allow(updatedInput: nil)])
        try await coordinator.shutdown()
    }

    @Test func storeGrantAndAuditCommitTogetherAndForbiddenGrantsCannotBeSaved() throws {
        let stores = try inMemoryStores()
        let (chat, original) = try agentStoreChat(stores)
        var session = original; session.sessionID = .init(provider: .claude, profile: "test", nativeID: "session-example")
        try stores.saveAgentSession(session)
        let input = AgentInput(text: "Example")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        let scope = AgentEventScope(runID: UUID(), session: session.sessionID, inputID: input.id)
        let request = AgentRequest(id: .string("permission"), scope: scope, kind: .permission(.init(name: "Write", input: .null)))
        let forbidden = AgentRequest(id: request.id, scope: scope, kind: .permission(.init(name: "mcp__mail__send", input: .null)))
        #expect(throws: AgentFailure.invalidRequest) { try stores.allowAgentTool(chatID: chat.id, request: forbidden) }
        try stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER grantAuditFailure BEFORE INSERT ON activityEvent WHEN NEW.connectorID = 'agent.setup' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        #expect(throws: (any Error).self) { try stores.allowAgentTool(chatID: chat.id, request: request) }
        #expect(try stores.agentAlwaysAllowedTools(chatID: chat.id).isEmpty)
        try stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER grantAuditFailure") }
        // Hiding a chat does not revoke the live turn's pending approvals.
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        try stores.allowAgentTool(chatID: chat.id, request: request)
        #expect(try stores.agentAlwaysAllowedTools(chatID: chat.id) == ["claude.Write"])
    }

    @Test(arguments: ["Bash", "commandExecution", "bash", "shell", "exec_command", "mcp__echo__send", "mcp__echo__reply", "mcp__echo__forward", "mcp__echo__compose", "mcp__echo__draft", "mcp__echo__post", "mcp__echo__PUBLISH"])
    func commandAndOutboundMCPGrantsAreNeverOfferedOrHonoured(name: String) async throws {
        let fingerprint = String(repeating: "a", count: 64)
        let raw = GrantRun(provider: .claude, fingerprints: ["echo": fingerprint])
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()),
            projectGrants: { ["claude." + name, "claude." + name + "@" + fingerprint] }, audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let request = await raw.offer(.permission(.init(name: name, input: .null)))
        try await waitGrant { await coordinator.pendingRequests().count == 1 }
        #expect(!request.canAlwaysAllowInProject)
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.alwaysAllow(to: request, persist: { Issue.record("Ineligible grant persisted") }) }
        #expect(await raw.responses.isEmpty)
        try await coordinator.respond(to: request, with: .deny)
        try await coordinator.shutdown()
    }

    @Test(arguments: [AgentMode.ask, .acceptEdits, .plan, .auto], [AgentPermissionSource.repo, .aitvaras])
    func outboundMCPHookAlwaysRequiresExplicitApproval(mode: AgentMode, source: AgentPermissionSource) async throws {
        let raw = GrantRun(provider: .claude)
        let coordinator = AgentActionCoordinator(run: raw, mode: mode, provenance: .init(chatID: UUID()), permissionSource: source, audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        _ = await raw.offer(.preToolUse(.init(name: "mcp__docs__publish", input: .null)))
        try await waitGrant { await raw.responses.count == 1 }
        #expect(await raw.responses == [.askHook])
        let command = AgentTool(name: "Read", input: .object(["type": .string("commandExecution")]))
        #expect(AgentToolPolicy.isCommandExecution(command))
        #expect(!AgentToolPolicy.grantEligible(command))
        #expect(AgentToolPolicy.risk(command) == .confirmable)
        try await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func mcpGrantRequiresCurrentServerFingerprint(changed: Bool) async throws {
        let old = String(repeating: "a", count: 64), current = String(repeating: changed ? "b" : "a", count: 64)
        let grant = try AgentToolPolicy.grantKey(provider: .claude, tool: "mcp__echo__echo", fingerprint: old)
        let grants = AgentToolPolicy.currentGrants([grant, "claude.mcp__echo__echo"], servers: ["echo": current])
        #expect(grants.isEmpty == changed)
        #expect(AgentToolPolicy.currentGrants([grant], servers: [:]).isEmpty)
        #expect(AgentToolPolicy.fingerprint(tool: "mcp__echo__nested__read", servers: ["echo": old, "echo__nested": current]) == nil)
        let raw = GrantRun(provider: .claude, fingerprints: ["echo": current])
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), projectGrants: { grants }, audit: { _ in })
        try await coordinator.send(.init(text: "Example"), willDeliver: {})
        let request = await raw.offer(.permission(.init(name: "mcp__echo__echo", input: .null)))
        if changed {
            try await waitGrant { await coordinator.pendingRequests().count == 1 }
            try await coordinator.respond(to: request, with: .deny)
        } else {
            try await waitGrant { await raw.responses.count == 1 }
            #expect(await raw.responses == [.allow(updatedInput: nil)])
        }
        try await coordinator.shutdown()
    }

    @Test func mcpPresentationNeverChangesTheWireNameOrInfersRiskFromTheLabel() {
        let tool = AgentTool(name: "mcp__docs__list_pages", input: .object(["command": .string("example")]))
        #expect(AgentActionPresentation(tool: tool).title == "Allow docs · list_pages?")
        #expect(tool.name == "mcp__docs__list_pages")
        #expect(AgentToolPolicy.risk(tool) == .confirmable)
    }
}

private struct GrantFailure: Error {}
private actor GrantAuditGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { continuation != nil }
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor GrantRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let session: AgentSessionID
    private var input: UUID?
    private var counter = 0
    var responses: [AgentResponse] = []
    nonisolated let mcpSetup: AgentMCPLaunchStatus?
    init(provider: AgentProvider, fingerprints: [String: String] = [:]) {
        mcpSetup = .init(revision: "fixture", repositoryUnreadable: false, unsupportedRepositoryServers: [], serverFingerprints: fingerprints, unavailableForLocal: [:])
        session = .init(provider: provider, profile: "test", nativeID: "session-example")
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver(); self.input = input.id
    }
    func offer(_ kind: AgentRequest.Kind) -> AgentRequest {
        counter += 1
        let scope = AgentEventScope(runID: id, session: session, inputID: input)
        let request = AgentRequest(id: .string("request-\(counter)"), scope: scope, kind: kind)
        continuation.yield(.init(scope: scope, kind: .request(request))); return request
    }
    func respond(to request: AgentRequest, with response: AgentResponse) { responses.append(response) }
    func complete() {
        continuation.yield(.init(scope: .init(runID: id, session: session, inputID: input), kind: .turnEnded(.completed)))
        input = nil
    }
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { continuation.finish() }
}
private func waitGrant(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(10))
    }
}
