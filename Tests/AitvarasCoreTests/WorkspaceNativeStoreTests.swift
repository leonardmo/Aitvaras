import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

@Suite struct WorkspaceNativeStoreTests {
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func page(
        provider: NativeSessionProvider = .claude, id: String = "synthetic-session",
        parent: String? = nil, range: Range<Int> = 0..<2,
        cursor: String? = nil, direction: NativeTranscriptPage.Direction = .newer
    ) -> NativeTranscriptPage {
        .init(session: .init(provider: provider, externalID: id, title: "Same synthetic title",
                             directory: "/synthetic/project", updatedAt: observedAt,
                             parentExternalID: parent),
              messages: range.map { .init(externalID: "synthetic-message-\($0)",
                                          role: $0.isMultiple(of: 2) ? .user : .assistant,
                                          text: "Synthetic text \($0)") },
              nextCursor: cursor, coverage: "Synthetic text-only coverage", direction: direction)
    }

    private func link(_ stores: Stores, _ chat: WorkspaceChat) throws -> WorkspaceSessionLink {
        try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
    }

    private func nativeCounts(_ stores: Stores) throws -> [Int] {
        try stores.db.queue.read { db in
            try [WorkspaceNativeSnapshot.fetchCount(db), WorkspaceNativeMessage.fetchCount(db),
                 WorkspaceNativeRevision.fetchCount(db), WorkspaceSessionLink.fetchCount(db),
                 WorkspaceChat.fetchCount(db), Conversation.fetchCount(db)]
        }
    }

