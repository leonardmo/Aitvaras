import Foundation
import AitvarasCore
import AitvarasAgents
import AitvarasStore

public struct GatewayOAuthSecrets: Sendable {
    let load: @Sendable (String) throws -> String?
    let save: @Sendable (String, String) throws -> Void
    let delete: @Sendable (String) throws -> Void

    public init(load: @escaping @Sendable (String) throws -> String?,
                save: @escaping @Sendable (String, String) throws -> Void,
                delete: @escaping @Sendable (String) throws -> Void) {
        self.load = load; self.save = save; self.delete = delete
    }
}

public actor GatewayUpstreamSessions {
    public struct SignIn: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let server: String
        public let authKind: GatewayUpstreamAuthKind
        public let tokenRejected: Bool
    }

    private struct Observer { weak var session: MCPGateway? }
    private var observers: [Observer] = []
    private var sessions: [UUID: GatewayRemoteSession] = [:]
    private var requested: [UUID: SignIn] = [:]
    private var authorizing: Set<UUID> = []
    private let secrets: GatewayOAuthSecrets
    private let send: GatewayHTTP
    private let needsAttention: @Sendable () async -> Void

    public init(secrets: GatewayOAuthSecrets, needsAttention: @escaping @Sendable () async -> Void) {
        self.init(secrets: secrets, send: GatewayHTTPClient.make(), needsAttention: needsAttention)
    }

    init(secrets: GatewayOAuthSecrets, send: @escaping GatewayHTTP, needsAttention: @escaping @Sendable () async -> Void = {}) {
        self.secrets = secrets; self.send = send; self.needsAttention = needsAttention
    }

    public func observe(_ session: MCPGateway) {
        observers.removeAll { $0.session == nil }
        observers.append(.init(session: session))
    }

    public func signInRequests() -> [SignIn] {
        requested.values.sorted { ($0.server, $0.id.uuidString) < ($1.server, $1.id.uuidString) }
    }

    private func noteSignIn(_ route: GatewayUpstream, error: MCPGatewayCallError) async {
        guard error == .needsSignIn || error == .needsToken || error == .tokenRejected else { return }
        let request = SignIn(id: route.account.id, server: route.account.serverName,
                             authKind: route.account.authKind, tokenRejected: error == .tokenRejected)
        guard requested.updateValue(request, forKey: request.id) != request else { return }
        await needsAttention()
    }

    private func session(_ route: GatewayUpstream) throws -> GatewayRemoteSession {
        if let current = sessions[route.account.id] { return current }
        let endpoint: URL
        if route.account.authKind == .staticHeader {
            try route.definition.validate()
            guard let url = route.definition.url.flatMap(URL.init(string:)) else { throw GatewayOAuthError.invalidMetadata }
            endpoint = url
        } else {
            endpoint = try GatewayOAuth.validated(route.definition.url.flatMap(URL.init(string:)))
        }
        let session = GatewayRemoteSession(route: route, oauth: .init(send: send, endpoint: endpoint), secrets: secrets)
        sessions[route.account.id] = session
        return session
    }

    public func catalog(_ route: GatewayUpstream) async throws -> [MCPGatewayTool] {
        let remote = try session(route)
        let catalog = try await remote.catalog(trusted: route.account.trusted)
        if await remote.tokenRejected { await noteSignIn(route, error: .tokenRejected) }
        return catalog
    }

    public func signedIn(_ route: GatewayUpstream) async throws -> Bool {
        try await session(route).signedIn()
    }

    public func signOut(_ route: GatewayUpstream) async throws {
        guard route.account.authKind == .oauth else { throw GatewayUpstreamError.invalidAccount }
        try await clearCredentials(route)
    }

    public func removeStaticToken(stores: Stores, id: UUID) async throws {
        let route = try stores.gatewayUpstream(id: id)
        guard route.account.authKind == .staticHeader else { throw GatewayUpstreamError.invalidAccount }
        try stores.recordGatewayAdministration("Remove upstream token", projectID: route.account.definitionProjectID)
        try await clearCredentials(route)
    }

    private func clearCredentials(_ route: GatewayUpstream) async throws {
        let id = route.account.id
        guard authorizing.insert(id).inserted else { throw GatewayOAuthError.busy }
        defer { authorizing.remove(id) }
        try await session(route).signOut()
        requested.removeValue(forKey: id)
        await credentialsChanged()
    }

    public func addStaticUpstream(stores: Stores, serverName: String, label: String, endpoint: String,
                                  projectID: UUID?, headerName: String?, token: String) async throws -> GatewayUpstreamAccount {
        try GatewayRemoteSession.validateToken(token)
        let id = UUID()
        let key = GatewayRemoteSession.staticKey(id)
        try secrets.save(key, token)
        let account: GatewayUpstreamAccount
        do {
            account = try stores.addGatewayUpstream(serverName: serverName, label: label, endpoint: endpoint,
                projectID: projectID, id: id, authKind: .staticHeader, headerName: headerName)
        } catch {
            try secrets.delete(key)
            throw error
        }
        await routingChanged()
        return account
    }

    public func replaceStaticToken(stores: Stores, id: UUID, token: String) async throws {
        try GatewayRemoteSession.validateToken(token)
        let route = try stores.gatewayUpstream(id: id)
        guard route.account.authKind == .staticHeader else { throw GatewayUpstreamError.invalidAccount }
        guard authorizing.insert(id).inserted else { throw GatewayOAuthError.busy }
        defer { authorizing.remove(id) }
        let remote = try session(route)
        try stores.recordGatewayAdministration("Replace upstream token", projectID: route.account.definitionProjectID)
        try await remote.replaceStaticToken(token)
        requested.removeValue(forKey: id)
        await credentialsChanged()
    }

    private func credentialsChanged() async {
        await needsAttention()
        await routingChanged()
    }

    public func routingChanged() async {
        for connection in observers.compactMap(\.session) { await connection.catalogChanged() }
    }

    public func requireSignInIfNeeded(_ route: GatewayUpstream) async throws {
        do { _ = try await session(route).access() }
        catch let error as MCPGatewayCallError {
            await noteSignIn(route, error: error)
            throw error
        }
    }

    public func call(_ route: GatewayUpstream, tool: MCPGatewayTool, arguments: JSONValue,
                     revalidate: MCPGateway.Authorize = {}) async throws -> MCPGatewayToolResult {
        do { return try await session(route).call(tool, trusted: route.account.trusted, arguments: arguments, revalidate: revalidate) }
        catch let error as MCPGatewayCallError {
            await noteSignIn(route, error: error)
            throw error
        }
    }

    /// The app supplies the browser and loopback receiver. MCP callers cannot
    /// open a browser or give the gateway a callback.
    public func signIn(_ id: UUID, currentRoute: @Sendable () throws -> GatewayUpstream,
                       openBrowser: @Sendable (URL) async throws -> Void) async throws {
        guard try currentRoute().account.authKind == .oauth else { throw GatewayUpstreamError.invalidAccount }
        let callback = try await GatewayOAuthCallback.start()
        defer { callback.stop() }
        try await signIn(id, currentRoute: currentRoute, redirect: callback.redirect, receive: { url in
            try await openBrowser(url)
            return try await callback.receive()
        })
    }

    func signIn(_ id: UUID, currentRoute: @Sendable () throws -> GatewayUpstream, redirect: URL,
                receive: @Sendable (URL) async throws -> URL) async throws {
        let route = try currentRoute()
        guard route.account.authKind == .oauth else { throw GatewayUpstreamError.invalidAccount }
        guard route.account.id == id else { throw MCPGatewayCallError.stale }
        guard authorizing.insert(id).inserted else { throw GatewayOAuthError.busy }
        defer { authorizing.remove(id) }
        let remote = try session(route)
        try await remote.signIn(redirect: redirect, receive: receive, validate: {
            guard try currentRoute() == route else { throw MCPGatewayCallError.stale }
        })
        try await remote.discoverTools()
        requested.removeValue(forKey: id)
        await routingChanged()
        await needsAttention()
    }
}

