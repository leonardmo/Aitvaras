import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

@Suite struct WorkspaceStoreTests {
    @Test func projectsWithDuplicateTitlesAreDistinctAndHiddenProjectsKeepEverything() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Example", instructions: "Keep local",
            folders: [.init(path: "/synthetic/example", access: .readOnly)])
        let second = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Main")
        #expect(project.id != second.id)
        #expect(!project.allowsCloud)
        project.isVisible = false
        try stores.saveWorkspaceProject(project)
        #expect(try stores.workspaceProjects(includeHidden: false).map(\.id) == [second.id])
        #expect(try stores.workspaceProjects().count == 2)
        #expect(try stores.workspaceFolders(projectID: project.id).count == 1)
        #expect(try stores.workspaceChat(id: chat.id) != nil)
        #expect(try stores.conversation(id: chat.localConversationID) != nil)
    }

    @Test func recentChatsSpanVisibleProjectsNewestFirstAndKeepTheirOwnProject() throws {
        let stores = try inMemoryStores()
        let course = try stores.createWorkspaceProject(title: "Course")
        let thesis = try stores.createWorkspaceProject(title: "Thesis")
        var hidden = try stores.createWorkspaceProject(title: "Hidden")
        hidden.isVisible = false
        try stores.saveWorkspaceProject(hidden)

        let older = try stores.createWorkspaceChat(projectID: course.id, title: "Older course chat")
        let newest = try stores.createWorkspaceChat(projectID: thesis.id, title: "Newest thesis chat")
        let archived = try stores.createWorkspaceChat(projectID: course.id, title: "Archived chat")
        let unseen = try stores.createWorkspaceChat(projectID: hidden.id, title: "Hidden project chat")
        // Activity only ever moves forward, so order these after creation.
        let base = Date.now
        try stores.touchWorkspaceChat(conversationID: older.localConversationID,
                                      at: base.addingTimeInterval(60))
        try stores.touchWorkspaceChat(conversationID: newest.localConversationID,
                                      at: base.addingTimeInterval(120))
        try stores.touchWorkspaceChat(conversationID: unseen.localConversationID,
                                      at: base.addingTimeInterval(180))
        try stores.setWorkspaceChatArchived(id: archived.id, archived: true)

        let recent = try stores.recentWorkspaceChats()
        #expect(recent.map(\.chat.id) == [newest.id, older.id])
        #expect(recent.map(\.project.title) == ["Thesis", "Course"])
        #expect(!recent.contains { $0.chat.id == unseen.id || $0.chat.id == archived.id })
        #expect(try stores.recentWorkspaceChats(limit: 1).map(\.chat.id) == [newest.id])
        #expect(throws: WorkspaceStoreError.self) { try stores.recentWorkspaceChats(limit: 0) }

        // Restoring an archived chat brings it back into the shared list.
        try stores.setWorkspaceChatArchived(id: archived.id, archived: false)
        #expect(try stores.recentWorkspaceChats().contains { $0.chat.id == archived.id })
    }

    @Test func validationRejectsBlankOversizedAndRelativeValuesWithoutPartialWrites() throws {
        let stores = try inMemoryStores()
        #expect(throws: WorkspaceStoreError.self) { try stores.createWorkspaceProject(title: " \n ") }
        #expect(throws: WorkspaceStoreError.self) { try stores.createWorkspaceProject(title: String(repeating: "x", count: 201)) }
        #expect(throws: WorkspaceStoreError.self) {
            try stores.createWorkspaceProject(title: "Invalid", folders: [.init(path: "relative/folder")])
        }
        #expect(try stores.workspaceProjects().isEmpty)
        let project = try stores.createWorkspaceProject(title: "Valid", folders: [.init(path: "/synthetic/old")])
        let original = try stores.workspaceFolders(projectID: project.id)
        #expect(throws: WorkspaceStoreError.self) {
            try stores.replaceWorkspaceFolders(projectID: project.id, folders: [.init(path: "/synthetic/new"), .init(path: "~/relative")])
        }
        #expect(try stores.workspaceFolders(projectID: project.id) == original)
        #expect(throws: WorkspaceStoreError.self) {
            try stores.replaceWorkspaceFolders(projectID: project.id, folders: [.init(path: "/synthetic/a/../b"), .init(path: "/synthetic/b")])
        }
        try stores.replaceWorkspaceFolders(projectID: project.id, folders: [.init(path: "/synthetic/old", access: .readWrite)])
        #expect(try stores.workspaceFolders(projectID: project.id).first?.id == original.first?.id)
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { db in
                try db.execute(sql: "UPDATE workspaceFolder SET access = 'invalid'")
            }
        }
    }

    @Test func assignmentIsAtomicUniqueAndCannotBeMoved() throws {
        let stores = try inMemoryStores()
        let first = try stores.createWorkspaceProject(title: "First")
        let second = try stores.createWorkspaceProject(title: "Second")
        let legacy = Conversation(title: "Legacy")
        try stores.saveConversation(legacy)
        let voiceID = try stores.persistentConversationID(forKey: "synthetic.voice", title: "Voice")
        let chat = try stores.createWorkspaceChat(projectID: first.id, title: "Assigned", existingConversationID: legacy.id)
        #expect(chat.localConversationID == legacy.id)
        #expect(try stores.unassignedConversations().map(\.id) == [voiceID])
        #expect(try stores.value(forKey: "synthetic.voice") == voiceID.uuidString)
        #expect(throws: WorkspaceStoreError.conversationAlreadyAssigned) {
            try stores.createWorkspaceChat(projectID: second.id, title: "Steal", existingConversationID: legacy.id)
        }
        var moved = chat
        moved.projectID = second.id
        #expect(throws: WorkspaceStoreError.immutableIdentity) { try stores.saveWorkspaceChat(moved) }
        let count = try stores.conversations().count
        #expect(throws: WorkspaceStoreError.projectNotFound) { try stores.createWorkspaceChat(projectID: UUID(), title: "Missing") }
        #expect(throws: WorkspaceStoreError.conversationNotFound) {
            try stores.createWorkspaceChat(projectID: first.id, title: "Missing", existingConversationID: UUID())
        }
        #expect(try stores.conversations().count == count)
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { db in try Conversation.deleteOne(db, key: legacy.id) }
        }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { db in try WorkspaceChat(projectID: UUID(), localConversationID: voiceID, title: "Orphan").insert(db) }
        }
    }

    @Test func archivingAndRestoringRetainsMessagesAndProviderIdentity() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Temporary", kind: .temporary)
        let message = StoredMessage(conversationID: chat.localConversationID, role: "user", content: "Preserve me")
        try stores.appendMessage(message)
        let link = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-session", displayName: "Example session"))
        let now = Date(timeIntervalSince1970: 2_000_000)
        try age(chat, stores: stores, at: now.addingTimeInterval(-Stores.workspaceTemporaryChatLifetime))
        #expect(try stores.archiveExpiredWorkspaceChats(now: now) == 1)
        #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        #expect(try stores.workspaceChats(projectID: project.id, includeArchived: true).count == 1)
        #expect(try stores.messages(in: chat.localConversationID).map(\.id) == [message.id])
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).map(\.id) == [link.id])
        try stores.setWorkspaceChatArchived(id: chat.id, archived: false, now: now)
        #expect(try stores.workspaceChats(projectID: project.id).count == 1)
        #expect(try stores.workspaceChat(id: chat.id)?.lastActivityAt == now)
        #expect(try stores.archiveExpiredWorkspaceChats(now: now) == 0)
        #expect(try stores.archiveExpiredWorkspaceChats(now: now.addingTimeInterval(Stores.workspaceTemporaryChatLifetime - 1)) == 0)
        #expect(try stores.archiveExpiredWorkspaceChats(now: now.addingTimeInterval(Stores.workspaceTemporaryChatLifetime)) == 1)
    }

    @Test func primaryRecentProtectedAndUnresolvedChatsNeverExpire() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-Stores.workspaceTemporaryChatLifetime - 1)
        let primary = try stores.createWorkspaceChat(projectID: project.id, title: "Primary")
        let protected = try stores.createWorkspaceChat(projectID: project.id, title: "Protected", kind: .temporary)
        let recent = try stores.createWorkspaceChat(projectID: project.id, title: "Recent", kind: .temporary)
        try age(primary, stores: stores, at: old)
        try age(protected, stores: stores, at: old)
        try age(recent, stores: stores, at: now.addingTimeInterval(-Stores.workspaceTemporaryChatLifetime + 1))
        var unresolved: [WorkspaceChat] = []
        for (index, state) in [ActivityRunState.queued, .running, .waiting, .awaitingApproval,
                              .cancellationRequested, .interrupted, .outcomeUnknown, .failed].enumerated() {
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: state.rawValue, kind: .temporary)
            try age(chat, stores: stores, at: old)
            let reference = index.isMultiple(of: 2) ? chat.id : chat.localConversationID
            try stores.db.queue.write { db in
                try ActivityRun(referenceID: reference.uuidString.lowercased(), category: .chat, state: state, title: "Pending").insert(db)
            }
            unresolved.append(chat)
        }
        #expect(try stores.archiveExpiredWorkspaceChats(now: now, protectedChatIDs: [protected.id]) == 0)
        #expect(try stores.workspaceChats(projectID: project.id).count == unresolved.count + 3)
        for run in try stores.activityAttentionRuns() { try stores.acknowledgeActivityRun(id: run.id) }
        #expect(try stores.archiveExpiredWorkspaceChats(now: now, protectedChatIDs: [protected.id]) == 3)
    }

    @Test func metadataDoesNotTouchActivityAndExplicitTouchIsMonotonic() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        var chat = try stores.createWorkspaceChat(projectID: project.id, title: "Before")
        let old = Date(timeIntervalSince1970: 100)
        try age(chat, stores: stores, at: old)
        chat.title = "After"
        try stores.saveWorkspaceChat(chat)
        #expect(try stores.workspaceChat(id: chat.id)?.lastActivityAt == old)
        let later = Date(timeIntervalSince1970: 200)
        try stores.touchWorkspaceChat(conversationID: chat.localConversationID, at: later)
        try stores.touchWorkspaceChat(conversationID: chat.localConversationID, at: old)
        #expect(try stores.workspaceChat(id: chat.id)?.lastActivityAt == later)
    }

    @Test func appendedMessagesAtomicallyRefreshActivityWithoutUnarchiving() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Temporary", kind: .temporary)
        let old = Date.now.addingTimeInterval(-Stores.workspaceTemporaryChatLifetime - 60)
        try age(chat, stores: stores, at: old)
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "New", createdAt: old))
        #expect(try stores.archiveExpiredWorkspaceChats(now: .now) == 0)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        let archivedAt = try stores.workspaceChat(id: chat.id)?.archivedAt
        try age(chat, stores: stores, at: old)
        try stores.appendMessages([.init(conversationID: chat.localConversationID, role: "assistant", content: "Saved")])
        #expect((try stores.workspaceChat(id: chat.id)?.lastActivityAt ?? old) > old)
        #expect(try stores.workspaceChat(id: chat.id)?.archivedAt == archivedAt)
        let beforeFailure = try stores.workspaceChat(id: chat.id)?.lastActivityAt
        #expect(throws: (any Error).self) {
            try stores.appendMessages([
                .init(conversationID: chat.localConversationID, role: "user", content: "Rollback"),
                .init(conversationID: UUID(), role: "user", content: "Invalid")])
        }
        #expect(try stores.messages(in: chat.localConversationID).count == 2)
        #expect(try stores.workspaceChat(id: chat.id)?.lastActivityAt == beforeFailure)
    }

    @Test func providerLinksUseExactIdentitiesAndRejectStealing() throws {
        let stores = try inMemoryStores()
        let first = try stores.createWorkspaceProject(title: "Same")
        let second = try stores.createWorkspaceProject(title: "Same")
        let firstChat = try stores.createWorkspaceChat(projectID: first.id, title: "Same")
        let secondChat = try stores.createWorkspaceChat(projectID: second.id, title: "Same")
        let link = try stores.saveWorkspaceProjectLink(.init(projectID: first.id, provider: .codex,
            externalID: "synthetic-project", displayName: "Same"))
        let duplicate = try stores.saveWorkspaceProjectLink(.init(projectID: first.id, provider: .codex,
            externalID: "synthetic-project", displayName: "Renamed"))
        #expect(duplicate.id == link.id)
        #expect(throws: WorkspaceStoreError.linkAlreadyAssigned) {
            try stores.saveWorkspaceProjectLink(.init(projectID: second.id, provider: .codex,
                externalID: "synthetic-project", displayName: "Same"))
        }
        try stores.saveWorkspaceProjectLink(.init(projectID: second.id, provider: .codex,
            externalID: "synthetic-project", hostID: "synthetic-host", displayName: "Same"))
        let session = try stores.saveWorkspaceSessionLink(.init(chatID: firstChat.id, provider: .claude,
            externalID: "synthetic-session", displayName: "Same"))
        let repeated = try stores.saveWorkspaceSessionLink(.init(chatID: firstChat.id, provider: .claude,
            externalID: "synthetic-session", displayName: "Changed"))
        #expect(session.id == repeated.id)
        #expect(throws: WorkspaceStoreError.linkAlreadyAssigned) {
            try stores.saveWorkspaceSessionLink(.init(chatID: secondChat.id, provider: .claude,
                externalID: "synthetic-session", displayName: "Same"))
        }
        #expect(try stores.workspaceProjectLinks(projectID: first.id).count == 1)
        #expect(try stores.workspaceSessionLinks(chatID: firstChat.id).count == 1)
        #expect(try stores.workspaceSessionLinks(chatID: secondChat.id).isEmpty)
    }

    @Test func v16UpgradePreservesLegacyRowsAndPointersWithoutAssigningAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let conversation = Conversation(title: "Existing")
        let message = StoredMessage(conversationID: conversation.id, role: "user", content: "Existing text")
        let document = RAGDocument(source: "synthetic", path: "/synthetic/document.md", mtime: 1, contentHash: "synthetic-hash")
        let chunk = RAGChunk(documentID: document.id, ord: 0, text: "Existing chunk")
        let fact = MemoryFact(text: "Existing fact")
        // Reconstruct the actual v16 schema from an empty migrated test-only
        // database, then seed legacy rows before reopening through v17/v18.
        do {
            let db = try AitvarasDatabase(url: url)
            try db.queue.write { dbc in
                try removeWorkspaceFrontierMigrationForTest(dbc)
                for trigger in ["workspacePolicyProjectInsert", "workspacePolicyInstructionsUpdate", "workspacePolicyFolderInsert", "workspacePolicyFolderDelete", "workspacePolicyFolderUpdate", "workspaceCaptureTargetImmutable"] {
                    try dbc.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
                }
                for table in ["workspaceCaptureTarget", "workspacePolicy", "workspacePolicyState"] { try dbc.drop(table: table) }
                try dbc.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v20-workspace-policy-capture-targets'")
                for table in ["workspaceNativeRevision", "workspaceNativeMessage", "workspaceNativeSnapshot"] {
                    try dbc.drop(table: table)
                }
                try dbc.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN ('v18-native-history', 'v19-native-history-refresh')")
                for table in ["workspaceSessionLink", "workspaceProjectLink", "workspaceFolder", "workspaceChat", "workspaceProject"] {
                    try dbc.drop(table: table)
                }
                try dbc.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v17-workspaces'")
                try conversation.insert(dbc)
                try message.insert(dbc)
                try document.insert(dbc)
                try chunk.insert(dbc)
                try fact.insert(dbc)
                try dbc.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?)", arguments: ["synthetic.voice", conversation.id.uuidString])
                try dbc.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?)", arguments: ["synthetic.setting", "preserve"])
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.workspaceProjects().isEmpty)
        #expect(try stores.unassignedConversations().map(\.id) == [conversation.id])
        #expect(try stores.messages(in: conversation.id).map(\.id) == [message.id])
        #expect(try stores.value(forKey: "synthetic.voice") == conversation.id.uuidString)
        #expect(try stores.value(forKey: "synthetic.setting") == "preserve")
        try stores.db.queue.read { dbc in
            let restoredFact = try MemoryFact.fetchOne(dbc, key: fact.id)
            let restoredDocument = try RAGDocument.fetchOne(dbc, key: document.id)
            let restoredChunk = try RAGChunk.fetchOne(dbc, key: chunk.id)
            #expect(restoredFact?.text == fact.text)
            #expect(restoredDocument?.contentHash == document.contentHash)
            #expect(restoredChunk?.text == chunk.text)
        }
    }

    private func age(_ chat: WorkspaceChat, stores: Stores, at date: Date) throws {
        try stores.db.queue.write { db in
            try db.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ?", arguments: [date, chat.id])
        }
    }
}
