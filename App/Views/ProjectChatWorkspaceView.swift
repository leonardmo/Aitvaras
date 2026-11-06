import SwiftUI
import AppKit
import AitvarasStore
import AitvarasAgents

/// Projects and their chats share the app's single sidebar.
struct WorkspaceRailView: View {
    var initialRecent = false
    @Environment(AppModel.self) private var model
    @State private var creatingChat: WorkspaceProject?
    @State private var showingNewProject = false
    @State private var showingProjectManager = false
    @State private var editingProject: WorkspaceProject?
    @State private var renamingChat: WorkspaceChat?
    @State private var newTitle = ""
    @State private var assigningConversation: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.workspaceProjects.filter(\.isVisible)) { project in
                        projectGroup(project)
                    }
                    DisclosureGroup("Unassigned") {
                        Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                            .accessibilityIdentifier("chat.new.unassigned")
                        ForEach(model.unassignedChatConversations) { conversation in
                            Button {
                                model.openUnassignedConversation(conversation.id)
                            } label: {
                                Label(conversation.title, systemImage: conversation.title == "Voice" ? "waveform" : "bubble.left")
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("chat.sidebar.\(conversation.id)")
                            .contextMenu {
                                if conversation.title != "Voice" {
                                    Button("Move to project…") { assigningConversation = conversation }
                                }
                            }
                        }
                    }.font(.callout).buttonStyle(.plain)
                }.padding(10)
            }
            Divider()
            HStack {
                Button("New project", systemImage: "folder.badge.plus") { showingNewProject = true }
                    .accessibilityIdentifier("chat.project.new")
                Spacer()
                Button("Refresh native chats", systemImage: model.chatModel?.nativeDiscoveryFailed == true ? "exclamationmark.circle" : "arrow.clockwise") {
                    Task { await refreshNativeChats() }
                }
                .disabled(model.chatModel?.discoveringNativeSessions == true)
                .help(model.chatModel?.nativeDiscoveryError ?? "Refresh native chats")
                .accessibilityIdentifier("chat.native.refresh")
                Menu {
                    Button("Manage projects…") { showingProjectManager = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("Projects").accessibilityIdentifier("chat.projects.menu")
                .menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.borderless).labelStyle(.iconOnly).padding(10)
        }
        .disabled(model.isWorkspaceSelectionBusy)
        .task { model.refreshWorkspaces() }
        .popover(item: $creatingChat) { project in
            NewAgentChatView(project: project) { creatingChat = nil }
        }
        .task(id: model.workspaceProjects.map { "\($0.id):\($0.updatedAt)" }.joined() + String(model.chatModel != nil)) {
            await refreshNativeChats()
        }
        .sheet(isPresented: $showingNewProject) {
            WorkspaceProjectEditor { title, instructions, folders in
                model.createWorkspaceProject(title: title, instructions: instructions, folderURLs: folders)
            }
        }
        .sheet(item: $editingProject) { project in
            WorkspaceProjectEditor(project: project) { title, instructions, _ in
                var updated = project; updated.title = title; updated.instructions = instructions
                return model.updateWorkspaceProject(updated)
            }
        }
        .sheet(isPresented: $showingProjectManager) { WorkspaceProjectManager() }
        .sheet(item: $assigningConversation) { WorkspaceConversationAssignmentEditor(conversation: $0) }
        .alert("Rename chat", isPresented: Binding(get: { renamingChat != nil }, set: { if !$0 { renamingChat = nil } })) {
            TextField("Title", text: $newTitle)
                .accessibilityIdentifier("chat.rename.title")
            Button("Save") {
                if let chat = renamingChat { model.renameWorkspaceChat(chat.id, title: newTitle) }
                renamingChat = nil
            }
            .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("chat.rename.save")
            Button("Cancel", role: .cancel) { renamingChat = nil }
                .accessibilityIdentifier("chat.rename.cancel")
        }
    }

    private func refreshNativeChats() async {
        guard !model.workspaceProjects.isEmpty, let chat = model.chatModel else { return }
        await chat.discoverNativeSessions()
        model.refreshWorkspaces()
    }

    private func projectGroup(_ project: WorkspaceProject) -> some View {
        let all = model.workspaceSidebarChats.filter { $0.projectID == project.id }
        let active = all.filter { $0.archivedAt == nil }.sorted {
            if $0.kind != $1.kind { return $0.kind == .primary }
            return $0.lastActivityAt > $1.lastActivityAt
        }
        let archived = all.filter { $0.archivedAt != nil }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(project.title, systemImage: "folder").font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button("New Chat", systemImage: "square.and.pencil") {
                    creatingChat = project
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .accessibilityIdentifier("chat.new.\(project.id)")
            }
            .foregroundStyle(.secondary)
            .contextMenu {
                Button("Edit project…") { editingProject = project }
                Button("Hide project") { var updated = project; updated.isVisible = false; model.updateWorkspaceProject(updated) }
            }
            ForEach(active) { chat in chatRow(chat) }
            if !archived.isEmpty {
                DisclosureGroup("Archived") { ForEach(archived) { chat in chatRow(chat) } }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.archived.\(project.id)")
            }
        }
    }
    private func chatRow(_ chat: WorkspaceChat) -> some View {
        SidebarChatRow(chat: chat, selected: model.selectedWorkspaceChatID == chat.id,
                       manager: model.agentSessionManager, open: { model.openWorkspaceChat(chat.id) })
        .contextMenu {
            Button("Rename") { newTitle = chat.title; renamingChat = chat }
                .accessibilityIdentifier("chat.rename.\(chat.id)")
            Button(chat.kind == .primary ? "Unpin" : "Pin") {
                var updated = chat; updated.kind = chat.kind == .primary ? .temporary : .primary
                model.updateWorkspaceChat(updated)
            }
            Button(chat.archivedAt == nil ? "Archive" : "Restore") {
                model.setWorkspaceChatArchived(chat.id, archived: chat.archivedAt == nil)
            }
            .accessibilityIdentifier("chat.\(chat.archivedAt == nil ? "archive" : "restore").\(chat.id)")
        }
    }
    static func chipLabel(_ title: String, limit: Int = 14) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }
}

