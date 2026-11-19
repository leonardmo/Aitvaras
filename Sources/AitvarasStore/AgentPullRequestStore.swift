import Foundation
import GRDB
import AitvarasAgents
import AitvarasCore

extension AgentPullRequest: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentPullRequest" }
}

extension Stores: AgentPullRequestWatchPersistence {
    public func watchedPullRequests() throws -> [AgentPullRequest] {
        try db.queue.read { db in
            try AgentPullRequest.filter(Column("watch") == true).order(Column("createdAt")).fetchAll(db).filter {
                try WorkspaceChat.fetchOne(db, key: $0.chatID)?.archivedAt == nil
            }
        }
    }

    public func compareAndAdvancePullRequest(from expected: AgentPullRequest, to next: AgentPullRequest,
                                            change: PullRequestWatchChange, turnID: UUID?) throws -> Bool {
        let changed = try db.queue.write { db -> Bool in
            guard expected.chatID == next.chatID, expected != next,
                  try AgentPullRequest.fetchOne(db, key: expected.chatID) == expected,
                  let chat = try WorkspaceChat.fetchOne(db, key: expected.chatID) else { return false }
            if change != .user || next.watch {
                guard chat.archivedAt == nil,
                      try WorkspaceProject.fetchOne(db, key: chat.projectID)?.isVisible == true else { return false }
            }
            if change != .user {
                guard expected.watch, try Self.backgroundWorkPolicy(in: db).permits(.pullRequestWatch) else { return false }
            }
            if let turnID {
                guard let turn = try AgentJournalTurn.fetchOne(db, key: turnID), turn.chatID == chat.id,
                      turn.origin == .autonomous(.pullRequest), turn.delivery == .prepared else { return false }
                try AgentTurnStore.advanceDelivery(turn, to: .deliveryUnknown, in: db)
            }
            try next.update(db, columns: ["watch", "commentWatermark", "checkWatermark"])
            if let title = change.title(watching: next.watch) {
                try ActivityEvent(kind: .toolExecuted, connectorID: "agent.forge", summary: title,
                    detailJSON: JSONValue.object(["chatID": .string(chat.id.uuidString), "on": .bool(next.watch)]).jsonString).insert(db)
                if change != .user {
                    try ActivityRun(referenceID: chat.id.uuidString, category: .chat, trigger: .automatic,
                        state: change.needsAttention ? .failed : .succeeded, title: title).insert(db)
                }
            }
            return true
        }
        if changed, change != .progress || turnID != nil {
            NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
        }
        return changed
    }
}
extension Stores: AgentPullRequestPersistence {
    public func agentPullRequest(chatID: UUID) throws -> AgentPullRequest? {
        try db.queue.read { try AgentPullRequest.fetchOne($0, key: chatID) }
    }
    public func bindAgentPullRequest(_ value: AgentPullRequest) throws {
        try db.queue.write { db in
            guard try WorkspaceChat.fetchOne(db, key: value.chatID) != nil else { throw AgentStoreError.missingChat }
            try value.save(db)
        }
    }
}
