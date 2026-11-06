import Foundation
import Testing
import AitvarasAgents
@testable import AitvarasStore

@Suite struct ChatPresentationTests {
    @Test func firstSendRequiresVisibleProjectAndNonemptyInput() throws {
        let stores = try inMemoryStores()
        #expect(try stores.newChatProjectID() == nil)
        #expect(try stores.defaultChatProjectID() == nil)
        #expect(try stores.createChatOnFirstSend(projectID: nil, text: " ") == nil)
        #expect(throws: AgentStoreError.invalidValue) { try stores.createChatOnFirstSend(projectID: nil, text: "hello") }
        #expect(throws: AgentStoreError.invalidValue) { try stores.createChatOnFirstSend(projectID: UUID(), text: "hello") }
        let project = try stores.createWorkspaceProject(title: "Example")
        _ = try stores.newChatProjectID(requested: project.id)
        #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        #expect(try stores.createChatOnFirstSend(projectID: project.id, text: "\n ") == nil)
        let chat = try #require(try stores.createChatOnFirstSend(projectID: project.id, text: "First message"))
        #expect(chat.projectID == project.id)
        #expect(try stores.workspaceChats(projectID: project.id).map(\.id) == [chat.id])
        let attachmentChat = try #require(try stores.createChatOnFirstSend(projectID: project.id, text: "", hasAttachments: true))
        #expect(attachmentChat.title == "New chat")
        var hidden = project; hidden.isVisible = false; try stores.saveWorkspaceProject(hidden)
        #expect(throws: AgentStoreError.invalidValue) { try stores.createChatOnFirstSend(projectID: project.id, text: "hello") }
    }

    @Test func requestedThenDefaultThenMostRecentProjectAndHiddenDefaultClears() throws {
        let stores = try inMemoryStores()
        let one = try stores.createWorkspaceProject(title: "One")
        let two = try stores.createWorkspaceProject(title: "Two")
        let three = try stores.createWorkspaceProject(title: "Three")
        _ = try stores.createChatOnFirstSend(projectID: three.id, text: "Recent")
        #expect(try stores.newChatProjectID() == three.id)
        try stores.setDefaultChatProject(two.id)
        #expect(try stores.newChatProjectID() == two.id)
        #expect(try stores.newChatProjectID(requested: one.id) == one.id)
        #expect(try stores.newChatProjectID(requested: UUID()) == two.id)
        var hidden = two; hidden.isVisible = false; try stores.saveWorkspaceProject(hidden)
        #expect(try stores.defaultChatProjectID() == nil)
        #expect(try stores.value(forKey: "chat.defaultProject") == "")
        #expect(try stores.newChatProjectID() == three.id)
        #expect(throws: AgentStoreError.invalidValue) { try stores.setDefaultChatProject(UUID()) }
        try stores.setDefaultChatProject(one.id)
        try stores.setDefaultChatProject(nil)
        #expect(try stores.defaultChatProjectID() == nil)
    }

    @Test func choicesAndSeenReceiptSurviveDatabaseReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-presentation-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let projectID: UUID, chatID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, session) = try agentStoreChat(stores)
            projectID = chat.projectID; chatID = chat.id
            try stores.setDefaultChatProject(projectID)
            let turn = AgentJournalTurn(input: .init(text: "Example"), chatID: chat.id, sessionID: session.id)
            try stores.prepareAgentTurn(turn)
            try stores.finishAgentTurn(id: turn.id, state: .completed)
            try stores.markChatSeen(chatID)
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.defaultChatProjectID() == projectID)
        #expect(try reopened.newChatProjectID() == projectID)
        #expect(!((try reopened.chatHasUnseenCompletion(chatID))))
    }

    @Test func fiveRecentPlusRunningWaitingAndSelectionRegardlessOfAge() {
        let project = UUID()
        var chats = (0..<10).map { index in
            WorkspaceChat(projectID: project, localConversationID: UUID(), title: "Chat \(index)",
                          lastActivityAt: Date(timeIntervalSince1970: Double(index)))
        }
        chats[0].archivedAt = .now
        let statuses: [UUID: ChatSidebarStatus] = [chats[0].id: .running, chats[1].id: .needsYou, chats[2].id: .failed]
        let visible = ProjectChatVisibility.visible(chats.reversed(), statuses: statuses, selectedID: nil, expanded: false)
        #expect(visible.map(\.id) == [9, 8, 7, 6, 5, 1, 0].map { chats[$0].id })
        #expect(ProjectChatVisibility.visible(chats, statuses: statuses, selectedID: chats[3].id, expanded: false).contains { $0.id == chats[3].id })
        #expect(ProjectChatVisibility.visible(chats, statuses: statuses, selectedID: nil, expanded: true).count == 10)
    }

    @Test func persistedSeenReceiptOnlyClearsCompletedTurnAndSurvivesReopen() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        var state = ChatState(chatID: chat.id)
        func newTurn() throws -> AgentJournalTurn {
            let turn = AgentJournalTurn(input: .init(text: "Example"), chatID: chat.id, sessionID: session.id)
            try stores.prepareAgentTurn(turn)
            return turn
        }
        #expect(!((try stores.chatHasUnseenCompletion(chat.id))))
        let first = try newTurn()
        try stores.markChatSeen(chat.id) // Watching a run does not acknowledge its future completion.
        try stores.finishAgentTurn(id: first.id, state: .completed)
        state.end(.completed)
        #expect(ChatSidebarStatus(state, unseen: try stores.chatHasUnseenCompletion(chat.id)) == .finishedUnseen)
        try stores.markChatSeen(chat.id)
        let reopened = Stores(db: stores.db)
        #expect(!((try reopened.chatHasUnseenCompletion(chat.id))))
        #expect(ChatSidebarStatus(state, unseen: try reopened.chatHasUnseenCompletion(chat.id)) == .idle)
        let next = try newTurn()
        try stores.finishAgentTurn(id: next.id, state: .completed)
        // The visible-chat observer acknowledges the completion as it arrives.
        try stores.markChatSeen(chat.id)
        #expect(!((try stores.chatHasUnseenCompletion(chat.id))))
        let failed = try newTurn()
        try stores.finishAgentTurn(id: failed.id, state: .failed)
        state.end(.failed(.unknown))
        #expect(ChatSidebarStatus(state, unseen: true) == .failed)
        #expect(!((try stores.chatHasUnseenCompletion(chat.id))))
        let interrupted = try newTurn()
        try stores.finishAgentTurn(id: interrupted.id, state: .interrupted)
        state.end(.interrupted)
        #expect(ChatSidebarStatus(state, unseen: true) == .interrupted)
        #expect(!((try stores.chatHasUnseenCompletion(chat.id))))
        let later = try newTurn()
        try stores.finishAgentTurn(id: later.id, state: .completed)
        #expect(try stores.chatHasUnseenCompletion(chat.id))
    }
}
