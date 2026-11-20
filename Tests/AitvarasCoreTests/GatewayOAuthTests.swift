import CryptoKit
import Foundation
import Synchronization
import Testing
import AitvarasAgents
import AitvarasStore
@testable import AitvarasAgent

@Suite(.timeLimit(.minutes(1))) struct GatewayOAuthTests {
    @Test func undiscoveredCatalogUsesTheSameSignInToolForEveryVendor() async throws {
        for endpoint in ["https://mcp.example.invalid/mcp", "https://mcp.linear.app/mcp"] {
            let fake = OAuthUpstreamFixture()
            let (sessions, route, _, _) = try make(fake, endpoint: endpoint)
            #expect(try await sessions.catalog(route).map(\.name) == ["issues_sign_in"])
            #expect(await fake.counts().initialize == 0)
        }
    }

    @Test func discoveryPKCEAndRotationShareOneSession() async throws {
        let fake = OAuthUpstreamFixture()
        let (sessions, route, vault, notices) = try make(fake)
        let initial = try await sessions.catalog(route)
        #expect(initial.map(\.name) == ["issues_sign_in"])
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        #expect(notices.value.withLock { $0 } == 1)
        try await login(sessions, route, fake)
        let tools = try await sessions.catalog(route)
        let tool = try #require(tools.first)
        #expect(tool.name == "issues_list_issues")
        #expect(await sessions.signInRequests().isEmpty)
        try await withThrowingTaskGroup(of: MCPGatewayToolResult.self) { group in
            for _ in 0..<8 {
                group.addTask { try await sessions.call(route, tool: tool, arguments: .object([:])) }
            }
            for try await reply in group { #expect(reply.content.first?["text"] == .string("Synthetic issue")) }
        }
        let counts = await fake.counts()
        #expect(counts.refresh == 2)
        #expect(counts.initialize == 1)
        #expect(counts.calls == 8)
        #expect(vault.value.withLock { $0.count } == 1)
        #expect(vault.value.withLock { $0.values.first?.contains("test-refresh-2") } == true)
        #expect(vault.value.withLock { $0.values.first?.contains("test-refresh-1") } == false)
    }

    @Test(arguments: ["state", "verifier", "cancel", "resource", "dcr"])
    func invalidOrCancelledSignInWritesNoCredentials(_ fault: String) async throws {
        let fake = OAuthUpstreamFixture(fault: fault)
        let (sessions, route, vault, _) = try make(fake)
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        await #expect(throws: (any Error).self) { try await login(sessions, route, fake, fault: fault) }
        #expect(vault.value.withLock { $0.isEmpty })
        #expect(await sessions.signInRequests().map(\.id) == [route.account.id])
        let counts = await fake.counts()
        #expect(counts.refresh == 0 && counts.initialize == 0)
    }

    @Test func failedRefreshRetainsCatalogAndDeduplicatesReauth() async throws {
        let fake = OAuthUpstreamFixture(fault: "refresh")
        let (sessions, route, vault, notices) = try make(fake)
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        try await login(sessions, route, fake)
        let tools = try await sessions.catalog(route)
        let tool = try #require(tools.first)
        await #expect(throws: MCPGatewayCallError.needsSignIn) {
            try await sessions.call(route, tool: tool, arguments: .object([:]))
        }
        #expect(try await sessions.catalog(route) == tools)
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        #expect(await sessions.signInRequests().count == 1)
        #expect(notices.value.withLock { $0 } == 3) // login request, removal, then one re-auth
        #expect(vault.value.withLock { $0.isEmpty })
    }

    @Test func legacyDiscoveryUsesIssuerWellKnownWithoutResource() async throws {
        let fake = OAuthUpstreamFixture(fault: "legacy")
        let (sessions, route, _, _) = try make(fake)
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        try await login(sessions, route, fake)
        #expect(try await sessions.catalog(route).map(\.name) == ["issues_list_issues"])
    }

    @Test func unauthorizedCallRefreshesWithoutReplayingTheRequest() async throws {
        let fake = OAuthUpstreamFixture(fault: "unauthorized")
        let (sessions, route, _, _) = try make(fake)
        await #expect(throws: MCPGatewayCallError.needsSignIn) { try await sessions.requireSignInIfNeeded(route) }
        try await login(sessions, route, fake)
        let tool = try #require(try await sessions.catalog(route).first)
        await #expect(throws: MCPGatewayCallError.unavailable) {
            try await sessions.call(route, tool: tool, arguments: .object([:]))
        }
        let counts = await fake.counts()
        #expect(counts.calls == 1)
        #expect(counts.refresh == 3)
        _ = try await sessions.call(route, tool: tool, arguments: .object([:]))
        #expect(await fake.counts().calls == 2)
        #expect(await sessions.signInRequests().isEmpty)
    }

    @Test func explicitTrustUpdatesCachedToolsAndSignOutPreventsPendingDispatch() async throws {
        let stores = try inMemoryStores(), fake = OAuthUpstreamFixture()
        let (sessions, route, vault, _) = try make(fake, stores: stores)
        #expect(try await !sessions.signedIn(route))
        try await login(sessions, route, fake)
        #expect(try await sessions.signedIn(route))
        let original = try #require(try await sessions.catalog(route).first)
        #expect(!original.trusted && original.annotations.readOnly == true)
        try stores.setGatewayUpstreamTrust(id: route.account.id, trusted: true)
        let trustedRoute = try stores.gatewayUpstream(id: route.account.id)
        let trusted = try #require(try await sessions.catalog(trustedRoute).first)
        #expect(trusted.trusted && trusted.revision != original.revision)
        await #expect(throws: MCPGatewayCallError.stale) {
            try await sessions.call(trustedRoute, tool: original, arguments: .object([:]))
        }
        await #expect(throws: MCPGatewayCallError.needsSignIn) {
            try await sessions.call(trustedRoute, tool: trusted, arguments: .object([:])) {
                try await sessions.signOut(trustedRoute)
            }
        }
        #expect(try await !sessions.signedIn(trustedRoute))
        #expect(await fake.counts().calls == 0)
        #expect(vault.value.withLock { $0.isEmpty })
    }

    private func make(_ fake: OAuthUpstreamFixture, endpoint: String = "https://mcp.example.invalid/mcp", stores supplied: Stores? = nil) throws -> (
        GatewayUpstreamSessions, GatewayUpstream, Locked<[String: String]>, Locked<Int>
    ) {
        let stores = try supplied ?? inMemoryStores()
        try stores.saveGlobalAgentMCPServers(["issues": .init(transport: .http,
            url: endpoint, management: .gatewayOAuth)])
        let account = try stores.registerGatewayUpstreamAccount(serverName: "issues", globallyAvailable: true, makeGlobalDefault: true)
        let vault = Locked<[String: String]>([:]), notices = Locked(0)
        let sessions = GatewayUpstreamSessions(secrets: .init(load: { key in vault.value.withLock { $0[key] } },
            save: { key, value in vault.value.withLock { $0[key] = value } },
            delete: { key in vault.value.withLock { _ = $0.removeValue(forKey: key) } }),
            send: { request, id in try await fake.send(request, id: id) }, needsAttention: { notices.value.withLock { $0 += 1 } })
        return (sessions, try stores.gatewayUpstream(id: account.id), vault, notices)
    }

    private final class Locked<Value: Sendable>: Sendable {
        let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
    }

    private func login(_ sessions: GatewayUpstreamSessions, _ route: GatewayUpstream, _ fake: OAuthUpstreamFixture,
                       fault: String = "") async throws {
        let redirect = URL(string: "http://127.0.0.1:49153/oauth/callback")!
        try await sessions.signIn(route.account.id, currentRoute: { route }, redirect: redirect) { browser in
            if fault == "cancel" { throw CancellationError() }
            return try await fake.authorize(browser, redirect: redirect, wrongState: fault == "state")
        }
    }
}

