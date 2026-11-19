import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents
import CryptoKit

extension Stores: AgentConversationPersistence {
    public func conversationSource(chatID: UUID) throws -> AgentConversationSource {
        try db.queue.read { try Self.conversationSource(chatID: chatID, in: $0) }
    }
    public func conversationSource(chatID: UUID, messageID: UUID) throws -> AgentConversationSource {
        try db.queue.read { db in
            guard let entry = try AgentTranscriptEntry.fetchOne(db, key: messageID), entry.chatID == chatID,
                  let sessionID = entry.sessionID else { throw AgentConversationError.invalidMessage }
            return try Self.conversationSource(chatID: chatID, sessionID: sessionID, in: db)
        }
    }
    private static func conversationSource(chatID: UUID, sessionID: UUID? = nil, in db: Database) throws -> AgentConversationSource {
        var selected = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?",
            arguments: ["agent.claudeProfile.\(chatID.uuidString)"]) ?? "default"
        if selected != "default" {
            if let id = UUID(uuidString: selected), let profile = try AgentProviderProfile.fetchOne(db, key: id), !profile.isDeleted {} else { selected = "default" }
        }
        let sessions = AgentChatSession.filter(Column("chatID") == chatID).filter(Column("provider") == AgentProvider.claude.rawValue)
        let session: AgentChatSession?
        if let sessionID { session = try sessions.filter(Column("id") == sessionID).fetchOne(db) }
        else { session = try sessions.filter(Column("providerProfile") == selected).fetchOne(db) }
        guard let chat = try WorkspaceChat.fetchOne(db, key: chatID), chat.archivedAt == nil,
              try WorkspaceProject.fetchOne(db, key: chat.projectID)?.isVisible == true,
              let session else { throw AgentConversationError.unavailable }
        guard try AgentJournalTurn.filter(Column("chatID") == chatID)
            .filter(Column("state") == AgentJournalState.running.rawValue).fetchCount(db) == 0 else { throw AgentConversationError.busy }
        let owned = try AgentWorktree.fetchOne(db, key: chatID)
        let requested = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: ["agent.worktreeRequested.\(chatID.uuidString)"]) == "true"
        if requested || owned != nil { guard owned?.state == .ready else { throw AgentGitError.creationFailed } }
        let entries = try AgentTranscriptEntry.filter(Column("chatID") == chatID).filter(Column("isActive") == true)
            .order(Column("position")).fetchAll(db).filter { ["user", "assistant"].contains($0.kind) }
        var completed = Set<UUID>(), current: AgentJournalTurn?
        for entry in entries {
            if entry.kind == "user" { current = try AgentJournalTurn.fetchOne(db, key: entry.id) }
            let payload = entry.payloadJSON.flatMap(JSONValue.parse)
            if let native = payload?["nativeHistory"] {
                if native["completed"]?.boolValue == true {
                    if let input = payload?["journalInputID"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                        if try AgentJournalTurn.fetchOne(db, key: input)?.state == .completed { completed.insert(entry.id) }
                    } else { completed.insert(entry.id) }
                }
            } else if current?.state == .completed, current?.sessionID == entry.sessionID { completed.insert(entry.id) }
        }
        return .init(chatID: chatID, projectID: chat.projectID, title: chat.title, session: session,
            entries: entries, completedIDs: completed, worktree: owned)
    }

    public func createConversationFork(_ plan: AgentConversationForkPlan, chatID: UUID, directory: URL,
                                       additionalRoots: [URL]) throws {
        let tool = ToolDefinition(name: "fork", description: "Fork conversation", parametersJSON: "{}", risk: .reversibleWrite)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.conversation") == .allow else { throw AgentFailure.invalidRequest }
        try db.queue.write { db in
            guard try Self.conversationSource(chatID: plan.source.chatID, sessionID: plan.source.session.id, in: db) == plan.source else { throw AgentConversationError.invalidMessage }
            let conversation = Conversation(title: String(("Fork of " + plan.source.title).prefix(200)))
            try conversation.insert(db)
            let chat = WorkspaceChat(id: chatID, projectID: plan.source.projectID, localConversationID: conversation.id, title: conversation.title)
            try chat.insert(db)
            var session = plan.source.session
            session.id = UUID(); session.chatID = chatID; session.sessionID = nil
            session.forkOrigin = plan.origin; session.cwd = directory.path
            session.additionalRootsJSON = String(decoding: try JSONEncoder().encode(additionalRoots.map(\.path)), as: UTF8.self)
            try session.insert(db)
            try db.execute(sql: "INSERT INTO kv(key, value) VALUES (?, ?)",
                arguments: ["agent.claudeProfile.\(chatID.uuidString)", session.providerProfile])
            for (position, original) in plan.prefix.enumerated() {
                var entry = original
                entry.id = UUID(); entry.chatID = chatID; entry.position = position
                if original.sessionID == plan.source.session.id { entry.sessionID = session.id }
                else { entry.sessionID = nil; entry.nativeMessageID = nil }
                let prior = original.payloadJSON.flatMap(JSONValue.parse)
                var wireDigest = prior?["forkWireDigest"] ?? .null
                if original.kind == "user", let turn = try AgentJournalTurn.fetchOne(db, key: original.id),
                   turn.sessionID == original.sessionID, turn.delivery == .acknowledged {
                    wireDigest = turn.prompt.map { .string(Self.conversationWireDigest($0)) } ?? .null
                }
                entry.payloadJSON = JSONValue.object([
                    "composer": original.payloadJSON.flatMap(JSONValue.parse)?["composer"] ?? .null,
                    "nativeHistory": .object(["completed": .bool(plan.source.completedIDs.contains(original.id))]),
                    "forkInheritedForSession": .string(session.id.uuidString), "forkSourceEntryID": .string(original.id.uuidString),
                    "forkWireDigest": wireDigest
                ]).jsonString
                try entry.insert(db)
            }
            try db.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?)", arguments: ["agent.provider.\(chatID.uuidString)", "claude"])
            if plan.source.worktree != nil {
                try db.execute(sql: "INSERT INTO kv(key,value) VALUES(?,?)", arguments: ["agent.worktreeRequested.\(chatID.uuidString)", "true"])
            }
            try ActivityEvent(kind: .toolExecuted, connectorID: "agent.conversation", summary: "Fork conversation",
                detailJSON: JSONValue.object(["sourceChatID": .string(plan.source.chatID.uuidString), "chatID": .string(chatID.uuidString),
                    "projectID": .string(plan.source.projectID.uuidString), "risk": .string(ActionRisk.reversibleWrite.rawValue)]).jsonString).insert(db)
        }
    }

    static func conversationWireDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func finishConversationFork(chatID: UUID, worktree: AgentWorktree) throws {
        try db.queue.read { db in
            guard worktree.chatID == chatID, worktree.state == .ready,
                  try AgentWorktree.fetchOne(db, key: chatID) == worktree,
                  let session = try AgentChatSession.filter(Column("chatID") == chatID)
                    .filter(Column("provider") == AgentProvider.claude.rawValue).fetchOne(db),
                  session.cwd == worktree.worktreePath || session.cwd.hasPrefix(worktree.worktreePath + "/") else { throw AgentGitError.ownershipConflict }
        }
    }
}
