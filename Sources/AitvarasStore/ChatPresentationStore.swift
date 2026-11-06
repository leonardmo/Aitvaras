import Foundation
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
        guard let turn = try latestAgentTurn(chatID: id), turn.state == .completed else { return false }
        return try value(forKey: "chat.lastSeen.\(id.uuidString)") != turn.id.uuidString
    }

    public func markChatSeen(_ id: UUID) throws {
        guard let turn = try latestAgentTurn(chatID: id), turn.state == .completed else { return }
        let key = "chat.lastSeen.\(id.uuidString)"
        if try value(forKey: key) != turn.id.uuidString { try setValues([key: turn.id.uuidString]) }
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
