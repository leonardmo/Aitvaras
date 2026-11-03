import Foundation
import AitvarasCore

/// Fetches all currently exposed text before the caller performs one atomic
/// save. No local state is changed, and no native execution/write API is used.
public enum NativeHistoryRefresh {
    public enum RefreshError: Error, LocalizedError, Sendable {
        case sourceVersionUnavailable, sourceChanged
        public var errorDescription: String? {
            switch self {
            case .sourceVersionUnavailable: "This source does not expose a reliable update time. A complete refresh cannot be verified; saved history is unchanged."
            case .sourceChanged: "The native history changed during refresh. Saved history is unchanged; try again."
            }
        }
    }

    public static func fetch(reader: any NativeSessionReader, id: String, directory: String?,
                             onProgress: @Sendable (Int) async -> Void = { _ in }) async throws -> [NativeTranscriptPage] {
        var pages: [NativeTranscriptPage] = []
        var cursor: String?
        var seenCursors = Set<String>()
        var characters = 0
        repeat {
            try Task.checkCancellation()
            guard pages.count < NativeHistoryReview.maximumPages else { throw NativeHistoryReviewError.budgetExceeded }
            let page = try await reader.readSession(id: id, directory: directory, cursor: cursor)
            try Task.checkCancellation()
            guard page.session.externalID == id, page.session.provider == reader.provider else {
                throw NativeHistoryReviewError.sourceMismatch
            }
            guard page.session.updatedAt != nil else { throw RefreshError.sourceVersionUnavailable }
            try NativeHistoryReview.validatePage(page)
            if let first = pages.first {
                guard page.session.id == first.session.id, page.session.directory == first.session.directory,
                      page.session.parentExternalID == first.session.parentExternalID,
                      page.session.parentRelationship == first.session.parentRelationship else {
                    throw NativeHistoryReviewError.sourceMismatch
                }
                guard page.direction == first.direction, page.session.updatedAt == first.session.updatedAt else {
                    throw NativeHistoryReviewError.staleCursor
                }
            }
            if let next = page.nextCursor, !seenCursors.insert(next).inserted {
                throw NativeHistoryReviewError.staleCursor
            }
            characters += page.messages.reduce(0) { $0 + $1.text.count }
            guard characters <= NativeHistoryReview.maximumCharacters else { throw NativeHistoryReviewError.budgetExceeded }
            pages.append(page)
            await onProgress(pages.count)
            try Task.checkCancellation()
            cursor = page.nextCursor
        } while cursor != nil
        _ = try canonicalNativeReview(pages)
        try Task.checkCancellation()

        // A session version can advance after the last page's metadata read.
        // Fence the traversal with a fresh initial read before exposing results.
        let fence = try await reader.readSession(id: id, directory: directory, cursor: nil)
        try Task.checkCancellation()
        try NativeHistoryReview.validatePage(fence)
        let first = pages[0]
        guard fence.session.id == first.session.id, fence.session.updatedAt == first.session.updatedAt,
              fence.session.directory == first.session.directory,
              fence.session.parentExternalID == first.session.parentExternalID,
              fence.session.parentRelationship == first.session.parentRelationship,
              fence.direction == first.direction, fence.nextCursor == first.nextCursor,
              fence.messages == first.messages else { throw RefreshError.sourceChanged }
        return pages
    }
}
