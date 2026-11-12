import Foundation
import Testing
import AitvarasAgents
import AitvarasStore

@Suite struct ChatSettingsTests {
    @Test func perChatAndProviderChoicesSurviveReloadWithoutSending() throws {
        let stores = try inMemoryStores()
        let (one, original) = try agentStoreChat(stores)
        let (two, second) = try agentStoreChat(stores)
        let model = AgentModel(id: "test-model", name: "Test model", efforts: ["low", "high"])
        var changed = ChatSettings.selecting(model: model, in: original)
        changed.effort = "high"; changed.mode = .plan
        try stores.saveAgentSession(changed)
        let codex = AgentChatSession(chatID: one.id, provider: .codex, cwd: "/tmp", model: "other-model")
        try stores.saveAgentSession(codex)
        var selection = ChatSelectionState()
        selection.select(one.id, provider: .claude); selection.draft = "kept"
        try selection.select(one.id, provider: .codex) {
            try stores.setValue("codex", forKey: "agent.provider.\(one.id)")
        }
        #expect(selection.draft == "kept")
        #expect(try stores.agentSession(chatID: one.id, provider: .claude) == changed)
        #expect(try stores.agentSession(chatID: two.id, provider: .claude) == second)
        #expect(try stores.agentSession(chatID: one.id, provider: .codex) == codex)
        #expect(try stores.value(forKey: "agent.provider.\(one.id)") == "codex")
        #expect(try stores.latestAgentTurn(chatID: one.id) == nil)
        #expect(try stores.agentEntries(chatID: one.id).isEmpty)
    }

    @Test func providerSwitchAndChatSwitchRestoreUsableModelsBeforeSend() async throws {
        let stores = try inMemoryStores()
        let (one, claude) = try agentStoreChat(stores)
        let (two, _) = try agentStoreChat(stores)
        let codexModels = [AgentModel(id: "codex-model", name: "Codex model", efforts: ["low"])]
        let received = SettingsSendRecorder()
        let backend = LocalBackend { configuration, _ in
            await received.record(configuration.model)
            return AsyncThrowingStream { $0.yield("Answer"); $0.finish() }
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        var selection = ChatSelectionState()
        selection.select(one.id, provider: .claude)
        // Reproduce a provider switch with the other provider's saved ID.
        var codex = AgentChatSession(chatID: one.id, provider: .codex, cwd: "/tmp", model: claude.model, effort: "high")
        selection.select(one.id, provider: .codex)
        codex = ChatSettings.restoring(codex, models: codexModels)
        #expect(codex.model == "codex-model")
        #expect(codex.effort == nil)
        try await manager.configure(codex)
        try await manager.send(chatID: one.id, provider: selection.provider, input: .init(text: "After provider switch"))
        try await waitSettingsTurn(manager, chatID: one.id)
        // Reload a stale/default selection after visiting another chat, using
        // the already cached provider catalog rather than fetching it again.
        selection.select(two.id, provider: .claude)
        var saved = try #require(try stores.agentSession(chatID: one.id, provider: .codex))
        saved.model = "default"; try stores.saveAgentSession(saved)
        selection.select(one.id, provider: .codex)
        let restored = ChatSettings.restoring(try #require(try stores.agentSession(chatID: one.id, provider: .codex)), models: codexModels)
        try await manager.configure(restored)
        try await manager.send(chatID: one.id, provider: selection.provider, input: .init(text: "After chat switch"))
        try await waitSettingsTurn(manager, chatID: one.id)
        #expect(await received.models == ["codex-model", "codex-model"])
        #expect(ChatSettings.restoring(restored, models: []).model == "codex-model")
        #expect(ChatSettings.restoring(saved, models: codexModels, automaticallySelect: false).model == "default")
        try await manager.shutdown()
    }

    @Test func modelChangeClearsUnsupportedEffortAndPreservesLocalMode() {
        var session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "old", effort: "high", mode: .plan)
        let plain = AgentModel(id: "plain", name: "Plain")
        #expect(ChatSettings.selecting(model: plain, in: session).effort == nil)
        let supported = AgentModel(id: "next", name: "Next", efforts: ["high"])
        #expect(ChatSettings.selecting(model: supported, in: session).effort == "high")
        session.provider = .local
        let local = ChatSettings.selecting(model: supported, in: session)
        #expect(local.effort == nil)
        #expect(local.mode == .plan)
        #expect(ChatSettings.contextFraction(nil) == nil)
        #expect(ChatSettings.contextFraction(.init(scope: .turn, contextTokens: 5, contextLimit: 0)) == nil)
        #expect(ChatSettings.contextFraction(.init(scope: .turn, contextTokens: 25, contextLimit: 100)) == 0.25)
    }

    @Test func renamePinArchiveAndRestoreKeepMessagesAndIdentity() throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores)
        let entry = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "Saved reply", sessionID: session.id))
        chat.title = "Renamed chat"; chat.kind = .primary
        try stores.saveWorkspaceChat(chat)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        #expect(try stores.workspaceChats(projectID: chat.projectID).isEmpty)
        #expect(try stores.workspaceChats(projectID: chat.projectID, includeArchived: true).first?.title == "Renamed chat")
        try stores.setWorkspaceChatArchived(id: chat.id, archived: false)
        #expect(try stores.workspaceChats(projectID: chat.projectID).first?.kind == .primary)
        #expect(try stores.agentSession(chatID: chat.id, provider: .claude) == session)
        #expect(try stores.agentEntries(chatID: chat.id) == [entry])
    }

    @Test func newProviderUsesLastChoiceThenLocalThenSignedIn() {
        let statuses: [AgentProvider: AgentStatus] = [
            .claude: .init(installed: true, authentication: .signedOut, capabilities: []),
            .codex: .init(installed: true, authentication: .subscription, capabilities: [])
        ]
        #expect(ChatSettings.newProvider(lastUsed: nil, localAvailable: true, statuses: statuses) == .local)
        #expect(ChatSettings.newProvider(lastUsed: nil, localAvailable: false, statuses: statuses) == .codex)
        #expect(ChatSettings.newProvider(lastUsed: .claude, localAvailable: false, statuses: statuses) == .claude)
        #expect(ChatSettings.newProvider(lastUsed: nil, localAvailable: false, statuses: [:]) == .local)
    }

    @Test func sidebarPrioritizesRequestsThenRunningThenFailure() {
        var state = ChatState(chatID: UUID())
        #expect(ChatSidebarStatus(state) == .idle)
        state.begin(.init(text: "hello"), session: .init(chatID: state.chatID, provider: .local, cwd: "/tmp", model: "local"), outputID: UUID())
        #expect(ChatSidebarStatus(state) == .running)
        state.pendingCards = [.init(id: .string("permission"), scope: .init(runID: UUID()),
                                    kind: .permission(.init(name: "test-tool", input: .object([:]))))]
        #expect(ChatSidebarStatus(state) == .needsYou)
        state.end(.failed(.offline))
        #expect(ChatSidebarStatus(state) == .failed)
    }
}

private actor SettingsSendRecorder {
    private(set) var models: [String] = []
    func record(_ model: String) { models.append(model) }
}
private func waitSettingsTurn(_ manager: AgentSessionManager, chatID: UUID) async throws {
    for _ in 0..<200 {
        if try await manager.state(chatID: chatID).outcome == .completed { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
