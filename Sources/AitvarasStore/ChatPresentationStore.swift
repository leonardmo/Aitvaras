import Foundation
import GRDB
import AitvarasAgents

/// Profile-local choices and read receipts use the existing key/value store.
extension Stores {
    public func defaultChatProjectID() throws -> UUID? {
        guard let raw = try value(forKey: "chat.defaultProject"), let id = UUID(uuidString: raw) else { return nil }
        guard try workspaceProject(id: id)?.isVisible == true else {
            try setValues(["chat.defaultProject": ""])
            return nil
        }
        return id
    }

    public func setDefaultChatProject(_ id: UUID?) throws {
        if let id, try workspaceProject(id: id)?.isVisible != true { throw AgentStoreError.invalidValue }
        try setValues(["chat.defaultProject": id?.uuidString ?? ""])
    }

    public func newChatProjectID(requested: UUID? = nil) throws -> UUID? {
        let projects = try workspaceProjects(includeHidden: false)
        if let requested, projects.contains(where: { $0.id == requested }) { return requested }
        if let id = try defaultChatProjectID() { return id }
        // Explicitly opened/sent chats update this profile-local usage pointer.
        if let raw = try value(forKey: "chat.lastProject"), let id = UUID(uuidString: raw),
           projects.contains(where: { $0.id == id }) { return id }
        if let recent = try recentWorkspaceChats(limit: 1).first { return recent.chat.projectID }
        return projects.last?.id
    }

    /// Called only by Send. Merely presenting or abandoning a draft writes no chat.
    public func createChatOnFirstSend(projectID: UUID?, text: String, hasAttachments: Bool = false, requiresWorktree: Bool = false) throws -> WorkspaceChat? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments else { return nil }
        guard let projectID, try workspaceProject(id: projectID)?.isVisible == true else { throw AgentStoreError.invalidValue }
        let chat = try createWorkspaceChat(projectID: projectID, title: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : String(text.prefix(60)),
                                           kind: .temporary, requiresWorktree: requiresWorktree)
        try setValues(["chat.lastProject": projectID.uuidString])
        return chat
    }

    public func chatHasUnseenCompletion(_ id: UUID) throws -> Bool {
        try db.queue.read { dbc in
            let previous = try Self.savedChatReceipt(id, in: dbc)
            if previous == Self.manualUnreadReceipt { return true }
            guard let turn = try AgentTurnStore.latest(chatID: id, in: dbc),
                  turn.state == .completed || turn.origin != .user else { return false }
            return previous != Self.chatReadReceipt(turn)
        }
    }

    public func markChatUnread(_ id: UUID) throws {
        try setValue(Self.manualUnreadReceipt, forKey: Self.chatReceiptKey(id))
    }

    public func markChatSeen(_ id: UUID, clearingManualUnread: Bool = true) throws {
        try db.queue.write { dbc in
            let previous = try Self.savedChatReceipt(id, in: dbc)
            if previous == Self.manualUnreadReceipt && !clearingManualUnread { return }
            let key = Self.chatReceiptKey(id)
            if let turn = try AgentTurnStore.latest(chatID: id, in: dbc),
               turn.state == .completed || turn.origin != .user {
                let receipt = Self.chatReadReceipt(turn)
                if previous != receipt {
                    try dbc.execute(sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                    arguments: [key, receipt])
                }
            } else if previous == Self.manualUnreadReceipt {
                try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    private static let manualUnreadReceipt = "unread"

    private static func chatReceiptKey(_ id: UUID) -> String { "chat.lastSeen.\(id.uuidString)" }

    private static func savedChatReceipt(_ id: UUID, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [chatReceiptKey(id)])
    }

    private static func chatReadReceipt(_ turn: AgentJournalTurn) -> String {
        turn.origin == .user ? turn.id.uuidString : "\(turn.id.uuidString):\(turn.state.rawValue)"
    }
}

public enum ProjectChatVisibility {
    public static func visible(_ chats: [WorkspaceChat], statuses: [UUID: ChatSidebarStatus],
                               selectedID: UUID?, expanded: Bool) -> [WorkspaceChat] {
        let sorted = chats.sorted {
            $0.lastActivityAt == $1.lastActivityAt ? $0.id.uuidString < $1.id.uuidString : $0.lastActivityAt > $1.lastActivityAt
        }
        if expanded { return sorted }
        let recent = Set(sorted.prefix(5).map(\.id))
        return sorted.filter {
            recent.contains($0.id) || $0.id == selectedID || statuses[$0.id] == .running || statuses[$0.id] == .needsYou
        }
    }
}
