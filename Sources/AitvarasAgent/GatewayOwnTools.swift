import Foundation
import AitvarasCore
import AitvarasAgents
import AitvarasStore
import AitvarasConnectors
import AitvarasRAG

/// Constructs the two catalog sources and sends every valid call through the
/// same ConnectorHub policy path. Upstream OAuth/session transport is injected.
public struct GatewayToolService: Sendable {
    public typealias UpstreamCatalog = @Sendable (GatewayUpstream) async throws -> [MCPGatewayTool]
    public typealias UpstreamCall = @Sendable (GatewayUpstream, MCPGatewayTool, JSONValue) async throws -> MCPGatewayToolResult
    public typealias Rules = @Sendable (MCPGatewayInvocation, MCPGatewayTool) async throws -> GatewayPolicyRules

    private let stores: Stores
    private let hub: ConnectorHub
    private let approvals: GatewayApprovalBroker
    private let knowledgeEmbedder: (any EmbeddingEngine)?
    private let upstreamCatalog: UpstreamCatalog
    private let upstreamCall: UpstreamCall
    private let upstreams: GatewayUpstreamSessions?
    private let rules: Rules

    public init(stores: Stores, hub: ConnectorHub, approvals: GatewayApprovalBroker,
                knowledgeEmbedder: (any EmbeddingEngine)? = nil,
                upstreamCatalog: @escaping UpstreamCatalog = { _ in [] },
                upstreamCall: @escaping UpstreamCall = { _, _, _ in throw MCPGatewayCallError.unavailable },
                rules: @escaping Rules = { _, _ in .init() }, upstreams: GatewayUpstreamSessions? = nil) {
        self.stores = stores
        self.hub = hub
        self.approvals = approvals
        self.knowledgeEmbedder = knowledgeEmbedder
        self.upstreamCatalog = upstreamCatalog
        self.upstreamCall = upstreamCall
        self.upstreams = upstreams
        self.rules = rules
    }

    public func connect(invocation: MCPGatewayInvocation, authorize: @escaping MCPGateway.Authorize) -> MCPGateway {
        let session = MCPGateway(invocation: invocation, authorize: authorize, catalog: { try await catalog(for: $0.context) },
            dispatch: { invocation, tool, arguments, revalidate in
                try await execute(invocation, tool: tool, arguments: arguments, revalidate: revalidate)
            })
        if let upstreams { Task { await upstreams.observe(session) } }
        return session
    }

    private func catalog(for launch: GatewayLaunchContext) async throws -> [MCPGatewayTool] {
        let own = try await ownTools(for: launch)
        var tools = try own.map { try MCPGatewayTool(origin: .aitvaras($0.scope), definition: $0.definition) }
        for route in try stores.gatewayUpstreams(for: launch) {
            let upstream: [MCPGatewayTool]
            if let upstreams { upstream = try await upstreams.catalog(route) }
            else { upstream = try await upstreamCatalog(route) }
            guard upstream.count <= 256 - tools.count, upstream.allSatisfy({ $0.origin == Self.origin(for: route) }) else {
                throw MCPGatewayCallError.unavailable
            }
            tools += upstream
        }
        return tools
    }

    private func ownTools(for launch: GatewayLaunchContext) async throws -> [GatewayScopedTool] {
        guard let projectID = launch.projectID else { return [] }
        let connectors = await hub.connectors
        var tools = GatewayOwnTools.projectTools
        for (scope, names) in GatewayOwnTools.profileTools {
            guard let connector = connectors[scope.rawValue] as? any GatewayProfileConnector else { continue }
            tools += await connector.tools.filter { names.contains($0.name) }
                .map { .init(definition: $0, scope: scope, access: .profile) }
        }
        let allowed = try stores.gatewayToolScopeGate().listedTools(tools, for: launch)
        if allowed.contains(where: { $0.scope == .knowledge }),
           try stores.gatewayKnowledgeSources(projectID: projectID).isEmpty {
            return allowed.filter { $0.scope != .knowledge }
        }
        return allowed
    }

