import Foundation
import GRDB
import AitvarasCore

/// A reviewed, text-only snapshot. This grants local display of this source
/// only, not retrieval, file access, provider execution, or automatic sync.
public struct WorkspaceNativeSnapshot: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceNativeSnapshot"
    public var sessionLinkID: UUID
    public var directory: String?
    public var parentExternalID: String?
    public var parentRelationship: String?
    public var providerUpdatedAt: Date?
    public var approvedAt: Date
    public var lastSyncedAt: Date
    /// Set only by a verified, atomic refresh of every currently exposed page.
    public var lastCompleteRefreshAt: Date?
    public var coverage: String
    public var nextCursor: String?
    public var direction: String
}

public struct WorkspaceNativeMessage: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceNativeMessage"
    public var id: UUID
    public var sessionLinkID: UUID
    public var externalID: String
    public var role: String
    public var text: String
    public var position: Int
    public var firstObservedAt: Date
    public var lastObservedAt: Date
    public var revision: Int
}

public struct WorkspaceNativeRevision: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceNativeRevision"
    public var id: UUID
    public var messageID: UUID
    public var revision: Int
    public var text: String
    public var observedAt: Date
}

public enum WorkspaceNativeError: Error, LocalizedError, Sendable {
    case invalidPage, sourceMismatch, staleCursor, unavailableProject, historyNotReviewed
    public var errorDescription: String? {
        switch self {
        case .invalidPage: "The source returned invalid or oversized history. No page was saved."
        case .sourceMismatch: "This native session is already linked elsewhere, or its source changed."
        case .staleCursor: "History changed while paging. Refresh the source and try again."
        case .unavailableProject: "Choose an available project before importing."
        case .historyNotReviewed: "Review this native session before saving its history."
        }
    }
}

