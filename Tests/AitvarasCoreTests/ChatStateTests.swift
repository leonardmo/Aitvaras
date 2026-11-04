import Foundation
import Testing
import AitvarasAgents

@Suite struct ChatStateTests {
    @Test func selectionRestoresProviderKeepsDraftsAndDoesNotCommitFailedWrites() throws {
        let first = UUID(), second = UUID()
        var state = ChatSelectionState()
        state.select(first, provider: .claude)
        state.draft = "first draft"
        state.select(second, provider: .local)
        #expect(state.draft.isEmpty)
        state.draft = "second draft"
        #expect(throws: AgentFailure.unknown) {
            try state.select(first, provider: .codex) { throw AgentFailure.unknown }
        }
        #expect(state.chatID == second)
        #expect(state.provider == .local)
        #expect(state.draft == "second draft")
        state.select(first, provider: .codex)
        #expect(state.draft == "first draft")
        state.clearDraft(chatID: second, ifUnchanged: "old draft")
        state.select(second, provider: .local)
        #expect(state.draft == "second draft")
        state.clearDraft(chatID: first, ifUnchanged: "first draft")
        state.select(first, provider: .codex)
        #expect(state.draft.isEmpty)
    }

    @Test func originalMessageIdentitySurvivesWireEchoAndHandoverIsSeparate() throws {
        let chat = UUID(), output = UUID()
        let input = AgentInput(text: "original")
        let session = AgentChatSession(chatID: chat, provider: .codex, cwd: "/tmp", model: "fixture")
        let earlier = AgentTranscriptEntry(chatID: chat, provider: .local, kind: "assistant", text: "earlier")
        let context = try #require(ChatContextProjection.make(entries: [earlier], provider: .codex))
        var state = ChatState(chatID: chat)
        state.begin(input, session: session, outputID: output, context: context)
        #expect(state.entries.map(\.kind) == ["handover", "user"])
        let scope = AgentEventScope(runID: UUID(), inputID: input.id)
        for _ in 0..<2 {
            state.reduce(.init(scope: scope, kind: .message(id: "native-input", role: "user", text: context.wire(message: input.text))), newEntryID: UUID())
        }
        state.reduce(.init(scope: scope, kind: .textDelta("hello")), newEntryID: UUID())
        state.reduce(.init(scope: scope, kind: .textDelta(" world")), newEntryID: UUID())
        #expect(state.entries.filter { $0.kind == "user" }.map(\.text) == ["original"])
        #expect(state.entries.last?.id == output)
        #expect(state.entries.last?.text == "hello world")
        state.end(.interrupted)
        let restored = ChatState(chatID: chat, entries: state.entries)
        #expect(restored.entries == state.entries)
    }

    @Test func testProviderSeamRequiresIsolationAndLeavesLegacyGuardsIntact() {
        let disabled = ["AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS": "1", "AITVARAS_UI_TEST_MODE": "1"]
        #expect(!AgentProviderLaunchPolicy.allowsProviders(environment: disabled, isolated: true))
        var real = disabled
        real["AITVARAS_AGENT_TEST_PROVIDERS"] = "real"
        #expect(AgentProviderLaunchPolicy.allowsProviders(environment: real, isolated: true))
        #expect(!AgentProviderLaunchPolicy.allowsProviders(environment: real, isolated: false))
        #expect(AgentProviderLaunchPolicy.isTestConfiguration(environment: real, isolated: true))
        let fake = ["AITVARAS_FAKE_CLAUDE": "/tmp/fake-claude", "AITVARAS_UI_TEST_MODE": "1"]
        #expect(AgentProviderLaunchPolicy.allowsProviders(environment: fake, isolated: true))
        #expect(AgentProviderLaunchPolicy.allows(.claude, environment: fake, isolated: true))
        #expect(!AgentProviderLaunchPolicy.allows(.codex, environment: fake, isolated: true))
        #expect(AgentProviderLaunchPolicy.executable(.claude, environment: fake, isolated: true)?.path == "/tmp/fake-claude")
        #expect(AgentProviderLaunchPolicy.executable(.claude, environment: fake, isolated: false) == nil)
        #expect(AgentProviderLaunchPolicy.allowsProviders(environment: [:], isolated: false))
    }
}