    private func execute(_ invocation: MCPGatewayInvocation, tool: MCPGatewayTool, arguments: JSONValue,
                         revalidate: MCPGateway.Authorize) async throws -> MCPGatewayToolResult {
        switch tool.origin {
        case .upstream:
            let resolve: @Sendable () throws -> GatewayUpstream = {
                let current = try stores.gatewayUpstreams(for: invocation.context)
                guard let route = current.first(where: { Self.origin(for: $0) == tool.origin }) else {
                    throw MCPGatewayCallError.stale
                }
                return route
            }
            return try await hub.executeGateway(invocation, tool: tool, arguments: arguments, approvals: approvals,
                rules: { try await rules(invocation, tool) }, revalidate: {
                    try await revalidate()
                    if let upstreams { try await upstreams.requireSignInIfNeeded(resolve()) }
                }) {
                    let route = try resolve()
                    if let upstreams {
                        return try await upstreams.call(route, tool: tool, arguments: arguments) {
                            try await revalidate()
                            _ = try resolve()
                        }
                    }
                    return try await upstreamCall(route, tool, arguments)
                }
        case .aitvaras(let scope):
            guard let local = try await ownTools(for: invocation.context).first(where: { $0.scope == scope && $0.definition == tool.definition }),
                  let projectID = invocation.context.projectID else { throw MCPGatewayCallError.denied }
            let gate = stores.gatewayToolScopeGate()
            let owner: @Sendable (GatewayToolScope, String) throws -> UUID? = { scope, id in
                try stores.gatewayRecordOwner(projectID: projectID, scope: scope, resourceID: id)
            }
            return try await hub.executeGateway(invocation, tool: tool, arguments: arguments, approvals: approvals,
                rules: { try await rules(invocation, tool) }, revalidate: {
                    try await revalidate()
                    try await gate.execute(local, for: invocation.context, arguments: arguments, recordOwner: owner) { _, _ in () }
                    try GatewayOwnTools.validate(local, arguments: arguments)
                }) {
                    try await gate.execute(local, for: invocation.context, arguments: arguments, recordOwner: owner) { access, args in
                        try await GatewayOwnTools(stores: stores, hub: hub, knowledgeEmbedder: knowledgeEmbedder).perform(local, access: access, arguments: args)
                    }
                }
        }
    }

    private static func origin(for route: GatewayUpstream) -> MCPGatewayTool.Origin {
        .upstream(server: route.account.serverName, accountID: route.account.id,
                  definitionFingerprint: route.account.definitionFingerprint)
    }
}

private struct GatewayOwnTools: Sendable {
    let stores: Stores
    let hub: ConnectorHub

    let knowledgeEmbedder: (any EmbeddingEngine)?

    static let profileTools: [GatewayToolScope: Set<String>] = [
        .memory: ["search", "about", "remember", "revise"],
        .goals: ["list_today"],
        .mail: ["recent_messages", "search_messages", "get_message"],
        .calendar: ["list_events", "create_event", "update_event", "delete_event"],
        .reminders: ["list_reminders", "create_reminder", "complete_reminder"]
    ]

    static let projectTools: [GatewayScopedTool] = [
        tool(.knowledge, "search", "Search the Knowledge sources linked to this project.",
             fields: ["query": "string", "limit": "integer"], required: ["query"]),
        tool(.activity, "recent", "List this project's recent gateway activity."),
        tool(.activity, "get", "Read a gateway activity entry from this project.",
             fields: ["id": "string"], required: ["id"], record: "id")
    ]

