import Foundation
import Testing
import GRDB
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentSetupFormTests {
    @Test(arguments: [AgentMCPServer.Transport.http, .sse])
    func secretFieldsStoreOnlyKeychainReferencesAndPreserveLiteralArguments(transport: AgentMCPServer.Transport) async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath()), setup = coordinator(stores, vault)
        var draft = AgentMCPServerDraft()
        draft.name = "echo"; draft.command = "example-command"; draft.arguments = "--label\nwords with spaces\n"
        draft.fields = [.init(name: "ACCESS_TOKEN", value: "synthetic-form-secret"), .init(name: "LABEL", value: "Example", secret: false)]
        try await setup.saveServer(projectID: chat.projectID, draft: draft)
        let saved = try stores.workspaceAgentSetup(projectID: chat.projectID)
        let server = try #require(try saved.mcpConfiguration().projectServers["echo"])
        #expect(server.args == ["--label", "words with spaces", ""])
        #expect(server.env["LABEL"] == .literal("Example"))
        if case .secretReference(let reference) = server.env["ACCESS_TOKEN"] {
            #expect(vault.values[reference] == "synthetic-form-secret")
        } else { Issue.record("Expected a Keychain reference") }
        var remote = AgentMCPServerDraft(); remote.name = "docs"; remote.transport = transport; remote.url = "https://docs.example.invalid/mcp"
        remote.fields = [.init(name: "Authorization", value: "Bearer synthetic-header-secret")]
        try await setup.saveServer(projectID: nil, draft: remote)
        #expect(try stores.globalAgentMCPServers()["docs"]?.transport == transport)
        let rows = try await stores.db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT extraServersJSON FROM workspaceAgentSetup")
                + String.fetchAll(db, sql: "SELECT value FROM kv WHERE key = 'agent.mcp.global'")
                + String.fetchAll(db, sql: "SELECT COALESCE(detailJSON, '') FROM activityEvent")
        }.joined()
        #expect(!rows.contains("synthetic-form-secret"))
        #expect(!rows.contains("synthetic-header-secret"))
        try await setup.removeServer(projectID: chat.projectID, name: "echo")
        #expect(try stores.workspaceAgentSetup(projectID: chat.projectID).mcpConfiguration().projectServers.isEmpty)
        // The removed server no longer retains its credential.
        #expect(vault.values.count == 1)
    }

    @Test func removalDeletesOnlyUnsharedMCPCredentialsAcrossAllProjectsAndGlobals() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory), setup = coordinator(stores, vault)
        var draft = AgentMCPServerDraft(); draft.name = "echo"; draft.command = "echo"
        draft.fields = [.init(name: "ACCESS", value: "synthetic-shared-secret")]
        try await setup.saveServer(projectID: chat.projectID, draft: draft)
        let server = try #require(try stores.workspaceAgentSetup(projectID: chat.projectID).mcpConfiguration().projectServers["echo"])
        try stores.saveGlobalAgentMCPServers(["shared": server])
        let other = try stores.createWorkspaceProject(title: "Other", folders: [.init(path: fixture.directory.path)])
        var otherSetup = WorkspaceAgentSetup(projectID: other.id)
        otherSetup.extraServersJSON = try AgentMCPConfiguration.encode(["shared": server])
        try stores.saveWorkspaceAgentSetup(otherSetup)
        try vault.set("unrelated", "foreign.account")
        try await setup.removeServer(projectID: chat.projectID, name: "echo")
        #expect(vault.values.count == 2)
        try await setup.removeServer(projectID: nil, name: "shared")
        #expect(vault.values.count == 2)
        try await setup.removeServer(projectID: other.id, name: "shared")
        #expect(vault.values.count == 1)
        #expect(vault.values["foreign.account"] == "unrelated")
    }

    @Test func failedRemovalAuditCannotDeleteCredentialsOrDefinitions() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory), setup = coordinator(stores, vault)
        var draft = AgentMCPServerDraft(); draft.name = "echo"; draft.command = "echo"
        draft.fields = [.init(name: "ACCESS", value: "synthetic-retained-secret")]
        try await setup.saveServer(projectID: chat.projectID, draft: draft)
        try await stores.db.queue.write {
            try $0.execute(sql: "CREATE TRIGGER removalAuditFailure BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        await #expect(throws: (any Error).self) { try await setup.removeServer(projectID: chat.projectID, name: "echo") }
        #expect(vault.values.count == 1)
        #expect(try stores.workspaceAgentSetup(projectID: chat.projectID).mcpConfiguration().projectServers["echo"] != nil)
    }

    @Test(arguments: ["keychain", "database", "audit"])
    func failedSaveNeverLeavesAStoredDefinitionOrResolvedSecret(scenario: String) async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault()
        let chat = try setupProjectChat(stores, directory: fixture.directory.resolvingSymlinksInPath())
        var draft = AgentMCPServerDraft(); draft.name = "echo"; draft.command = "example-command"
        draft.fields = [.init(name: "FIRST_TOKEN", value: "synthetic-first-value"), .init(name: "SECOND_TOKEN", value: "synthetic-second-value")]
        if scenario == "keychain" { vault.failAfter = 1 }
        if scenario == "database" {
            try await stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER setupFailure BEFORE INSERT ON workspaceAgentSetup BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        }
        let setup = AgentSetupCoordinator(persistence: stores,
            secrets: .init(set: { try vault.set($0, $1) }, delete: { vault.delete($0) }), backends: [:], audit: {
                if scenario == "audit" { throw AgentMCPError.auditFailed }
                _ = try stores.record($0)
            })
        await #expect(throws: (any Error).self) { try await setup.saveServer(projectID: chat.projectID, draft: draft) }
        #expect(vault.values.isEmpty)
        #expect(try stores.workspaceAgentSetup(projectID: chat.projectID).extraServersJSON == "{}")
        #expect(try stores.activity(since: .distantPast).allSatisfy { !($0.detailJSON ?? "").contains("synthetic-first-value") })
    }

    @Test func invalidDuplicateFieldsAndHeaderNewlinesFailBeforeKeychainWrites() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores(), vault = SetupVault(), setup = coordinator(stores, vault)
        var draft = AgentMCPServerDraft(); draft.name = "docs"; draft.transport = .http; draft.url = "https://docs.example.invalid/mcp"
        draft.fields = [.init(name: "Authorization", value: "first"), .init(name: "Authorization", value: "second")]
        await #expect(throws: AgentMCPError.invalidConfiguration) { try await setup.saveServer(projectID: nil, draft: draft) }
        draft.fields = [.init(name: "Authorization", value: "first\nsecond")]
        await #expect(throws: AgentMCPError.invalidConfiguration) { try await setup.saveServer(projectID: nil, draft: draft) }
        #expect(vault.values.isEmpty)
        #expect(try stores.globalAgentMCPServers().isEmpty)
    }
}
