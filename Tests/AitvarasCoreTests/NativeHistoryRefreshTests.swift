import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

private actor SyntheticHistoryReader: NativeSessionReader {
    nonisolated let provider: NativeSessionProvider = .claude
    var responses: [NativeTranscriptPage]
    var requests: [String?] = []
    let failAt: Int?
    init(_ responses: [NativeTranscriptPage], failAt: Int? = nil) {
        self.responses = responses; self.failAt = failAt
    }
    func capabilities() async -> NativeSessionCapability {
        .init(provider: provider, state: .ready, detail: "Synthetic")
    }
    func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage {
        .init(sessions: [], coverage: "Synthetic")
    }
    func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage {
        let index = requests.count
        requests.append(cursor)
        if index == failAt { throw SyntheticError.failed }
        guard responses.indices.contains(index) else { throw SyntheticError.failed }
        return responses[index]
    }
    enum SyntheticError: Error { case failed }
}

@Suite struct NativeHistoryRefreshTests {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func page(_ ids: [String], cursor: String? = nil,
              direction: NativeTranscriptPage.Direction = .newer) -> NativeTranscriptPage {
        .init(session: .init(provider: .claude, externalID: "synthetic-session", title: "Synthetic",
                             updatedAt: timestamp),
              messages: ids.map { .init(externalID: $0, role: .assistant, text: "Text \($0)") },
              nextCursor: cursor, coverage: "Synthetic exposed text only", direction: direction)
    }

    @Test func exactReviewAndImportAgreeForAnchoredOverlapInBothDirections() throws {
        for direction in [NativeTranscriptPage.Direction.newer, .older] {
            let pages = [page(["b", "d"], cursor: "next", direction: direction),
                         page(["a", "b", "c", "d", "e"], direction: direction)]
            let review = try canonicalNativeReview(pages)
            #expect(review.messages.map(\.externalID) == ["a", "b", "c", "d", "e"])
            let stores = try inMemoryStores()
            let project = try stores.createWorkspaceProject(title: "Synthetic")
            let chat = try stores.importWorkspaceNativeSession(pages: pages, projectID: project.id, reviewed: true)
            let link = try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
            let saved = try stores.workspaceNativeMessages(linkID: link.id)
            #expect(saved.map(\.externalID) == review.messages.map(\.externalID))
            #expect(saved.map(\.text) == review.messages.map(\.text))
            #expect(try stores.workspaceNativeSnapshot(linkID: link.id)?.lastCompleteRefreshAt == nil)
        }
    }

