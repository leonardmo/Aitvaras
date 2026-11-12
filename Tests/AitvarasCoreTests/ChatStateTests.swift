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

    @Test func unsavedDraftNeverLeaksIntoAnotherChatsComposer() {
        var selection = ChatSelectionState()
        selection.draft = "Unsent project draft"
        selection.select(nil, provider: .claude)
        #expect(selection.draft == "Unsent project draft")
        let saved = UUID()
        selection.select(saved, provider: .local)
        #expect(selection.draft.isEmpty)
        selection.draft = "Saved chat draft"
        selection.select(nil, provider: .codex)
        #expect(selection.draft == "Unsent project draft")
        selection.draft = ""
        selection.select(saved, provider: .local)
        #expect(selection.draft == "Saved chat draft")
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

    @Test(arguments: [AgentProvider.claude, .codex], ["tool", "delta", "message"])
    func laterWorkClosesEarlierToolsWithoutClaimingSuccess(provider: AgentProvider, progress: String) throws {
        let chat = UUID(), run = UUID()
        let input = AgentInput(text: "Run example commands")
        let session = AgentChatSession(chatID: chat, provider: provider, cwd: "/tmp", model: "fixture")
        var state = ChatState(chatID: chat)
        state.begin(input, session: session, outputID: UUID())
        func scope(_ item: String, inputID: UUID? = nil) -> AgentEventScope {
            .init(runID: run, inputID: inputID ?? input.id, turnID: "turn", itemID: item)
        }
        let tool = AgentTool(name: "Bash", input: .object(["command": .string("touch example.txt")]))
        state.reduce(.init(scope: scope("approved"), kind: .toolStarted(tool)), newEntryID: UUID())
        let approvedRow = try #require(state.entries.last?.id)
        state.pendingCards = [.init(id: .string("approval"), scope: scope("approved"), kind: .permission(tool))]
        // Another tool starts while the first still awaits approval.
        state.reduce(.init(scope: scope("pending"), kind: .toolStarted(tool)), newEntryID: UUID())
        #expect(state.tools.allSatisfy { !$0.isFinished })
        let pending = AgentRequest(id: .string("pending-approval"), scope: scope("pending"), kind: .permission(tool))
        // The first approval was answered; only the second remains pending.
        state.pendingCards = [pending]
        state.reduce(.init(scope: scope("approved"), kind: .toolStarted(tool)), newEntryID: UUID())
        #expect(state.tools.allSatisfy { !$0.isFinished })
        state.reduce(.init(scope: scope("stale", inputID: UUID()), kind: .textDelta("stale")), newEntryID: UUID())
        #expect(state.tools.allSatisfy { !$0.isFinished })

        let kind: AgentEvent.Kind = progress == "tool" ? .toolStarted(tool)
            : progress == "delta" ? .textDelta("Continuing")
            : .message(id: "reply", role: "assistant", text: "Continuing")
        state.reduce(.init(scope: scope("later"), kind: kind), newEntryID: UUID())
        #expect(state.isRunning)
        #expect(state.outcome == nil)
        #expect(state.pendingCards == [pending])
        #expect(state.tools.first?.isFinished == true)
        #expect(state.tools.first?.completionUnconfirmed == true)
        #expect(state.tools.first?.isError == false)
        #expect(state.tools.first { $0.id == "pending" }?.isFinished == false)
        if progress == "tool" { #expect(state.tools.last?.isFinished == false) }
        let row = try #require(state.entries.first { $0.id == approvedRow })
        let payload = try #require(row.payloadJSON.flatMap(JSONValue.parse))
        #expect(payload["finished"] == .bool(true))
        #expect(payload["completionUnconfirmed"] == .bool(true))
        #expect(row.presentationIdentifier == "chat.tool.unconfirmed")
        #expect(AgentActionPresentation.toolSummary(tool, finished: true, isError: false,
            completionUnconfirmed: true, turnCompletedNormally: payload["turnCompletedNormally"]?.boolValue == true)
            == "touch example.txt")
        let restored = try JSONDecoder().decode(AgentTranscriptEntry.self, from: JSONEncoder().encode(row))
        #expect(restored == row)

        // Late streamed output remains available before the authoritative result.
        state.reduce(.init(scope: scope("approved"), kind: .toolOutput(.string("late output"))), newEntryID: UUID())
        #expect(state.tools.first?.output == .string("late output"))
        state.reduce(.init(scope: scope("approved"), kind: .toolFinished(output: .null, isError: false)), newEntryID: UUID())
        let confirmed = try #require(state.entries.first { $0.id == approvedRow })
        #expect(confirmed.presentationIdentifier == "chat.tool.completed")
        #expect(state.tools.first?.completionUnconfirmed == false)
        #expect(state.tools.first?.output == .string("late output"))

        state.pendingCards = []
        state.reduce(.init(scope: scope("reply"), kind: .textDelta("Done")), newEntryID: UUID())
        #expect(state.tools.first { $0.id == "pending" }?.completionUnconfirmed == true)
        state.reduce(.init(scope: scope("pending"), kind: .toolFinished(output: .string("command failed"), isError: true)), newEntryID: UUID())
        let failed = try #require(state.tools.first { $0.id == "pending" })
        #expect(failed.isFinished)
        #expect(failed.isError)
        #expect(!failed.completionUnconfirmed)
        let failedRow = try #require(state.entries.first { $0.payloadJSON.flatMap(JSONValue.parse)?["itemID"] == .string("pending") })
        #expect(failedRow.presentationIdentifier != "chat.tool.completed")
        #expect(failedRow.presentationIdentifier != "chat.tool.unconfirmed")
        #expect(AgentActionPresentation.toolSummary(tool, finished: failed.isFinished, isError: failed.isError,
            completionUnconfirmed: failed.completionUnconfirmed) == "Failed to run touch example.txt")
        #expect(state.entries.first { $0.id == approvedRow } == confirmed)
        #expect(state.entries.filter { $0.kind == "tool" }.count == (progress == "tool" ? 3 : 2))
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
