import Foundation
import GRDB
import Testing
import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(1))) struct GatewayUpstreamStoreTests {
    private let linear = AgentMCPServer(transport: .http, url: "https://mcp.example.invalid/stream", management: .gatewayOAuth)

    @Test func v44UpgradePreservesLegacyDefinitionsAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.sqlite")
        let legacy = AgentMCPServer(transport: .http, url: "https://legacy.example.invalid/mcp",
            headers: ["Authorization": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])
        let legacyDefinitions = ["legacy": legacy]
        let setup: WorkspaceAgentSetup
        let oldJSON: String
        do {
            let old = Stores(db: try AitvarasDatabase(url: url, migrateThrough: "v44-agent-account-keys"))
            let project = try old.createWorkspaceProject(title: "Example")
            var settings = WorkspaceAgentSetup(projectID: project.id)
            oldJSON = try AgentMCPConfiguration.encode(legacyDefinitions)
            settings.extraServersJSON = oldJSON
            settings.disabledGlobalServers = ["legacy"]
            settings.permissionSource = .aitvaras
            settings.localMayUseMCP = true
            try old.saveWorkspaceAgentSetup(settings)
            try old.saveGlobalAgentMCPServers(legacyDefinitions)
            setup = settings
        }
        let upgraded = Stores(db: try AitvarasDatabase(url: url))
        #expect(try upgraded.workspaceAgentSetup(projectID: setup.projectID) == setup)
        #expect(try upgraded.globalAgentMCPServers() == legacyDefinitions)
        #expect(try upgraded.value(forKey: "agent.mcp.global") == oldJSON)
        #expect(!oldJSON.contains("management"))
        #expect(try upgraded.gatewayUpstreams(for: .init(client: .claude, projectID: setup.projectID)).isEmpty)
        #expect(try upgraded.gatewayToolScopeSettings(projectID: setup.projectID).scopes.isEmpty)
        #expect(try upgraded.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
        #expect(throws: GatewayUpstreamError.definitionUnavailable) {
            try upgraded.registerGatewayUpstreamAccount(serverName: "legacy", globallyAvailable: true)
        }
    }

    @Test func defaultOptOutAndProjectAccountSelectionAreIndependent() throws {
        let stores = try inMemoryStores()
        let one = try stores.createWorkspaceProject(title: "One")
        let two = try stores.createWorkspaceProject(title: "Two")
        try stores.saveGlobalAgentMCPServers(["linear": linear])
        try stores.editAgentSetup(projectID: one.id, edit: .server(name: "linear", definition: linear))
        let primary = try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: true, makeGlobalDefault: true)
        let alternate = try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: true)
        let local = try stores.registerGatewayUpstreamAccount(serverName: "linear", definitionProjectID: one.id, globallyAvailable: false)
        let outside = GatewayLaunchContext(client: .claude, projectID: nil)
        let first = GatewayLaunchContext(client: .claude, projectID: one.id)
        let second = GatewayLaunchContext(client: .codex, projectID: two.id)

        #expect(Set(try stores.gatewayUpstreamAccounts(projectID: one.id).map(\.id)) == [primary.id, alternate.id, local.id])
        #expect(Set(try stores.gatewayUpstreamAccounts(projectID: two.id).map(\.id)) == [primary.id, alternate.id])
        #expect(try stores.gatewayUpstreams(for: outside).map(\.account.id) == [primary.id])
        #expect(try stores.gatewayUpstreams(for: first).map(\.account.id) == [primary.id])
        try stores.selectGatewayUpstreamAccount(projectID: one.id, serverName: "linear", accountID: alternate.id)
        #expect(try stores.gatewayUpstreams(for: first).map(\.account.id) == [alternate.id])
        #expect(try stores.gatewayUpstreams(for: second).map(\.account.id) == [primary.id])

        try stores.editAgentSetup(projectID: one.id, edit: .globalEnabled(name: "linear", enabled: false))
        #expect(try stores.gatewayUpstreams(for: first).isEmpty)
        try stores.selectGatewayUpstreamAccount(projectID: one.id, serverName: "linear", accountID: local.id)
        #expect(try stores.gatewayUpstreams(for: first).map(\.account.id) == [local.id])
        #expect(throws: GatewayUpstreamError.invalidAccount) {
            try stores.selectGatewayUpstreamAccount(projectID: two.id, serverName: "linear", accountID: local.id)
        }
        #expect(throws: GatewayUpstreamError.accountInUse) { try stores.removeGatewayUpstreamAccount(id: local.id) }
        try stores.setGatewayGlobalDefault(serverName: "linear", accountID: alternate.id)
        #expect(try stores.gatewayUpstreams(for: outside).map(\.account.id) == [alternate.id])
        #expect(try stores.gatewayUpstreams(for: first).map(\.account.id) == [local.id])
    }

    @Test func staleDefinitionAndNameCollisionsFailVisibly() throws {
        let stores = try inMemoryStores()
        try stores.saveGlobalAgentMCPServers(["linear": linear, "memory": linear])
        let defaultAccount = try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: true, makeGlobalDefault: true)
        #expect(throws: GatewayUpstreamError.defaultAlreadySet) {
            try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: true, makeGlobalDefault: true)
        }
        #expect(throws: GatewayUpstreamError.invalidServerName) {
            try stores.registerGatewayUpstreamAccount(serverName: "memory", globallyAvailable: true)
        }
        let changed = AgentMCPServer(transport: .http, url: "https://other.example.invalid/mcp", management: .gatewayOAuth)
        try stores.saveGlobalAgentMCPServers(["linear": changed])
        let outside = GatewayLaunchContext(client: .claude, projectID: nil)
        #expect(throws: GatewayUpstreamError.definitionChanged) { try stores.gatewayUpstreams(for: outside) }
        #expect(throws: GatewayUpstreamError.definitionChanged) {
            try stores.setGatewayGlobalDefault(serverName: "linear", accountID: defaultAccount.id)
        }
        try stores.removeGatewayUpstreamAccount(id: defaultAccount.id)
        #expect(try stores.gatewayUpstreams(for: outside).isEmpty)
    }

    @Test func gatewayDefinitionIsExcludedFromNativeConfigAndCannotHoldStaticCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
        let legacy = AgentMCPServer(command: "echo")
        let resolution = try AgentMCPResolver.prepare(directory: directory, setup: .init(localMayUseMCP: true),
                                                     globalServers: ["linear": linear, "legacy": legacy])
        #expect(resolution.claudeServers == ["legacy": legacy])
        #expect(resolution.localServers == ["legacy": legacy])
        let invalid = AgentMCPServer(transport: .http, url: linear.url, headers: [
            "Authorization": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")
        ], management: .gatewayOAuth)
        #expect(throws: AgentMCPError.invalidConfiguration) { try invalid.validate() }
    }
}
