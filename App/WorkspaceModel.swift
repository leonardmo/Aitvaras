import Foundation
import AppKit
import AitvarasCore
import AitvarasStore
import AitvarasAgents

/// First workspace checkpoint: durable organization and isolated text-only
/// project conversations. Registering a folder never grants a tool access.
extension AppModel {
    func startNewAgentChat(projectID: UUID? = nil) {
        guard !isWorkspaceSelectionBusy else { return }
        let project = try? stores?.newChatProjectID(requested: projectID)
        showingEarlierChat = false
        selectedWorkspaceChatID = nil; selectedWorkspaceProjectID = nil
        chatModel?.prepareNew(projectID: project)
        try? persistWorkspaceSelection(projectID: nil, chatID: nil)
        workspaceMessage = nil
        NotificationCenter.default.post(name: .init("aitvaras.openWorkspaceChat"), object: nil)
    }

    func chooseChatProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Add project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let preserveDraft = chatModel?.chatID == nil && !showingEarlierChat
        let draft = preserveDraft ? chatModel?.draft : nil
        let composition = preserveDraft ? chatModel?.composerSelection : nil
        if createWorkspaceProject(title: url.lastPathComponent, instructions: "", folderURLs: [url]),
           let projectID = selectedWorkspaceProjectID {
            startNewAgentChat(projectID: projectID)
            if let draft { chatModel?.draft = draft }
            if let composition { chatModel?.composerSelection = composition }
        }
    }

    func setDefaultChatProject(_ id: UUID?) {
        do { try stores?.setDefaultChatProject(id); refreshWorkspaces() }
        catch { workspaceMessage = "Default project could not be saved." }
    }

    var selectedWorkspaceChat: WorkspaceChat? {
        workspaceChats.first { $0.id == selectedWorkspaceChatID }
    }

    var selectedChatConversationID: UUID? { chatConversationID }
    var isWorkspaceSelectionBusy: Bool { isResponding || microphoneInUseByVoice }
    var selectedUnassignedVoiceHistory: Bool {
        selectedWorkspaceProjectID == nil && unassignedChatConversations.contains {
            $0.id == chatConversationID && $0.title == "Voice"
        }
    }

    private static let workspaceProjectKey = "workspace.selectedProjectID"
    private static let workspaceChatKey = "workspace.selectedChatID"

    func refreshWorkspaces() {
        guard let stores else { return }
        do {
            let protectedID = try selectedWorkspaceChatID
                ?? stores.value(forKey: Self.workspaceChatKey).flatMap(UUID.init(uuidString:))
            _ = try stores.archiveExpiredWorkspaceChats(now: .now,
                protectedChatIDs: Set([protectedID].compactMap { $0 }))
            let projects = try stores.workspaceProjects()
            let unassigned = try stores.unassignedConversations().filter { try stores.messageCount(in: $0.id) > 0 }
            let recent = try stores.recentWorkspaceChats(limit: 30)
            let chats = try selectedWorkspaceProjectID.map {
                try stores.workspaceChats(projectID: $0, includeArchived: true)
            } ?? []
            workspaceSidebarChats = try projects.filter(\.isVisible).flatMap {
                try stores.workspaceChats(projectID: $0.id, includeArchived: true)
            }
            defaultChatProjectID = try stores.defaultChatProjectID()
            if let chatModel, chatModel.chatID == nil, let chosen = chatModel.newProjectID,
               !projects.contains(where: { $0.id == chosen && $0.isVisible }) {
                chatModel.newProjectID = try stores.newChatProjectID()
            }
            chatModel?.observeSidebar(workspaceSidebarChats)
            workspaceProjects = projects
            workspaceChats = chats
            unassignedChatConversations = unassigned
            recentWorkspaceChats = recent
            refreshNativeLinks()
        } catch {
            workspaceMessage = "Project history could not be refreshed. Saved conversations have not been removed."
        }
    }

    func restoreWorkspaceSelection() {
        guard let stores else { return }
        do {
            // The last-opened chat is protected from automatic expiry. This is
            // event-driven maintenance, not a background timer or model call.
            let savedChat = try stores.value(forKey: Self.workspaceChatKey).flatMap(UUID.init(uuidString:))
            _ = try stores.archiveExpiredWorkspaceChats(now: .now,
                protectedChatIDs: Set([savedChat].compactMap { $0 }))
            refreshWorkspaces()
            if let id = savedChat,
               let chat = try stores.workspaceChat(id: id),
               let project = try stores.workspaceProject(id: chat.projectID), project.isVisible {
                try loadWorkspaceConversation(chat.localConversationID,
                    projectID: project.id, chatID: chat.id, persist: false)
            } else if let raw = try stores.value(forKey: Self.workspaceProjectKey),
                      let id = UUID(uuidString: raw),
                      let project = try stores.workspaceProject(id: id), project.isVisible {
                selectedWorkspaceProjectID = id
                selectedWorkspaceChatID = nil
                chatModel?.select(nil)
                chatConversationID = nil
                messages = []
                earlierChatMessagesAreHidden = false
            } else if let current = chatConversationID,
                      try stores.workspaceChat(forConversationID: current) != nil {
                // A stale legacy pointer must never route a scoped chat as a
                // global one. Find/create an unassigned conversation instead.
                try loadUnassignedFallback()
            }
            refreshWorkspaces()
        } catch {
            chatConversationID = nil
            selectedWorkspaceProjectID = nil
            selectedWorkspaceChatID = nil
            chatModel?.select(nil)
            messages = []
            workspaceMessage = "Workspace restoration needs a retry. No conversation was deleted or sent."
        }
    }

    func selectWorkspaceProject(_ id: UUID?) {
        guard allowWorkspaceSelection() else { return }
        guard let stores else { return }
        do {
            if let id {
                guard let project = try stores.workspaceProject(id: id), project.isVisible else {
                    throw WorkspaceSelectionError.unavailable
                }
                showingEarlierChat = false
                let chats = try stores.workspaceChats(projectID: id)
                if let first = chats.first(where: { $0.kind == .primary }) ?? chats.first {
                    try loadWorkspaceConversation(first.localConversationID,
                        projectID: id, chatID: first.id)
                } else {
                    try persistWorkspaceSelection(projectID: id, chatID: nil)
                    selectedWorkspaceProjectID = id
                    selectedWorkspaceChatID = nil
                    chatModel?.prepareNew(projectID: id)
                    chatConversationID = nil
                    messages = []
                    earlierChatMessagesAreHidden = false
                }
            } else {
                startNewAgentChat()
            }
            workspaceMessage = nil
            refreshWorkspaces()
        } catch { reportWorkspaceFailure("Project could not be opened", error) }
    }

    func openWorkspaceChat(_ id: UUID) {
        guard allowWorkspaceSelection(), let stores else { return }
        do {
            guard let chat = try stores.workspaceChat(id: id),
                  let project = try stores.workspaceProject(id: chat.projectID), project.isVisible else {
                throw WorkspaceSelectionError.unavailable
            }
            showingEarlierChat = false
            try loadWorkspaceConversation(chat.localConversationID,
                projectID: chat.projectID, chatID: chat.id)
            try stores.setValues(["chat.lastProject": chat.projectID.uuidString])
            chatModel?.markChatOpened(chat.id)
            workspaceMessage = nil
            refreshWorkspaces()
        } catch { reportWorkspaceFailure("Chat could not be opened", error) }
    }

    func openUnassignedConversation(_ id: UUID) {
        guard allowWorkspaceSelection(), let stores else { return }
        do {
            guard try stores.workspaceChat(forConversationID: id) == nil else {
                throw WorkspaceSelectionError.unavailable
            }
            showingEarlierChat = true
            try loadWorkspaceConversation(id, projectID: nil, chatID: nil)
            workspaceMessage = nil
            refreshWorkspaces()
        } catch { reportWorkspaceFailure("Saved conversation could not be opened", error) }
    }

    @discardableResult
    func createWorkspaceProject(title: String, instructions: String, folderURLs: [URL]) -> Bool {
        guard allowWorkspaceSelection(), let stores else { return false }
        do {
            let folders = folderURLs.map {
                WorkspaceFolderDraft(path: $0.resolvingSymlinksInPath().standardizedFileURL.path)
            }
            let project = try stores.createWorkspaceProject(title: title,
                instructions: instructions, folders: folders)
            refreshWorkspaces()
            selectWorkspaceProject(project.id)
            return true
        } catch { reportWorkspaceFailure("Project could not be created", error); return false }
    }

    @discardableResult
    func updateWorkspaceProject(_ project: WorkspaceProject) -> Bool {
        guard allowWorkspaceSelection(), let stores else { return false }
        do {
            // Cloud/session execution is not enabled by this first checkpoint.
            var safeProject = project
            safeProject.allowsCloud = false
            try stores.saveWorkspaceProject(safeProject)
            refreshWorkspaces()
            if !safeProject.isVisible, selectedWorkspaceProjectID == safeProject.id {
                startNewAgentChat()
                refreshWorkspaces()
            }
            workspaceMessage = nil
            return true
        } catch { reportWorkspaceFailure("Project changes were not saved", error); return false }
    }

    @discardableResult
    func createWorkspaceChat(title: String, kind: WorkspaceChat.Kind, purpose: String, projectID: UUID? = nil) -> Bool {
        guard allowWorkspaceSelection(), let stores, let projectID = projectID ?? selectedWorkspaceProjectID else { return false }
        do {
            let chat = try stores.createWorkspaceChat(projectID: projectID, title: title,
                kind: kind, purpose: purpose)
            refreshWorkspaces()
            openWorkspaceChat(chat.id)
            return true
        } catch { reportWorkspaceFailure("Chat could not be created", error); return false }
    }


    @discardableResult
    func updateWorkspaceChat(_ chat: WorkspaceChat) -> Bool {
        guard allowWorkspaceSelection(), let stores else { return false }
        do {
            try stores.saveWorkspaceChat(chat)
            workspaceMessage = nil
            refreshWorkspaces()
            return true
        } catch { reportWorkspaceFailure("Chat changes were not saved", error); return false }
    }

    @discardableResult
    func assignUnassignedConversation(_ id: UUID, projectID: UUID, title: String,
                                     kind: WorkspaceChat.Kind, purpose: String) -> Bool {
        guard allowWorkspaceSelection(), let stores else { return false }
        do {
            guard let conversation = try stores.conversation(id: id), conversation.title != "Voice",
                  let project = try stores.workspaceProject(id: projectID), project.isVisible else {
                throw WorkspaceSelectionError.unavailable
            }
            let chat = try stores.createWorkspaceChat(projectID: projectID, title: title,
                kind: kind, purpose: purpose, existingConversationID: id)
            refreshWorkspaces()
            openWorkspaceChat(chat.id)
            return true
        } catch { reportWorkspaceFailure("Conversation could not be assigned", error); return false }
    }

    func setWorkspaceChatArchived(_ id: UUID, archived: Bool) {
        guard let agentSessionManager else { return }
        Task {
            do {
                try await agentSessionManager.setArchived(chatID: id, archived: archived)
                workspaceMessage = nil
                refreshWorkspaces()
            } catch { reportWorkspaceFailure("Chat archive status was not changed", error) }
        }
    }

    func renameWorkspaceChat(_ id: UUID, title: String) {
        guard let agentSessionManager else { return }
        Task {
            do {
                try await agentSessionManager.rename(chatID: id, title: title)
                workspaceMessage = nil
                refreshWorkspaces()
            } catch { reportWorkspaceFailure("Chat title was not saved", error) }
        }
    }

    private func allowWorkspaceSelection() -> Bool {
        guard !isWorkspaceSelectionBusy else {
            workspaceMessage = "Finish or stop the active response or voice conversation before changing chats."
            return false
        }
        return true
    }

    private func loadUnassignedFallback() throws {
        guard let stores else { throw WorkspaceSelectionError.unavailable }
        let candidates = try stores.unassignedConversations()
        let saved = try stores.value(forKey: "chat.conversationID").flatMap(UUID.init(uuidString:))
        if let conversation = candidates.first(where: { $0.id == saved })
            ?? candidates.first(where: { $0.title == "Chat" }) {
            try loadWorkspaceConversation(conversation.id, projectID: nil, chatID: nil)
        } else {
            let id = try stores.rotatePersistentConversation(forKey: "chat.conversationID", title: "Chat")
            try loadWorkspaceConversation(id, projectID: nil, chatID: nil)
        }
    }

    private func persistWorkspaceSelection(projectID: UUID?, chatID: UUID?, conversationID: UUID? = nil) throws {
        guard let stores else { throw WorkspaceSelectionError.unavailable }
        var values = [
            Self.workspaceProjectKey: projectID?.uuidString ?? "",
            Self.workspaceChatKey: chatID?.uuidString ?? ""
        ]
        if projectID == nil, let conversationID { values["chat.conversationID"] = conversationID.uuidString }
        try stores.setValues(values)
    }

    private func loadWorkspaceConversation(_ id: UUID, projectID: UUID?, chatID: UUID?, persist: Bool = true) throws {
        guard let stores, try stores.conversation(id: id) != nil else { throw WorkspaceSelectionError.unavailable }
        let loaded = try stores.messages(in: id, limit: Self.visibleChatMessageLimit).compactMap { stored -> DisplayMessage? in
            guard let role = DisplayMessage.Role(storedRole: stored.role) else { return nil }
            return DisplayMessage(id: stored.id, role: role, text: stored.content)
        }
        let count = try stores.messageCount(in: id)
        if persist { try persistWorkspaceSelection(projectID: projectID, chatID: chatID, conversationID: id) }
        chatConversationID = id
        selectedWorkspaceProjectID = projectID
        selectedWorkspaceChatID = chatID
        messages = loaded
        earlierChatMessagesAreHidden = count > Self.visibleChatMessageLimit
        // Warm the next project's rows before publishing the selected chat.
        workspaceChats = try projectID.map { try stores.workspaceChats(projectID: $0, includeArchived: true) } ?? []
        chatModel?.select(chatID)
    }

    private func reportWorkspaceFailure(_ title: String, _ error: Error) {
        // Keep configuration failures inline, rather than producing background
        // notifications containing project names or personal filesystem paths.
        workspaceMessage = "\(title). \(error.localizedDescription)"
    }
}

private enum WorkspaceSelectionError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The selected saved workspace is unavailable. Refresh and try again." }
}