private struct SidebarChatRow: View {
    let chat: WorkspaceChat
    let selected: Bool
    let manager: AgentSessionManager?
    let open: () -> Void
    @State private var state: ChatState?
    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityLabel(statusTitle)
                    .accessibilityIdentifier("chat.status.\(chat.id)")
                Text(chat.title).lineLimit(1)
                Spacer(minLength: 0)
                if chat.kind == .primary { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            .font(.callout).padding(.horizontal, 7).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(statusTitle)
        .accessibilityIdentifier("chat.sidebar.\(chat.id)")
        .accessibilityValue(statusTitle)
        .task(id: manager.map { ObjectIdentifier($0) }) {
            guard let manager else { return }
            do {
                for await value in try await manager.updates(chatID: chat.id) {
                    guard !Task.isCancelled else { return }; state = value
                }
            } catch { state = nil }
        }
    }
    private var statusColor: Color {
        switch ChatSidebarStatus(state) {
        case .idle: .secondary
        case .running: .green
        case .needsYou, .interrupted: .orange
        case .failed: .red
        }
    }
    private var statusTitle: String {
        switch ChatSidebarStatus(state) {
        case .idle: "Idle"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }
}

/// Project chats use the unified screen; unassigned and voice history keep
/// their existing local reader. Native imports remain read-only evidence.
struct ChatDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var importedHistory: WorkspaceSessionLink?
    @State private var showingDetails = false
    @State private var creatingChat: WorkspaceProject?

    private var nativeLinks: [WorkspaceSessionLink] {
        model.selectedWorkspaceChatID.map { model.nativeSessionLinks(for: $0) } ?? []
    }

