import Foundation
import GRDB
import Testing
import AitvarasAgents
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

@Suite(.timeLimit(.minutes(1))) struct GatewayApprovalSettingsTests {
    @Test func serverPolicyIsProjectAndAccountScopedAndKeepsExistingRoutes() throws {
        let stores = try inMemoryStores()
        let first = try stores.createWorkspaceProject(title: "Example")
        let second = try stores.createWorkspaceProject(title: "Another project")
        let endpoint = "https://mcp.example.invalid/mcp"
        let original = try stores.addGatewayUpstream(serverName: "example", label: "Existing", endpoint: endpoint, projectID: nil)
        let fresh = try stores.addGatewayUpstream(serverName: "example", label: "New", endpoint: endpoint, projectID: nil)
        _ = try stores.db.queue.write { dbc in
            // A migrated account has the column's false default.
            try GatewayUpstreamAccount.filter(Column("id") == original.id)
                .updateAll(dbc, Column("approvalDefaultsToAsk").set(to: false))
        }
        #expect(try stores.gatewayProjectApprovalSettings(projectID: first.id, accountID: original.id).mode == nil)
        #expect(try stores.gatewayProjectApprovalSettings(projectID: first.id, accountID: fresh.id).mode == .ask)
        try stores.setGatewayServerApprovalMode(projectID: first.id, accountID: fresh.id, mode: .fullAuto)
        #expect(try stores.gatewayProjectApprovalSettings(projectID: first.id, accountID: fresh.id).mode == .fullAuto)
        #expect(try stores.gatewayProjectApprovalSettings(projectID: second.id, accountID: fresh.id).mode == .ask)
        #expect(try stores.gatewayProjectApprovalSettings(projectID: first.id, accountID: original.id).mode == nil)
        let tool = try makeTool(fresh)
        #expect(try stores.gatewayToolApprovalRule(projectID: nil, tool: tool).mode == .ask)
    }

    @Test func serverModeAndExplicitClassificationNarrowChatAuthority() throws {
        let accountID = UUID(), projectID = UUID()
        let origin = MCPGatewayTool.Origin.upstream(server: "example", accountID: accountID, definitionFingerprint: String(repeating: "a", count: 64))
        let read = try gatewayFixtureTool(name: "get_example", origin: origin, annotations: .init(readOnly: true), trusted: true)
        let write = try gatewayFixtureTool(name: "update_example", origin: origin)
        let delete = try gatewayFixtureTool(name: "get_then_remove_example", origin: origin, annotations: .init(readOnly: true), trusted: true)
        let forbidden = try gatewayFixtureTool(name: "send_mail", origin: origin)
        let grant = try #require(GatewayExactGrant(projectID: projectID, tool: write))
        func verdict(_ tool: MCPGatewayTool, mode: GatewayServerApprovalMode, permissions: AgentChatPermissions,
                     override: ActionRisk? = nil, grants: Set<GatewayExactGrant> = []) -> GatewayPolicyDecision {
            let invocation = MCPGatewayInvocation(launchID: UUID(),
                context: .init(client: .claude, projectID: projectID, permissions: permissions), presentation: .inline(chatID: UUID()))
            let overrides = override.map { [tool.revision: $0] } ?? [:]
            return .init(tool: tool, invocation: invocation,
                         rules: .init(overrides: overrides, grants: grants, serverMode: mode), policy: .init())
        }
        #expect(verdict(read, mode: .ask, permissions: .fullAccess).verdict == .requireConfirmation)
        #expect(verdict(read, mode: .autoAllowReads, permissions: .auto).verdict == .allow)
        #expect(verdict(read, mode: .fullAuto, permissions: .ask).verdict == .requireConfirmation)
        #expect(verdict(write, mode: .autoAllowReads, permissions: .fullAccess).verdict == .requireConfirmation)
        #expect(verdict(write, mode: .autoAllowReads, permissions: .auto, override: .read).verdict == .allow)
        #expect(verdict(write, mode: .fullAuto, permissions: .auto).verdict == .allow)
        #expect(verdict(write, mode: .fullAuto, permissions: .fullAccess, override: .confirmable, grants: [grant]).verdict == .requireConfirmation)
        #expect(verdict(write, mode: .fullAuto, permissions: .plan).forbidden)
        #expect(verdict(write, mode: .ask, permissions: .auto, grants: [grant]).verdict == .allow)
        #expect(verdict(write, mode: .ask, permissions: .ask, grants: [grant]).verdict == .requireConfirmation)
        #expect(verdict(delete, mode: .fullAuto, permissions: .fullAccess, override: .read).verdict == .requireConfirmation)
        #expect(!verdict(delete, mode: .fullAuto, permissions: .fullAccess, override: .read).canAlwaysAllow)
        #expect(verdict(forbidden, mode: .fullAuto, permissions: .fullAccess, override: .read).forbidden)
    }

    @Test func exactApprovalsFromScopedLaunchExpireAndFullAutoIsAudited() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let account = try stores.addGatewayUpstream(serverName: "example", label: "Example",
            endpoint: "https://mcp.example.invalid/mcp", projectID: project.id)
        let tool = try makeTool(account)
        let revised = try makeTool(account, description: "Revised example")
        let hub = ConnectorHub(stores: stores)
        let approvals = GatewayApprovalBroker(outsideTimeout: .seconds(2))
        let invocation = gatewayFixtureInvocation(projectID: project.id)
        @Sendable func call(_ tool: MCPGatewayTool) async throws -> MCPGatewayToolResult {
            try await hub.executeGateway(invocation, tool: tool, arguments: .object([:]), approvals: approvals,
                                         rules: { .init() }, revalidate: {}) { .init(text: "Result") }
        }
        let pending = Task { try await call(tool) }
        defer { pending.cancel() }
        let deadline = ContinuousClock.now + .seconds(1)
        while await approvals.requests().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let offer = try #require(await approvals.requests().first)
        #expect(offer.canAlwaysAllow)
        #expect(await approvals.decide(id: offer.id, allow: true, forProject: true))
        _ = try await pending.value
        _ = try await call(tool)
        #expect(try stores.gatewayProjectApprovalSettings(projectID: project.id, accountID: account.id).toolGrants.map(\.toolRevision) == [tool.revision])
        try stores.setGatewayToolApprovalOverride(projectID: project.id, tool: tool, risk: .read)
        try stores.expireChangedGatewayToolRules(projectID: project.id, tools: [revised])
        let settings = try stores.gatewayProjectApprovalSettings(projectID: project.id, accountID: account.id)
        #expect(settings.toolOverrides.isEmpty && settings.toolGrants.isEmpty)
        #expect(!(try stores.hasGatewayToolGrant(projectID: project.id, toolRevision: tool.revision)))
        #expect(!(try stores.hasGatewayToolGrant(projectID: project.id, toolRevision: revised.revision)))

        try stores.setGatewayServerApprovalMode(projectID: project.id, accountID: account.id, mode: .fullAuto)
        _ = try await call(revised)
        let events = try stores.recentActivity().compactMap { $0.detailJSON.flatMap(JSONValue.parse) }
        #expect(events.contains { $0["approval"] == .string("serverFullAuto") && $0["outcome"] == .string("succeeded") })
    }

    @Test func revokeAndClearAffectOnlyTheSelectedProjectAndAccount() throws {
        let stores = try inMemoryStores()
        let first = try stores.createWorkspaceProject(title: "Example")
        let second = try stores.createWorkspaceProject(title: "Another project")
        let chat = try stores.createWorkspaceChat(projectID: first.id, title: "Example chat")
        let endpoint = "https://mcp.example.invalid/mcp"
        let account = try stores.addGatewayUpstream(serverName: "example", label: "Example", endpoint: endpoint, projectID: nil)
        let other = try stores.addGatewayUpstream(serverName: "other", label: "Other", endpoint: endpoint, projectID: nil)
        let tool = try makeTool(account)
        let otherTool = try makeTool(other)
        for projectID in [first.id, second.id] {
            try stores.setGatewayToolApprovalOverride(projectID: projectID, tool: tool, risk: .read)
        }
        try stores.setGatewayToolApprovalOverride(projectID: first.id, tool: otherTool, risk: .read)
        func recordGrant() throws {
            try stores.recordGatewayActivity(.init(kind: .toolExecuted, connectorID: "agent.gateway", summary: "Example grant"),
                projectID: first.id, grant: (chat.id, tool.revision), gatewayTool: tool)
        }
        try recordGrant()
        try stores.revokeGatewayToolGrant(projectID: first.id, toolRevision: tool.revision)
        #expect(!(try stores.hasGatewayToolGrant(projectID: first.id, toolRevision: tool.revision)))
        #expect(try stores.gatewayToolApprovalRule(projectID: first.id, tool: tool).override == .read)
        try recordGrant()
        try stores.clearGatewayServerApprovalRules(projectID: first.id, accountID: account.id)
        #expect(!(try stores.hasGatewayToolGrant(projectID: first.id, toolRevision: tool.revision)))
        #expect(try stores.gatewayToolApprovalRule(projectID: first.id, tool: tool).override == nil)
        #expect(try stores.gatewayToolApprovalRule(projectID: second.id, tool: tool).override == .read)
        #expect(try stores.gatewayToolApprovalRule(projectID: first.id, tool: otherTool).override == .read)
    }

    private func makeTool(_ account: GatewayUpstreamAccount, description: String = "Example tool") throws -> MCPGatewayTool {
        try .init(origin: .upstream(server: account.serverName, accountID: account.id, definitionFingerprint: account.definitionFingerprint),
                  definition: .init(name: "example_tool", description: description,
                                    parametersJSON: "{\"type\":\"object\"}", risk: .confirmable))
    }
}
