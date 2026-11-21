import Foundation
import Testing
import AitvarasCore
import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct MCPGatewayTests {
    @Test func protocolNegotiatesAndPaginatesStableCatalog() async throws {
        let entries = try (0..<19).map { try gatewayFixtureTool(name: String(format: "item_%02d", $0)) }
        let catalog = GatewayCatalogFixture(Array(entries.reversed()))
        let gateway = MCPGateway(invocation: gatewayFixtureInvocation(), authorize: {}, catalog: { _ in await catalog.tools },
            dispatch: { _, tool, args, check in
                try await check()
                return .init(text: tool.name + ":" + (args["query"]?.stringValue ?? ""))
            })
        let premature = await gatewayFrame(gateway, method: "tools/list", id: 1)
        #expect(premature?["error"]?["code"] == .number(-32000))
        let initialization = await gatewayFrame(gateway, method: "initialize", id: 2, params: ["protocolVersion": .string("2025-06-18")])
        #expect(initialization?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(initialization?["result"]?["capabilities"]?["tools"]?["listChanged"] == .bool(true))
        await gatewayReady(gateway, initialize: false)
        let first = await gatewayFrame(gateway, method: "tools/list", id: 3)
        let cursor = try #require(first?["result"]?["nextCursor"]?.stringValue)
        #expect(first?["result"]?["tools"]?.arrayValue?.count == 16)
        #expect(first?["result"]?["tools"]?.arrayValue?.first?["name"] == .string("memory_item_00"))
        let second = await gatewayFrame(gateway, method: "tools/list", id: 4, params: ["cursor": .string(cursor)])
        #expect(second?["result"]?["tools"]?.arrayValue?.count == 3)
        #expect(second?["result"]?["nextCursor"] == nil)
        let call = await gatewayCall(gateway, name: entries[0].name, arguments: ["query": .string("example")])
        #expect(gatewayText(call) == "memory_item_00:example")
        await catalog.replace(Array(entries.dropFirst()))
        await gateway.catalogChanged()
        var events = gateway.notifications.makeAsyncIterator()
        let notification = await events.next().flatMap(gatewayJSON)
        #expect(notification?["method"] == .string("notifications/tools/list_changed"))
        let stale = await gatewayFrame(gateway, method: "tools/list", id: 5, params: ["cursor": .string(cursor)])
        #expect(stale?["error"]?["code"] == .number(-32602))
        await gateway.close()
        #expect(await events.next() == nil)
    }

    @Test func malformedFramesOversizedResultsAndCollisionsDoNotRoute() async throws {
        let tool = try gatewayFixtureTool()
        let catalog = GatewayCatalogFixture([tool])
        let gateway = MCPGateway(invocation: gatewayFixtureInvocation(), authorize: {}, catalog: { _ in await catalog.tools },
            dispatch: { _, _, _, _ in .init(text: String(repeating: "x", count: 220_000)) })
        await gatewayReady(gateway)
        let bad = await gateway.receive(Data("{".utf8)).flatMap(gatewayJSON)
        #expect(bad?["error"]?["code"] == .number(-32700))
        let deep = await gateway.receive(Data((String(repeating: "[", count: 35) + String(repeating: "]", count: 35)).utf8)).flatMap(gatewayJSON)
        #expect(deep?["error"]?["code"] == .number(-32600))
        let invalid = await gatewayFrame(gateway, method: "tools/call", id: 1, params: ["name": .string(tool.name), "arguments": .array([])])
        #expect(invalid?["error"]?["code"] == .number(-32602))
        let huge = await gatewayCall(gateway, name: tool.name)
        #expect(huge?["result"]?["isError"] == .bool(true))
        #expect(gatewayText(huge)?.contains("Do not retry") == true)
        let other = try gatewayFixtureTool(name: "search", origin: .upstream(server: "memory", accountID: UUID(),
                                                                             definitionFingerprint: String(repeating: "a", count: 64)))
        await catalog.replace([tool, other])
        let collision = await gatewayFrame(gateway, method: "tools/list", id: 2)
        #expect(collision?["error"]?["code"] == .number(-32603))
    }

    @Test func cancellationAndDisconnectStopInflightWork() async throws {
        let tool = try gatewayFixtureTool()
        let events = AsyncStream<Void>.makeStream()
        let gateway = MCPGateway(invocation: gatewayFixtureInvocation(), authorize: {}, catalog: { _ in [tool] },
            dispatch: { _, _, _, _ in
                events.continuation.yield()
                try await Task.sleep(for: .seconds(2))
                return .init(text: "too late")
            })
        await gatewayReady(gateway)
        var seen = events.stream.makeAsyncIterator()
        let request = Task { await gatewayCall(gateway, name: tool.name, id: 10) }
        _ = await seen.next()
        let duplicate = await gatewayCall(gateway, name: tool.name, id: 10)
        #expect(duplicate?["error"]?["code"] == .number(-32600))
        #expect(await gatewayFrame(gateway, method: "notifications/cancelled", params: ["requestId": .number(10)]) == nil)
        #expect(await request.value == nil)
        let next = Task { await gatewayCall(gateway, name: tool.name, id: 11) }
        _ = await seen.next()
        await gateway.close()
        #expect(await next.value == nil)
        events.continuation.finish()
    }
}

private actor GatewayCatalogFixture {
    var tools: [MCPGatewayTool]
    init(_ tools: [MCPGatewayTool]) { self.tools = tools }
    func replace(_ value: [MCPGatewayTool]) { tools = value }
}

func gatewayFixtureTool(name: String = "search", risk: ActionRisk = .read, origin: MCPGatewayTool.Origin = .aitvaras(.memory),
                        annotations: MCPGatewayTool.Annotations = .init(), trusted: Bool = false) throws -> MCPGatewayTool {
    try .init(origin: origin, definition: .init(name: name, description: "Example tool",
        parametersJSON: #"{"type":"object"}"#, risk: risk), annotations: annotations, trusted: trusted)
}

func gatewayFixtureInvocation(projectID: UUID? = UUID(), presentation: MCPGatewayInvocation.Presentation = .outside) -> MCPGatewayInvocation {
    .init(launchID: UUID(), context: .init(client: .claude, projectID: projectID), presentation: presentation)
}

func gatewayJSON(_ data: Data) -> JSONValue? { JSONValue.parse(String(decoding: data, as: UTF8.self)) }

func gatewayFrame(_ gateway: MCPGateway, method: String, id: Int? = nil, params: [String: JSONValue]? = nil) async -> JSONValue? {
    var frame: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
    if let id { frame["id"] = .number(Double(id)) }
    if let params { frame["params"] = .object(params) }
    return await gateway.receive(Data(JSONValue.object(frame).jsonString.utf8)).flatMap(gatewayJSON)
}

func gatewayReady(_ gateway: MCPGateway, initialize: Bool = true) async {
    if initialize {
        _ = await gatewayFrame(gateway, method: "initialize", id: 100, params: ["protocolVersion": .string("2025-11-25")])
    }
    _ = await gatewayFrame(gateway, method: "notifications/initialized")
}

func gatewayCall(_ gateway: MCPGateway, name: String, arguments: [String: JSONValue] = [:], id: Int = 90) async -> JSONValue? {
    await gatewayFrame(gateway, method: "tools/call", id: id, params: ["name": .string(name), "arguments": .object(arguments)])
}

func gatewayText(_ response: JSONValue?) -> String? {
    response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
}