    @Test func inconsistentDuplicateCannotBePreviewedOrImported() throws {
        let first = page(["a", "b"], cursor: "next")
        for changeRole in [false, true] {
            var second = page(["b", "c"])
            if changeRole { second.messages[0].role = .user }
            else { second.messages[0].text = "Conflicting text" }
            #expect(throws: NativeHistoryReviewError.conflictingMessage) { try canonicalNativeReview([first, second]) }
            let stores = try inMemoryStores()
            let project = try stores.createWorkspaceProject(title: "Synthetic")
            #expect(throws: WorkspaceNativeError.sourceMismatch) {
                try stores.importWorkspaceNativeSession(pages: [first, second], projectID: project.id, reviewed: true)
            }
            #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        }
        #expect(throws: NativeHistoryReviewError.sourceMismatch) {
            try canonicalNativeReview([first, page(["b", "a"])])
        }
    }

    @Test func fullRefreshReadsNewestEditAndAppendAndRetainsRevisionAndLocalSeparation() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic")
        let initial = [page(["a", "b"], cursor: "next"), page(["c"])]
        let chat = try stores.importWorkspaceNativeSession(pages: initial, projectID: project.id,
                                                          reviewed: true, now: timestamp)
        let link = try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
        let before = try stores.workspaceNativeMessages(linkID: link.id)
        var latest = page(["c", "d"])
        latest.messages[0].text = "Edited newest text"
        let reader = SyntheticHistoryReader([initial[0], latest, initial[0]])
        let pages = try await NativeHistoryRefresh.fetch(reader: reader, id: "synthetic-session", directory: nil)
        let now = timestamp.addingTimeInterval(20)
        try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: pages, expectedLastSyncedAt: timestamp, now: now)
        #expect(await reader.requests == [nil, "next", nil])
        let after = try stores.workspaceNativeMessages(linkID: link.id)
        #expect(after.map(\.externalID) == ["a", "b", "c", "d"])
        #expect(Array(after.prefix(3).map(\.id)) == before.map(\.id))
        #expect(try stores.workspaceNativeRevisions(messageID: before[2].id).map(\.text) == ["Text c", "Edited newest text"])
        #expect(try stores.workspaceNativeSnapshot(linkID: link.id)?.lastCompleteRefreshAt == now)
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.workspaceChats(projectID: project.id).first?.archivedAt == nil)
    }

    @Test func failedOrCancelledTraversalLeavesVisibleDataAndFreshnessUntouched() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic")
        let first = page(["a"], cursor: "next")
        let chat = try stores.importWorkspaceNativeSession(pages: [first], projectID: project.id,
                                                          reviewed: true, now: timestamp)
        let link = try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
        let before = try stores.workspaceNativeMessages(linkID: link.id)
        let snapshot = try stores.workspaceNativeSnapshot(linkID: link.id)
        let failing = SyntheticHistoryReader([first], failAt: 1)
        await #expect(throws: SyntheticHistoryReader.SyntheticError.self) {
            let pages = try await NativeHistoryRefresh.fetch(reader: failing, id: "synthetic-session", directory: nil)
            try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: pages, expectedLastSyncedAt: timestamp)
        }
        let cancelled = Task {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first]),
                id: "synthetic-session", directory: nil, onProgress: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try stores.workspaceNativeMessages(linkID: link.id) == before)
        #expect(try stores.workspaceNativeSnapshot(linkID: link.id) == snapshot)
    }

    @Test func loopMutableSourceAndFinalVersionFenceFailClosed() async throws {
        let first = page(["a"], cursor: "next")
        await #expect(throws: NativeHistoryReviewError.staleCursor) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, page(["b"], cursor: "next")]),
                id: "synthetic-session", directory: nil)
        }
        var changed = page(["b"])
        changed.session.updatedAt = timestamp.addingTimeInterval(1)
        await #expect(throws: NativeHistoryReviewError.staleCursor) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, changed]),
                id: "synthetic-session", directory: nil)
        }
        var fence = first
        fence.session.updatedAt = timestamp.addingTimeInterval(1)
        await #expect(throws: NativeHistoryRefresh.RefreshError.sourceChanged) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, page(["b"]), fence]),
                id: "synthetic-session", directory: nil)
        }
        var unversioned = page(["a"])
        unversioned.session.updatedAt = nil
        await #expect(throws: NativeHistoryRefresh.RefreshError.sourceVersionUnavailable) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([unversioned]),
                id: "synthetic-session", directory: nil)
        }
    }

    @Test func fullRefreshRollsBackRoleConflictAndRejectsConcurrentOrStaleSource() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic")
        let chat = try stores.importWorkspaceNativeSession(pages: [page(["a", "b"])],
            projectID: project.id, reviewed: true, now: timestamp)
        let link = try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
        let before = try stores.workspaceNativeMessages(linkID: link.id)
        let snapshot = try stores.workspaceNativeSnapshot(linkID: link.id)
        var conflict = page(["a", "b"])
        conflict.messages[0].text = "Must roll back"
        conflict.messages[1].role = .user
        #expect(throws: WorkspaceNativeError.sourceMismatch) {
            try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: [conflict], expectedLastSyncedAt: timestamp)
        }
        #expect(throws: WorkspaceNativeError.staleCursor) {
            try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: [page(["a", "b"])], expectedLastSyncedAt: timestamp.addingTimeInterval(-1))
        }
        var stale = page(["a", "b"])
        stale.session.updatedAt = timestamp.addingTimeInterval(-1)
        #expect(throws: WorkspaceNativeError.staleCursor) {
            try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: [stale], expectedLastSyncedAt: timestamp)
        }
        #expect(try stores.workspaceNativeMessages(linkID: link.id) == before)
        #expect(try stores.workspaceNativeSnapshot(linkID: link.id) == snapshot)
        #expect(try stores.workspaceNativeRevisions(messageID: before[0].id).count == 1)
    }

    @Test func pageBudgetFailsWithoutReturningTruncatedHistory() async throws {
        let pages = (0..<101).map { page([], cursor: "cursor-\($0)") }
        await #expect(throws: NativeHistoryReviewError.budgetExceeded) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader(pages), id: "synthetic-session", directory: nil)
        }
    }

    @Test func wrongIdentityDirectionOrUnversionedEditIsRejected() async throws {
        let first = page(["a"], cursor: "next")
        var wrongSource = page(["b"])
        wrongSource.session.externalID = "other-synthetic-session"
        await #expect(throws: NativeHistoryReviewError.sourceMismatch) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, wrongSource]),
                id: "synthetic-session", directory: nil)
        }
        await #expect(throws: NativeHistoryReviewError.staleCursor) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, page(["b"], direction: .older)]),
                id: "synthetic-session", directory: nil)
        }
        var changedFirst = first
        changedFirst.messages[0].text = "Changed without a new timestamp"
        await #expect(throws: NativeHistoryRefresh.RefreshError.sourceChanged) {
            try await NativeHistoryRefresh.fetch(reader: SyntheticHistoryReader([first, page(["b"]), changedFirst]),
                id: "synthetic-session", directory: nil)
        }
    }

    @Test func archivedEvidenceAndUnverifiedParentSurviveFullRefreshAndPartialReads() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic")
        var initial = page(["a", "b"])
        initial.session.parentExternalID = "synthetic-parent"
        let chat = try stores.importWorkspaceNativeSession(pages: [initial], projectID: project.id,
            reviewed: true, now: timestamp)
        let link = try #require(stores.workspaceSessionLinks(chatID: chat.id).first)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true, now: timestamp)
        let refreshAt = timestamp.addingTimeInterval(10)
        var fewerExposed = initial
        fewerExposed.messages = [initial.messages[0]]
        try stores.refreshWorkspaceNativeSession(linkID: link.id, pages: [fewerExposed],
            expectedLastSyncedAt: timestamp, now: refreshAt)
        #expect(try stores.workspaceNativeMessageCount(linkID: link.id) == 2)
        #expect(try stores.workspaceChats(projectID: project.id).isEmpty)
        let snapshot = try #require(try stores.workspaceNativeSnapshot(linkID: link.id))
        #expect(snapshot.parentExternalID == "synthetic-parent")
        #expect(snapshot.parentRelationship == nil)
        #expect(snapshot.lastCompleteRefreshAt == refreshAt)
        try stores.mergeWorkspaceNativePage(linkID: link.id, page: initial, requestCursor: nil,
            now: refreshAt.addingTimeInterval(10))
        #expect(try stores.workspaceNativeSnapshot(linkID: link.id)?.lastCompleteRefreshAt == refreshAt)
        #expect(try stores.workspaceNativeSnapshot(linkID: link.id)?.lastSyncedAt == refreshAt.addingTimeInterval(10))
    }

    @Test func aggregateCharacterBudgetRejectsOtherwiseValidPages() throws {
        let text = String(repeating: "x", count: 100_000)
        let pages = (0..<17).map { index in
            var value = page((0..<6).map { "\(index)-\($0)" }, cursor: index == 16 ? nil : "next-\(index)")
            for item in value.messages.indices { value.messages[item].text = text }
            return value
        }
        #expect(throws: NativeHistoryReviewError.budgetExceeded) { try canonicalNativeReview(pages) }
    }

    @Test func v18UpgradePreservesEvidenceWithoutInventingFreshnessOrParentKind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-v18-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let linkID: UUID
        let messageID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let project = try stores.createWorkspaceProject(title: "Synthetic upgrade")
            var legacyPage = page(["a"])
            legacyPage.session.parentExternalID = "synthetic-unverified-parent"
            let chat = try stores.importWorkspaceNativeSession(pages: [legacyPage], projectID: project.id,
                reviewed: true, now: timestamp)
            linkID = try #require(try stores.workspaceSessionLinks(chatID: chat.id).first?.id)
            messageID = try #require(try stores.workspaceNativeMessages(linkID: linkID).first?.id)
            try stores.db.queue.write { db in
                try db.execute(sql: "ALTER TABLE workspaceNativeSnapshot DROP COLUMN lastCompleteRefreshAt")
                try db.execute(sql: "ALTER TABLE workspaceNativeSnapshot DROP COLUMN parentRelationship")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v19-native-history-refresh'")
            }
        }
        let upgraded = Stores(db: try AitvarasDatabase(url: url))
        let snapshot = try #require(try upgraded.workspaceNativeSnapshot(linkID: linkID))
        #expect(snapshot.lastSyncedAt == timestamp)
        #expect(snapshot.lastCompleteRefreshAt == nil)
        #expect(snapshot.parentExternalID == "synthetic-unverified-parent")
        #expect(snapshot.parentRelationship == nil)
        #expect(try upgraded.workspaceNativeMessages(linkID: linkID).first?.id == messageID)
        #expect(try upgraded.workspaceNativeRevisions(messageID: messageID).map(\.text) == ["Text a"])
    }
}
