import Testing
import Foundation
import AitvarasCore
import AitvarasEngines

/// Real-model smoke tests — they run only when the MLX models are
/// downloaded (they are on the dev machine; CI without models skips).
@Suite struct MLXIntegrationTests {
    static var lightModelPresent: Bool {
        FileManager.default.fileExists(
            atPath: MLXEngine.modelsDirectory()
                .appendingPathComponent("Qwen3-4B-4bit/config.json").path)
    }

    @Test(.enabled(if: lightModelPresent), .timeLimit(.minutes(5)))
    func lightModelGeneratesText() async throws {
        let engine = MLXEngine()
        #expect(await engine.isAvailable(for: .voice))

        var text = ""
        var reasoning = ""
        var finished = false
        let messages = [
            ChatMessage(role: .system, content: "You are a terse assistant. No thinking needed."),
            ChatMessage(role: .user, content: "Reply with exactly the word: pong")
        ]
        for try await chunk in await engine.complete(messages: messages, tools: [], tier: .voice) {
            switch chunk {
            case .text(let t): text += t
            case .reasoning(let r): reasoning += r
            case .toolCall: break
            case .done: finished = true
            }
        }
        #expect(finished)
        #expect(text.lowercased().contains("pong"))
        // Reasoning (if any) must have been separated from text.
        #expect(!text.contains("<think>"))
        _ = reasoning
        await engine.unload(tier: .voice)
    }

    @Test(.enabled(if: lightModelPresent), .timeLimit(.minutes(5)))
    func lightModelEmitsToolCall() async throws {
        let engine = MLXEngine()
        let tool = ToolDefinition(
            name: "calendar.create_event",
            description: "Create a calendar event",
            parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"},"startISO":{"type":"string"}},"required":["title","startISO"]}"#,
            risk: .reversibleWrite)
        let messages = [
            ChatMessage(role: .system, content: "Use the available tools to fulfil requests."),
            ChatMessage(role: .user, content: "Put 'Dentist' in my calendar for 2026-07-10 at 14:00.")
        ]
        var calls: [AitvarasCore.ToolCall] = []
        for try await chunk in await engine.complete(messages: messages, tools: [tool], tier: .voice) {
            if case .toolCall(let call) = chunk { calls.append(call) }
        }
        #expect(!calls.isEmpty)
        #expect(calls.first?.toolName == "calendar.create_event")
        #expect(calls.first?.argumentsJSON.lowercased().contains("dentist") == true)
        await engine.unload(tier: .voice)
    }
}
