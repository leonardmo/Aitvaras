import Foundation
import Synchronization
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayStaticTokenTests {
    @Test func projectAccountSharesSessionAndKeepsTrustedWritesConfirmable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = Stores(db: try AitvarasDatabase(url: root.appendingPathComponent("state.sqlite")))
        let project = try stores.createWorkspaceProject(title: "Example")
        let other = try stores.createWorkspaceProject(title: "Other")
        let token = UUID().uuidString
        let replacement = UUID().uuidString
        let remote = StaticUpstreamFixture(token: token)
        let vault = StaticTestVault()
        let sessions = GatewayUpstreamSessions(secrets: vault.adapter, send: { try await remote.send($0, id: $1) })
        let account = try await sessions.addStaticUpstream(stores: stores, serverName: "issues", label: "Example",
            endpoint: staticTestEndpoint, projectID: project.id, headerName: nil, token: token)
        #expect(account.authKind == .staticHeader && !account.trusted)
        let storedInAdapter = vault.matches(account.id, token: token)
        #expect(storedInAdapter)

        let approvals = GatewayApprovalBroker(outsideTimeout: .seconds(5))
        let service = GatewayToolService(stores: stores, hub: ConnectorHub(stores: stores), approvals: approvals, upstreams: sessions)
        func connect(_ client: GatewayLaunchContext.Client, projectID: UUID?) -> MCPGateway {
            service.connect(invocation: .init(launchID: UUID(), context: .init(client: client, projectID: projectID),
                                              presentation: .outside), authorize: {})
        }
        let claude = connect(.claude, projectID: project.id)
        let codex = connect(.codex, projectID: project.id)
        let foreign = connect(.codex, projectID: other.id)
        let outside = connect(.claude, projectID: nil)
        for client in [claude, codex, foreign, outside] { await gatewayReady(client) }
        #expect(await names(claude) == ["issues_list_issues", "issues_update_issue"])
        #expect(await names(codex) == ["issues_list_issues", "issues_update_issue"])
        #expect(await names(foreign).isEmpty)
        #expect(await names(outside).isEmpty)
        let invisible = await gatewayCall(foreign, name: "issues_list_issues")
        #expect(invisible?["error"]?["message"] == .string("Unknown tool."))
        #expect(await remote.methods == ["initialize", "notifications/initialized", "tools/list"])

        try await approvedCall("issues_list_issues", on: claude, approvals: approvals)
        try stores.setGatewayUpstreamTrust(id: account.id, trusted: true)
        try stores.setGatewayServerApprovalMode(projectID: project.id, accountID: account.id, mode: .autoAllowReads)
        await sessions.routingChanged()
        let read = gatewayText(await gatewayCall(codex, name: "issues_list_issues"))
        #expect(read == "Example issue")
        try await approvedCall("issues_update_issue", on: codex, approvals: approvals)

        await remote.changeToken(to: replacement, status: 403)
        let rejected = gatewayText(await gatewayCall(claude, name: "issues_list_issues"))
        #expect(rejected == "Token rejected, update it in Settings → Connections.")
        let count = await remote.methods.count
        _ = await gatewayCall(codex, name: "issues_list_issues")
        #expect(await remote.methods.count == count)
        let request = try #require(await sessions.signInRequests().first)
        #expect(request.id == account.id && request.authKind == .staticHeader && request.tokenRejected)

        try await sessions.replaceStaticToken(stores: stores, id: account.id, token: replacement)
        #expect(await sessions.signInRequests().isEmpty)
        let success = gatewayText(await gatewayCall(codex, name: "issues_list_issues"))
        #expect(success == "Example issue")
        let replacedInAdapter = vault.matches(account.id, token: replacement)
        #expect(replacedInAdapter)
        await remote.reflectHeader()
        let reflected = gatewayText(await gatewayCall(codex, name: "issues_list_issues"))
        let concealed = reflected?.contains(replacement) == false
        #expect(concealed)
        try await sessions.removeStaticToken(stores: stores, id: account.id)
        #expect(vault.count == 0)
        let removed = gatewayText(await gatewayCall(claude, name: "issues_list_issues"))
        #expect(removed == "Add a token in Settings → Connections.")

        let events = try stores.recentActivity()
        #expect(events.contains { $0.detailJSON?.contains("tokenRejected") == true })
        let needles = [token, replacement].map { Data($0.utf8) }
        let activity = try JSONEncoder().encode(events)
        let activityIsClean = !needles.contains { activity.range(of: $0) != nil }
        #expect(activityIsClean)
        let configuration = GatewayCLIConfiguration(executable: root.appendingPathComponent("aitvaras-mcp"), stateDirectory: root)
        for client in [GatewayLaunchContext.Client.claude, .codex] {
            _ = try configuration.withLaunchArguments([], client: client) { arguments in
                let overrides = Data(arguments.joined(separator: "\n").utf8)
                let overridesAreClean = !needles.contains { overrides.range(of: $0) != nil }
                #expect(overridesAreClean)
                if client == .claude {
                    let path = try #require(arguments.last)
                    let config = try Data(contentsOf: URL(fileURLWithPath: path))
                    let configIsClean = !needles.contains { config.range(of: $0) != nil }
                    #expect(configIsClean)
                }
                return 0
            }
        }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: file)
            let fileIsClean = !needles.contains { data.range(of: $0) != nil }
            #expect(fileIsClean, "A profile file contains a fixture credential.")
        }
        for client in [claude, codex, foreign, outside] { await client.close() }
    }

    @Test func customHeaderWrongTokenCanBeReplacedAndGlobalAccountCanBeOptedOut() async throws {
        let token = UUID().uuidString
        let remote = StaticUpstreamFixture(token: token, header: "X-API-Key")
        let vault = StaticTestVault()
        let sessions = GatewayUpstreamSessions(secrets: vault.adapter, send: { try await remote.send($0, id: $1) })
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let account = try await sessions.addStaticUpstream(stores: stores, serverName: "issues", label: "Default",
            endpoint: staticTestEndpoint, projectID: nil, headerName: "X-API-Key", token: UUID().uuidString)
        let alternate = try await sessions.addStaticUpstream(stores: stores, serverName: "issues", label: "Alternate",
            endpoint: staticTestEndpoint, projectID: nil, headerName: "X-API-Key", token: token)
        let context = GatewayLaunchContext(client: .codex, projectID: project.id)
        let route = try #require(try stores.gatewayUpstreams(for: context).first)
        #expect(route.account == account && route.account.headerName == "X-API-Key")
        let placeholder = try #require(try await sessions.catalog(route).first)
        #expect(placeholder.name == "issues_set_token")
        await #expect(throws: MCPGatewayCallError.tokenRejected) {
            try await sessions.call(route, tool: placeholder, arguments: .object([:]))
        }
        #expect(await remote.methods == ["initialize"])
        #expect(await sessions.signInRequests().first?.id == account.id)

        try await sessions.replaceStaticToken(stores: stores, id: account.id, token: token)
        let tools = try await sessions.catalog(route)
        let read = try #require(tools.first { $0.name == "issues_list_issues" })
        _ = try await sessions.call(route, tool: read, arguments: .object([:]))
        #expect(await remote.methods == ["initialize", "initialize", "notifications/initialized", "tools/list", "tools/call"])

        try stores.selectGatewayUpstreamAccount(projectID: project.id, serverName: "issues", accountID: alternate.id)
        #expect(try stores.gatewayUpstreams(for: context).map(\.account.id) == [alternate.id])
        try stores.editAgentSetup(projectID: project.id, edit: .globalEnabled(name: "issues", enabled: false))
        #expect(try stores.gatewayUpstreams(for: context).isEmpty)
        #expect(try stores.gatewayUpstreams(for: .init(client: .claude, projectID: nil)).map(\.account.id) == [account.id])
    }

    @Test func invalidMetadataOrKeychainFailureDoesNotLeaveAProvisionedAccount() async throws {
        let stores = try inMemoryStores()
        let vault = StaticTestVault()
        let sessions = GatewayUpstreamSessions(secrets: vault.adapter, send: { _, _ in throw GatewayOAuthError.invalidResponse })
        let token = UUID().uuidString
        await #expect(throws: GatewayUpstreamError.invalidHeader) {
            try await sessions.addStaticUpstream(stores: stores, serverName: "example", label: "Example",
                endpoint: staticTestEndpoint, projectID: nil, headerName: "mcp-session-id", token: token)
        }
        let acceptsQuery = (try? await sessions.addStaticUpstream(stores: stores, serverName: "example", label: "Example",
            endpoint: staticTestEndpoint + "?key=example", projectID: nil, headerName: nil, token: token)) != nil
        #expect(!acceptsQuery)
        #expect(vault.count == 0)
        let inaccessible = GatewayUpstreamSessions(secrets: .init(load: { _ in nil },
            save: { _, _ in throw GatewayOAuthError.invalidResponse }, delete: { _ in }),
            send: { _, _ in throw GatewayOAuthError.invalidResponse })
        await #expect(throws: GatewayOAuthError.invalidResponse) {
            try await inaccessible.addStaticUpstream(stores: stores, serverName: "example", label: "Example",
                endpoint: staticTestEndpoint, projectID: nil, headerName: nil, token: token)
        }
        #expect(try stores.allGatewayUpstreamAccounts().isEmpty)
        #expect(try stores.globalAgentMCPServers().isEmpty)
    }

    private func names(_ gateway: MCPGateway) async -> Set<String> {
        let frame = await gatewayFrame(gateway, method: "tools/list", id: 4)
        return Set(frame?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
    }

    private func approvedCall(_ name: String, on gateway: MCPGateway, approvals: GatewayApprovalBroker) async throws {
        let call = Task { await gatewayCall(gateway, name: name) }
        defer { call.cancel() }
        let request = try await AsyncDeadline.run(for: .seconds(3)) {
            var changes = approvals.changes.makeAsyncIterator()
            while !Task.isCancelled {
                if let request = await approvals.requests().first { return request }
                guard await changes.next() != nil else { break }
            }
            throw CancellationError()
        }
        #expect(request.risk == .confirmable && request.toolName == name)
        #expect(await approvals.decide(id: request.id, allow: true))
        let response = gatewayText(await call.value)
        #expect(response == "Example issue")
    }
}