actor OAuthUpstreamFixture {
    let fault: String
    let includesWriteTool: Bool
    private(set) var registrations = 0
    private var challenge: String?
    private var registeredRedirect: String?
    private var refreshes = 0, initialized = 0, calls = 0
    init(fault: String = "", includesWriteTool: Bool = false) {
        self.fault = fault
        self.includesWriteTool = includesWriteTool
    }

    func counts() -> (refresh: Int, initialize: Int, calls: Int) { (refreshes, initialized, calls) }

    func authorize(_ url: URL, redirect: URL, wrongState: Bool) throws -> URL {
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard fields["code_challenge_method"] == "S256", fields["redirect_uri"] == registeredRedirect,
              fields["client_id"] == "test-client", fields["state"]?.count == 43,
              fields["resource"] == (fault == "legacy" ? nil : "https://mcp.example.invalid/mcp") else { throw FixtureError.request }
        challenge = fields["code_challenge"]
        var result = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        result.queryItems = [.init(name: "code", value: "test-code"), .init(name: "state", value: wrongState ? "wrong" : fields["state"])]
        return result.url!
    }

    func send(_ request: URLRequest, id: JSONValue?) async throws -> GatewayHTTPResponse {
        let path = request.url!.path
        let issuer = fault == "legacy" ? "https://mcp.example.invalid" : "https://auth.example.invalid/tenant"
        switch path {
        case "/.well-known/oauth-protected-resource/mcp":
            if fault == "legacy" { return reply(404) }
            let resource = fault == "resource" ? "https://other.example.invalid/mcp" : "https://mcp.example.invalid/mcp"
            return reply(200, .object(["resource": .string(resource), "authorization_servers": .array([.string(issuer)])]))
        case "/.well-known/oauth-authorization-server/tenant", "/.well-known/oauth-authorization-server":
            return reply(200, .object(["issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/authorize"),
                "registration_endpoint": .string(issuer + "/register"), "token_endpoint": .string(issuer + "/token"),
                "code_challenge_methods_supported": .array([.string("S256")]),
                "token_endpoint_auth_methods_supported": .array([.string("none")])]))
        case "/tenant/register", "/register":
            if fault == "dcr" { return reply(400) }
            let data = JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            guard data?["token_endpoint_auth_method"] == .string("none"),
                  let redirect = data?["redirect_uris"]?.arrayValue?.first?.stringValue else { throw FixtureError.request }
            registeredRedirect = redirect
            registrations += 1
            return reply(201, .object(["client_id": .string("test-client")]))
        case "/tenant/token", "/token":
            var form = URLComponents()
            form.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let fields = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard fields["client_id"] == "test-client",
                  fields["resource"] == (fault == "legacy" ? nil : "https://mcp.example.invalid/mcp") else { throw FixtureError.request }
            if fields["grant_type"] == "authorization_code" {
                guard let verifier = fields["code_verifier"], verifier.count == 43, fields["code"] == "test-code",
                      fields["redirect_uri"] == registeredRedirect else { throw FixtureError.request }
                let expected = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                if fault == "verifier" || expected != challenge { return reply(400, .object(["error": .string("invalid_grant")])) }
                return tokens(0)
            }
            guard fields["refresh_token"] == "test-refresh-\(refreshes)" else { throw FixtureError.request }
            refreshes += 1
            try await Task.sleep(for: .milliseconds(20))
            if fault == "refresh", refreshes > 1 { return reply(400, .object(["error": .string("invalid_grant")])) }
            return tokens(refreshes)
        case "/mcp":
            guard let bearer = request.value(forHTTPHeaderField: "Authorization") else {
                return fault == "legacy" ? reply(401) : reply(401, headers: [
                    "www-authenticate": #"Bearer resource_metadata="https://mcp.example.invalid/.well-known/oauth-protected-resource/mcp""#])
            }
            guard bearer == "Bearer test-access-\(refreshes)" else { throw FixtureError.request }
            let body = JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            let method = body?["method"]?.stringValue
            if method == "initialize" {
                initialized += 1
                return rpc(id, ["protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])])],
                    headers: ["mcp-session-id": "test-session"])
            }
            guard request.value(forHTTPHeaderField: "Mcp-Session-Id") == "test-session",
                  request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18" else { throw FixtureError.request }
            switch method {
            case "notifications/initialized": return reply(202)
            case "tools/list":
                let names = includesWriteTool ? ["list_issues", "update_issue"] : ["list_issues"]
                return rpc(id, ["tools": .array(names.map { .object(["name": .string($0),
                    "inputSchema": .object(["type": .string("object")]),
                    "annotations": .object(["readOnlyHint": .bool(true)])]) })])
            case "tools/call":
                calls += 1
                if fault == "unauthorized", calls == 1 { return reply(401) }
                return rpc(id, ["content": .array([.object(["type": .string("text"), "text": .string("Synthetic issue")])])])
            default: throw FixtureError.request
            }
        default: return reply(404)
        }
    }

    private func tokens(_ index: Int) -> GatewayHTTPResponse {
        reply(200, .object(["token_type": .string("Bearer"), "access_token": .string("test-access-\(index)"),
            "refresh_token": .string("test-refresh-\(index)"), "expires_in": .number(index < 2 ? 1 : 3600)]))
    }

    private func rpc(_ id: JSONValue?, _ result: [String: JSONValue], headers: [String: String] = [:]) -> GatewayHTTPResponse {
        reply(200, .object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": .object(result)]), headers: headers)
    }

    private func reply(_ status: Int, _ body: JSONValue = .null, headers: [String: String] = [:]) -> GatewayHTTPResponse {
        .init(status: status, headers: headers, body: Data(body.jsonString.utf8))
    }

    private enum FixtureError: Error { case request }
}
