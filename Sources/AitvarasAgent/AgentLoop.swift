import Foundation
import AitvarasCore
import AitvarasStore

/// Picks the best available engine per tier: MLX when its model is on
/// disk, otherwise Ollama; Apple FM only ever for light tier plain
/// completions (D2).
public actor EngineRouter {
    private let ranked: [any InferenceEngine]

    public init(ranked: [any InferenceEngine]) {
        self.ranked = ranked
    }

    public func engine(for tier: ModelTier) async -> (any InferenceEngine)? {
        for engine in ranked where await engine.isAvailable(for: tier) {
            return engine
        }
        return nil
    }

    public func engineDescription(for tier: ModelTier) async -> String {
        await engine(for: tier)?.identifier ?? "none"
    }
}

/// What the UI (chat view, voice pipeline, companion state machine)
/// receives while a turn runs.
public enum AgentUpdate: Sendable {
    case reasoningDelta(String)
    case textDelta(String)
    case toolStarted(String)
    case toolFinished(name: String, output: String)
    case confirmationRequested(Suggestion)
    case finished
    case failed(String)
}

/// The tool-use loop (see ARCHITECTURE.md "Core flow").
public actor AgentLoop {
    private let router: EngineRouter
    private let hub: ConnectorHub
    private let stores: Stores
    private let retriever: (any ContextRetriever)?

    public init(router: EngineRouter, hub: ConnectorHub, stores: Stores,
                retriever: (any ContextRetriever)?) {
        self.router = router
        self.hub = hub
        self.stores = stores
        self.retriever = retriever
    }

    private static let maxToolIterations = 8

    /// Reply announces an action instead of performing it.
    static func soundsLikeUnkeptPromise(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let promises = [
            "i will ", "i'll ", "let me ", "i am going to", "i'm going to",
            "one moment", "just a moment", "ich werde ", "einen moment",
            "ich schaue", "ich prüfe", "lass mich"
        ]
        return promises.contains { lowered.contains($0) }
    }

    /// Run one user turn. `history` is prior conversation (user/assistant
    /// only). `causedBy`/`sourceID` carry provenance when the turn was
    /// triggered by a connector event instead of the user.
    public func run(
        history: [ChatMessage],
        userMessage: String,
        voiceMode: Bool = false,
        tier: ModelTier = .chat,
        causedBy: UUID? = nil,
        sourceID: String? = nil
    ) -> AsyncStream<AgentUpdate> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    guard let engine = await router.engine(for: tier) else {
                        continuation.yield(.failed("No inference engine available. Is a model downloaded or Ollama running?"))
                        continuation.finish()
                        return
                    }

                    let tools = await hub.allTools()
                    var retrieved: [RetrievedChunk] = []
                    if let retriever {
                        retrieved = (try? await retriever.retrieve(query: userMessage, limit: 6)) ?? []
                    }
                    let facts = (try? stores.activeFacts(limit: 40)) ?? []
                    let memories = facts.isEmpty ? ((try? stores.activeMemories()) ?? []) : []

                    var messages: [ChatMessage] = [
                        ChatMessage(role: .system, content: PromptBuilder.systemPrompt(
                            memories: memories, facts: facts, retrieved: retrieved, voiceMode: voiceMode))
                    ]
                    messages += history
                    // Instructions attached to the user turn outrank the
                    // system prompt for small models — voice needs both.
                    let effectiveUserMessage = voiceMode
                        ? userMessage + "\n\n(Answer in English only, in short spoken prose — no lists, no symbols.)"
                        : userMessage
                    messages.append(ChatMessage(role: .user, content: effectiveUserMessage))

                    var iterations = 0
                    var executedAnyTool = false
                    var promiseRetryUsed = false
                    while iterations <= Self.maxToolIterations {
                        iterations += 1
                        var assistantText = ""
                        var pendingCalls: [ToolCall] = []
                        var stopReason = InferenceChunk.StopReason.endOfTurn

                        let stream = await engine.complete(messages: messages, tools: tools, tier: tier)
                        for try await chunk in stream {
                            try Task.checkCancellation()
                            switch chunk {
                            case .text(let delta):
                                assistantText += delta
                                continuation.yield(.textDelta(delta))
                            case .reasoning(let delta):
                                continuation.yield(.reasoningDelta(delta))
                            case .toolCall(let call):
                                pendingCalls.append(call)
                            case .done(let reason):
                                stopReason = reason
                            }
                        }

                        if pendingCalls.isEmpty || stopReason == .cancelled {
                            // Models love announcing actions ("I'll add that…")
                            // and ending the turn without doing anything —
                            // observed live: claimed goal/reminder creation
                            // with an empty database. If the reply promises
                            // action but no tool ran this turn, force one redo.
                            if stopReason != .cancelled,
                               !promiseRetryUsed,
                               !executedAnyTool,
                               !tools.isEmpty,
                               Self.soundsLikeUnkeptPromise(assistantText) {
                                promiseRetryUsed = true
                                messages.append(ChatMessage(role: .assistant, content: assistantText))
                                messages.append(ChatMessage(role: .user, content:
                                    "(system check: you announced an action but made no tool call. Execute the required tool call NOW — no further announcements. If no tool fits, state plainly that you cannot do it.)"))
                                continuation.yield(.textDelta(" "))
                                continue
                            }
                            break
                        }
                        executedAnyTool = true

                        // Record the assistant turn (text + calls), then run tools.
                        let callsDescription = pendingCalls
                            .map { "<tool_call>{\"name\": \"\($0.toolName)\", \"arguments\": \($0.argumentsJSON)}</tool_call>" }
                            .joined(separator: "\n")
                        messages.append(ChatMessage(
                            role: .assistant,
                            content: assistantText.isEmpty ? callsDescription : assistantText + "\n" + callsDescription))

                        for call in pendingCalls {
                            continuation.yield(.toolStarted(call.toolName))
                            let resultText: String
                            do {
                                switch try await hub.execute(call: call, causedBy: causedBy, sourceID: sourceID) {
                                case .output(let output):
                                    resultText = output
                                    continuation.yield(.toolFinished(name: call.toolName, output: output))
                                case .awaitingConfirmation(let suggestion):
                                    resultText = "This action requires user confirmation. A confirmation card was shown to the user — tell them briefly what you proposed and that it awaits their approval. Do not retry."
                                    continuation.yield(.confirmationRequested(suggestion))
                                }
                            } catch {
                                resultText = "Error: \(error.localizedDescription)"
                                continuation.yield(.toolFinished(name: call.toolName, output: resultText))
                            }
                            messages.append(ChatMessage(role: .tool, content: resultText, toolCallID: call.id))
                        }
                    }

                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finished)
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum PromptBuilder {
    public static func systemPrompt(
        memories: [Memory],
        facts: [MemoryFact] = [],
        retrieved: [RetrievedChunk],
        voiceMode: Bool,
        now: Date = .now
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var prompt = """
        You are Aitvaras, a personal AI assistant running fully locally on the user's Mac. Your name comes from the small dragon of Lithuanian folklore that lives behind the hearth and brings its household provisions. \
        You are warm, direct and competent — a capable colleague, not a servile bot. \
        Answer in the language the user writes or speaks (German or English). \
        Current date and time: \(formatter.string(from: now)).

        You can act through tools (calendar, reminders, mail reading and search, web search \
        and page fetching, daily goals, knowledge search, memory and more). \
        Use them when they genuinely help; don't narrate routine lookups. \
        For current events, facts you're unsure about, or anything after your training data, \
        search the web instead of guessing. You can plan the user's day with them (goals tools) \
        and check on progress when asked. \
        Before answering a non-trivial question about the user (their preferences, people, \
        projects, habits) that isn't already covered below, call memory.search first. \
        When the user asks you to remember something, or states a durable fact about \
        themselves, save it with memory.remember; correct outdated facts with memory.revise. \
        Some actions require user confirmation — when told so, summarize what you proposed and stop.
        """

        if !facts.isEmpty {
            // Voice runs the small model and wants a lean prompt — prompt
            // tokens are latency (MASTERPLAN §1 corollary).
            let budget = voiceMode ? 12 : 40
            prompt += "\n\n# What you know about the user\n"
            prompt += "The most salient current facts. Treat as background truth; search memory for more.\n"
            prompt += facts.prefix(budget).map { fact in
                let tag = fact.entitiesText.isEmpty ? "" : " [\(fact.entitiesText)]"
                return "- \(fact.text)\(tag)"
            }.joined(separator: "\n")
        } else if !memories.isEmpty {
            prompt += "\n\n# What you remember about the user\n"
            prompt += memories.prefix(30).map { "- \($0.content)" }.joined(separator: "\n")
        }

        if !retrieved.isEmpty {
            prompt += "\n\n# Possibly relevant excerpts from the user's notes and code\n"
            prompt += "Cite the origin in brackets when you use one.\n"
            for chunk in retrieved {
                prompt += "\n[\(chunk.origin)]\n\(chunk.text)\n"
            }
        }

        // Voice rules come LAST — small models weight the end of the
        // system prompt far more than the middle.
        if voiceMode {
            prompt += """


            # VOICE MODE — STRICT OUTPUT RULES
            Your answer is read aloud by a text-to-speech engine.
            - Reply ONLY in English, even when the user speaks German.
            - Plain spoken sentences. NO markdown, NO bullet lists, NO asterisks, NO headings, NO code.
            - No symbols, URLs, file paths or IDs. Summarize instead of enumerating: "You have seven meetings tomorrow, the first at half past eight" — never a list of entries.
            - Round numbers, speak times naturally.
            - ACT, THEN SPEAK: perform every needed tool call BEFORE composing your answer. NEVER announce future actions — "I will check", "let me look that up", "I'll add it" are forbidden endings. By the time you speak, it is DONE and you report the result.
            - Questions about mail, calendar, reminders, goals, weather or facts: CALL the matching tool first, then answer from its result. Never claim you cannot check something a tool covers, and never ask permission to use a read tool.
            - NEVER claim an action succeeded without having called the tool in this very turn. No tool result = no claim.
            - Follow-ups like "what kind of appointment is that?" refer to what was just discussed — use the conversation history and, if detail is missing, call the tool again instead of asking the user.
            /no_think
            """
        }

        return prompt
    }
}
