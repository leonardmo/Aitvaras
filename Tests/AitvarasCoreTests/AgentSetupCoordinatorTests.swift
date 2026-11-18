import Foundation
import Darwin
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentSetupCoordinatorTests {
    @Test func approvalRequiresTheDisplayedFingerprintAndUnknownServersStayOff() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath())
        try repository(fixture.directory, #"{"echo":{"command":"echo","env":{"ACCESS_TOKEN":"synthetic-repo-value"}},"future":{"type":"future"}}"#)
        let setup = coordinator(stores, vault)
        var state = try await setup.state(projectID: chat.projectID, provider: .claude)
        let echo = try #require(state.servers.first { $0.name == "echo" })
        #expect(echo.indicator == .pendingApproval)
        #expect(!echo.canSignIn)
        #expect(state.servers.first { $0.name == "future" }?.canApprove == false)
        #expect(!String(describing: state).contains("synthetic-repo-value"))
        let fingerprint = try #require(echo.fingerprint)
        try repository(fixture.directory, #"{"echo":{"command":"echo","timeout":12},"future":{"type":"future"}}"#)
        await #expect(throws: AgentMCPError.invalidApproval) {
            try await setup.edit(projectID: chat.projectID, edit: .approve(name: "echo", fingerprint: fingerprint))
        }
        state = try await setup.state(projectID: chat.projectID, provider: .claude)
        let fresh = try #require(state.servers.first { $0.name == "echo" }?.fingerprint)
        try await setup.edit(projectID: chat.projectID, edit: .approve(name: "echo", fingerprint: fresh))
        #expect(try stores.workspaceAgentSetup(projectID: chat.projectID).approvedProjectServerFingerprints["echo"] == fresh)
        try await setup.edit(projectID: chat.projectID, edit: .deny(name: "echo"))
        #expect(try await setup.state(projectID: chat.projectID, provider: .claude).servers.first { $0.name == "echo" }?.indicator == .off)
        let unsupported = try #require(state.servers.first { $0.name == "future" }?.fingerprint)
        await #expect(throws: AgentMCPError.invalidApproval) {
            try await setup.edit(projectID: chat.projectID, edit: .approve(name: "future", fingerprint: unsupported))
        }
        #expect(try !stores.workspaceAgentSetup(projectID: chat.projectID).approvedProjectServers.contains("future"))
    }

    @Test func globalsOverridesPolicyAndLocalOptInRemainProjectScoped() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath())
        let other = try agentStoreChat(stores).0
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo"), "docs": .init(transport: .http, url: "https://docs.example.invalid/mcp")])
        let setup = coordinator(stores, vault)
        var state = try await setup.state(projectID: chat.projectID, provider: .local)
        #expect(state.servers.first { $0.name == "docs" }?.detail == "Local: stdio servers only")
        #expect(state.servers.first { $0.name == "echo" }?.indicator == .off)
        try await setup.edit(projectID: chat.projectID, edit: .permissionSource(.aitvaras))
        try await setup.edit(projectID: chat.projectID, edit: .localMayUseMCP(true))
        try await setup.edit(projectID: chat.projectID, edit: .globalEnabled(name: "echo", enabled: false))
        state = try await setup.state(projectID: chat.projectID, provider: .local)
        #expect(state.permissionSource == .aitvaras && state.localMayUseMCP)
        #expect(state.servers.first { $0.name == "echo" }?.isOffInProject == true)
        #expect(try stores.workspaceAgentSetup(projectID: other.projectID).disabledGlobalServers.isEmpty)
        var draft = AgentMCPServerDraft(); draft.name = "echo"; draft.command = "example-command"
        try await setup.saveServer(projectID: chat.projectID, draft: draft)
        state = try await setup.state(projectID: chat.projectID, provider: .claude)
        #expect(state.servers.filter { $0.name == "echo" }.map(\.source) == [.project])
        try await setup.removeServer(projectID: chat.projectID, name: "echo")
        #expect(try await setup.state(projectID: chat.projectID, provider: .claude).servers.first { $0.name == "echo" }?.source == .global)
        #expect(try await setup.state(projectID: nil, provider: .claude).servers.count == 2)
    }

    @Test func unreadableRepoAndCollisionsAreVisibleWithoutHidingRemovalActions() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath()), setup = coordinator(stores, vault)
        try Data("garbage".utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        #expect(try await !setup.state(projectID: chat.projectID, provider: .claude).notices.isEmpty)
        try repository(fixture.directory, #"{"echo":{"command":"echo"}}"#)
        var draft = AgentMCPServerDraft(); draft.name = "echo"; draft.command = "echo"
        draft.fields = [.init(name: "ACCESS_TOKEN", value: "synthetic-form-value")]
        await #expect(throws: AgentMCPError.nameCollision) { try await setup.saveServer(projectID: chat.projectID, draft: draft) }
        #expect(vault.values.isEmpty)
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")])
        let state = try await setup.state(projectID: chat.projectID, provider: .claude)
        #expect(state.notices.contains { $0.contains("names conflict") })
        #expect(state.servers.first { $0.source == .global }?.canRemove == true)
    }

    @Test func probeRacingAnEditAndOldNativeReportsCannotPublishStaleStatus() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault(), gate = SetupGate()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath())
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")])
        let backend = SetupBackend(gate: gate)
        let setup = coordinator(stores, vault, backend: backend)
        let oldRevision = try mcpTestPolicy(stores, root: fixture.directory).snapshot(directory: fixture.directory.resolvingSymlinksInPath(), projectID: chat.projectID).status.revision
        let probe = Task { try await setup.refresh(projectID: chat.projectID, provider: .claude) }
        try await setupWait { await gate.waiting }
        try await setup.edit(projectID: chat.projectID, edit: .globalEnabled(name: "echo", enabled: false))
        await gate.release()
        await #expect(throws: CancellationError.self) { try await probe.value }
        var snapshot = AgentSetupSnapshot(provider: .claude)
        snapshot.servers = [.init(name: "echo", status: .connected)]; snapshot.serversAvailable = true
        await setup.report(snapshot, projectID: chat.projectID, directory: fixture.directory.resolvingSymlinksInPath(), revision: oldRevision)
        let state = try await setup.state(projectID: chat.projectID, provider: .claude)
        #expect(state.servers.first?.indicator == .off)
        #expect(state.snapshot?.serversAvailable == false)
    }

    @Test func signInIsOfferedOnlyForEligibleNativeServersAndRefreshesAfterCompletion() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault(), backend = SetupBackend()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath())
        try repository(fixture.directory, #"{"docs":{"type":"http","url":"https://docs.example.invalid/mcp"}}"#)
        try stores.saveGlobalAgentMCPServers(["helper": .init(transport: .http, url: "https://helper.example.invalid/mcp")])
        let setup = coordinator(stores, vault, backend: backend)
        await #expect(throws: AgentFailure.unsupported) {
            try await setup.signIn(projectID: chat.projectID, provider: .claude, rowID: "repository.docs") { _ in }
        }
        let row = try #require(try await setup.state(projectID: chat.projectID, provider: .claude).servers.first { $0.name == "docs" })
        try await setup.edit(projectID: chat.projectID, edit: .approve(name: "docs", fingerprint: try #require(row.fingerprint)))
        #expect(try await setup.state(projectID: chat.projectID, provider: .claude).servers.first { $0.name == "docs" }?.canSignIn == true)
        var snapshot = AgentSetupSnapshot(provider: .claude)
        snapshot.serversAvailable = true
        snapshot.servers = [.init(name: "docs", status: .needsAuth, source: "project"),
            .init(name: "helper", status: .needsAuth), .init(name: "account-docs", status: .needsAuth, source: "claudeai")]
        await setup.report(snapshot, projectID: chat.projectID, directory: fixture.directory.resolvingSymlinksInPath())
        let state = try await setup.state(projectID: chat.projectID, provider: .claude)
        #expect(state.servers.first { $0.name == "helper" }?.canSignIn == false)
        #expect(state.servers.first { $0.name == "account-docs" }?.canSignIn == true)
        await #expect(throws: AgentFailure.unsupported) {
            try await setup.signIn(projectID: chat.projectID, provider: .claude, rowID: "global.helper") { _ in }
        }
        let refreshed = try await setup.signIn(projectID: chat.projectID, provider: .claude, rowID: "repository.docs") { _ in }
        #expect(refreshed.servers.first { $0.name == "docs" }?.indicator == .connected)
        #expect(await backend.logins == ["docs"])
        #expect(try stores.activity(since: .distantPast).allSatisfy { !($0.detailJSON ?? "").contains("synthetic-browser-value") })
    }

    @Test func setupEditAuditFailureRollsBackAndConcurrentIndependentEditsPreserveEachOther() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath()), setup = coordinator(stores, vault)
        async let one: Void = setup.edit(projectID: chat.projectID, edit: .permissionSource(.aitvaras))
        async let two: Void = setup.edit(projectID: chat.projectID, edit: .localMayUseMCP(true))
        _ = try await (one, two)
        try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER setupAuditFailure BEFORE INSERT ON activityEvent WHEN NEW.connectorID = 'agent.setup' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        await #expect(throws: (any Error).self) { try await setup.edit(projectID: chat.projectID, edit: .permissionSource(.repo)) }
        let saved = try stores.workspaceAgentSetup(projectID: chat.projectID)
        #expect(saved.permissionSource == .aitvaras && saved.localMayUseMCP)
    }

    @Test func shutdownCancelsManagedLoginAndAwaitsProcessCleanup() async throws {
        let fixture = try AgentExecutableFixture(#"""
        echo $$ > child.pid
        trap '' TERM
        i=0; while [ $i -lt 15 ]; do /bin/sleep 1; i=$((i+1)); done
        """#)
        defer { fixture.remove() }
        let directory = fixture.directory.resolvingSymlinksInPath()
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let setup = coordinator(stores, vault, backend: backend)
        var snapshot = AgentSetupSnapshot(provider: .claude)
        snapshot.serversAvailable = true; snapshot.servers = [.init(name: "docs", status: .needsAuth, source: "user")]
        await setup.report(snapshot, projectID: chat.projectID, directory: directory)
        let login = Task { try await setup.signIn(projectID: chat.projectID, provider: .claude, rowID: "user.docs") { _ in } }
        try await setupWait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("child.pid").path) }
        await setup.shutdown()
        await #expect(throws: CancellationError.self) { try await login.value }
        #expect(kill(try fixture.childPID(), 0) != 0 && errno == ESRCH)
        #expect(try stores.activity(since: .distantPast).contains { $0.summary == "MCP sign-in cancelled" })
    }
}

private func repository(_ directory: URL, _ servers: String) throws {
    try Data(("{\"mcpServers\":" + servers + "}").utf8).write(to: directory.appendingPathComponent(".mcp.json"))
}
func setupProjectChat(_ stores: Stores, directory: URL) throws -> WorkspaceChat {
    let project = try stores.createWorkspaceProject(title: "Example project", folders: [.init(path: directory.path)])
    return try stores.createWorkspaceChat(projectID: project.id, title: "Example chat")
}
func coordinator(_ stores: Stores, _ vault: SetupVault, backend: (any AgentBackend)? = nil) -> AgentSetupCoordinator {
    .init(persistence: stores, secrets: .init(set: { try vault.set($0, $1) }, delete: { vault.delete($0) }),
        backends: backend.map { [.claude: $0] } ?? [:], audit: { _ = try stores.record($0) })
}

final class SetupVault: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    private var failureLimit: Int?
    var failAfter: Int? {
        get { lock.withLock { failureLimit } }
        set { lock.withLock { failureLimit = newValue } }
    }
    var values: [String: String] { lock.withLock { stored } }
    func set(_ value: String, _ key: String) throws {
        try lock.withLock {
            if let failureLimit, stored.count >= failureLimit { throw AgentMCPError.secretUnavailable }
            stored[key] = value
        }
    }
    func delete(_ key: String) { lock.withLock { _ = stored.removeValue(forKey: key) } }
}
private actor SetupBackend: AgentBackend {
    var logins: [String] = []
    private let gate: SetupGate?
    init(gate: SetupGate? = nil) { self.gate = gate }
    func setup(directory: URL, projectID: UUID?) async throws -> AgentSetupSnapshot {
        await gate?.wait()
        var snapshot = AgentSetupSnapshot(provider: .claude)
        snapshot.serversAvailable = true
        snapshot.servers = [.init(name: "docs", status: logins.isEmpty ? .needsAuth : .connected, source: "project")]
        return snapshot
    }
    func signInMCP(name: String, directory: URL, timeout: Duration, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        await onBrowserURL(URL(string: "https://auth.example.invalid/authorize?state=synthetic-browser-value")!)
        logins.append(name)
    }
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: []) }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func models() -> [AgentModel] { [] }
    func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun { throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
private actor SetupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private func setupWait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !predicate() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(10))
    }
}
