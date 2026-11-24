import SwiftUI
import AppKit
import AitvarasStore
import AitvarasAgents

/// Projects and their chats share the app's single sidebar.
struct WorkspaceRailView: View {
    var initialRecent = false
    @Environment(AppModel.self) private var model
    @State private var expandedProjects: Set<UUID> = []
    @State private var earlierExpanded = false
    @State private var showingHiddenProjects = false
    @State private var renamingChat: WorkspaceChat?
    @State private var newTitle = ""
    @State private var assigningConversation: Conversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("New Chat", systemImage: "square.and.pencil") { model.startNewAgentChat() }
                .buttonStyle(.plain).padding(10)
                .accessibilityIdentifier("chat.new.unassigned")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.workspaceProjects.filter(\.isVisible)) { project in
                        projectGroup(project)
                    }
                    let hidden = model.workspaceProjects.filter { !$0.isVisible }
                    if !hidden.isEmpty { hiddenProjects(hidden) }
                    if !model.unassignedChatConversations.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Earlier chats").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if earlierExpanded {
                                ForEach(model.unassignedChatConversations) { conversation in
                                    Button { model.openUnassignedConversation(conversation.id) } label: {
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
                            }
                            Button(earlierExpanded ? "Show less" : "Show more") { earlierExpanded.toggle() }
                                .accessibilityIdentifier("chat.earlier.more")
                        }.font(.callout).buttonStyle(.plain)
                    }
                }.padding(10)
            }
            Divider()
            HStack {
                Button("New project", systemImage: "folder.badge.plus") { model.chooseChatProjectFolder() }
                    .accessibilityIdentifier("chat.project.new")
                Spacer()
                Button("Refresh native chats", systemImage: model.chatModel?.nativeDiscoveryFailed == true ? "exclamationmark.circle" : "arrow.clockwise") {
                    Task { await refreshNativeChats() }
                }
                .disabled(model.chatModel?.discoveringNativeSessions == true)
                .help(model.chatModel?.nativeDiscoveryError ?? "Refresh native chats")
                .accessibilityIdentifier("chat.native.refresh")
            }.buttonStyle(.borderless).labelStyle(.iconOnly).padding(10)
        }
        .disabled(model.isWorkspaceSelectionBusy || model.chatModel?.creatingChat == true)
        .task { model.refreshWorkspaces() }
        .task(id: model.workspaceProjects.map { "\($0.id):\($0.updatedAt)" }.joined() + String(model.chatModel != nil)) {
            await refreshNativeChats()
        }
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
        let statuses = Dictionary(uniqueKeysWithValues: all.map { ($0.id, model.chatModel?.sidebarStatus($0.id) ?? .idle) })
        let visible = ProjectChatVisibility.visible(all, statuses: statuses, selectedID: model.selectedWorkspaceChatID,
                                                     expanded: expandedProjects.contains(project.id))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(project.title, systemImage: "folder").font(.caption.weight(.semibold)).lineLimit(1)
                if model.defaultChatProjectID == project.id {
                    Image(systemName: "star.fill").font(.caption2)
                        .accessibilityLabel("Default project")
                }
                Spacer(minLength: 0)
                Button("Project settings", systemImage: "gearshape") {
                    SettingsNavigation.open(.project(project.id, section: .general))
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help("Project settings")
                .accessibilityIdentifier("chat.project.settings.\(project.id)")
                Button("New Chat", systemImage: "plus") {
                    model.startNewAgentChat(projectID: project.id)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .accessibilityIdentifier("chat.new.\(project.id)")
            }
            .foregroundStyle(.secondary)
            .contextMenu {
                Button("Project settings…") {
                    SettingsNavigation.open(.project(project.id, section: .general))
                }
            }
            ForEach(visible) { chat in chatRow(chat) }
            if all.count > visible.count || expandedProjects.contains(project.id) {
                Button(expandedProjects.contains(project.id) ? "Show less" : "Show more") {
                    if !expandedProjects.insert(project.id).inserted { expandedProjects.remove(project.id) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("chat.project.\(project.id).more")
            }
        }
    }
    private func hiddenProjects(_ projects: [WorkspaceProject]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showingHiddenProjects.toggle()
            } label: {
                Label("Hidden projects", systemImage: showingHiddenProjects ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityValue(showingHiddenProjects ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat.projects.hidden")
            if showingHiddenProjects {
                ForEach(projects) { project in
                    Button {
                        SettingsNavigation.open(.project(project.id, section: .general))
                    } label: {
                        Label(project.title, systemImage: "folder")
                            .font(.callout).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.projects.hidden.\(project.id)")
                }
            }
        }
    }

    private func chatRow(_ chat: WorkspaceChat) -> some View {
        SidebarChatRow(chat: chat, selected: model.selectedWorkspaceChatID == chat.id,
                       status: model.chatModel?.sidebarStatus(chat.id) ?? .idle,
                       unseen: model.chatModel?.unseenChats.contains(chat.id) == true, open: { model.openWorkspaceChat(chat.id) })
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
    let status: ChatSidebarStatus
    let unseen: Bool
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                statusIcon
                Text(chat.title).lineLimit(1)
                Spacer(minLength: 0)
                if unseen && status != .finishedUnseen {
                    Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Unread")
                        .accessibilityIdentifier("chat.sidebar.\(chat.id).unread")
                }
                if chat.kind == .primary { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
            }
            .font(.callout).padding(.horizontal, 7).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.sidebar.\(chat.id)")
        .accessibilityLabel(chat.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    @ViewBuilder private var statusIcon: some View {
        if status != .idle {
            Group {
                switch status {
                case .running: ProgressView().controlSize(.mini).scaleEffect(0.65).frame(width: 12, height: 12)
                case .needsYou: Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color.accentColor)
                case .finishedUnseen: Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(Color.accentColor)
                case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                case .interrupted: Image(systemName: "pause.circle").foregroundStyle(.secondary)
                case .idle: EmptyView()
                }
            }
            .accessibilityLabel(statusLabel)
            .accessibilityIdentifier("chat.sidebar.\(chat.id).status.\(status.rawValue)")
        }
    }
    private var statusLabel: String {
        switch status {
        case .idle: "Seen"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .finishedUnseen: "Finished, not yet seen"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }
}

/// Project chats use the unified screen; unassigned and voice history keep
/// their existing local reader. Native imports remain read-only evidence.
struct ChatDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var importedHistory: WorkspaceSessionLink?
    @State private var showingDetails = false

    private var nativeLinks: [WorkspaceSessionLink] {
        model.selectedWorkspaceChatID.map { model.nativeSessionLinks(for: $0) } ?? []
    }

    var body: some View {
        if model.showingEarlierChat {
            LocalChatView()
        } else if let chatModel = model.chatModel {
            let chatID = model.selectedWorkspaceChatID ?? chatModel.newChatID
            AgentChatView(chat: chatModel, chatID: chatID,
                          canSend: model.selectedWorkspaceChat?.archivedAt == nil,
                          workspaceError: model.workspaceMessage.map { _ in "Chat changes could not be saved." })
                .navigationTitle(model.selectedWorkspaceChat?.title ?? "Chat")
                .toolbar {
                    if model.selectedWorkspaceChatID != nil {
                        Button("Chat details", systemImage: "info.circle") { showingDetails = true }
                            .accessibilityIdentifier("chat.details")
                    }
                    Button("New Chat", systemImage: "square.and.pencil") {
                        model.startNewAgentChat()
                    }
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
        } else {
            ProgressView().accessibilityLabel("Loading chat")
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
