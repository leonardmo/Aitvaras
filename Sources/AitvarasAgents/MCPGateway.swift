import Foundation
import CryptoKit
import AitvarasCore

public struct MCPGatewayInvocation: Sendable, Equatable {
    public enum Presentation: Sendable, Equatable { case outside, inline(chatID: UUID) }
    public let launchID: UUID
    public let context: GatewayLaunchContext
    public let presentation: Presentation

    public init(launchID: UUID, context: GatewayLaunchContext, presentation: Presentation) {
        self.launchID = launchID
        self.context = context
        self.presentation = presentation
    }
}

public struct MCPGatewayTool: Sendable, Equatable {
    public enum Origin: Sendable, Equatable, Hashable {
        case aitvaras(GatewayToolScope)
        case upstream(server: String, accountID: UUID, definitionFingerprint: String)

        public var prefix: String {
            switch self {
            case .aitvaras(let scope): scope.rawValue
            case .upstream(let server, _, _): server
            }
        }
    }

    public struct Annotations: Sendable, Equatable {
        public var readOnly: Bool?
        public var destructive: Bool?
        public var idempotent: Bool?
        public init(readOnly: Bool? = nil, destructive: Bool? = nil, idempotent: Bool? = nil) {
            self.readOnly = readOnly
            self.destructive = destructive
            self.idempotent = idempotent
        }
    }

    public let origin: Origin
    public let definition: ToolDefinition
    public let annotations: Annotations
    /// The local upstream registry sets this. Remote tool metadata cannot set it.
    public let trusted: Bool
    public let inputSchema: JSONValue
    public let revision: String
    public var name: String { origin.prefix + "_" + definition.name }

    public init(origin: Origin, definition: ToolDefinition, annotations: Annotations = .init(), trusted: Bool = false) throws {
        let isASCIIName = { (text: String) in
            !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
        }
        guard isASCIIName(origin.prefix), isASCIIName(definition.name),
              origin.prefix.utf8.count + definition.name.utf8.count < 128,
              definition.description.utf8.count <= 2_048, definition.parametersJSON.utf8.count <= 8_192,
              let schema = JSONValue.parse(definition.parametersJSON), schema["type"]?.stringValue == "object"
        else { throw MCPGatewayCallError.invalidArguments }
        self.origin = origin
        self.definition = definition
        self.annotations = annotations
        self.trusted = trusted
        self.inputSchema = schema
        let upstream: [JSONValue]
        switch origin {
        case .aitvaras: upstream = []
        case .upstream(_, let account, let fingerprint):
            guard fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else { throw MCPGatewayCallError.invalidArguments }
            upstream = [.string(account.uuidString), .string(fingerprint)]
        }
        revision = Self.digest(.array([.string(origin.prefix), .string(definition.name), schema,
            .string(definition.description), .string(definition.risk.rawValue), .bool(trusted),
            annotations.readOnly.map(JSONValue.bool) ?? .null, annotations.destructive.map(JSONValue.bool) ?? .null,
            annotations.idempotent.map(JSONValue.bool) ?? .null, .array(upstream)]))
    }

    var listing: JSONValue {
        .object(["name": .string(name), "description": .string(definition.description), "inputSchema": inputSchema])
    }

