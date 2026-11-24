import Foundation
import GRDB
import Testing
import AitvarasAgent
import AitvarasAgents
import AitvarasConnectors
import AitvarasCore
import AitvarasStore

@Suite(.timeLimit(.minutes(1))) struct GatewayOwnToolsTests {
    @Test func memoryUsesProfileFactsAndKeepsQuarantineAndGatewayProvenance() async throws {
        let fixture = try await OwnToolFixture(scopes: [.memory])
        let existing = MemoryFact(text: "sample active profile fact", source: .userStated)
        let invalidated = MemoryFact(text: "sample invalidated", source: .extracted, validTo: .now)
        let hidden = MemoryFact(text: "sample quarantined", source: .extracted, needsReview: true)
        for fact in [existing, invalidated, hidden] {
            try fixture.stores.saveFact(fact, entityNames: "Example subject")
        }
        let search = await gatewayCall(fixture.gateway, name: "memory_search", arguments: ["query": .string("sample")])
        let about = await gatewayCall(fixture.gateway, name: "memory_about", arguments: ["entity": .string("Example subject")])
        for result in [search, about] {
            #expect(gatewayText(result)?.contains(existing.text) == true)
            #expect(gatewayText(result)?.contains(invalidated.text) == false)
            #expect(gatewayText(result)?.contains(hidden.text) == false)
        }

        let original = await gatewayCall(fixture.gateway, name: "memory_remember", arguments: ["text": .string("sample original")])
        let oldUUID = try #require(item(original)?["id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(try fixture.stores.fact(id: oldUUID)?.text == "sample original")
        let sensitive = await gatewayCall(fixture.gateway, name: "memory_remember", arguments: ["text": .string("sample synthetic diagnosis")])
        #expect(item(sensitive)?["needsReview"] == .bool(true))
        #expect(try fixture.stores.factsNeedingReview().contains { $0.text == "sample synthetic diagnosis" })
        let denied = await gatewayCall(fixture.gateway, name: "memory_revise", arguments: [
            "old_id": .string(hidden.id.uuidString), "text": .string("example replacement")])
        #expect(denied?["result"]?["isError"] == .bool(true))
        let revision = await gatewayCall(fixture.gateway, name: "memory_revise", arguments: [
            "old_id": .string(oldUUID.uuidString), "text": .string("sample revised")])
        let newUUID = try #require(item(revision)?["new_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let previous = try fixture.stores.fact(id: oldUUID)
        #expect(previous?.validTo != nil)
        #expect(previous?.supersededBy == newUUID)
        #expect(try fixture.stores.activeFacts().map(\.id).contains(newUUID))

        let recorded = try fixture.stores.recentActivity().compactMap { $0.detailJSON.flatMap(JSONValue.parse) }
        let write = try #require(recorded.first { $0["tool"] == .string("memory_remember") && $0["outcome"] == .string("succeeded") })
        #expect(write["launchID"] == .string(fixture.invocation.launchID.uuidString))
        #expect(write["client"] == .string("claude"))
        #expect(write["projectID"] == .string(fixture.project.id.uuidString))
        #expect(!recorded.map(\.jsonString).joined().contains("sample"))
    }

    @Test func theSameUpstreamToolNameRoutesToEachConnectionsOwnAccount() async throws {
        let stores = try inMemoryStores()
        let first = try stores.createWorkspaceProject(title: "First project")
        let second = try stores.createWorkspaceProject(title: "Second project")
        let definition = AgentMCPServer(transport: .http, url: "https://mcp.example.invalid/tools", management: .gatewayOAuth)
        try stores.saveGlobalAgentMCPServers(["linear": definition])
        let shared = try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: true, makeGlobalDefault: true)
        let assigned = try stores.registerGatewayUpstreamAccount(serverName: "linear", globallyAvailable: false)
        try stores.selectGatewayUpstreamAccount(projectID: first.id, serverName: "linear", accountID: assigned.id)
        for (project, account) in [(first, assigned), (second, shared)] {
            try stores.setGatewayUpstreamTrust(id: account.id, trusted: true)
            try stores.setGatewayServerApprovalMode(projectID: project.id, accountID: account.id, mode: .autoAllowReads)
        }
        let service = GatewayToolService(stores: stores, hub: ConnectorHub(stores: stores), approvals: GatewayApprovalBroker(),
            upstreamCatalog: { route in
                [try gatewayFixtureTool(origin: .upstream(server: route.account.serverName, accountID: route.account.id,
                    definitionFingerprint: route.account.definitionFingerprint), annotations: .init(readOnly: true), trusted: route.account.trusted)]
            }, upstreamCall: { route, _, _ in .init(text: route.account.id.uuidString) })
        let one = service.connect(invocation: gatewayFixtureInvocation(projectID: first.id), authorize: {})
        let two = service.connect(invocation: gatewayFixtureInvocation(projectID: second.id), authorize: {})
        await gatewayReady(one)
        await gatewayReady(two)
        let resultOne = await gatewayCall(one, name: "linear_search")
        let resultTwo = await gatewayCall(two, name: "linear_search")
        #expect(gatewayText(resultOne) == assigned.id.uuidString)
        #expect(gatewayText(resultTwo) == shared.id.uuidString)
    }

    @Test func knowledgeRequiresSourceLinksAndTracksNewDocumentsAndUnlinking() async throws {
        let fixture = try await OwnToolFixture(scopes: [.knowledge, .activity])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first")
        let otherRoot = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
        let sources = [KnowledgeSourceConfiguration(id: "src-one", name: "First", path: firstRoot.path),
                       KnowledgeSourceConfiguration(id: "src-other", name: "Other", path: otherRoot.path)]
        try fixture.stores.setValue(try AgentMCPConfiguration.encode(sources), forKey: KnowledgeSourceConfiguration.settingsKey)
        let withoutLink = await gatewayFrame(fixture.gateway, method: "tools/list", id: 3)
        #expect(!names(withoutLink).contains("knowledge_search"))
        let settings = try fixture.stores.gatewayToolScopeSettings(projectID: fixture.project.id)
        let linked = try fixture.stores.saveGatewayToolScopes(projectID: fixture.project.id, scopes: settings.scopes,
                                                              expectedRevision: settings.revision, knowledgeSourceIDs: ["src-one"])
        #expect(throws: WorkspacePolicyError.invalidPolicy) {
            try fixture.stores.saveGatewayToolScopes(projectID: fixture.project.id, scopes: settings.scopes,
                                                     expectedRevision: linked.revision, knowledgeSourceIDs: ["unconfigured"])
        }
        for (configured, folder, label) in [(sources[0], firstRoot, "sample linked"), (sources[1], otherRoot, "sample foreign")] {
            let file = folder.appendingPathComponent("example.md")
            try label.write(to: file, atomically: true, encoding: .utf8)
            let doc = RAGDocument(source: configured.id, path: file.path, mtime: 1, contentHash: configured.id)
            try fixture.stores.upsertDocument(doc, chunks: [.init(documentID: doc.id, ord: 0, text: label)])
        }
        let result = await gatewayCall(fixture.gateway, name: "knowledge_search", arguments: ["query": .string("sample")])
        #expect(gatewayText(result)?.contains("sample linked") == true)
        #expect(gatewayText(result)?.contains("sample foreign") == false)
        try fixture.stores.setValue(try AgentMCPConfiguration.encode([sources[1]]), forKey: KnowledgeSourceConfiguration.settingsKey,
                                    removingRAGDocumentsFrom: "src-one")
        #expect(try fixture.stores.gatewayToolScopeSettings(projectID: fixture.project.id).knowledgeSourceIDs.isEmpty)
        let removed = await gatewayCall(fixture.gateway, name: "knowledge_search", arguments: ["query": .string("sample")])
        #expect(removed?["error"]?["code"] == .number(-32602))

        let foreign = ActivityEvent(kind: .toolExecuted, summary: "Other activity")
        try fixture.stores.recordGatewayActivity(foreign, projectID: fixture.other.id)
        let forged = await gatewayCall(fixture.gateway, name: "activity_get", arguments: ["id": .string(foreign.id.uuidString)])
        #expect(forged?["result"]?["isError"] == .bool(true))
        #expect(try fixture.stores.gatewayActivity(projectID: fixture.project.id).allSatisfy { $0.id != foreign.id })
    }

    @Test func goalsAndMailUseTheProfileAndRevocationStopsDispatch() async throws {
        let mail = GatewayProfileFixture(id: "mail", tools: [
            GatewayProfileFixture.tool("recent_messages"), GatewayProfileFixture.tool("search_messages", field: "query"),
            GatewayProfileFixture.tool("get_message", field: "messageID"), GatewayProfileFixture.tool("send_message")
        ])
        let fixture = try await OwnToolFixture(scopes: [.goals, .mail], connectors: [mail])
        try fixture.stores.saveGoal(Goal(day: Goal.today(), text: "Example profile goal"))
        let listed = await gatewayFrame(fixture.gateway, method: "tools/list", id: 3)
        #expect(names(listed).filter { $0.hasPrefix("mail_") } == ["mail_get_message", "mail_recent_messages", "mail_search_messages"])
        #expect(names(listed).filter { $0.hasPrefix("goals_") } == ["goals_list_today"])
        let goals = await gatewayCall(fixture.gateway, name: "goals_list_today")
        #expect(gatewayText(goals)?.contains("Example profile goal") == true)
        _ = await gatewayCall(fixture.gateway, name: "mail_recent_messages")
        _ = await gatewayCall(fixture.gateway, name: "mail_search_messages", arguments: ["query": .string("example")])
        let read = await gatewayCall(fixture.gateway, name: "mail_get_message", arguments: ["messageID": .string("example-message")])
        #expect(gatewayText(read) == "example profile item")
        #expect(await mail.invocations == ["recent_messages", "search_messages", "get_message"])

        let settings = try fixture.stores.gatewayToolScopeSettings(projectID: fixture.project.id)
        try fixture.stores.saveGatewayToolScopes(projectID: fixture.project.id, scopes: [.goals], expectedRevision: settings.revision)
        let after = await gatewayCall(fixture.gateway, name: "mail_recent_messages")
        #expect(after?["error"]?["code"] == .number(-32602))
        #expect(await mail.invocations.count == 3)
    }

    @Test func calendarAndRemindersUseExistingProfileReadersAndStrictOwnershipTags() async throws {
        let calendar = GatewayProfileFixture(id: "calendar", tools: [GatewayProfileFixture.tool("list_events")])
        let reminders = GatewayProfileFixture(id: "reminders", tools: [GatewayProfileFixture.tool("list_reminders")])
        let fixture = try await OwnToolFixture(scopes: [.calendar, .reminders], connectors: [calendar, reminders])
        let events = await gatewayCall(fixture.gateway, name: "calendar_list_events")
        let remindersResult = await gatewayCall(fixture.gateway, name: "reminders_list_reminders")
        #expect(gatewayText(events) == "example profile item")
        #expect(gatewayText(remindersResult) == "example profile item")
        let event = AitvarasEventTag.makeURL()
        let reminder = AitvarasEventTag.makeURL(item: .reminder)
        #expect(AitvarasEventTag.owns(event, item: .event))
        #expect(AitvarasEventTag.owns(reminder, item: .reminder))
        #expect(!AitvarasEventTag.owns(event, item: .reminder))
        #expect(!AitvarasEventTag.owns(URL(string: "aitvaras://reminder/untagged"), item: .reminder))
        #expect(!AitvarasEventTag.owns(nil, item: .reminder))
    }

    private func names(_ response: JSONValue?) -> [String] {
        response?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    private func item(_ response: JSONValue?) -> JSONValue? {
        gatewayText(response).flatMap(JSONValue.parse)
    }
}