    var body: some View {
        if let chatID = model.selectedWorkspaceChatID, let chatModel = model.chatModel {
            AgentChatView(chat: chatModel, chatID: chatID,
                          canSend: model.selectedWorkspaceChat?.archivedAt == nil,
                          workspaceError: model.workspaceMessage.map { _ in "Chat changes could not be saved." })
                .navigationTitle(model.selectedWorkspaceChat?.title ?? "Chat")
                .toolbar {
                    Button("Chat details", systemImage: "info.circle") { showingDetails = true }
                        .accessibilityIdentifier("chat.details")
                    Button("New Chat", systemImage: "square.and.pencil") {
                        creatingChat = model.workspaceProjects.first { $0.id == model.selectedWorkspaceChat?.projectID }
                    }
                        .popover(item: $creatingChat) { project in NewAgentChatView(project: project) { creatingChat = nil } }
                        .disabled(model.isWorkspaceSelectionBusy).accessibilityIdentifier("chat.new")
                    if !nativeLinks.isEmpty {
                        Menu("Imported History", systemImage: "clock.arrow.circlepath") {
                            ForEach(nativeLinks) { link in
                                Button(link.displayName) { importedHistory = link }
                                    .accessibilityIdentifier("chat.import.\(link.id)")
                            }
                        }.accessibilityIdentifier("chat.imports")
                    }
                }
                .sheet(isPresented: $showingDetails) {
                    WorkspaceInspectorView(chatID: chatID, provider: chatModel.provider)
                }
                .sheet(item: $importedHistory) { link in
                    VStack {
                        Button("Done") { importedHistory = nil }
                            .keyboardShortcut(.cancelAction).accessibilityIdentifier("chat.import.done")
                        NativeSessionSourceView(link: link)
                    }.padding().frame(width: 760, height: 600)
                }
        } else if model.selectedWorkspaceChatID != nil {
            ProgressView().accessibilityLabel("Loading chat")
        } else {
            LocalChatView()
        }
    }

}

/// Rail and chat side by side. The window composes these two itself; this
/// stays the one surface synthetic snapshots render.
struct ProjectChatWorkspaceView: View {
    var recent = false
    var body: some View {
        HStack(spacing: 0) {
            WorkspaceRailView(initialRecent: recent).frame(width: 240)
            Divider()
            ChatDetailView()
        }
    }
}

