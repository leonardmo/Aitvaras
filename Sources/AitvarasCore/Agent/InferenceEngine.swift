import Foundation

/// A single message in a model conversation.
public struct ChatMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system, user, assistant, tool
    }

    public var role: Role
    public var content: String
    /// Set when `role == .tool`: which tool call this message answers.
    public var toolCallID: String?

    public init(role: Role, content: String, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }
}

/// A tool invocation requested by the model.
public struct ToolCall: Sendable, Codable, Equatable {
    public var id: String
    public var toolName: String
    /// Raw JSON arguments as produced by the model.
    public var argumentsJSON: String

    public init(id: String, toolName: String, argumentsJSON: String) {
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

/// Incremental output from a streaming completion.
public enum InferenceChunk: Sendable {
    case text(String)
    /// Model reasoning (e.g. Qwen3 <think> blocks) — shown collapsed in UI,
    /// never spoken by TTS.
    case reasoning(String)
    case toolCall(ToolCall)
    case done(stopReason: StopReason)

    public enum StopReason: Sendable {
        case endOfTurn
        case toolUse
        case cancelled
        case contextOverflow
    }
}

/// Which ROLE a request runs as. The user assigns a concrete model to
/// each role (D2 revised): typed chat wants depth, voice wants speed,
/// background automation (mail triage, focus checks) wants accuracy.
public enum ModelTier: String, Sendable, CaseIterable {
    case chat
    case voice
    case background

    public var displayName: String {
        switch self {
        case .chat: "Chat"
        case .voice: "Voice"
        case .background: "Background"
        }
    }
}

/// A source of completions. Implementations: MLXEngine (primary),
/// OllamaEngine (fallback), AppleFMEngine (micro-tasks). See D2.
public protocol InferenceEngine: Actor {
    var identifier: String { get }

    /// Whether the engine is loaded and ready to serve `tier`.
    func isAvailable(for tier: ModelTier) async -> Bool

    /// Stream a completion. `tools` are JSON Schema tool definitions.
    func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error>
}

/// A tool the model may call, as exposed by a connector.
public struct ToolDefinition: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    /// JSON Schema for the arguments.
    public var parametersJSON: String
    public var risk: ActionRisk

    public init(name: String, description: String, parametersJSON: String, risk: ActionRisk) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.risk = risk
    }
}
