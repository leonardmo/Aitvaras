import Foundation

public enum NativeHistoryReviewError: Error, LocalizedError, Sendable {
    case invalidPage, sourceMismatch, staleCursor, conflictingMessage, budgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidPage: "The source returned invalid history. No history was saved."
        case .sourceMismatch: "The native history source or message order changed. Review it again."
        case .staleCursor: "The native history changed while paging. Review it again."
        case .conflictingMessage: "Two pages disagree about the same message. Review the source again."
        case .budgetExceeded: "The complete history exceeds the safe review limit. No partial refresh was saved."
        }
    }
}

/// The single text/order definition used by both the review UI and persistence.
/// A page overlap must agree exactly; edits between separate reads are retained
/// as revisions by the store, never silently resolved inside one review.
public struct NativeHistoryReview: Sendable, Equatable {
    public static let maximumPages = 100
    public static let maximumCharacters = 10_000_000
    public let session: NativeSessionSummary
    public let messages: [NativeTextMessage]
    public let nextCursor: String?
    public let coverage: String
    public let direction: NativeTranscriptPage.Direction

    public static func validatePage(_ page: NativeTranscriptPage) throws {
        let source = page.session
        guard source.hostID == "local", !source.externalID.isEmpty, source.externalID.count <= 2_000,
              !source.externalID.contains("\0"), !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.title.count <= 200, page.messages.count <= 200,
              page.coverage.count <= 4_000, !page.coverage.isEmpty,
              (page.nextCursor?.count ?? 0) <= 16_384,
              (source.parentExternalID?.count ?? 0) <= 2_000,
              source.updatedAt == nil || source.updatedAt!.timeIntervalSince1970.isFinite else {
            throw NativeHistoryReviewError.invalidPage
        }
        if let directory = source.directory {
            guard directory.hasPrefix("/"), directory.count <= 4_096, !directory.contains("\0") else {
                throw NativeHistoryReviewError.invalidPage
            }
        }
        if let cursor = page.nextCursor, cursor.isEmpty || cursor.contains("\0") {
            throw NativeHistoryReviewError.invalidPage
        }
        var ids = Set<String>()
        var characters = 0
        for message in page.messages {
            characters += message.text.count
            guard !message.externalID.isEmpty, message.externalID.count <= 2_000,
                  !message.externalID.contains("\0"), ids.insert(message.externalID).inserted,
                  message.text.count <= 200_000, characters <= 600_000 else {
                throw NativeHistoryReviewError.invalidPage
            }
        }
    }

    /// Pages themselves are chronological, even when the continuation goes
    /// backwards. Shared IDs anchor inserts; contradictory anchors fail closed.
    public static func mergedOrder(existing: [String], incoming: [String],
                                   direction: NativeTranscriptPage.Direction) throws -> [String] {
        guard Set(existing).count == existing.count, Set(incoming).count == incoming.count else {
            throw NativeHistoryReviewError.invalidPage
        }
        let positions = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element, $0.offset) })
        let anchors = incoming.compactMap { positions[$0] }
        guard zip(anchors, anchors.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw NativeHistoryReviewError.sourceMismatch
        }
        guard !anchors.isEmpty else { return direction == .older ? incoming + existing : existing + incoming }
        var result = existing
        var present = Set(existing)
        for (index, id) in incoming.enumerated() where !present.contains(id) {
            if let next = incoming.dropFirst(index + 1).first(where: { present.contains($0) }),
               let insertion = result.firstIndex(of: next) {
                result.insert(id, at: insertion)
            } else if let previous = incoming.prefix(index).last(where: { present.contains($0) }),
                      let insertion = result.firstIndex(of: previous) {
                result.insert(id, at: insertion + 1)
            }
            present.insert(id)
        }
        return result
    }
}

public func canonicalNativeReview(_ pages: [NativeTranscriptPage]) throws -> NativeHistoryReview {
    guard let first = pages.first else { throw NativeHistoryReviewError.invalidPage }
    guard pages.count <= NativeHistoryReview.maximumPages else { throw NativeHistoryReviewError.budgetExceeded }
    var messages: [String: NativeTextMessage] = [:]
    var orderedIDs: [String] = []
    var cursors = Set<String>()
    var characters = 0
    for (index, page) in pages.enumerated() {
        try NativeHistoryReview.validatePage(page)
        guard page.session.id == first.session.id,
              page.session.directory == first.session.directory,
              page.session.parentExternalID == first.session.parentExternalID,
              page.session.parentRelationship == first.session.parentRelationship else {
            throw NativeHistoryReviewError.sourceMismatch
        }
        guard page.direction == first.direction, page.session.updatedAt == first.session.updatedAt else {
            throw NativeHistoryReviewError.staleCursor
        }
        if index > 0, pages[index - 1].nextCursor == nil { throw NativeHistoryReviewError.invalidPage }
        if let cursor = page.nextCursor, !cursors.insert(cursor).inserted { throw NativeHistoryReviewError.staleCursor }
        for message in page.messages {
            characters += message.text.count
            guard characters <= NativeHistoryReview.maximumCharacters else { throw NativeHistoryReviewError.budgetExceeded }
            if let previous = messages[message.externalID], previous != message {
                throw NativeHistoryReviewError.conflictingMessage
            }
            messages[message.externalID] = message
        }
        orderedIDs = try NativeHistoryReview.mergedOrder(existing: orderedIDs,
            incoming: page.messages.map(\.externalID), direction: page.direction)
    }
    return NativeHistoryReview(session: first.session, messages: orderedIDs.map { messages[$0]! },
        nextCursor: pages.last!.nextCursor, coverage: pages.last!.coverage, direction: first.direction)
}
