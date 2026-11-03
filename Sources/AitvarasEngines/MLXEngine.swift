import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import AitvarasCore
import Tokenizers

public enum LocalModelLoadEvent: Sendable {
    case started(id: UUID, model: String)
    case finished(id: UUID, succeeded: Bool)
}

/// Primary engine (D2): runs Qwen3 models in-process via MLX.
/// Tool calls are handled natively by MLXLMCommon (it parses the model's
/// <tool_call> output); <think> reasoning blocks are split out here.
public actor MLXEngine: InferenceEngine {
    public let identifier = "mlx"

    private var containers: [String: ModelContainer] = [:]
    private var lastUsed: [String: Date] = [:]
    private let reportLoad: (@Sendable (LocalModelLoadEvent) -> Void)?

    /// Combined on-disk size of loaded models above which the least
    /// recently used gets evicted before a new load on memory-constrained machines.
    private static let loadedBudgetBytes: Int64 = 26 * 1024 * 1024 * 1024

    public static func modelsDirectory() -> URL {
        AitvarasPaths.modelsDirectory
    }

    public init(reportLoad: (@Sendable (LocalModelLoadEvent) -> Void)? = nil) {
        self.reportLoad = reportLoad
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024   // 1 GB reuse cache; keep RAM headroom
    }

    // MARK: Role → model assignment (user-selectable, D2 revised)

    public static let defaultAssignments: [ModelTier: String] = [
        .chat: "Qwen3-30B-A3B-4bit",
        .voice: "Qwen3-4B-4bit",
        .background: "Qwen3-30B-A3B-4bit"
    ]

    public static func assignedModel(for tier: ModelTier) -> String {
        AitvarasPreferences.current.string(forKey: "model.role.\(tier.rawValue)")
            ?? defaultAssignments[tier]!
    }

    public static func assign(model directoryName: String, to tier: ModelTier) {
        AitvarasPreferences.current.set(directoryName, forKey: "model.role.\(tier.rawValue)")
    }

    /// Complete model directories on disk (configuration + all weights).
    public static func installedModels() -> [String] {
        let dir = modelsDirectory()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter(AitvarasPaths.isCompleteModelDirectory)
            .map(\.lastPathComponent)
            .sorted()
    }

    public static func sizeOnDisk(of directoryName: String) -> Int64 {
        let dir = modelsDirectory().appendingPathComponent(directoryName)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func modelURL(named directoryName: String) -> URL {
        Self.modelsDirectory().appendingPathComponent(directoryName, isDirectory: true)
    }

    public func isAvailable(for tier: ModelTier) async -> Bool {
        AitvarasPaths.isCompleteModelDirectory(
            modelURL(named: Self.assignedModel(for: tier)))
    }

    private func container(for tier: ModelTier) async throws -> ModelContainer {
        let key = Self.assignedModel(for: tier)
        lastUsed[key] = .now
        if let existing = containers[key] { return existing }
        let loadID = UUID()
        reportLoad?(.started(id: loadID, model: key))

        // Evict least-recently-used models until the new one fits.
        let incomingSize = Self.sizeOnDisk(of: key)
        var loadedSize = containers.keys.reduce(Int64(0)) { $0 + Self.sizeOnDisk(of: $1) }
        while loadedSize + incomingSize > Self.loadedBudgetBytes,
              let oldest = containers.keys.min(by: { (lastUsed[$0] ?? .distantPast) < (lastUsed[$1] ?? .distantPast) }) {
            containers[oldest] = nil
            loadedSize -= Self.sizeOnDisk(of: oldest)
            MLX.Memory.clearCache()
        }

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: modelURL(named: key),
                using: #huggingFaceTokenizerLoader())
            try Task.checkCancellation()
            containers[key] = container
            reportLoad?(.finished(id: loadID, succeeded: true))
            return container
        } catch {
            reportLoad?(.finished(id: loadID, succeeded: false))
            throw error
        }
    }

    /// Load a role's model ahead of first use.
    public func prewarm(tier: ModelTier) async {
        _ = try? await container(for: tier)
    }

    /// Free a loaded model (e.g. under memory pressure).
    public func unload(tier: ModelTier) {
        containers[Self.assignedModel(for: tier)] = nil
        MLX.Memory.clearCache()
    }

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let modelIdentifier =
                        "mlx:\(Self.assignedModel(for: tier))"
                    let container = try await self.container(for: tier)

                    try await container.perform { (context: ModelContext) in
                        // Build the chat inside the isolation domain —
                        // Chat.Message is not Sendable.
                        var chat: [Chat.Message] = []
                        for message in messages {
                            switch message.role {
                            case .system: chat.append(.system(message.content))
                            case .user: chat.append(.user(message.content))
                            case .assistant: chat.append(.assistant(message.content))
                            case .tool: chat.append(.tool(message.content, id: message.toolCallID))
                            }
                        }
                        let toolSpecs: [ToolSpec]? = tools.isEmpty ? nil : tools.map { tool in
                            let params = (try? JSONSerialization.jsonObject(
                                with: Data(tool.parametersJSON.utf8))) as? [String: any Sendable] ?? [:]
                            return [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": params
                                ] as [String: any Sendable]
                            ]
                        }

                        let input = try await context.processor.prepare(
                            input: UserInput(chat: chat, tools: toolSpecs))
                        let parameters = GenerateParameters(
                            maxTokens: 8192, temperature: 0.6, topP: 0.95)
                        let stream = try MLXLMCommon.generate(
                            input: input, parameters: parameters, context: context)

                        var parser = QwenStreamParser()
                        var sawToolCall = false
                        for await generation in stream {
                            try Task.checkCancellation()
                            switch generation {
                            case .chunk(let text):
                                for chunk in parser.consume(text) {
                                    continuation.yield(chunk)
                                }
                            case .toolCall(let call):
                                sawToolCall = true
                                continuation.yield(.toolCall(Self.convert(call)))
                            case .info(let info):
                                continuation.yield(.usage(InferenceUsage(
                                    inputTokens: info.promptTokenCount,
                                    outputTokens: info.generationTokenCount,
                                    modelIdentifier: modelIdentifier)))
                            }
                        }
                        for chunk in parser.finish() {
                            continuation.yield(chunk)
                        }
                        if parser.sawToolCall { sawToolCall = true }
                        continuation.yield(.done(stopReason: sawToolCall ? .toolUse : .endOfTurn))
                    }
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

    static func convert(_ call: MLXLMCommon.ToolCall) -> AitvarasCore.ToolCall {
        let argsJSON: String
        if let data = try? JSONEncoder().encode(call.function.arguments) {
            argsJSON = String(decoding: data, as: UTF8.self)
        } else {
            argsJSON = "{}"
        }
        return AitvarasCore.ToolCall(
            id: "call_\(UUID().uuidString.prefix(8))",
            toolName: call.function.name,
            argumentsJSON: argsJSON)
    }
}

