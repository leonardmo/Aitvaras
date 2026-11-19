import Foundation
import GRDB
import AitvarasCore

public struct ActivityRunDetailSnapshot: Sendable, Equatable {
    public let run: ActivityRun
    public let representedRuns: [ActivityRun]
    public let dismissalGroup: ActivityAttentionGroup?
    public let destination: ActivityDetailDestination?
    public let steps: [ActivityRunStep]
    public let events: [ActivityEvent]
    public var earlierFailures: [ActivityRun] {
        representedRuns.filter { $0.id != run.id && ($0.state == .failed || $0.state == .interrupted) }
    }
}

public enum ActivityRunDetailError: Error, Sendable { case runNotFound }

extension Stores {
    public func activityRunDetailSnapshot(_ selection: ActivityRunDetailSelection) throws -> ActivityRunDetailSnapshot {
        try db.queue.read { db in
            guard let run = try ActivityRun.fetchOne(db, key: selection.id) else { throw ActivityRunDetailError.runNotFound }
            let ids = Array(Set(selection.runIDs))
            var records: [UUID: ActivityRun] = [:]
            for offset in stride(from: 0, to: ids.count, by: 500) {
                let batch = Array(ids[offset..<min(offset + 500, ids.count)])
                for record in try ActivityRun.filter(batch.contains(Column("id"))).fetchAll(db) { records[record.id] = record }
            }
            let represented = selection.runIDs.compactMap { records[$0] }
            let attention = try Self.activityAttentionSnapshot(in: db)
            let expectedID: ActivityAttentionGroup.ID
            if let group = selection.group { expectedID = group.id }
            else if let key = run.jobKey, run.state == .failed || run.state == .interrupted { expectedID = .job(key) }
            else { expectedID = .run(run.id) }
            let representedIDs = Set(ids)
            let eligible = attention.groups.first { $0.id == expectedID }?.runs.filter { representedIDs.contains($0.id) } ?? []
            let dismissal = eligible.first.map { ActivityAttentionGroup(id: expectedID, latestRun: $0, earlierRuns: Array(eligible.dropFirst())) }
            return ActivityRunDetailSnapshot(run: run, representedRuns: represented, dismissalGroup: dismissal,
                destination: try Self.activityDetailDestination(for: run, in: db),
                steps: try ActivityRunStep.filter(Column("runID") == run.id).order(Column("timestamp"), Column("rowid")).fetchAll(db),
                events: try ActivityEvent.filter(Column("runID") == run.id).order(Column("timestamp"), Column("id")).fetchAll(db))
        }
    }

    /// Revalidate on Open as well as when building the action row. Missing,
    /// malformed and hidden destinations are not a reason to dismiss the sheet.
    public func activityDetailDestination(for run: ActivityRun) throws -> ActivityDetailDestination? {
        try db.queue.read { try Self.activityDetailDestination(for: run, in: $0) }
    }

    private static func activityDetailDestination(for run: ActivityRun, in db: Database) throws -> ActivityDetailDestination? {
        guard let reference = run.referenceID, let id = UUID(uuidString: reference) else { return nil }
        if run.category == .capture {
            return try CaptureRecord.fetchOne(db, key: id) == nil ? nil : .capture(id)
        }
        guard [.chat, .voice, .memory].contains(run.category) else { return nil }
        // Native chat runs reference the workspace chat; archiving and legacy
        // chat/voice runs reference its local conversation instead.
        if run.category == .chat, let chat = try WorkspaceChat.fetchOne(db, key: id) {
            return try validActivityChat(chat, in: db) ? .workspaceChat(chat.id) : nil
        }
        guard try Conversation.fetchOne(db, key: id) != nil else { return nil }
        if let chat = try WorkspaceChat.filter(Column("localConversationID") == id).fetchOne(db) {
            return try validActivityChat(chat, in: db) ? .workspaceChat(chat.id) : nil
        }
        return .conversation(id)
    }

    private static func validActivityChat(_ chat: WorkspaceChat, in db: Database) throws -> Bool {
        guard let project = try WorkspaceProject.fetchOne(db, key: chat.projectID), project.isVisible else { return false }
        return try Conversation.fetchOne(db, key: chat.localConversationID) != nil
    }
}
