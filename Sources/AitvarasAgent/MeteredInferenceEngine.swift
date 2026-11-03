import Foundation
import AitvarasCore
import AitvarasStore

/// Transparent local-engine wrapper. It removes usage metadata from the
/// assistant stream and persists only numeric accounting. Content never
/// enters the usage table.
actor MeteredInferenceEngine: InferenceEngine {
    nonisolated let identifier: String

    private let base: any InferenceEngine
    private let stores: Stores
    private let reporter: ActivityReporter?

    init(
        base: any InferenceEngine,
        identifier: String,
        stores: Stores,
        reporter: ActivityReporter? = nil
    ) {
        self.base = base
        self.identifier = identifier
        self.stores = stores
        self.reporter = reporter
    }

    func isAvailable(for tier: ModelTier) async -> Bool {
        await base.isAvailable(for: tier)
    }

    func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        let base = base
        let stores = stores
        let identifier = identifier
        let reporter = reporter
        return AsyncThrowingStream { continuation in
            let task = Task {
                let runID = reporter?.begin(ActivityRun(category: .model,
                    title: "Local model inference", stage: "Generating",
                    provider: identifier, executionLocation: "Local",
                    dataAccess: "Bounded prompt context", dataDestination: "Local inference"))
                let started = Date()
                var reportedUsage: InferenceUsage?
                var outputCharacters = 0
                var cancelled = false
                do {
                    try Task.checkCancellation()
                    for try await chunk in await base.complete(
                        messages: messages, tools: tools, tier: tier
                    ) {
                        try Task.checkCancellation()
                        switch chunk {
                        case .usage(let usage):
                            reportedUsage = usage
                        case .text(let text), .reasoning(let text):
                            outputCharacters += text.utf8.count
                            continuation.yield(chunk)
                        case .toolCall(let call):
                            outputCharacters += call.toolName.utf8.count
                                + call.argumentsJSON.utf8.count
                            continuation.yield(chunk)
                        case .done(let reason):
                            if case .cancelled = reason { cancelled = true }
                            continuation.yield(chunk)
                        }
                    }
                    try Task.checkCancellation()
                    if let runID { reporter?.finish(id: runID,
                        state: cancelled ? .cancelled : .succeeded,
                        outcome: cancelled ? "Cancelled" : "Inference completed") }
                    Self.record(
                        stores: stores,
                        identifier: identifier,
                        tier: tier,
                        started: started,
                        messages: messages,
                        tools: tools,
                        outputCharacters: outputCharacters,
                        reportedUsage: reportedUsage,
                        succeeded: !cancelled,
                        failureKind: cancelled ? "CancellationError" : nil)
                    continuation.finish()
                } catch {
                    if let runID { reporter?.finish(id: runID,
                        state: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
                        outcome: "Inference stopped") }
                    Self.record(
                        stores: stores,
                        identifier: identifier,
                        tier: tier,
                        started: started,
                        messages: messages,
                        tools: tools,
                        outputCharacters: outputCharacters,
                        reportedUsage: reportedUsage,
                        succeeded: false,
                        failureKind: String(describing: type(of: error)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func record(
        stores: Stores,
        identifier: String,
        tier: ModelTier,
        started: Date,
        messages: [ChatMessage],
        tools: [ToolDefinition],
        outputCharacters: Int,
        reportedUsage: InferenceUsage?,
        succeeded: Bool,
        failureKind: String?
    ) {
        let inputCharacters = messages.reduce(0) {
            $0 + $1.content.utf8.count
        } + tools.reduce(0) {
            $0 + $1.name.utf8.count
                + $1.description.utf8.count
                + $1.parametersJSON.utf8.count
        }
        let usage = reportedUsage ?? InferenceUsage(
            inputTokens: estimatedTokens(forCharacters: inputCharacters),
            outputTokens: estimatedTokens(forCharacters: outputCharacters),
            isEstimated: true)
        _ = try? stores.recordLocalModelUsage(LocalModelUsageRecord(
            engine: usage.modelIdentifier ?? identifier,
            tier: tier.rawValue,
            durationMilliseconds:
                Int(Date().timeIntervalSince(started) * 1_000),
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            isEstimated: usage.isEstimated,
            succeeded: succeeded,
            failureKind: failureKind))
    }

    private nonisolated static func estimatedTokens(
        forCharacters characters: Int
    ) -> Int {
        guard characters > 0 else { return 0 }
        return max(1, Int(ceil(Double(characters) / 4.0)))
    }
}
