import Foundation
import Testing
import GRDB
import AitvarasAgents
@testable import AitvarasStore

@Suite struct AgentChatStoreTests {
    @Test func freshDatabaseIdentitySettingsAndEntries() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let store = AgentChatStore(db: stores.db)
        #expect(try store.session(chatID: chat.id, provider: .claude) == session)
        var changed = session
        changed.cwd = "/tmp/other"; changed.model = "other"; changed.effort = "high"; changed.mode = .plan
        changed.sessionID = .init(provider: .claude, profile: "fixture", nativeID: "native-first")
        try store.saveSession(changed)
        changed.sessionID = .init(provider: .claude, profile: "fixture", nativeID: "native-second")
        try store.saveSession(changed)
        #expect(try store.session(chatID: chat.id, provider: .claude) == changed)
        let first = try store.saveEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "one",
                                             sessionID: session.id, nativeMessageID: "message-one"))
        let duplicate = try store.saveEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant", text: "updated",
                                                 sessionID: session.id, nativeMessageID: "message-one"))
        #expect(first.id == duplicate.id)
        #expect(duplicate.position == 0)
        _ = try store.saveEntry(.init(chatID: chat.id, provider: .claude, kind: "tool", payloadJSON: "{}"))
        #expect(try store.entries(chatID: chat.id).map(\.position) == [0, 1])
        #expect(try stores.workspaceChat(id: chat.id)?.localConversationID == chat.localConversationID)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }
    @Test func duplicateNativeSessionAndCrossChatWritesAreRejected() throws {
        let stores = try inMemoryStores()
        let (one, original) = try agentStoreChat(stores)
        let (two, other) = try agentStoreChat(stores)
        let store = AgentChatStore(db: stores.db)
        var first = original; first.sessionID = .init(provider: .claude, profile: "test", nativeID: "same")
        var second = other; second.sessionID = first.sessionID
        try store.saveSession(first)
        #expect(throws: (any Error).self) { try store.saveSession(second) }
        second.sessionID = .init(provider: .claude, profile: "other-profile", nativeID: "same")
        try store.saveSession(second)
        #expect(throws: AgentStoreError.identityConflict) {
            try store.saveEntry(.init(chatID: two.id, provider: .claude, kind: "assistant", sessionID: first.id))
        }
        let entry = try store.saveEntry(.init(chatID: one.id, provider: .claude, kind: "user"))
        var moved = entry; moved.chatID = two.id
        #expect(throws: AgentStoreError.identityConflict) { try store.saveEntry(moved) }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try AgentTranscriptEntry(chatID: UUID(), provider: .claude, kind: "user").insert($0) }
        }
    }
    @Test func upgradesPreserveLegacyChatAndConversation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-migration-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var chatID: UUID!; var conversationID: UUID!; var legacyID: UUID!
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, _) = try agentStoreChat(stores)
            chatID = chat.id; conversationID = chat.localConversationID
            let review = try stores.workspacePolicyReview(projectID: chat.projectID)
            let policy = try stores.reviewWorkspacePolicy(projectID: chat.projectID, allowedProviders: [.codex], expectedRevision: review.revision)
            let packet = try stores.workspaceContextPacket(chatID: chat.id)
            let legacy = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "legacy-model", effort: nil,
                expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
            legacyID = legacy.id
            try stores.db.queue.write { db in
                try db.drop(table: "agentTurn")
                try db.drop(table: "agentTranscriptEntry")
                try db.drop(table: "agentChatSession")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?)",
                    arguments: ["v28-agent-chat-journal", "v32-agent-history-reconciliation"])
                try db.drop(table: "agentHistoryObservation")
            }
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.workspaceChat(id: chatID)?.localConversationID == conversationID)
        #expect(try reopened.db.queue.read { try Conversation.fetchOne($0, key: conversationID!) != nil })
        #expect(try reopened.agentEntries(chatID: chatID).isEmpty)
        #expect(try reopened.workspaceFrontierSessions(chatID: chatID).map(\.id) == [legacyID!])
        #expect(try reopened.workspaceFrontierSession(id: legacyID)?.model == "legacy-model")
        #expect(try reopened.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name='workspaceClaudeSessionImmutable'") } == 1)
    }
}

func agentStoreChat(_ stores: Stores, provider: AgentProvider = .claude, cwd: String = "/tmp") throws -> (WorkspaceChat, AgentChatSession) {
    let project = try stores.createWorkspaceProject(title: "Example project")
    let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Example chat")
    let session = AgentChatSession(chatID: chat.id, provider: provider, cwd: cwd, model: "test-model")
    try stores.saveAgentSession(session)
    return (chat, session)
}
