import Foundation
import AitvarasCore

/// Fallback engine (D2): talks to a local Ollama daemon. Works with the
/// models the user already has pulled (qwen3:30b) and needs zero setup.
public actor OllamaEngine: InferenceEngine {
    public let identifier = "ollama"

    private let baseURL: URL
    /// Fallback engine: one model for every role.
    private let model: String
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
                model: String = "qwen3:30b") {
        self.baseURL = baseURL
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    public func isAvailable(for tier: ModelTier) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        let wanted = model
        return models.contains { ($0["name"] as? String)?.hasPrefix(wanted) == true }
    }

    public func complete(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        tier: ModelTier
    ) -> AsyncThrowingStream<InferenceChunk, Error> {
        let modelName = model
        let baseURL = baseURL
        let session = session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": modelName,
                        "stream": true,
                        "messages": messages.map { m -> [String: Any] in
                            var dict: [String: Any] = ["role": m.role.rawValue, "content": m.content]
                            if m.role == .tool, let id = m.toolCallID { dict["tool_name"] = id }
                            return dict
                        }
                    ]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { tool -> [String: Any] in
                            let params = (try? JSONSerialization.jsonObject(
                                with: Data(tool.parametersJSON.utf8))) ?? [String: Any]()
                            return [
                                "type": "function",
                                "function": [
                                    "name": tool.name,
                                    "description": tool.description,
                                    "parameters": params
                                ]
                            ]
                        }
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw NSError(domain: "OllamaEngine", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Ollama returned status \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                        ])
                    }

                    var inThink = false
                    var sawToolCall = false
                    var toolCallCounter = 0

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        if let message = json["message"] as? [String: Any] {
                            if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                                continuation.yield(.reasoning(thinking))
                            }
                            if let calls = message["tool_calls"] as? [[String: Any]] {
                                for call in calls {
                                    guard let fn = call["function"] as? [String: Any],
                                          let name = fn["name"] as? String else { continue }
                                    let args = fn["arguments"] ?? [String: Any]()
                                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                                    toolCallCounter += 1
                                    sawToolCall = true
                                    continuation.yield(.toolCall(ToolCall(
                                        id: "call_\(toolCallCounter)",
                                        toolName: name,
                                        argumentsJSON: String(decoding: argsData, as: UTF8.self))))
                                }
                            }
                            if var content = message["content"] as? String, !content.isEmpty {
                                // Some models emit <think> inline instead of the thinking field.
                                while !content.isEmpty {
                                    if inThink {
                                        if let end = content.range(of: "</think>") {
                                            continuation.yield(.reasoning(String(content[..<end.lowerBound])))
                                            content = String(content[end.upperBound...])
                                            inThink = false
                                        } else {
                                            continuation.yield(.reasoning(content)); content = ""
                                        }
                                    } else if let start = content.range(of: "<think>") {
                                        let before = String(content[..<start.lowerBound])
                                        if !before.isEmpty { continuation.yield(.text(before)) }
                                        content = String(content[start.upperBound...])
                                        inThink = true
                                    } else {
                                        continuation.yield(.text(content)); content = ""
                                    }
                                }
                            }
                        }
                        if (json["done"] as? Bool) == true {
                            continuation.yield(.done(stopReason: sawToolCall ? .toolUse : .endOfTurn))
                        }
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
}
