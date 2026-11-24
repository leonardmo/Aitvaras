import Foundation
import GRDB
import AitvarasAgents

extension Stores: AgentMessageQueuePersistence {
    public func messageQueue(chatID: UUID) throws -> AgentMessageQueue {
        try db.queue.read { database in
            guard let data = try Data.fetchOne(database, sql: "SELECT payload FROM agentMessageQueue WHERE chatID = ?",
                                               arguments: [chatID]) else { return .init() }
            return try JSONDecoder().decode(AgentMessageQueue.self, from: data)
        }
    }

    public func saveMessageQueue(_ queue: AgentMessageQueue, chatID: UUID) throws {
        try db.queue.write { database in
            if queue.messages.isEmpty {
                try database.execute(sql: "DELETE FROM agentMessageQueue WHERE chatID = ?", arguments: [chatID])
            } else {
                try database.execute(sql: """
                    INSERT INTO agentMessageQueue (chatID, payload) VALUES (?, ?)
                    ON CONFLICT(chatID) DO UPDATE SET payload = excluded.payload
                    """, arguments: [chatID, JSONEncoder().encode(queue)])
            }
        }
    }
}