private struct OwnToolFixture {
    let stores: Stores
    let project: WorkspaceProject
    let other: WorkspaceProject
    let gateway: MCPGateway
    let invocation: MCPGatewayInvocation

    init(scopes: Set<GatewayToolScope>, connectors: [any Connector] = []) async throws {
        stores = try inMemoryStores()
        project = try stores.createWorkspaceProject(title: "Example project")
        other = try stores.createWorkspaceProject(title: "Other project")
        try stores.saveGatewayToolScopes(projectID: project.id, scopes: scopes, expectedRevision: 0)
        try stores.saveGatewayToolScopes(projectID: other.id, scopes: scopes, expectedRevision: 0)
        let hub = ConnectorHub(stores: stores)
        await hub.register(MemoryConnector(stores: stores, embedder: GatewayMemoryEmbedder()))
        await hub.register(GoalsConnector(stores: stores))
        for connector in connectors { await hub.register(connector) }
        invocation = gatewayFixtureInvocation(projectID: project.id)
        gateway = GatewayToolService(stores: stores, hub: hub, approvals: GatewayApprovalBroker())
            .connect(invocation: invocation, authorize: {})
        await gatewayReady(gateway)
    }
}

actor GatewayMemoryEmbedder: EmbeddingEngine {
    nonisolated let identifier = "gateway-fixture"
    nonisolated let dimensions = 1
    func embed(texts: [String]) async throws -> [[Float]] { [] }
}

private actor GatewayProfileFixture: GatewayProfileConnector {
    nonisolated let id: String
    nonisolated let displayName = "Example connector"
    nonisolated let tools: [ToolDefinition]
    var invocations: [String] = []

    init(id: String, tools: [ToolDefinition]) { self.id = id; self.tools = tools }
    func health() async -> ConnectorHealth { .ready }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        invocations.append(toolName)
        return "example profile item"
    }

    static func tool(_ name: String, field: String? = nil) -> ToolDefinition {
        let properties = field.map { [$0: JSONValue.object(["type": .string("string")])] } ?? [:]
        let required = field.map { [JSONValue.string($0)] } ?? []
        let schema = JSONValue.object(["type": .string("object"), "properties": .object(properties), "required": .array(required)])
        return .init(name: name, description: "Example connector tool", parametersJSON: schema.jsonString, risk: .read)
    }
}
