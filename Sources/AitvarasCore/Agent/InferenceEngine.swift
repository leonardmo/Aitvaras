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

/// Token accounting emitted by an inference engine.
public struct InferenceUsage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var isEstimated: Bool
    public var modelIdentifier: String?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        isEstimated: Bool = false,
        modelIdentifier: String? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.isEstimated = isEstimated
        self.modelIdentifier = modelIdentifier
    }
}

/// Incremental output from a streaming completion.
public enum InferenceChunk: Sendable {
    case text(String)
    /// Model reasoning (e.g. Qwen3 <think> blocks) — shown collapsed in UI,
    /// never spoken by TTS.
    case reasoning(String)
    case toolCall(ToolCall)
    /// Metering metadata; never assistant-visible content.
    case usage(InferenceUsage)
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

    /// Maximum silence between streamed chunks. This includes initial model
    /// loading; values are deliberately generous for local hardware while
    /// still preventing a wedged engine from blocking the app indefinitely.
    public var inferenceInactivityTimeout: Duration {
        switch self {
        case .voice: .seconds(45)
        case .chat: .seconds(120)
        case .background: .seconds(180)
        }
    }
}

/// News is a deliberate exception to the default low-latency voice model.
/// Current-events requests deserve the full chat tier for selecting and
/// contextualizing source material; reader-button narration uses no model.
public enum VoiceModelRouting {
    public static func tier(for userText: String) -> ModelTier {
        let normalized = userText.lowercased()
        let newsMarkers = [
            "news", "headlines", "current events", "news feed", "newsfeed",
            "nachrichten", "schlagzeilen", "presseschau", "neuigkeiten"
        ]
        return newsMarkers.contains(where: normalized.contains) ? .chat : .voice
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

public struct InferenceInactivityError: Error, LocalizedError, Sendable {
    public let timeout: Duration

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public var errorDescription: String? {
        "The local inference engine stopped responding. Its stream was cancelled after \(timeout.formatted()) without output."
    }
}

public struct InferenceOutputLimitError: Error, LocalizedError, Sendable {
    public let maximumCharacters: Int

    public init(maximumCharacters: Int) {
        self.maximumCharacters = maximumCharacters
    }

    public var errorDescription: String? {
        "The local inference engine produced more than \(maximumCharacters.formatted()) characters and was cancelled. Try a narrower request."
    }
}

public extension InferenceEngine {
    /// The production entry point: wraps the engine's raw stream with an
    /// inactivity timeout and propagates consumer cancellation back to it.
    func completeWithInactivityTimeout(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier,
        timeout: Duration? = nil
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        InferenceStreams.withInactivityTimeout(
            complete(messages: messages, tools: tools, tier: tier),
            timeout: timeout ?? tier.inferenceInactivityTimeout,
            maximumOutputCharacters: 64_000)
    }
}

public enum InferenceStreams {
    public static func withInactivityTimeout(
        _ source: AsyncThrowingStream<InferenceChunk, Error>,
        timeout: Duration,
        checkEvery: Duration = .seconds(1),
        maximumOutputCharacters: Int = 64_000
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            let activity = InferenceStreamActivity()
            let relay = Task {
                do {
                    var outputCharacters = 0
                    for try await chunk in source {
                        let cost = Self.characterCost(of: chunk)
                        guard cost <= max(0, maximumOutputCharacters - outputCharacters) else {
                            throw InferenceOutputLimitError(
                                maximumCharacters: maximumOutputCharacters)
                        }
                        outputCharacters += cost
                        await activity.touch()
                        continuation.yield(chunk)
                    }
                    if await activity.finishIfRunning() {
                        continuation.finish()
                    }
                } catch {
                    if await activity.finishIfRunning() {
                        continuation.finish(throwing: error)
                    }
                }
            }
            let watchdog = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: checkEvery)
                        if await activity.isFinished { return }
                        if await activity.hasTimedOut(after: timeout),
                           await activity.finishIfRunning() {
                            continuation.finish(throwing: InferenceInactivityError(timeout: timeout))
                            relay.cancel()
                            return
                        }
                    }
                } catch {
                    // Cancellation is normal when the stream finishes or its
                    // consumer goes away.
                }
            }
            continuation.onTermination = { _ in
                relay.cancel()
                watchdog.cancel()
            }
        }
    }

    private static func characterCost(of chunk: InferenceChunk) -> Int {
        switch chunk {
        case .text(let text), .reasoning(let text):
            text.count
        case .toolCall(let call):
            call.id.count + call.toolName.count + call.argumentsJSON.count
        case .usage, .done:
            0
        }
    }
}

private actor InferenceStreamActivity {
    private let clock = ContinuousClock()
    private var lastActivity: ContinuousClock.Instant
    private(set) var isFinished = false

    init() {
        lastActivity = clock.now
    }

    func touch() {
        guard !isFinished else { return }
        lastActivity = clock.now
    }

    func hasTimedOut(after timeout: Duration) -> Bool {
        lastActivity.duration(to: clock.now) >= timeout
    }

    func finishIfRunning() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        return true
    }
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
