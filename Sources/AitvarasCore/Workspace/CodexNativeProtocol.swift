import Foundation

/// Lossless JSON shape for native protocol fields, including item kinds unknown to this client.
public enum CodexJSONValue: Codable, Sendable, Equatable {
    case object([String: CodexJSONValue]), array([CodexJSONValue]), string(String)
    case int(Int), double(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([CodexJSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: CodexJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var objectValue: [String: Self]? { if case .object(let v) = self { v } else { nil } }
    public var arrayValue: [Self]? { if case .array(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var intValue: Int? { if case .int(let v) = self { v } else { nil } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public subscript(_ key: String) -> Self? { objectValue?[key] }
    public func encoded() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(self) }
}
extension CodexJSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension CodexJSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .int(value) } }
extension CodexJSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension CodexJSONValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: Self...) { self = .array(elements) } }
extension CodexJSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Self)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) }
}

public enum CodexNativeTransport: Codable, Sendable, Equatable {
    case defaultProxy
    case loopbackWebSocket(String)
}
public struct CodexNativeConnectionConfiguration: Sendable, Equatable {
    public let transport: CodexNativeTransport
    public let profileNamespace: String
    public let codexHome: URL?
    public init(transport: CodexNativeTransport = .defaultProxy, profileNamespace: String, codexHome: URL? = nil) {
        self.transport = transport; self.profileNamespace = profileNamespace; self.codexHome = codexHome
    }
}
public struct CodexNativeConnectionInfo: Codable, Sendable, Equatable {
    public let transport: String
    public let runtimeIdentityKnown: Bool
    public let desktopAttachmentVerified: Bool
    public let detail: String
    public init(transport: String, runtimeIdentityKnown: Bool = false, desktopAttachmentVerified: Bool = false, detail: String) {
        self.transport = transport; self.runtimeIdentityKnown = runtimeIdentityKnown
        self.desktopAttachmentVerified = desktopAttachmentVerified; self.detail = detail
    }
}
public struct CodexNativeThreadSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let projectID: String?
    public let cwd: String
    public let status: String
    public let raw: CodexJSONValue
    public let turns: [CodexNativeTurnSnapshot]
    public let items: [CodexNativeItemSnapshot]
    /// Exhausted every page; not an atomic server revision or an exclusive writer lock.
    public let complete: Bool
    public let observedAt: Date
    public init(id: String, name: String?, projectID: String?, cwd: String, status: String, raw: CodexJSONValue,
                turns: [CodexNativeTurnSnapshot], items: [CodexNativeItemSnapshot], complete: Bool, observedAt: Date = Date()) {
        self.id = id; self.name = name; self.projectID = projectID; self.cwd = cwd; self.status = status
        self.raw = raw; self.turns = turns; self.items = items; self.complete = complete; self.observedAt = observedAt
    }
}
public struct CodexNativeTurnSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let status: String
    public let order: Int
    public let raw: CodexJSONValue
    public init(id: String, status: String, order: Int, raw: CodexJSONValue) {
        self.id = id; self.status = status; self.order = order; self.raw = raw
    }
}
public struct CodexNativeItemSnapshot: Codable, Sendable, Equatable {
    public let id: String
    public let turnID: String
    public let kind: String
    public let order: Int
    /// The entire ThreadItemEntry, including timing metadata and the unmodified item.
    public let raw: CodexJSONValue
    public init(id: String, turnID: String, kind: String, order: Int, raw: CodexJSONValue) {
        self.id = id; self.turnID = turnID; self.kind = kind; self.order = order; self.raw = raw
    }
}
public struct CodexNativeResumeConfiguration: Codable, Sendable, Equatable {
    public let threadID: String
    public let model: String
    public let modelProvider: String
    public let cwd: String
    public let approvalPolicy: CodexJSONValue
    public let approvalsReviewer: String
    public let sandbox: CodexJSONValue
    public let runtimeWorkspaceRoots: [String]
    public let activePermissionProfile: CodexJSONValue?
    public let raw: CodexJSONValue
    public init(threadID: String, model: String, modelProvider: String, cwd: String, approvalPolicy: CodexJSONValue,
                approvalsReviewer: String, sandbox: CodexJSONValue, runtimeWorkspaceRoots: [String],
                activePermissionProfile: CodexJSONValue?, raw: CodexJSONValue) {
        self.threadID = threadID; self.model = model; self.modelProvider = modelProvider; self.cwd = cwd
        self.approvalPolicy = approvalPolicy; self.approvalsReviewer = approvalsReviewer; self.sandbox = sandbox
        self.runtimeWorkspaceRoots = runtimeWorkspaceRoots; self.activePermissionProfile = activePermissionProfile; self.raw = raw
    }
}
public struct CodexNativeServerRequest: Codable, Sendable, Equatable, Identifiable {
    /// A JSON-RPC id is opaque and may be numeric or textual; never coerce it to a native item id.
    public let id: CodexJSONValue
    public let method: String
    public let threadID: String
    public let turnID: String
    public let itemID: String?
    public let params: CodexJSONValue
    public init(id: CodexJSONValue, method: String, threadID: String, turnID: String, itemID: String?, params: CodexJSONValue) {
        self.id = id; self.method = method; self.threadID = threadID; self.turnID = turnID; self.itemID = itemID; self.params = params
    }
}
extension CodexJSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let v): hasher.combine(1); hasher.combine(v)
        case .int(let v): hasher.combine(2); hasher.combine(v)
        case .double(let v): hasher.combine(3); hasher.combine(v)
        case .string(let v): hasher.combine(4); hasher.combine(v)
        case .array(let v): hasher.combine(5); hasher.combine(v)
        case .object(let v): hasher.combine(6); for key in v.keys.sorted() { hasher.combine(key); hasher.combine(v[key]) }
        }
    }
}
public enum CodexNativeEvent: Sendable, Equatable {
    case notification(method: String, params: CodexJSONValue)
    case serverRequest(CodexNativeServerRequest)
    case disconnected
}
public enum CodexNativeApprovalDecision: String, Codable, Sendable { case accept, decline, cancel }

public enum CodexNativeError: String, Error, LocalizedError, Sendable, Equatable {
    case disabled, invalidRequest, invalidEndpoint, unavailable, unsupported, rejected, timeout, tooLarge, malformed
    case disconnected, busy, approvalScope, unreviewedConfiguration, uncertainOutcome
    public var errorDescription: String? {
        switch self {
        case .disabled: "External integrations are disabled for this profile."
        case .invalidRequest: "The native Codex request is invalid or outside the reviewed method boundary."
        case .invalidEndpoint: "Use an explicit ws:// endpoint with 127.0.0.1 or [::1] and a port."
        case .unavailable: "The native Codex runtime is unavailable. No server was started. Shared runtime setup may be required."
        case .unsupported: "This Codex runtime does not support the requested native operation."
        case .rejected: "The native Codex runtime rejected the request."
        case .timeout: "The native Codex request timed out. A write may have an unknown outcome; it will not be replayed."
        case .tooLarge: "The native Codex response exceeds a bounded protocol or history limit."
        case .malformed: "The native Codex runtime returned an unsupported protocol response."
        case .disconnected: "The native Codex connection ended. In-flight work may continue; no input will be replayed."
        case .busy: "This native Codex thread is active or its idle status could not be confirmed."
        case .approvalScope: "This approval is stale or does not match the pending request, thread and turn."
        case .unreviewedConfiguration: "Resume this native thread and review its effective permissions before sending."
        case .uncertainOutcome: "A prior native send has an uncertain outcome. Reconcile native history before sending again."
        }
    }
}