let staticTestEndpoint = "https://mcp.example.invalid/mcp"

final class StaticTestVault: Sendable {
    private let entries = Mutex<[String: String]>([:])
    var adapter: GatewayOAuthSecrets {
        .init(load: { key in self.entries.withLock { $0[key] } },
              save: { key, value in self.entries.withLock { $0[key] = value } },
              delete: { key in self.entries.withLock { _ = $0.removeValue(forKey: key) } })
    }

    var count: Int { entries.withLock { $0.count } }

    func matches(_ accountID: UUID, token: String) -> Bool {
        entries.withLock { $0[GatewayRemoteSession.staticKey(accountID)] == token }
    }
}

private actor StaticUpstreamFixture {
    private var token: String
    private let header: String?
    private var status = 401
    private var echo = false
    private(set) var methods: [String] = []

    init(token: String, header: String? = nil) {
        self.token = token; self.header = header
    }

    func changeToken(to value: String, status: Int) {
        token = value
        self.status = status
    }

    func reflectHeader() { echo = true }

    func send(_ request: URLRequest, id: JSONValue?) throws -> GatewayHTTPResponse {
        guard request.url?.absoluteString == staticTestEndpoint, request.httpMethod == "POST",
              let body = request.httpBody, let message = JSONValue.parse(String(decoding: body, as: UTF8.self)),
              let method = message["method"]?.stringValue, message["id"] == id,
              methods.count < 24 else { throw GatewayOAuthError.invalidResponse }
        methods.append(method)
        let supplied = request.value(forHTTPHeaderField: header ?? "Authorization")
        let expected = header == nil ? "Bearer " + token : token
        guard supplied == expected, header == nil || request.value(forHTTPHeaderField: "Authorization") == nil else {
            return .init(status: status, headers: [:], body: Data((supplied ?? "").utf8))
        }
        let result: JSONValue
        switch method {
        case "initialize":
            result = .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])])])
            return reply(result, id: id, headers: ["mcp-session-id": "fixture-session"])
        case "notifications/initialized":
            return .init(status: 202, headers: [:], body: Data())
        case "tools/list":
            result = .object(["tools": .array([tool("list_issues", readOnly: true), tool("update_issue", readOnly: false)])])
        case "tools/call":
            result = .object(["content": .array([.object(["type": .string("text"), "text": .string(echo ? expected : "Example issue")])])])
        default: throw GatewayOAuthError.invalidResponse
        }
        guard request.value(forHTTPHeaderField: "Mcp-Session-Id") == "fixture-session",
              request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18" else {
            throw GatewayOAuthError.invalidResponse
        }
        return reply(result, id: id)
    }

    private func tool(_ name: String, readOnly: Bool) -> JSONValue {
        .object(["name": .string(name), "inputSchema": .object(["type": .string("object")]),
                 "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(false), "idempotentHint": .bool(true)])])
    }

    private func reply(_ result: JSONValue, id: JSONValue?, headers: [String: String] = [:]) -> GatewayHTTPResponse {
        let response = JSONValue.object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
        return .init(status: 200, headers: headers, body: Data(response.jsonString.utf8))
    }
}