    private static func tool(_ scope: GatewayToolScope, _ name: String, _ description: String,
                             risk: ActionRisk = .read, fields: [String: String] = [:], required: [String] = [],
                             record: String? = nil) -> GatewayScopedTool {
        let schema: JSONValue = .object(["type": .string("object"),
            "properties": .object(fields.mapValues { .object(["type": .string($0)]) }),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
        return .init(definition: .init(name: name, description: description, parametersJSON: schema.jsonString, risk: risk),
                     scope: scope, access: record.map { .records(idArguments: [$0]) } ?? .projectQuery)
    }

    func perform(_ tool: GatewayScopedTool, access: GatewayToolAccess, arguments: JSONValue) async throws -> MCPGatewayToolResult {
        // Exact own-tool schema rejects extra project selectors and connector
        // options before reaching a platform API.
        try Self.validate(tool, arguments: arguments)
        let projectID = access.projectID
        let name = tool.definition.name
        func string(_ key: String, max: Int) throws -> String {
            guard let value = arguments[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= max, !value.contains("\0") else { throw MCPGatewayCallError.invalidArguments }
            return value
        }
        func id(_ key: String) throws -> UUID {
            guard let id = UUID(uuidString: try string(key, max: 36)) else { throw MCPGatewayCallError.invalidArguments }
            return id
        }
        if case .profile = tool.access {
            guard let connector = try await hub.gatewayConnector(access.scope.rawValue) as? any GatewayProfileConnector else {
                throw MCPGatewayCallError.unavailable
            }
            guard await connector.tools.contains(tool.definition) else { throw MCPGatewayCallError.stale }
            let output = try await connector.executeGatewayTool(toolName: name, argumentsJSON: arguments.jsonString,
                                                                projectID: projectID) {
                guard try stores.gatewayToolScopeSettings(projectID: projectID).scopes.contains(access.scope) else {
                    throw GatewayToolScopeError.notGranted
                }
            }
            return .init(text: Self.bounded(output))
        }
        switch (access.scope, name) {
        case (.knowledge, "search"):
            let sources = try stores.gatewayKnowledgeSources(projectID: projectID)
            guard !sources.isEmpty else { throw MCPGatewayCallError.unavailable }
            let indexSources = sources.map { IndexSource(id: $0.id, name: $0.name, url: URL(fileURLWithPath: $0.path, isDirectory: true)) }
            let retriever = HybridRetriever(stores: stores, embedder: knowledgeEmbedder, sources: indexSources, enforceSourceScope: true)
            let limit = min(max(Int(arguments["limit"]?.doubleValue ?? 10), 1), 20)
            let chunks = try await retriever.retrieve(query: string("query", max: 1_000), limit: limit)
            guard try stores.gatewayKnowledgeSources(projectID: projectID) == sources else { throw MCPGatewayCallError.stale }
            return rows(chunks.map { ["source": .string(Self.bounded($0.origin, bytes: 500)),
                                       "text": .string(Self.bounded($0.text, bytes: 1_200))] })
        case (.activity, "recent"), (.activity, "get"):
            let events = try stores.gatewayActivity(projectID: projectID, id: name == "get" ? id("id") : nil)
            return rows(events.map { event in
                ["id": .string(event.id.uuidString), "summary": .string(event.summary),
                 "tool": event.detailJSON.flatMap(JSONValue.parse)?["tool"] ?? .null]
            })
        default:
            throw MCPGatewayCallError.unavailable
        }
    }

    static func validate(_ tool: GatewayScopedTool, arguments: JSONValue) throws {
        guard case .object(let fields) = arguments, let schema = JSONValue.parse(tool.definition.parametersJSON),
              case .object(let properties)? = schema["properties"]
        else { throw MCPGatewayCallError.invalidArguments }
        for key in schema["required"]?.arrayValue ?? [] {
            guard let key = key.stringValue, fields[key] != nil else { throw MCPGatewayCallError.invalidArguments }
        }
        for (key, value) in fields {
            switch properties[key]?["type"]?.stringValue {
            case "string":
                guard let text = value.stringValue, text.utf8.count <= 8_000, !text.contains("\0") else {
                    throw MCPGatewayCallError.invalidArguments
                }
            case "boolean":
                guard value.boolValue != nil else { throw MCPGatewayCallError.invalidArguments }
            case "integer":
                guard let n = value.doubleValue, abs(n) <= 1_000_000, n.rounded() == n else { throw MCPGatewayCallError.invalidArguments }
            default: throw MCPGatewayCallError.invalidArguments
            }
        }
    }

    private func rows(_ rows: [[String: JSONValue]]) -> MCPGatewayToolResult {
        .init(text: JSONValue.array(rows.map(JSONValue.object)).jsonString)
    }

    private static func bounded(_ text: String, bytes: Int = 16_000) -> String {
        String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }
}