/// Streaming parser for Qwen3 text output: routes <think> to .reasoning
/// and — as a fallback when the library doesn't intercept them —
/// <tool_call> JSON to .toolCall. Everything else streams as .text.
struct QwenStreamParser {
    private enum Mode { case text, think, toolCall }
    private var mode: Mode = .text
    private var buffer = ""
    private var callCount = 0
    private(set) var sawToolCall = false

    private static let openTags = ["<think>", "<tool_call>"]

    mutating func consume(_ text: String) -> [InferenceChunk] {
        buffer += text
        var out: [InferenceChunk] = []
        var progress = true
        while progress {
            progress = false
            switch mode {
            case .text:
                if let found = earliestTag(in: buffer, tags: Self.openTags) {
                    let before = String(buffer[..<found.range.lowerBound])
                    if !before.isEmpty { out.append(.text(before)) }
                    buffer = String(buffer[found.range.upperBound...])
                    mode = found.tag == "<think>" ? .think : .toolCall
                    progress = true
                } else {
                    let holdback = partialTagSuffixLength(of: buffer, tags: Self.openTags)
                    let emitCount = buffer.count - holdback
                    if emitCount > 0 {
                        let idx = buffer.index(buffer.startIndex, offsetBy: emitCount)
                        out.append(.text(String(buffer[..<idx])))
                        buffer = String(buffer[idx...])
                    }
                }
            case .think:
                if let range = buffer.range(of: "</think>") {
                    let inner = String(buffer[..<range.lowerBound])
                    if !inner.isEmpty { out.append(.reasoning(inner)) }
                    buffer = String(buffer[range.upperBound...])
                    mode = .text
                    progress = true
                } else {
                    let holdback = partialTagSuffixLength(of: buffer, tags: ["</think>"])
                    let emitCount = buffer.count - holdback
                    if emitCount > 0 {
                        let idx = buffer.index(buffer.startIndex, offsetBy: emitCount)
                        out.append(.reasoning(String(buffer[..<idx])))
                        buffer = String(buffer[idx...])
                    }
                }
            case .toolCall:
                if let range = buffer.range(of: "</tool_call>") {
                    let raw = String(buffer[..<range.lowerBound])
                    buffer = String(buffer[range.upperBound...])
                    mode = .text
                    if let call = parseToolCall(raw) {
                        out.append(.toolCall(call))
                        sawToolCall = true
                    }
                    progress = true
                }
            }
        }
        return out
    }

    mutating func finish() -> [InferenceChunk] {
        var out: [InferenceChunk] = []
        switch mode {
        case .text:
            if !buffer.isEmpty { out.append(.text(buffer)) }
        case .think:
            if !buffer.isEmpty { out.append(.reasoning(buffer)) }
        case .toolCall:
            if let call = parseToolCall(buffer) {
                out.append(.toolCall(call))
                sawToolCall = true
            }
        }
        buffer = ""
        return out
    }

    private mutating func parseToolCall(_ raw: String) -> AitvarasCore.ToolCall? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        let args = json["arguments"] ?? [String: Any]()
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        callCount += 1
        return AitvarasCore.ToolCall(id: "textcall_\(callCount)", toolName: name,
                                  argumentsJSON: String(decoding: argsData, as: UTF8.self))
    }

    private func earliestTag(in text: String, tags: [String]) -> (tag: String, range: Range<String.Index>)? {
        tags.compactMap { tag in text.range(of: tag).map { (tag, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
    }

    /// If the buffer ends with a prefix of any tag, hold those characters
    /// back so a tag split across stream chunks isn't emitted as text.
    private func partialTagSuffixLength(of text: String, tags: [String]) -> Int {
        for length in stride(from: tags.map(\.count).max()! - 1, through: 1, by: -1) {
            guard text.count >= length else { continue }
            let suffix = String(text.suffix(length))
            if tags.contains(where: { $0.hasPrefix(suffix) }) { return length }
        }
        return 0
    }
}
