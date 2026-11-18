import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct WorkspaceAgentSetupTests {
    @Test func defaultsAndEveryFieldRoundTripByProject() throws {
        let stores = try inMemoryStores()
        let one = try stores.createWorkspaceProject(title: "Example project")
        let two = try stores.createWorkspaceProject(title: "Other project")
        let defaults = try stores.workspaceAgentSetup(projectID: one.id)
        #expect(defaults == WorkspaceAgentSetup(projectID: one.id))
        #expect(try stores.db.queue.read { try WorkspaceAgentSetup.fetchCount($0) } == 0)
        let server = AgentMCPServer(command: "echo", args: ["example"], env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])
        var setup = defaults
        setup.approvedProjectServers = ["echo"]
        setup.approvedProjectServerFingerprints = ["echo": try server.fingerprint()]
        setup.deniedProjectServers = ["blocked"]
        setup.extraServersJSON = try AgentMCPConfiguration.encode(["helper": server])
        setup.disabledGlobalServers = ["global"]
        setup.alwaysAllowedTools = ["claude.mcp__echo__echo"]
        setup.permissionSource = .aitvaras; setup.localMayUseMCP = true
        try stores.saveWorkspaceAgentSetup(setup)
        #expect(try stores.workspaceAgentSetup(projectID: one.id) == setup)
        #expect(try stores.workspaceAgentSetup(projectID: two.id) == WorkspaceAgentSetup(projectID: two.id))
        #expect(try setup.mcpConfiguration().approvedServers == setup.approvedProjectServerFingerprints)
        #expect(try setup.mcpConfiguration().projectServers == ["helper": server])
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
        #expect(try stores.db.queue.read { try WorkspaceAgentSetup.filter(Column("projectID") == one.id).fetchCount($0) } == 1)
    }

    @Test func globalDefinitionsRoundTripAndRemainSeparate() throws {
        let stores = try inMemoryStores()
        #expect(try stores.globalAgentMCPServers().isEmpty)
        let servers = ["echo": AgentMCPServer(command: "echo")]
        try stores.saveGlobalAgentMCPServers(servers)
        #expect(try stores.globalAgentMCPServers() == servers)
        #expect(try stores.value(forKey: "agent.mcp.global") == AgentMCPConfiguration.encode(servers))
        try stores.saveGlobalAgentMCPServers([:])
        #expect(try stores.globalAgentMCPServers().isEmpty)
    }

    @Test func invalidWritesAndAuditFailureAreAtomic() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        #expect(throws: WorkspaceStoreError.projectNotFound) { try stores.workspaceAgentSetup(projectID: UUID()) }
        #expect(throws: WorkspaceStoreError.projectNotFound) { try stores.saveWorkspaceAgentSetup(.init(projectID: UUID())) }
        var setup = WorkspaceAgentSetup(projectID: project.id)
        setup.approvedProjectServers = ["bad name"]
        #expect(throws: AgentMCPError.invalidName) { try stores.saveWorkspaceAgentSetup(setup) }
        setup.approvedProjectServers = ["echo"]; setup.approvedProjectServerFingerprints = ["echo": "invalid"]
        #expect(throws: AgentMCPError.invalidApproval) { try stores.saveWorkspaceAgentSetup(setup) }
        setup = .init(projectID: project.id); setup.extraServersJSON = "garbage"
        #expect(throws: AgentMCPError.invalidConfiguration) { try stores.saveWorkspaceAgentSetup(setup) }
        #expect(throws: AgentMCPError.invalidConfiguration) {
            try stores.saveGlobalAgentMCPServers(["echo": .init(command: "")])
        }
        try stores.db.queue.write {
            try $0.execute(sql: "CREATE TRIGGER setupAuditFailure BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        #expect(throws: (any Error).self) { try stores.saveWorkspaceAgentSetup(.init(projectID: project.id)) }
        #expect(throws: (any Error).self) { try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")]) }
        #expect(try stores.db.queue.read { try WorkspaceAgentSetup.fetchCount($0) } == 0)
        #expect(try stores.value(forKey: "agent.mcp.global") == nil)
    }

    @Test func namesNormalizeButNameOnlyApprovalDoesNotAuthorize() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        var setup = WorkspaceAgentSetup(projectID: project.id)
        setup.approvedProjectServers = ["echo", "echo"]
        setup.alwaysAllowedTools = ["claude.mcp__echo__echo", "claude.mcp__echo__echo"]
        try stores.saveWorkspaceAgentSetup(setup)
        let saved = try stores.workspaceAgentSetup(projectID: project.id)
        #expect(saved.approvedProjectServers == ["echo"])
        #expect(saved.alwaysAllowedTools.count == 1)
        #expect(try saved.mcpConfiguration().approvedServers.isEmpty)
    }

    @Test func launchContextUsesExplicitChatOwnershipAndRejectsAmbiguousProbes() throws {
        let stores = try inMemoryStores()
        let root = "/synthetic/example"
        let one = try stores.createWorkspaceProject(title: "Example one", folders: [.init(path: root)])
        let two = try stores.createWorkspaceProject(title: "Example two", folders: [.init(path: root)])
        var setup = WorkspaceAgentSetup(projectID: two.id)
        setup.extraServersJSON = try AgentMCPConfiguration.encode(["helper": AgentMCPServer(command: "echo")])
        try stores.saveWorkspaceAgentSetup(setup)
        let directory = URL(fileURLWithPath: root)
        #expect(throws: AgentStoreError.identityConflict) { try stores.agentMCPLaunchContext(directory: directory, projectID: nil) }
        #expect(try stores.agentMCPLaunchContext(directory: directory, projectID: one.id).setup.projectServers.isEmpty)
        #expect(try stores.agentMCPLaunchContext(directory: directory, projectID: two.id).setup.projectServers.keys.sorted() == ["helper"])
        let chat = try stores.createWorkspaceChat(projectID: two.id, title: "Example")
        #expect(try stores.agentProjectID(chatID: chat.id) == two.id)
    }

    @Test func v32UpgradeIsAdditiveAndPreservesExistingRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite")
        var project: WorkspaceProject!
        var chat: WorkspaceChat!
        var session: AgentChatSession!
        var entry: AgentTranscriptEntry!
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            (chat, session) = try agentStoreChat(stores)
            project = try stores.workspaceProject(id: chat.projectID)
            entry = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "user", text: "Example message", sessionID: session.id))
            // Compare persisted dates, which SQLite stores at its own precision.
            chat = try stores.workspaceChat(id: chat.id)
            try stores.setValue("unchanged", forKey: "example.setting")
            try stores.db.queue.write { db in
                try db.drop(table: "workspaceAgentSetup")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v33-workspace-agent-setup"])
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.workspaceProject(id: project.id) == project)
        #expect(try stores.workspaceChat(id: chat.id) == chat)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude) == session)
        #expect(try stores.agentEntries(chatID: chat.id) == [entry!])
        #expect(try stores.value(forKey: "example.setting") == "unchanged")
        #expect(try stores.workspaceAgentSetup(projectID: project.id) == .init(projectID: project.id))
        #expect(try stores.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM activityEvent") } == 0)
        try stores.saveWorkspaceAgentSetup(.init(projectID: project.id))
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func resolvedCredentialsNeverEnterRowsSessionConfigurationOrAudit() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let secret = "synthetic-runtime-value"
        let definitions = ["echo": AgentMCPServer(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])]
        var setup = WorkspaceAgentSetup(projectID: project.id)
        setup.extraServersJSON = try AgentMCPConfiguration.encode(definitions)
        try stores.saveWorkspaceAgentSetup(setup)
        try stores.saveGlobalAgentMCPServers(definitions)
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project.id, runID: UUID(),
            servers: definitions, audit: { _ = try stores.record($0) }, resolveSecret: { _ in secret })
        try await file.remove()
        let rows = try await stores.db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM workspaceAgentSetup").map { String(describing: $0) }
                + Row.fetchAll(db, sql: "SELECT * FROM kv").map { String(describing: $0) }
                + Row.fetchAll(db, sql: "SELECT * FROM activityEvent").map { String(describing: $0) }
        }.joined()
        #expect(!rows.contains(secret))
        #expect(rows.contains("agent.mcp.00000000-0000-4000-8000-000000000001"))
        let configuration = AgentSessionConfiguration(directory: fixture.directory, model: "default")
        #expect(!String(reflecting: configuration).contains(secret))
        let audit = try stores.activity(since: .distantPast)
        #expect(audit.count == 5)
        #expect(audit.allSatisfy { !($0.detailJSON ?? "").contains(secret) && !$0.summary.contains(secret) })
    }
}
