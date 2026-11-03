import Foundation
import Testing
import AitvarasCore
import AitvarasStore

@Suite struct WorkspaceChatTimelineTests {
    private func session(_ stores: Stores, chat: WorkspaceChat) throws -> WorkspaceFrontierSession {
        let review = try stores.workspacePolicyReview(projectID: chat.projectID)
        let policy = try stores.reviewWorkspacePolicy(projectID: chat.projectID,
            allowedProviders: [.codex], expectedRevision: review.revision)
        return try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: policy.revision,
            reviewedContext: stores.workspaceContextPacket(chatID: chat.id).promptText)
    }

    private func turn(_ stores: Stores, session: WorkspaceFrontierSession, prompt: String,
                      output: String, state: WorkspaceFrontierTurnState = .completed) throws -> WorkspaceFrontierTurn {
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: prompt)
        turn.state = .running
        turn.providerTurnID = "synthetic-\(turn.id.uuidString)"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.state = state
        turn.outputText = output
        turn.endedAt = state.isTerminal ? .now : nil
        try stores.saveWorkspaceFrontierTurn(turn)
        return turn
    }

    @Test func mergesOnlySelectedChatAcrossOwnedSessionsWithoutChangingSources() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Same title")
        let other = try stores.createWorkspaceChat(projectID: project.id, title: "Same title")
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Local input",
            createdAt: Date(timeIntervalSince1970: 1)))
        try stores.appendMessage(.init(conversationID: other.localConversationID, role: "assistant", content: "OTHER_CHAT"))
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "system", content: "SYSTEM"))
        let first = try session(stores, chat: chat)
        let firstTurn = try turn(stores, session: first, prompt: "Owned input", output: "Owned answer")
        let second = try session(stores, chat: chat)
        let secondTurn = try turn(stores, session: second, prompt: "Uncertain input", output: "Partial", state: .outcomeUnknown)
        let timeline = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(timeline.count == 5)
        #expect(timeline.first?.text == "Local input")
        #expect(Set(timeline.compactMap(\.sourceTurnID)) == [firstTurn.id, secondTurn.id])
        #expect(timeline.filter { $0.sourceTurnID == secondTurn.id }.allSatisfy { $0.state == .outcomeUnknown })
        #expect(Set(timeline.map(\.id)).count == timeline.count)
        #expect(timeline.contains { $0.id == "codex:\(firstTurn.id.uuidString):user" })
        #expect(timeline.contains { $0.id == "codex:\(firstTurn.id.uuidString):assistant" })
        #expect(try stores.workspaceChatTimeline(chatID: chat.id) == timeline)
        #expect(try stores.workspaceChatTimeline(chatID: chat.id, limit: 2) == Array(timeline.suffix(2)))
        #expect(try stores.workspaceChatTimeline(chatID: chat.id, limit: 0).isEmpty)
        #expect(try stores.messages(in: chat.localConversationID).count == 2)
        let history = try stores.workspaceChatHistoryText(chatID: chat.id)
        #expect(history.contains("[user / local]\nLocal input"))
        #expect(history.contains("Owned answer"))
        #expect(!history.contains("Uncertain input") && !history.contains("Partial") && !history.contains("OTHER_CHAT"))
    }

    @Test func importedNativeTranscriptIsNeverIncluded() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let page = NativeTranscriptPage(session: .init(provider: .codex, externalID: "synthetic-import",
            title: "Synthetic chat", directory: "/synthetic/project"),
            messages: [.init(externalID: "synthetic-message", role: .assistant, text: "IMPORTED_CANARY")],
            nextCursor: nil, coverage: "Synthetic coverage", direction: .newer)
        let chat = try stores.importWorkspaceNativeSession(pages: [page], projectID: project.id, reviewed: true)
        #expect(try stores.workspaceChatTimeline(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceChatHistoryText(chatID: chat.id).isEmpty)
    }

    @Test func equalTurnTimestampsKeepUserBeforeAssistantAndLatestLimit() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic chat")
        let owned = try session(stores, chat: chat)
        var saved = try stores.beginWorkspaceFrontierTurn(sessionID: owned.id, prompt: "Synthetic question")
        saved.state = .running
        saved.providerTurnID = "synthetic-provider-turn"
        try stores.saveWorkspaceFrontierTurn(saved)
        saved.state = .completed
        saved.outputText = "Synthetic answer"
        saved.endedAt = saved.startedAt
        try stores.saveWorkspaceFrontierTurn(saved)
        let timeline = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(timeline.map(\.role) == ["user", "assistant"])
        #expect(timeline.first?.timestamp == timeline.last?.timestamp)
        #expect(try stores.workspaceChatTimeline(chatID: chat.id, limit: 1) == Array(timeline.suffix(1)))
    }

    @Test func historyIsDeterministicallyBoundedAndExcludesEveryIncompleteOutcome() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic chat")
        let states: [WorkspaceFrontierTurnState] = [.failed, .cancelled, .outcomeUnknown, .running]
        for state in states {
            let owned = try session(stores, chat: chat)
            _ = try turn(stores, session: owned, prompt: "UNCERTAIN_\(state.rawValue)", output: "PARTIAL", state: state)
        }
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "assistant",
            content: String(repeating: "界", count: 100)))
        for maximum in [0, 1, 20, 40, 200] {
            let history = try stores.workspaceChatHistoryText(chatID: chat.id, maximumCharacters: maximum)
            #expect(history.count <= maximum)
            #expect(!history.contains("UNCERTAIN") && !history.contains("PARTIAL"))
            #expect(history == (try stores.workspaceChatHistoryText(chatID: chat.id, maximumCharacters: maximum)))
        }
        #expect(try stores.workspaceChatHistoryText(chatID: chat.id, maximumCharacters: 40).hasSuffix("…"))
    }
}