private struct WorkspaceProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var instructions: String
    @State private var folderURLs: [URL] = []
    private let existingProject: WorkspaceProject?
    let save: (String, String, [URL]) -> Bool

    init(project: WorkspaceProject? = nil, save: @escaping (String, String, [URL]) -> Bool) {
        existingProject = project
        _title = State(initialValue: project?.title ?? "")
        _instructions = State(initialValue: project?.instructions ?? "")
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingProject == nil ? "New project" : "Edit project").font(.title2.weight(.semibold))
            TextField("Project title", text: $title).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("Project instructions").font(.headline)
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(height: 115)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Text("Used for chats in this project.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if existingProject == nil {
                VStack(alignment: .leading, spacing: 7) {
                    Button("Register folder…", systemImage: "folder.badge.plus", action: chooseFolders)
                    ForEach(folderURLs, id: \.self) { url in
                        HStack {
                            Text(url.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove", systemImage: "xmark.circle") { folderURLs.removeAll { $0 == url } }
                                .labelStyle(.iconOnly).buttonStyle(.plain)
                        }.font(.caption)
                    }
                    Text("Optional working folders for this project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            WorkspaceValidationMessage()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existingProject == nil ? "Create project" : "Save") {
                    if save(title.trimmingCharacters(in: .whitespacesAndNewlines), instructions, folderURLs) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Register"
        if panel.runModal() == .OK {
            for url in panel.urls where !folderURLs.contains(url) { folderURLs.append(url) }
        }
    }
}

private struct WorkspaceProjectManager: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reviewingProject: WorkspaceProject?

    var body: some View {
        if let project = reviewingProject {
            WorkspaceProjectEditor(project: project) { title, instructions, _ in
                var updated = project; updated.title = title; updated.instructions = instructions
                let saved = model.updateWorkspaceProject(updated)
                if saved { reviewingProject = nil }
                return saved
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage projects").font(.title2.weight(.semibold))
                Text("Hidden projects keep their chats and folders.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.workspaceProjects.isEmpty {
                            Text("No projects yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.workspaceProjects) { project in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(project.title, systemImage: "folder").font(.headline)
                                    Spacer()
                                    Button("Settings") { reviewingProject = project }
                                    Button(project.isVisible ? "Hide" : "Show") {
                                        var updated = project
                                        updated.isVisible.toggle()
                                        model.updateWorkspaceProject(updated)
                                    }
                                }
                                if !project.instructions.isEmpty {
                                    Text(project.instructions).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                let registration = folderRegistration(projectID: project.id)
                                if registration.loadFailed {
                                    Label("Could not read folder registration.", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                } else if registration.paths.isEmpty {
                                    Text("No registered folders").font(.caption).foregroundStyle(.tertiary)
                                } else {
                                    ForEach(registration.paths, id: \.self) { path in
                                        Label(path, systemImage: "folder")
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                WorkspaceValidationMessage()
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
            .padding(24)
            .frame(width: 560, height: 450)
        }
    }

    private func folderRegistration(projectID: UUID) -> (paths: [String], loadFailed: Bool) {
        guard let stores = model.stores else { return ([], true) }
        do {
            return (try stores.workspaceFolders(projectID: projectID).map(\.path), false)
        } catch {
            return ([], true)
        }
    }
}

private struct WorkspaceConversationAssignmentEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var title: String
    @State private var purpose = ""
    @State private var kind: WorkspaceChat.Kind = .temporary
    let conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
        _title = State(initialValue: conversation.title)
    }

    private var projects: [WorkspaceProject] { model.workspaceProjects.filter(\.isVisible) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move to project").font(.title2.weight(.semibold))
            if projects.isEmpty {
                Text("Create or show a project first, then move this chat from Unassigned.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $projectID) {
                    Text("Choose a project").tag(nil as UUID?)
                    ForEach(projects) { project in Text(project.title).tag(Optional(project.id)) }
                }
                TextField("Chat title", text: $title).textFieldStyle(.roundedBorder)
                TextField("Purpose (optional)", text: $purpose, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                Picker("Chat type", selection: $kind) {
                    Text("Primary").tag(WorkspaceChat.Kind.primary)
                    Text("Temporary").tag(WorkspaceChat.Kind.temporary)
                }.pickerStyle(.segmented)
                Text(kind == .primary ? "Primary chats stay pinned to this project." : "Temporary chats archive after 7 days of inactivity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Keeps all messages in this chat.")
                .font(.caption).foregroundStyle(.secondary)
            WorkspaceValidationMessage()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move chat") {
                    guard let projectID else { return }
                    if model.assignUnassignedConversation(conversation.id, projectID: projectID,
                                                          title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          kind: kind, purpose: purpose) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(projectID == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorkspaceSelectionBusy)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { projectID = projects.first?.id }
    }
}

private struct WorkspaceValidationMessage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let message = model.workspaceMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One small creation popover; isolation is optional and defaults off.
private struct NewAgentChatView: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceProject
    let dismiss: () -> Void
    @State private var useWorktree = false
    @State private var gitRepository = false
    @State private var creating = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat").font(.headline)
            if gitRepository {
                Toggle("Use worktree", isOn: $useWorktree).controlSize(.small)
                    .accessibilityIdentifier("chat.new.worktree")
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Spacer()
                if creating { ProgressView().controlSize(.mini) }
                Button("Create") {
                    creating = true
                    Task {
                        if await model.createAgentChat(projectID: project.id, worktree: useWorktree) { dismiss() }
                        else { failure = "Chat could not be created. No fallback checkout was selected." }
                        creating = false
                    }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("chat.new.create")
            }
        }.padding(16).frame(width: 260).disabled(creating)
        .task {
            guard let folders = try? model.stores?.workspaceFolders(projectID: project.id), let first = folders.first else { return }
            gitRepository = (try? await GitWorkspace().repository(at: URL(fileURLWithPath: first.path))) != nil
        }
    }
}
