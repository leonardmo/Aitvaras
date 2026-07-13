import Testing
import Foundation
@testable import AitvarasEngines
@testable import AitvarasAgent
import AitvarasStore
import AitvarasCore

@Suite struct EngineParserTests {
    private func collect(_ chunks: [String]) -> [InferenceChunk] {
        var parser = QwenStreamParser()
        var out: [InferenceChunk] = []
        for chunk in chunks { out += parser.consume(chunk) }
        out += parser.finish()
        return out
    }

    private func text(_ chunks: [InferenceChunk]) -> String {
        chunks.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    private func reasoning(_ chunks: [InferenceChunk]) -> String {
        chunks.compactMap { if case .reasoning(let t) = $0 { t } else { nil } }.joined()
    }

    @Test func plainTextPassesThrough() {
        let out = collect(["Hello ", "world."])
        #expect(text(out) == "Hello world.")
        #expect(reasoning(out).isEmpty)
    }

    @Test func thinkBlockIsSeparated() {
        let out = collect(["<think>pondering", " deeply</think>", "Answer."])
        #expect(reasoning(out) == "pondering deeply")
        #expect(text(out) == "Answer.")
    }

    @Test func tagSplitAcrossChunksIsNotLeaked() {
        // "<thi" + "nk>...</think>" must not emit "<thi" as text.
        let out = collect(["<thi", "nk>hidden</think>Visible"])
        #expect(text(out) == "Visible")
        #expect(reasoning(out) == "hidden")
    }

    @Test func toolCallParsedFromText() {
        let out = collect([
            "I'll check.", "<tool_call>\n{\"name\": \"calendar.list_events\", ",
            "\"arguments\": {\"startISO\": \"2026-07-04\"}}\n</tool_call>"
        ])
        let calls = out.compactMap { if case .toolCall(let c) = $0 { c } else { nil } }
        #expect(calls.count == 1)
        #expect(calls.first?.toolName == "calendar.list_events")
        #expect(calls.first?.argumentsJSON.contains("2026-07-04") == true)
        #expect(text(out) == "I'll check.")
    }

    @Test func unterminatedThinkFlushesAsReasoning() {
        let out = collect(["<think>never closed"])
        #expect(reasoning(out) == "never closed")
        #expect(text(out).isEmpty)
    }

    @Test func promptBuilderIncludesMemoriesAndVoiceRules() {
        let prompt = PromptBuilder.systemPrompt(
            memories: [.init(content: "Studies at TUM", category: "fact")],
            retrieved: [.init(text: "chunk body", origin: "studium/notes.md § Intro", score: 1)],
            voiceMode: true)
        #expect(prompt.contains("Studies at TUM"))
        #expect(prompt.contains("studium/notes.md"))
        #expect(prompt.contains("VOICE"))
    }

    @Test func unkeptPromiseDetection() {
        #expect(AgentLoop.soundsLikeUnkeptPromise("I will set a reminder for you."))
        #expect(AgentLoop.soundsLikeUnkeptPromise("Let me create an entry for that."))
        #expect(AgentLoop.soundsLikeUnkeptPromise("Ich werde das gleich prüfen."))
        #expect(!AgentLoop.soundsLikeUnkeptPromise("Done — the reminder is set for tomorrow at nine."))
        #expect(!AgentLoop.soundsLikeUnkeptPromise("You have three meetings tomorrow."))
    }

    @Test func speechSanitizerStripsMarkdownAndSymbols() {
        let raw = "- **Seminar Vorbesprechung**: 08:30 - 09:30 Uhr (Online), see https://moodle.example.edu/x#4 & mail me @ user"
        let clean = ConversationController.sanitizeForSpeech(raw)
        #expect(!clean.contains("*"))
        #expect(!clean.contains("#"))
        #expect(!clean.contains("https"))
        #expect(!clean.contains("&"))
        #expect(clean.contains("Seminar Vorbesprechung"))
        #expect(clean.contains("08:30"))
        #expect(clean.contains(" at "))
    }

    @Test func sentenceExtractionForTTS() {
        var buffer = "Das ist ein Satz. Und hier"
        let first = AitvarasVoiceSentenceProxy.extract(&buffer)
        #expect(first?.hasPrefix("Das ist ein Satz.") == true)
        #expect(buffer == " Und hier")
        #expect(AitvarasVoiceSentenceProxy.extract(&buffer) == nil)
    }
}

@testable import AitvarasVoice

enum AitvarasVoiceSentenceProxy {
    static func extract(_ buffer: inout String) -> String? {
        ConversationController.extractSentence(from: &buffer)
    }
}