actor GatewayRemoteSession {
    static let versions = ["2025-06-18", "2025-03-26", "2025-11-25"]
    static let initialize = JSONValue.object(["protocolVersion": .string(versions[0]), "capabilities": .object([:]),
        "clientInfo": .object(["name": .string("Aitvaras"), "version": .string("1")])])

    private struct Remote: Sendable, Equatable {
        let id: String?
        let version: String
    }

    private let route: GatewayUpstream
    private let oauth: GatewayOAuth
    private let secrets: GatewayOAuthSecrets
    private let key: String
    private var credentials: GatewayOAuth.Credentials?
    private var staticToken: String?
    private(set) var tokenRejected = false
    private var credentialGeneration = UUID()
    private var loaded = false
    private var signingIn = false
    private var attemptedUnauthorizedRefresh = false
    private var refresh: Task<GatewayOAuth.Credentials, Error>?
    private var connecting: Task<(Remote, [MCPGatewayTool]), Error>?
    private var remote: Remote?
    private var tools: [MCPGatewayTool] = []

    init(route: GatewayUpstream, oauth: GatewayOAuth, secrets: GatewayOAuthSecrets) {
        self.route = route; self.oauth = oauth; self.secrets = secrets
        key = route.account.authKind == .staticHeader ? Self.staticKey(route.account.id)
            : "gateway.oauth.\(route.account.id.uuidString).\(route.account.definitionFingerprint)"
    }

    static func staticKey(_ id: UUID) -> String { "gateway.static.\(id.uuidString)" }

    static func validateToken(_ token: String) throws {
        guard GatewayOAuth.credential(.string(token)) != nil else { throw GatewayUpstreamError.invalidToken }
    }

    private func loadCredentials() throws {
        if !loaded {
            if let saved = try secrets.load(key) {
                if route.account.authKind == .staticHeader {
                    try Self.validateToken(saved)
                    staticToken = saved
                } else {
                    credentials = try JSONDecoder().decode(GatewayOAuth.Credentials.self, from: Data(saved.utf8))
                }
            }
            loaded = true
        }
    }

    func signedIn() throws -> Bool {
        try loadCredentials()
        if route.account.authKind == .staticHeader { return staticToken != nil && !tokenRejected }
        return credentials.map { $0.expires > .now || $0.refresh != nil } ?? false
    }

    func signOut() throws {
        try secrets.delete(key)
        if route.account.authKind == .staticHeader {
            changeStaticToken(nil)
            return
        }
        refresh?.cancel()
        connecting?.cancel()
        credentials = nil
        loaded = true
        remote = nil
    }

    func replaceStaticToken(_ token: String) throws {
        try secrets.save(key, token)
        changeStaticToken(token)
    }

    private func changeStaticToken(_ token: String?) {
        staticToken = token
        loaded = true
        tokenRejected = false
        credentialGeneration = UUID()
        connecting?.cancel()
        connecting = nil
        remote = nil
    }

    func access() async throws -> String {
        try loadCredentials()
        if route.account.authKind == .staticHeader {
            if tokenRejected { throw MCPGatewayCallError.tokenRejected }
            guard let staticToken else { throw MCPGatewayCallError.needsToken }
            return staticToken
        }
        if let refresh { return try await refresh.value.access }
        guard let credentials else { throw MCPGatewayCallError.needsSignIn }
        if credentials.expires.timeIntervalSinceNow > 30 { return credentials.access }
        guard !signingIn, let token = credentials.refresh else { throw MCPGatewayCallError.needsSignIn }
        let job = Task {
            do {
                let updated = try await oauth.exchange(credentials.discovery, client: credentials.client,
                    fields: ["grant_type": "refresh_token", "refresh_token": token], previousRefresh: token)
                try Task.checkCancellation()
                try save(updated)
                return updated
            } catch {
                // A lost response could already have rotated the refresh token.
                // Require a new login instead of replaying the old token.
                if !Task.isCancelled { clearCredentials() }
                throw MCPGatewayCallError.needsSignIn
            }
        }
        refresh = job
        defer { refresh = nil }
        return try await job.value.access
    }

    func signIn(redirect: URL, receive: @Sendable (URL) async throws -> URL,
                validate: @Sendable () throws -> Void) async throws {
        guard !signingIn, refresh == nil else { throw GatewayOAuthError.busy }
        signingIn = true
        defer { signingIn = false }
        let discovery = try await oauth.discover()
        let client = try await oauth.register(discovery, redirect: redirect)
        let state = try GatewayOAuth.random(), verifier = try GatewayOAuth.random()
        let url = try oauth.browserURL(discovery, client: client, redirect: redirect, state: state, verifier: verifier)
        let callback = try await receive(url)
        let code = try GatewayOAuth.code(callback, redirect: redirect, state: state, issuer: discovery.issuer)
        let issued = try await oauth.exchange(discovery, client: client, fields: ["grant_type": "authorization_code",
            "code": code, "code_verifier": verifier, "redirect_uri": redirect.absoluteString])
        try Task.checkCancellation()
        try validate()
        try save(issued)
        attemptedUnauthorizedRefresh = false
        remote = nil
    }

    private func save(_ value: GatewayOAuth.Credentials) throws {
        let encoded = try JSONEncoder().encode(value)
        try secrets.save(key, String(decoding: encoded, as: UTF8.self))
        credentials = value; loaded = true
    }

    private func clearCredentials() {
        credentials = nil
        loaded = true
        remote = nil
        try? secrets.delete(key)
    }

    func catalog(trusted: Bool) async throws -> [MCPGatewayTool] {
        if remote == nil {
            do { _ = try await connect() }
            catch { try Task.checkCancellation() }
        }
        if !tools.isEmpty || remote != nil { return try catalogTools(trusted: trusted) }
        // A first launch has no schemas yet. The placeholder points to
        // credential setup and is replaced by discovery before dispatch.
        let isStatic = route.account.authKind == .staticHeader
        return [try MCPGatewayTool(origin: origin, definition: .init(name: isStatic ? "set_token" : "sign_in",
            description: isStatic ? "Manage this upstream token in Settings → Connections." : "Sign in to use this upstream.",
            parametersJSON: "{\"type\":\"object\"}", risk: .confirmable))]
    }

    func discoverTools() async throws {
        _ = try await connect()
    }

    private var origin: MCPGatewayTool.Origin {
        .upstream(server: route.account.serverName, accountID: route.account.id,
                  definitionFingerprint: route.account.definitionFingerprint)
    }

    private func connect() async throws -> Remote {
        if let remote { return remote }
        if let connecting { return try await connecting.value.0 }
        let generation = credentialGeneration
        let job = Task { () throws -> (Remote, [MCPGatewayTool]) in
            let token = try await access()
            try checkGeneration(generation)
            let id = JSONValue.string(UUID().uuidString)
            let response = try await oauth.send(GatewayOAuth.rpc(oauth.endpoint, method: "initialize", id: id,
                params: Self.initialize, authorization: token, headerName: route.account.headerName), id)
            try checkGeneration(generation)
            let result = try await check(response, id: id, token: token)
            guard let version = result?["protocolVersion"]?.stringValue, Self.versions.contains(version),
                  case .object? = result?["capabilities"]?["tools"] else { throw GatewayOAuthError.invalidResponse }
            let sessionID = GatewayOAuth.credential(response["mcp-session-id"].map(JSONValue.string), maximum: 1024)
            guard response["mcp-session-id"] == nil || sessionID != nil else { throw GatewayOAuthError.invalidResponse }
            let connection = Remote(id: sessionID, version: version)
            _ = try await request("notifications/initialized", id: nil, params: nil, token: token, remote: connection,
                                  generation: generation)
            var cursor: String?, seen: Set<String> = [], discovered: [MCPGatewayTool] = []
            for _ in 0..<16 {
                let params = cursor.map { JSONValue.object(["cursor": .string($0)]) }
                let page = try await request("tools/list", id: .string(UUID().uuidString), params: params, token: token,
                                             remote: connection, generation: generation)
                guard let entries = page?["tools"]?.arrayValue, entries.count + discovered.count <= 256 else {
                    throw GatewayOAuthError.invalidResponse
                }
                discovered += try entries.map(tool)
                guard let next = page?["nextCursor"]?.stringValue else {
                    guard Set(discovered.map(\.name)).count == discovered.count else { throw GatewayOAuthError.invalidResponse }
                    try Task.checkCancellation()
                    try checkGeneration(generation)
                    tools = discovered
                    remote = connection
                    return (connection, discovered)
                }
                guard next.utf8.count <= 1024, seen.insert(next).inserted else { throw GatewayOAuthError.invalidResponse }
                cursor = next
            }
            throw GatewayOAuthError.invalidResponse
        }
        connecting = job
        defer { if credentialGeneration == generation { connecting = nil } }
        return try await job.value.0
    }

    private func tool(_ entry: JSONValue) throws -> MCPGatewayTool {
        guard let name = entry["name"]?.stringValue, let schema = entry["inputSchema"] else {
            throw GatewayOAuthError.invalidResponse
        }
        let hints = entry["annotations"]
        return try .init(origin: origin, definition: .init(name: name, description: entry["description"]?.stringValue ?? "",
            parametersJSON: schema.jsonString, risk: .confirmable), annotations: .init(readOnly: hints?["readOnlyHint"]?.boolValue,
            destructive: hints?["destructiveHint"]?.boolValue,
            idempotent: route.account.authKind == .oauth ? hints?["idempotentHint"]?.boolValue : nil),
            trusted: false)
    }

    private func catalogTools(trusted: Bool) throws -> [MCPGatewayTool] {
        guard trusted else { return tools }
        return try tools.map { try MCPGatewayTool(origin: $0.origin, definition: $0.definition,
                                                   annotations: $0.annotations, trusted: true) }
    }

    func call(_ tool: MCPGatewayTool, trusted: Bool, arguments: JSONValue, revalidate: MCPGateway.Authorize) async throws -> MCPGatewayToolResult {
        let generation = credentialGeneration
        let session = try await connect()
        _ = try await access()
        try await revalidate()
        try checkGeneration(generation)
        guard let token = staticToken ?? credentials?.access else { throw MCPGatewayCallError.needsSignIn }
        guard try catalogTools(trusted: trusted).contains(tool) else { throw MCPGatewayCallError.stale }
        guard remote == session else { throw MCPGatewayCallError.stale }
        try Task.checkCancellation()
        let result = try await request("tools/call", id: .string(UUID().uuidString), params: .object([
            "name": .string(tool.definition.name), "arguments": arguments]), token: token, remote: session,
            generation: generation)
        guard let content = result?["content"]?.arrayValue else { throw MCPGatewayCallError.invalidResult }
        let structured: [String: JSONValue]?
        if case .object(let fields)? = result?["structuredContent"] { structured = fields }
        else { structured = nil }
        return .init(content: content, structuredContent: structured,
                     isError: result?["isError"]?.boolValue ?? false)
    }

    private func checkGeneration(_ generation: UUID) throws {
        guard generation == credentialGeneration else { throw MCPGatewayCallError.stale }
        if tokenRejected { throw MCPGatewayCallError.tokenRejected }
    }

    private func request(_ method: String, id: JSONValue?, params: JSONValue?, token: String, remote: Remote,
                         generation: UUID) async throws -> JSONValue? {
        try checkGeneration(generation)
        let response = try await oauth.send(GatewayOAuth.rpc(oauth.endpoint, method: method, id: id, params: params,
            authorization: token, headerName: route.account.headerName, sessionID: remote.id, version: remote.version), id)
        // A credential change after dispatch cannot establish whether a write ran.
        guard generation == credentialGeneration else { throw MCPGatewayCallError.invalidResult }
        if response.status == 404, self.remote == remote { self.remote = nil }
        return try await check(response, id: id, token: token)
    }

    private func check(_ response: GatewayHTTPResponse, id: JSONValue?, token: String) async throws -> JSONValue? {
        if route.account.authKind == .staticHeader {
            if [401, 403].contains(response.status) {
                tokenRejected = true
                remote = nil
                throw MCPGatewayCallError.tokenRejected
            }
        } else if response.status == 401 {
            guard let current = credentials else { throw MCPGatewayCallError.needsSignIn }
            guard current.access == token, refresh == nil else { throw MCPGatewayCallError.unavailable }
            if !signingIn, !attemptedUnauthorizedRefresh, current.refresh != nil {
                attemptedUnauthorizedRefresh = true
                credentials = .init(discovery: current.discovery, client: current.client, access: token,
                                    refresh: current.refresh, expires: .distantPast)
                _ = try await access()
                // Never replay a dispatched tool request.
                throw MCPGatewayCallError.unavailable
            }
            clearCredentials()
            throw MCPGatewayCallError.needsSignIn
        }
        guard (200..<300).contains(response.status) else { throw GatewayOAuthError.invalidResponse }
        if credentials?.access == token { attemptedUnauthorizedRefresh = false }
        guard let id else { return nil }
        guard let message = response.json, message["jsonrpc"] == .string("2.0"), message["id"] == id,
              let result = message["result"], case .object = result else { throw GatewayOAuthError.invalidResponse }
        if route.account.authKind == .staticHeader, Self.reflectsCredential(result, token: token) {
            throw MCPGatewayCallError.invalidResult
        }
        return result
    }

    /// Prevent a reflected authorization header from reaching catalogs, tool
    /// results, or the tool names saved by the activity log.
    private static func reflectsCredential(_ value: JSONValue, token: String) -> Bool {
        func matches(_ text: String) -> Bool { text == token || text.contains("Bearer " + token) }
        switch value {
        case .string(let text): return matches(text)
        case .array(let values): return values.contains { reflectsCredential($0, token: token) }
        case .object(let fields):
            return fields.contains { matches($0.key) || reflectsCredential($0.value, token: token) }
        default: return false
        }
    }
}