    @Test func nativeImportRequiresExplicitReviewAndLeavesNoPartialObjects() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        #expect(throws: WorkspaceNativeError.historyNotReviewed) {
            try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: false)
        }
        #expect(try nativeCounts(stores) == [0, 0, 0, 0, 0, 0])
        let chat = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true, now: observedAt)
        let source = try link(stores, chat)
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id)?.approvedAt == observedAt)
    }

    @Test func nativeSnapshotsAreSeparateFromLocalMessagesGlobalFactsAndRAG() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let unrelated = Conversation(title: "Unrelated local chat")
        let fact = MemoryFact(text: "Existing synthetic global fact")
        let document = RAGDocument(source: "synthetic", path: "/synthetic/document.md", mtime: 1, contentHash: "synthetic-hash")
        try stores.db.queue.write { db in
            try unrelated.insert(db)
            try fact.insert(db)
            try document.insert(db)
            try RAGChunk(documentID: document.id, ord: 0, text: "Existing synthetic chunk").insert(db)
        }
        let local = StoredMessage(conversationID: unrelated.id, role: "user", content: "Existing local text")
        try stores.appendMessage(local)
        let chat = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 2)
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.messages(in: unrelated.id).map(\.id) == [local.id])
        try stores.db.queue.read { db in
            let messageCount = try StoredMessage.fetchCount(db)
            let facts = try MemoryFact.fetchAll(db)
            let documents = try RAGDocument.fetchAll(db)
            let chunkCount = try RAGChunk.fetchCount(db)
            #expect(messageCount == 1)
            #expect(facts.map(\.id) == [fact.id])
            #expect(documents.map(\.id) == [document.id])
            #expect(chunkCount == 1)
        }
    }

    @Test func sameTitlesUseProviderHostAndExternalIdentityAndPreserveForkParent() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let sources = [page(), page(provider: .codex), page(id: "synthetic-fork", parent: "synthetic-session")]
        let chats = try sources.map { try stores.importWorkspaceNativeSession(pages: [$0], projectID: project.id, reviewed: true) }
        #expect(Set(chats.map(\.id)).count == 3)
        #expect(Set(chats.map(\.title)).count == 1)
        let links = try chats.map { try link(stores, $0) }
        #expect(Set(links.map(\.id)).count == 3)
        #expect(try stores.workspaceNativeSnapshot(linkID: links[2].id)?.parentExternalID == "synthetic-session")
        var remote = sources[0]
        remote.session.hostID = "synthetic-remote-host"
        #expect(remote.session.id != sources[0].session.id)
        #expect(sources[0].session.id != sources[1].session.id)
        // A2 local-only import must not silently alias a remote host to local.
        #expect(throws: WorkspaceNativeError.invalidPage) {
            try stores.importWorkspaceNativeSession(pages: [remote], projectID: project.id, reviewed: true)
        }
        #expect(try stores.workspaceChats(projectID: project.id).count == 3)
    }

    @Test func nativeReimportDeduplicatesAndRetainsEveryUpdatedMessageVersion() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true, now: observedAt)
        let source = try link(stores, chat)
        let original = try stores.workspaceNativeMessages(linkID: source.id)
        let repeated = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true,
                                                               now: observedAt.addingTimeInterval(10))
        #expect(repeated.id == chat.id)
        #expect(try stores.workspaceNativeMessages(linkID: source.id).map(\.id) == original.map(\.id))
        #expect(try stores.workspaceNativeRevisions(messageID: original[0].id).count == 1)
        var changed = page()
        changed.messages[0].text = "Updated synthetic text"
        try stores.mergeWorkspaceNativePage(linkID: source.id, page: changed, requestCursor: nil, now: observedAt.addingTimeInterval(20))
        let revisions = try stores.workspaceNativeRevisions(messageID: original[0].id)
        #expect(revisions.map(\.revision) == [1, 2])
        #expect(revisions.map(\.text) == ["Synthetic text 0", "Updated synthetic text"])
        let latest = try stores.workspaceNativeMessages(linkID: source.id)
        #expect(latest[0].id == original[0].id)
        #expect(latest[0].revision == 2)
        #expect(latest[0].firstObservedAt == observedAt)
        #expect(latest[0].lastObservedAt == observedAt.addingTimeInterval(20))
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id)?.approvedAt == observedAt)
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id)?.lastSyncedAt == observedAt.addingTimeInterval(20))
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 2)
    }

    @Test func nativeBrowsePaginatesBeyondThreeHundredWithoutTruncation() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page(range: 0..<200, cursor: "next-200")],
                                                           projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 200..<400, cursor: "next-400"), requestCursor: "next-200")
        try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 400..<451), requestCursor: "next-400")
        var loaded: [WorkspaceNativeMessage] = []
        for offset in stride(from: 0, to: 500, by: 100) {
            loaded += try stores.workspaceNativeMessages(linkID: source.id, offset: offset, limit: 100)
        }
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 451)
        #expect(loaded.map(\.externalID) == (0..<451).map { "synthetic-message-\($0)" })
        #expect(Set(loaded.map(\.id)).count == 451)
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id)?.nextCursor == nil)
        #expect(throws: WorkspaceNativeError.invalidPage) { try stores.workspaceNativeMessages(linkID: source.id, offset: -1) }
        #expect(throws: WorkspaceNativeError.invalidPage) { try stores.workspaceNativeMessages(linkID: source.id, limit: 201) }
    }

    @Test func nativeOlderPaginationPrependsChronologicalPagesAndDeduplicatesOverlap() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page(range: 200..<400, cursor: "older", direction: .older)],
                                                           projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 100..<250, direction: .older), requestCursor: "older")
        let first = try stores.workspaceNativeMessages(linkID: source.id, limit: 200)
        let second = try stores.workspaceNativeMessages(linkID: source.id, offset: 200, limit: 200)
        #expect((first + second).map(\.externalID) == (100..<400).map { "synthetic-message-\($0)" })
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 300)
    }

    @Test func nativeStaleCursorAndDirectionChangesDoNotMutateSnapshotOrMessages() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page(cursor: "expected")], projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        let snapshot = try stores.workspaceNativeSnapshot(linkID: source.id)
        let messages = try stores.workspaceNativeMessages(linkID: source.id)
        #expect(throws: WorkspaceNativeError.staleCursor) {
            try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 2..<4), requestCursor: "stale")
        }
        #expect(throws: WorkspaceNativeError.staleCursor) {
            try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 2..<4, direction: .older), requestCursor: "expected")
        }
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id) == snapshot)
        #expect(try stores.workspaceNativeMessages(linkID: source.id) == messages)
    }

    @Test func nativeSourceAndRoleMismatchRollBackEarlierWritesAndRevisions() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        let before = try stores.workspaceNativeMessages(linkID: source.id)
        let snapshot = try stores.workspaceNativeSnapshot(linkID: source.id)
        let counts = try nativeCounts(stores)
        for mismatch in [page(provider: .codex), page(id: "different-synthetic-session")] {
            #expect(throws: WorkspaceNativeError.sourceMismatch) {
                try stores.mergeWorkspaceNativePage(linkID: source.id, page: mismatch, requestCursor: nil)
            }
        }
        var roleMismatch = page()
        roleMismatch.messages[0].text = "Must be rolled back"
        roleMismatch.messages[1].role = .user
        #expect(throws: WorkspaceNativeError.sourceMismatch) {
            try stores.mergeWorkspaceNativePage(linkID: source.id, page: roleMismatch, requestCursor: nil)
        }
        #expect(try stores.workspaceNativeMessages(linkID: source.id) == before)
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id) == snapshot)
        #expect(try nativeCounts(stores) == counts)
        let other = try stores.createWorkspaceProject(title: "Other synthetic project")
        #expect(throws: WorkspaceNativeError.sourceMismatch) {
            try stores.importWorkspaceNativeSession(pages: [page()], projectID: other.id, reviewed: true)
        }
        #expect(try stores.workspaceChats(projectID: other.id).isEmpty)
    }

    @Test func nativeOversizeDuplicateAndBrokenMultipageImportsRollBackAtomically() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        var hugeText = page()
        hugeText.messages[0].text = String(repeating: "x", count: 200_001)
        var hugeTotal = page(range: 0..<4)
        for index in hugeTotal.messages.indices { hugeTotal.messages[index].text = String(repeating: "x", count: 160_000) }
        var duplicate = page()
        duplicate.messages[1].externalID = duplicate.messages[0].externalID
        for invalid in [hugeText, hugeTotal, duplicate, page(range: 0..<201)] {
            #expect(throws: WorkspaceNativeError.invalidPage) {
                try stores.importWorkspaceNativeSession(pages: [page(cursor: "next"), invalid], projectID: project.id, reviewed: true)
            }
            #expect(try nativeCounts(stores) == [0, 0, 0, 0, 0, 0])
        }
        #expect(throws: WorkspaceNativeError.invalidPage) {
            try stores.importWorkspaceNativeSession(pages: [page(), page(range: 2..<4)], projectID: project.id, reviewed: true)
        }
        #expect(throws: WorkspaceNativeError.sourceMismatch) {
            try stores.importWorkspaceNativeSession(pages: [page(cursor: "next"), page(id: "wrong-source", range: 2..<4)], projectID: project.id, reviewed: true)
        }
        #expect(try nativeCounts(stores) == [0, 0, 0, 0, 0, 0])
    }

    @Test func nativeHiddenProjectsRejectImportAndMergeWithoutErasingSavedHistory() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page(cursor: "next")], projectID: project.id, reviewed: true)
        let source = try link(stores, chat)
        let snapshot = try stores.workspaceNativeSnapshot(linkID: source.id)
        project.isVisible = false
        try stores.saveWorkspaceProject(project)
        #expect(throws: WorkspaceNativeError.unavailableProject) {
            try stores.importWorkspaceNativeSession(pages: [page(id: "new-source")], projectID: project.id, reviewed: true)
        }
        #expect(throws: WorkspaceNativeError.unavailableProject) {
            try stores.mergeWorkspaceNativePage(linkID: source.id, page: page(range: 2..<4), requestCursor: "next")
        }
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 2)
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id) == snapshot)
    }

    @Test func nativeLogicalArchiveRetainsDataAndReimportNeverRestoresChat() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, kind: .temporary, reviewed: true)
        let source = try link(stores, chat)
        let before = try stores.workspaceNativeMessages(linkID: source.id)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true, now: observedAt)
        #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        #expect(try stores.workspaceNativeMessages(linkID: source.id) == before)
        #expect(try stores.workspaceNativeRevisions(messageID: before[0].id).count == 1)
        let repeated = try stores.importWorkspaceNativeSession(pages: [page()], projectID: project.id, reviewed: true)
        #expect(repeated.id == chat.id)
        #expect(repeated.archivedAt == observedAt)
        #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).map(\.id) == [source.id])
        #expect(try stores.workspaceNativeSnapshot(linkID: source.id) != nil)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: false)
        #expect(try stores.workspaceNativeMessageCount(linkID: source.id) == 2)
    }
}
