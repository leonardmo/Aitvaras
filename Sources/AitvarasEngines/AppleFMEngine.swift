import Foundation
import FoundationModels
import AitvarasCore

/// Apple's on-device model (macOS 26 FoundationModels framework) for
/// micro-tasks: notification triage, short summaries (D2). No tool use —
/// AgentCore only routes plain completions here.
public actor AppleFMEngine: InferenceEngine {
    public let identifier = "apple-fm"

    public init() {}

    public func isAvailable(for tier: ModelTier) async -> Bool {
        guard tier == .background else { return false }
        return SystemLanguageModel.default.availability == .available
    }

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard tools.isEmpty else {
                        throw NSError(domain: "AppleFMEngine", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "AppleFMEngine does not support tool use"
                        ])
                    }
                    let instructions = messages.first(where: { $0.role == .system })?.content
                        ?? "You are a concise assistant."
                    let prompt = messages
                        .filter { $0.role != .system }
                        .map { "\($0.role.rawValue): \($0.content)" }
                        .joined(separator: "\n")

                    let session = LanguageModelSession(instructions: instructions)
                    let stream = session.streamResponse(to: prompt)
                    var previous = ""
                    for try await partial in stream {
                        try Task.checkCancellation()
                        let full = partial.content
                        if full.hasPrefix(previous) {
                            let delta = String(full.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(.text(delta)) }
                        } else {
                            continuation.yield(.text(full))
                        }
                        previous = full
                    }
                    continuation.yield(.done(stopReason: .endOfTurn))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.done(stopReason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
