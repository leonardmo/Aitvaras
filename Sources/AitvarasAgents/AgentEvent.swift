import Foundation

/// Preserve JSON-RPC numeric IDs without rounding them through Double.
public enum AgentRequestID: Hashable, Sendable, Codable {
    case string(String), integer(Int64)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else { self = .string(try value.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let id): try value.encode(id)
        case .integer(let id): try value.encode(id)
        }
    }
}

public struct AgentEventScope: Sendable, Equatable {
    public let runID: UUID
    public let session: AgentSessionID?
    public let inputID: UUID?
    public let turnID: String?
    public let itemID: String?

    public init(runID: UUID, session: AgentSessionID? = nil, inputID: UUID? = nil,
                turnID: String? = nil, itemID: String? = nil) {
        self.runID = runID; self.session = session; self.inputID = inputID
        self.turnID = turnID; self.itemID = itemID
    }
}

public struct AgentTool: Sendable, Equatable {
    public let name: String
    public let input: JSONValue
    public init(name: String, input: JSONValue) { self.name = name; self.input = input }
}

public struct AgentQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public let label: String
        public let description: String
        public init(label: String, description: String) { self.label = label; self.description = description }
    }
    /// Native question ID, or Claude's question text used as its answer key.
    public let id: String
    public let prompt: String
    public let options: [Option]
    public let allowsMultiple: Bool
    public let isSecret: Bool
    public init(id: String, prompt: String, options: [Option] = [], allowsMultiple: Bool = false, isSecret: Bool = false) {
        self.id = id; self.prompt = prompt; self.options = options
        self.allowsMultiple = allowsMultiple; self.isSecret = isSecret
    }
}

public struct AgentRequest: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Claude hooks run even when native permission rules skip a prompt.
        case preToolUse(AgentTool)
        case postToolUse(AgentTool, output: JSONValue)
        case permission(AgentTool)
        /// Codex permission/network grants retain the full structured request.
        case permissions(JSONValue)
        case plan(String)
        case questions([AgentQuestion])
        /// Requires an explicit unsupported/deny response, never a false success.
        case unknown(method: String, parameters: JSONValue)
    }
    public let id: AgentRequestID
    public let scope: AgentEventScope
    public let kind: Kind
    public let isBlocking: Bool
    public init(id: AgentRequestID, scope: AgentEventScope, kind: Kind, isBlocking: Bool = true) {
        self.id = id; self.scope = scope; self.kind = kind; self.isBlocking = isBlocking
    }
}

public enum AgentResponse: Sendable, Equatable {
    case allow(updatedInput: JSONValue?)
    case deny
    case answers([String: [String]])
    case continueHook
    case unsupported
}

public struct AgentUsage: Sendable, Equatable {
    /// Codex's `last` is one model call, not necessarily a whole turn.
    public enum Scope: Sendable { case lastCall, turn, session, process }
    public var scope: Scope
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheWriteInputTokens: Int?
    public var thinkingTokens: Int?
    public var contextTokens: Int?
    public var contextLimit: Int?
    public var costUSD: Double?

    public init(scope: Scope, inputTokens: Int? = nil, outputTokens: Int? = nil,
                cachedInputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil, thinkingTokens: Int? = nil,
                contextTokens: Int? = nil, contextLimit: Int? = nil, costUSD: Double? = nil) {
        self.scope = scope; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens; self.cacheWriteInputTokens = cacheWriteInputTokens
        self.thinkingTokens = thinkingTokens; self.contextTokens = contextTokens
        self.contextLimit = contextLimit; self.costUSD = costUSD
    }
}

public struct AgentRateLimitWindow: Sendable, Equatable {
    public let id: String
    /// Normalized to 0...1; nil is unavailable, never zero usage.
    public let utilization: Double?
    public let duration: TimeInterval?
    public let resetsAt: Date?
    public init(id: String, utilization: Double?, duration: TimeInterval? = nil, resetsAt: Date? = nil) {
        self.id = id; self.utilization = utilization; self.duration = duration; self.resetsAt = resetsAt
    }
}

public struct AgentEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sessionStarted(AgentSessionID)
        case delivery(AgentDeliveryState)
        case textDelta(String)
        case thinkingDelta(String)
        /// Complete canonical message, distinct from partial streaming deltas.
        case message(id: String, role: String, text: String)
        case toolStarted(AgentTool)
        case toolOutput(JSONValue)
        case toolFinished(output: JSONValue, isError: Bool)
        case fileChanged(path: String, diff: String)
        case request(AgentRequest)
        /// Informational plan updates do not imply a request for execution.
        case planUpdated(JSONValue)
        case usage(AgentUsage)
        case rateLimits([AgentRateLimitWindow])
        case turnEnded(AgentTurnOutcome)
        case unknown(name: String, payload: JSONValue)
    }
    public let scope: AgentEventScope
    public let kind: Kind
    public init(scope: AgentEventScope, kind: Kind) { self.scope = scope; self.kind = kind }
}