extension Stores {
    /// The caller must have shown the selected text and obtained explicit
    /// confirmation. Only local native histories are supported by this slice.
    /// All reviewed pages, link creation and local chat creation are atomic.
    public func importWorkspaceNativeSession(pages: [NativeTranscriptPage], projectID: UUID,
                                             kind: WorkspaceChatKind = .primary,
                                             reviewed: Bool, now: Date = .now) throws -> WorkspaceChat {
        guard reviewed else { throw WorkspaceNativeError.historyNotReviewed }
        let review = try Self.review(pages)
        let first = pages[0]
        return try db.queue.write { dbc in
            guard let project = try WorkspaceProject.fetchOne(dbc, key: projectID), project.isVisible else {
                throw WorkspaceNativeError.unavailableProject
            }
            let provider = first.session.provider.rawValue
            let existing = try WorkspaceSessionLink.filter(Column("provider") == provider)
                .filter(Column("hostID") == first.session.hostID)
                .filter(Column("externalID") == first.session.externalID).fetchOne(dbc)
            let chat: WorkspaceChat
            let link: WorkspaceSessionLink
            if let existing {
                guard let owner = try WorkspaceChat.fetchOne(dbc, key: existing.chatID), owner.projectID == projectID else {
                    throw WorkspaceNativeError.sourceMismatch
                }
                chat = owner
                link = existing
            } else {
                let conversation = Conversation(title: first.session.title)
                try conversation.insert(dbc)
                chat = WorkspaceChat(projectID: projectID, localConversationID: conversation.id,
                    title: first.session.title, purpose: "Linked native history; local chat is separate.", kind: kind)
                try chat.insert(dbc)
                link = WorkspaceSessionLink(chatID: chat.id,
                    provider: WorkspaceSessionProvider(rawValue: provider)!,
                    externalID: first.session.externalID, hostID: first.session.hostID, displayName: first.session.title)
                try link.insert(dbc)
            }
            try Self.saveNativeReview(review, link: link, requestCursor: nil, in: dbc, now: now)
            // Import is an explicit user action; it must not immediately expire
            // an existing temporary chat. It never silently restores archives.
            try dbc.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ? AND lastActivityAt < ?",
                arguments: [now, chat.id, now])
            return try WorkspaceChat.fetchOne(dbc, key: chat.id)!
        }
    }

    public func mergeWorkspaceNativePage(linkID: UUID, page: NativeTranscriptPage,
                                         requestCursor: String?, now: Date = .now) throws {
        try db.queue.write { dbc in
            guard let link = try WorkspaceSessionLink.fetchOne(dbc, key: linkID),
                  let chat = try WorkspaceChat.fetchOne(dbc, key: link.chatID),
                  let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible,
                  try WorkspaceNativeSnapshot.fetchOne(dbc, key: linkID) != nil else {
                throw WorkspaceNativeError.unavailableProject
            }
            try Self.saveNativeReview(Self.review([page]), link: link, requestCursor: requestCursor, in: dbc, now: now)
        }
    }

    /// Complete refresh is one transaction, including freshness and revisions.
    /// A page read or a reviewed partial import must never claim full freshness.
    public func refreshWorkspaceNativeSession(linkID: UUID, pages: [NativeTranscriptPage],
                                               expectedLastSyncedAt: Date?, now: Date = .now) throws {
        try Task.checkCancellation()
        let review = try Self.review(pages)
        guard review.nextCursor == nil, review.session.updatedAt != nil else { throw WorkspaceNativeError.invalidPage }
        try db.queue.write { dbc in
            try Task.checkCancellation()
            guard let link = try WorkspaceSessionLink.fetchOne(dbc, key: linkID),
                  let chat = try WorkspaceChat.fetchOne(dbc, key: link.chatID),
                  let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible,
                  let old = try WorkspaceNativeSnapshot.fetchOne(dbc, key: linkID) else {
                throw WorkspaceNativeError.unavailableProject
            }
            guard old.lastSyncedAt == expectedLastSyncedAt else { throw WorkspaceNativeError.staleCursor }
            try Self.saveNativeReview(review, link: link, requestCursor: nil, completeRefresh: true, in: dbc, now: now)
            try Task.checkCancellation()
        }
    }

    public func workspaceNativeSnapshot(linkID: UUID) throws -> WorkspaceNativeSnapshot? {
        try db.queue.read { try WorkspaceNativeSnapshot.fetchOne($0, key: linkID) }
    }

    public func workspaceNativeMessages(linkID: UUID, offset: Int = 0, limit: Int = 100) throws -> [WorkspaceNativeMessage] {
        guard offset >= 0, (1...200).contains(limit) else { throw WorkspaceNativeError.invalidPage }
        return try db.queue.read { dbc in
            try WorkspaceNativeMessage.filter(Column("sessionLinkID") == linkID)
                .order(Column("position"), Column("id")).limit(limit, offset: offset).fetchAll(dbc)
        }
    }

    public func workspaceNativeMessageCount(linkID: UUID) throws -> Int {
        try db.queue.read { try WorkspaceNativeMessage.filter(Column("sessionLinkID") == linkID).fetchCount($0) }
    }

    public func workspaceNativeRevisions(messageID: UUID) throws -> [WorkspaceNativeRevision] {
        try db.queue.read { dbc in
            try WorkspaceNativeRevision.filter(Column("messageID") == messageID).order(Column("revision")).fetchAll(dbc)
        }
    }

    private static func review(_ pages: [NativeTranscriptPage]) throws -> NativeHistoryReview {
        do { return try canonicalNativeReview(pages) }
        catch let error as NativeHistoryReviewError {
            switch error {
            case .invalidPage, .budgetExceeded: throw WorkspaceNativeError.invalidPage
            case .staleCursor: throw WorkspaceNativeError.staleCursor
            case .sourceMismatch, .conflictingMessage: throw WorkspaceNativeError.sourceMismatch
            }
        }
    }

    private static func saveNativeReview(_ page: NativeHistoryReview, link: WorkspaceSessionLink,
                                        requestCursor: String?, completeRefresh: Bool = false,
                                        in dbc: Database, now: Date) throws {
        guard link.provider.rawValue == page.session.provider.rawValue,
              link.hostID == page.session.hostID, link.externalID == page.session.externalID else {
            throw WorkspaceNativeError.sourceMismatch
        }
        let old = try WorkspaceNativeSnapshot.fetchOne(dbc, key: link.id)
        if let previousVersion = old?.providerUpdatedAt {
            guard let version = page.session.updatedAt, version >= previousVersion else {
                throw WorkspaceNativeError.staleCursor
            }
        }
        if let requestCursor {
            guard old?.nextCursor == requestCursor, old?.direction == page.direction.rawValue,
                  old?.providerUpdatedAt == page.session.updatedAt else {
                throw WorkspaceNativeError.staleCursor
            }
            guard page.nextCursor != requestCursor else { throw WorkspaceNativeError.staleCursor }
        }
        let existing = try WorkspaceNativeMessage.filter(Column("sessionLinkID") == link.id)
            .order(Column("position"), Column("id")).fetchAll(dbc)
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.externalID, $0) })
        let pageIDs = page.messages.map(\.externalID)
        if requestCursor == nil, !existing.isEmpty, !pageIDs.isEmpty, !pageIDs.contains(where: { byID[$0] != nil }) {
            // A wholly rewritten initial page cannot safely be stitched into
            // old evidence. Keep it intact and require a fresh reviewed link.
            throw WorkspaceNativeError.sourceMismatch
        }
        let orderedIDs: [String]
        do {
            orderedIDs = try NativeHistoryReview.mergedOrder(existing: existing.map(\.externalID),
                incoming: pageIDs, direction: page.direction)
        } catch { throw WorkspaceNativeError.sourceMismatch }
        let positions = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        for source in page.messages {
            if var message = byID[source.externalID] {
                guard message.role == source.role.rawValue else { throw WorkspaceNativeError.sourceMismatch }
                if requestCursor != nil, message.text != source.text { throw WorkspaceNativeError.sourceMismatch }
                if message.text != source.text {
                    message.revision += 1
                    message.text = source.text
                    try WorkspaceNativeRevision(id: UUID(), messageID: message.id, revision: message.revision,
                        text: source.text, observedAt: now).insert(dbc)
                }
                message.lastObservedAt = now
                message.position = positions[source.externalID]!
                try message.update(dbc)
            } else {
                let message = WorkspaceNativeMessage(id: UUID(), sessionLinkID: link.id, externalID: source.externalID,
                    role: source.role.rawValue, text: source.text, position: positions[source.externalID]!,
                    firstObservedAt: now, lastObservedAt: now, revision: 1)
                try message.insert(dbc)
                try WorkspaceNativeRevision(id: UUID(), messageID: message.id, revision: 1,
                    text: source.text, observedAt: now).insert(dbc)
            }
        }
        for message in existing where positions[message.externalID] != message.position {
            try dbc.execute(sql: "UPDATE workspaceNativeMessage SET position = ? WHERE id = ?",
                arguments: [positions[message.externalID]!, message.id])
        }
        let snapshot = WorkspaceNativeSnapshot(sessionLinkID: link.id,
            directory: page.session.directory, parentExternalID: page.session.parentExternalID,
            parentRelationship: page.session.parentRelationship?.rawValue,
            providerUpdatedAt: page.session.updatedAt, approvedAt: old?.approvedAt ?? now,
            lastSyncedAt: now, lastCompleteRefreshAt: completeRefresh ? now : old?.lastCompleteRefreshAt,
            coverage: page.coverage, nextCursor: page.nextCursor,
            direction: page.direction.rawValue)
        try snapshot.save(dbc)
        var updatedLink = link
        updatedLink.displayName = page.session.title
        updatedLink.lastSyncedAt = now
        try updatedLink.update(dbc)
    }
}
