import Foundation
import GRDB
import AitvarasAgents

extension AgentPullRequest: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentPullRequest" }
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
