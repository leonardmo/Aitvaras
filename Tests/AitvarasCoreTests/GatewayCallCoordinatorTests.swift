import Foundation
import GRDB
import Testing
import AitvarasAgents
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

@Suite(.timeLimit(.minutes(1))) struct GatewayCallCoordinatorTests {
    @Test func precedenceAndExactGrantsCannotOverrideHardRules() throws {
        let invocation = gatewayFixtureInvocation()
        let origin = MCPGatewayTool.Origin.upstream(server: "linear", accountID: UUID(), definitionFingerprint: String(repeating: "a", count: 64))
        let trust = try gatewayFixtureTool(origin: origin, annotations: .init(readOnly: true), trusted: true)
        let untrusted = try gatewayFixtureTool(origin: origin, annotations: .init(readOnly: true))
        let update = try gatewayFixtureTool(name: "update", origin: origin, annotations: .init(destructive: false, idempotent: true), trusted: true)
        let outbound = try gatewayFixtureTool(name: "post", origin: origin, annotations: .init(readOnly: true), trusted: true)
        let forbidden = try gatewayFixtureTool(name: "send_mail", origin: origin, annotations: .init(readOnly: true), trusted: true)
        #expect(GatewayPolicyDecision(tool: trust, invocation: invocation, rules: .init(), policy: .init()).risk == .read)
        #expect(GatewayPolicyDecision(tool: untrusted, invocation: invocation, rules: .init(), policy: .init()).risk == .confirmable)
        #expect(GatewayPolicyDecision(tool: update, invocation: invocation, rules: .init(), policy: .init()).risk == .reversibleWrite)
        let overridden = GatewayPolicyDecision(tool: trust, invocation: invocation, rules: .init(overrides: [trust.revision: .confirmable]), policy: .init())
        #expect(overridden.verdict == .requireConfirmation)
        let grant = try #require(GatewayExactGrant(projectID: invocation.context.projectID, tool: untrusted))
        let rules = GatewayPolicyRules(overrides: [outbound.revision: .read, forbidden.revision: .read], grants: [grant])
        #expect(GatewayPolicyDecision(tool: untrusted, invocation: invocation, rules: rules, policy: .init()).verdict == .allow)
        let changedAccount = try gatewayFixtureTool(origin: .upstream(server: "linear", accountID: UUID(),
                                                                     definitionFingerprint: String(repeating: "a", count: 64)))
        #expect(GatewayPolicyDecision(tool: changedAccount, invocation: invocation, rules: rules, policy: .init()).verdict == .requireConfirmation)
        #expect(GatewayPolicyDecision(tool: outbound, invocation: invocation, rules: rules, policy: .init()).verdict == .requireConfirmation)
        #expect(GatewayExactGrant(projectID: invocation.context.projectID, tool: outbound) == nil)
        #expect(GatewayPolicyDecision(tool: forbidden, invocation: invocation, rules: rules, policy: .init()).forbidden)
    }

    @Test func approvalIsOneShotAndOnlyMetadataReachesStorage() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let hub = ConnectorHub(stores: stores)
        await hub.register(GatewayLegacyAuditFixture())
        let approvals = GatewayApprovalBroker()
        let tool = try gatewayFixtureTool(risk: .confirmable)
        let invocation = gatewayFixtureInvocation(projectID: project.id)
        let args = JSONValue.object(["access": .string("fixture-secret"), "unsafe fixture key": .string("private argument"),
                                     "nested": .object(["password": .string("nested fixture secret")]), "limit": .number(5)])
        let call = Task {
            try await hub.executeGateway(invocation, tool: tool, arguments: args, approvals: approvals,
                rules: { .init() }, revalidate: {}) {
                    // An accidental inner call must not reach the legacy suggestion/audit path.
                    let nested = ToolCall(id: "nested", toolName: "example.send", argumentsJSON: args.jsonString)
                    do {
                        _ = try await hub.execute(call: nested, causedBy: nil, sourceID: nil)
                        throw GatewayFixtureFailure.unexpected
                    } catch MCPGatewayCallError.denied {}
                    return .init(text: "fixture result")
                }
        }
        defer { call.cancel() }
        let pending = try await nextGatewayApproval(approvals)
        #expect(pending.arguments == args)
        #expect(await approvals.decide(id: pending.id, allow: true))
        #expect(!(await approvals.decide(id: pending.id, allow: true)))
        #expect(try await call.value.content.first?["text"] == .string("fixture result"))
        let events = try stores.recentActivity()
        #expect(events.count == 3)
        #expect(try stores.pendingSuggestions().isEmpty)
        let details = events.compactMap { $0.detailJSON.flatMap(JSONValue.parse) }
        let serialized = events.compactMap(\.detailJSON).joined()
        for text in ["fixture-secret", "private argument", "unsafe fixture key", "nested fixture secret", "fixture result"] {
            #expect(!serialized.contains(text))
        }
        #expect(details.contains { $0["approval"] == .string("approved") && $0["outcome"] == .string("succeeded") })
        #expect(details.allSatisfy { $0["arguments"]?["limit"] == .number(5) && $0["arguments"]?["redactedFields"] == .number(3) })
    }

    @Test func timeoutRevocationAndStaleApprovalNeverDispatch() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let tool = try gatewayFixtureTool(risk: .confirmable)
        let timer = GatewayApprovalBroker(outsideTimeout: .milliseconds(15))
        let outside = gatewayFixtureInvocation(projectID: nil)
        await #expect(throws: MCPGatewayCallError.timedOut) {
            try await hub.executeGateway(outside, tool: tool, arguments: .object([:]), approvals: timer,
                rules: { .init() }, revalidate: {}) { throw GatewayFixtureFailure.unexpected }
        }
        let inline = gatewayFixtureInvocation(projectID: nil, presentation: .inline(chatID: UUID()))
        let inlineCall = Task {
            try await hub.executeGateway(inline, tool: tool, arguments: .object([:]), approvals: timer,
                rules: { .init() }, revalidate: {}) { throw GatewayFixtureFailure.unexpected }
        }
        defer { inlineCall.cancel() }
        let active = try await nextGatewayApproval(timer)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await timer.requests().map(\.id) == [active.id])
        await timer.cancel(launchID: inline.launchID)
        await #expect(throws: MCPGatewayCallError.denied) { try await inlineCall.value }

        let check = GatewayFixtureState()
        let approvals = GatewayApprovalBroker()
        let call = Task {
            try await hub.executeGateway(outside, tool: tool, arguments: .object([:]), approvals: approvals,
                rules: { .init() }, revalidate: {
                    guard await check.open else { throw MCPGatewayCallError.stale }
                }) { throw GatewayFixtureFailure.unexpected }
        }
        defer { call.cancel() }
        let pending = try await nextGatewayApproval(approvals)
        await check.close()
        #expect(await approvals.decide(id: pending.id, allow: true))
        await #expect(throws: MCPGatewayCallError.stale) { try await call.value }
        #expect(try !stores.recentActivity().compactMap(\.detailJSON).contains { $0.contains("dispatching") })
    }

    @Test func failedAuditBlocksDispatchAndFailedWriteIsUncertain() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let approvals = GatewayApprovalBroker()
        let tool = try gatewayFixtureTool(name: "add", risk: .reversibleWrite)
        let invocation = gatewayFixtureInvocation(projectID: nil)
        try await stores.db.queue.write { try $0.execute(sql: """
            CREATE TRIGGER gatewayAuditFailure BEFORE INSERT ON activityEvent
            BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
            """) }
        await #expect(throws: MCPGatewayCallError.auditUnavailable) {
            try await hub.executeGateway(invocation, tool: tool, arguments: .object([:]), approvals: approvals,
                rules: { .init() }, revalidate: {}) { throw GatewayFixtureFailure.unexpected }
        }
        try await stores.db.queue.write {
            try $0.execute(sql: "DROP TRIGGER gatewayAuditFailure")
            try $0.execute(sql: """
                CREATE TRIGGER gatewayAuditFailure BEFORE INSERT ON activityEvent
                WHEN json_extract(NEW.detailJSON,'$.outcome') = 'succeeded'
                BEGIN SELECT RAISE(ABORT, 'fixture failure'); END
                """)
        }
        await #expect(throws: MCPGatewayCallError.completedWithoutAudit) {
            try await hub.executeGateway(invocation, tool: tool, arguments: .object([:]), approvals: approvals,
                rules: { .init() }, revalidate: {}) { .init(text: "fixture result") }
        }
        await #expect(throws: MCPGatewayCallError.outcomeUnknown) {
            try await hub.executeGateway(invocation, tool: tool, arguments: .object([:]), approvals: approvals,
                rules: { .init() }, revalidate: {}) { throw GatewayFixtureFailure.unexpected }
        }
        #expect(try stores.recentActivity().compactMap(\.detailJSON).contains { $0.contains("outcomeUnknown") })
    }
}

private enum GatewayFixtureFailure: Error { case unexpected, noApproval }
private actor GatewayFixtureState {
    var open = true
    func close() { open = false }
}

private func nextGatewayApproval(_ broker: GatewayApprovalBroker) async throws -> GatewayApprovalRequest {
    for _ in 0..<200 {
        if let pending = await broker.requests().first { return pending }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw GatewayFixtureFailure.noApproval
}

private actor GatewayLegacyAuditFixture: Connector {
    nonisolated let id = "example"
    nonisolated let displayName = "Example"
    nonisolated let tools: [ToolDefinition] = [
        .init(name: "send", description: "Fixture action", parametersJSON: "{}", risk: .confirmable)
    ]
    func health() async -> ConnectorHealth { .ready }
    func execute(toolName: String, argumentsJSON: String) async throws -> String { throw GatewayFixtureFailure.unexpected }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
}