    static func digest(_ value: JSONValue) -> String {
        SHA256.hash(data: Data(value.jsonString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct MCPGatewayToolResult: Sendable, Equatable {
    public let content: [JSONValue]
    public let structuredContent: [String: JSONValue]?
    public let isError: Bool

    public init(content: [JSONValue], structuredContent: [String: JSONValue]? = nil, isError: Bool = false) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    public init(text: String, isError: Bool = false) {
        self.init(content: [.object(["type": .string("text"), "text": .string(text)])], isError: isError)
    }

    public func validated() throws -> JSONValue {
        guard content.count <= 64, content.allSatisfy({ item in
            switch item["type"]?.stringValue {
            case "text": item["text"]?.stringValue != nil
            case "image", "audio": item["data"]?.stringValue != nil && item["mimeType"]?.stringValue != nil
            case "resource": item["resource"]?["uri"]?.stringValue != nil
            case "resource_link": item["uri"]?.stringValue != nil && item["name"]?.stringValue != nil
            default: false
            }
        }) else { throw MCPGatewayCallError.invalidResult }
        var result: [String: JSONValue] = ["content": .array(content), "isError": .bool(isError)]
        if let structuredContent { result["structuredContent"] = .object(structuredContent) }
        let value = JSONValue.object(result)
        guard let encoded = try? JSONEncoder().encode(value), encoded.count <= 192 * 1024 else {
            throw MCPGatewayCallError.invalidResult
        }
        return value
    }
}

public enum MCPGatewayCallError: Error, Sendable, Equatable {
    case invalidArguments, invalidResult, denied, timedOut, unavailable, stale, needsSignIn
    case failed, outcomeUnknown, auditUnavailable, completedWithoutAudit

    var message: String {
        switch self {
        case .invalidArguments: "Invalid tool arguments."
        case .invalidResult: "Unusable tool result. Do not retry automatically."
        case .denied: "Aitvaras denied the tool call."
        case .timedOut: "Approval expired. The tool was not run."
        case .unavailable: "This tool is unavailable."
        case .stale: "The tool or launch changed. List tools again."
        case .needsSignIn: "This upstream needs sign-in in Aitvaras."
        case .failed: "The tool failed."
        case .outcomeUnknown: "The write outcome is unknown. Do not retry automatically."
        case .auditUnavailable: "Aitvaras could not record the action. The tool was not run."
        case .completedWithoutAudit: "The tool completed, but Aitvaras could not save its audit. Do not retry."
        }
    }
}

/// One MCP session over any transport. The transport supplies verified launch
/// authorization, delivers notifications and calls close on disconnect.
public actor MCPGateway {
    public typealias Authorize = @Sendable () async throws -> Void
    public typealias Catalog = @Sendable (MCPGatewayInvocation) async throws -> [MCPGatewayTool]
    public typealias Dispatch = @Sendable (MCPGatewayInvocation, MCPGatewayTool, JSONValue, Authorize) async throws -> MCPGatewayToolResult

    private enum State { case initial, initialized, ready, closed }
    private enum RequestID: Hashable {
        case text(String), integer(Int64)

        init?(_ value: JSONValue?) {
            if let text = value?.stringValue, text.utf8.count <= 128 { self = .text(text) }
            else if let n = value?.doubleValue, abs(n) <= 9_007_199_254_740_991, let id = Int64(exactly: n) { self = .integer(id) }
            else { return nil }
        }
        var json: JSONValue {
            switch self { case .text(let text): .string(text); case .integer(let n): .number(Double(n)) }
        }
    }

    private static let versions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let invocation: MCPGatewayInvocation
    private let authorize: Authorize
    private let catalog: Catalog
    private let dispatch: Dispatch
    private var state = State.initial
    private var active: [RequestID: Task<JSONValue, Never>] = [:]
    private var lastCatalogRevision: String?
    public nonisolated let notifications: AsyncStream<Data>
    private let outgoing: AsyncStream<Data>.Continuation

    public init(invocation: MCPGatewayInvocation, authorize: @escaping Authorize, catalog: @escaping Catalog,
                dispatch: @escaping Dispatch) {
        self.invocation = invocation
        self.authorize = authorize
        self.catalog = catalog
        self.dispatch = dispatch
        (notifications, outgoing) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        for task in active.values { task.cancel() }
        outgoing.finish()
    }

    public func close() {
        state = .closed
        for task in active.values { task.cancel() }
        active.removeAll()
        outgoing.finish()
    }

    public func receive(_ data: Data) async -> Data? {
        guard state != .closed else { return nil }
        guard data.count <= 128 * 1024, Self.boundedNesting(data) else { return Self.error(-32600, "Invalid request.", id: .null) }
        guard let raw = String(data: data, encoding: .utf8), let message = JSONValue.parse(raw) else {
            return Self.error(-32700, "Parse error.", id: .null)
        }
        let id = RequestID(message["id"])
        guard message["jsonrpc"] == .string("2.0"), let method = message["method"]?.stringValue,
              message["result"] == nil, message["error"] == nil, message["id"] == nil || id != nil else {
            return Self.error(-32600, "Invalid request.", id: id?.json ?? .null)
        }
        guard let id else {
            handleNotification(method, params: message["params"])
            return nil
        }
        guard message["params"] == nil || message["params"]?.objectValue != nil else {
            return Self.error(-32602, "Invalid parameters.", id: id.json)
        }
        if method != "tools/list" && method != "tools/call" {
            do { try await authorize() }
            catch { return Self.error(-32000, "Launch is unavailable.", id: id.json) }
        }
        guard state != .closed else { return nil }
        switch method {
        case "initialize":
            guard state == .initial, let version = message["params"]?["protocolVersion"]?.stringValue else {
                return Self.error(-32602, "Invalid initialization.", id: id.json)
            }
            state = .initialized
            return Self.reply(.object(["protocolVersion": .string(Self.versions.contains(version) ? version : Self.versions[0]),
                "serverInfo": .object(["name": .string("aitvaras"), "version": .string("1")]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(true)])])]), id: id)
        case "ping":
            return Self.reply(.object([:]), id: id)
        case "tools/list", "tools/call":
            guard state == .ready else { return Self.error(-32000, "Session is not ready.", id: id.json) }
            guard active[id] == nil, active.count < 32 else {
                return Self.error(-32600, "Duplicate request ID or too many active requests.", id: id.json)
            }
            let params = message["params"]
            let task = Task { await self.toolRequest(method, params: params, id: id) }
            active[id] = task
            let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            active.removeValue(forKey: id)
            return state == .closed || task.isCancelled ? nil : Data(outcome.jsonString.utf8)
        default:
            return Self.error(-32601, "Method not found.", id: id.json)
        }
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        if method == "notifications/initialized", state == .initialized {
            state = .ready
        } else if method == "notifications/cancelled", let id = RequestID(params?["requestId"]) {
            active[id]?.cancel()
        }
    }

    /// The app calls this when upstream state or project access changes.
    public func catalogChanged() async {
        guard state == .ready else { return }
        let revision = try? await currentCatalog().revision
        guard state == .ready, revision != lastCatalogRevision || revision == nil else { return }
        lastCatalogRevision = revision
        let message = JSONValue.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")])
        outgoing.yield(Data(message.jsonString.utf8))
    }

    private func currentCatalog() async throws -> (tools: [MCPGatewayTool], revision: String) {
        try Task.checkCancellation()
        try await authorize()
        let tools = try await catalog(invocation).sorted { $0.name < $1.name }
        try Task.checkCancellation()
        guard state != .closed, tools.count <= 256, Set(tools.map(\.name)).count == tools.count else {
            throw MCPGatewayCallError.unavailable
        }
        return (tools, MCPGatewayTool.digest(.array(tools.map { .string($0.revision) })))
    }

    private func verify(_ tool: MCPGatewayTool) async throws {
        guard try await currentCatalog().tools.contains(where: { $0.name == tool.name && $0.revision == tool.revision })
        else { throw MCPGatewayCallError.stale }
    }

    private func toolRequest(_ method: String, params: JSONValue?, id: RequestID) async -> JSONValue {
        do {
            let current = try await currentCatalog()
            if method == "tools/list" {
                let offset: Int
                if let cursor = params?["cursor"] {
                    let parts = cursor.stringValue?.split(separator: ":", omittingEmptySubsequences: false) ?? []
                    guard parts.count == 2, parts[0] == current.revision, let position = Int(parts[1]),
                          position > 0, position.isMultiple(of: 16), position < current.tools.count else {
                        return Self.errorValue(-32602, "Invalid or stale cursor.", id: id.json)
                    }
                    offset = position
                } else { offset = 0 }
                lastCatalogRevision = current.revision
                let end = min(offset + 16, current.tools.count)
                var page: [String: JSONValue] = ["tools": .array(current.tools[offset..<end].map(\.listing))]
                if end < current.tools.count { page["nextCursor"] = .string("\(current.revision):\(end)") }
                return Self.replyValue(.object(page), id: id)
            }
            let args = params?["arguments"] ?? .object([:])
            guard let name = params?["name"]?.stringValue, args.objectValue != nil, args.jsonString.utf8.count <= 64 * 1024 else {
                return Self.errorValue(-32602, "Invalid tool call.", id: id.json)
            }
            guard let tool = current.tools.first(where: { $0.name == name }) else {
                return Self.errorValue(-32602, "Unknown tool.", id: id.json)
            }
            let result = try await dispatch(invocation, tool, args) { try await self.verify(tool) }
            return Self.replyValue(try result.validated(), id: id)
        } catch {
            guard method == "tools/call" else { return Self.errorValue(-32603, "Tool catalog is unavailable.", id: id.json) }
            let error = error as? MCPGatewayCallError ?? .failed
            let result: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string(error.message)])]),
                                             "isError": .bool(true)])
            return Self.replyValue(result, id: id)
        }
    }

    private static func replyValue(_ result: JSONValue, id: RequestID) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id.json, "result": result])
    }
    private static func reply(_ result: JSONValue, id: RequestID) -> Data { Data(replyValue(result, id: id).jsonString.utf8) }
    private static func errorValue(_ code: Int, _ message: String, id: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
    private static func error(_ code: Int, _ message: String, id: JSONValue) -> Data {
        Data(errorValue(code, message, id: id).jsonString.utf8)
    }

    private static func boundedNesting(_ data: Data) -> Bool {
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 32 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { break } }
        }
        return true
    }
}
