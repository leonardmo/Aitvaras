import Foundation
import AitvarasCore
import AitvarasEngines

/// Headless verification (`Aitvaras.app/Contents/MacOS/Aitvaras --selftest`):
/// exercises the real MLX path inside the app bundle, where the Metal
/// library is available (CLI `swift test` can't load it — mlx-swift
/// requires xcodebuild-built bundles for GPU code).
enum SelfTest {
    static var requested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    static func run() async -> Never {
        print("[selftest] starting")
        let engine = MLXEngine()
        guard await engine.isAvailable(for: .voice) else {
            print("[selftest] FAIL: light model not on disk")
            exit(1)
        }
        do {
            var text = ""
            var sawThinkTagInText = false
            let messages = [
                ChatMessage(role: .system, content: "You are a terse assistant."),
                ChatMessage(role: .user, content: "Reply with exactly the word: pong")
            ]
            let start = Date()
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .voice) {
                if case .text(let t) = chunk {
                    text += t
                    if t.contains("<think>") { sawThinkTagInText = true }
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            print("[selftest] response (\(String(format: "%.1f", elapsed))s): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")

            // Tool-call path
            let tool = ToolDefinition(
                name: "calendar_create_event",
                description: "Create a calendar event",
                parametersJSON: #"{"type":"object","properties":{"title":{"type":"string"},"startISO":{"type":"string"}},"required":["title","startISO"]}"#,
                risk: .reversibleWrite)
            var toolName = ""
            var toolArgs = ""
            for try await chunk in await engine.complete(
                messages: [
                    ChatMessage(role: .system, content: "Use the available tools."),
                    ChatMessage(role: .user, content: "Put 'Dentist' in my calendar for 2026-07-10 14:00.")
                ],
                tools: [tool], tier: .voice
            ) {
                if case .toolCall(let call) = chunk {
                    toolName = call.toolName
                    toolArgs = call.argumentsJSON
                }
            }
            print("[selftest] tool call: \(toolName) \(toolArgs)")

            let ok = text.lowercased().contains("pong")
                && !sawThinkTagInText
                && toolName == "calendar_create_event"
                && toolArgs.lowercased().contains("dentist")
            print(ok ? "[selftest] PASS" : "[selftest] FAIL")
            exit(ok ? 0 : 1)
        } catch {
            print("[selftest] FAIL: \(error)")
            exit(1)
        }
    }
}
