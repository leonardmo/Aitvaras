import SwiftUI
import AppKit
import AitvarasStore

/// The project rail. It is the lower half of the app sidebar, so the window
/// carries one navigation surface rather than two stacked rails.
struct WorkspaceRailView: View {
    /// Snapshot seam: lets a synthetic scenario open on the shared view.
    var initialRecent = false
    @Environment(AppModel.self) private var model
    @State private var showingArchived = false
    @State private var showingNewProject = false
    @State private var showingProjectManager = false
    @State private var settingsProject: WorkspaceProject?
    @State private var showingNewChat = false
    @State private var editingChat: WorkspaceChat?
    @State private var assigningConversation: Conversation?
    @State private var showingNativeImport = false
    /// Recent is a view across projects, not a selection, so opening one of
    /// its chats keeps the list in place instead of snapping to that project.
    @State private var showingRecent = false

    private var selectedProject: WorkspaceProject? {
        model.workspaceProjects.first { $0.id == model.selectedWorkspaceProjectID }
    }

    private var visibleProjects: [WorkspaceProject] {
        model.workspaceProjects.filter { $0.isVisible || $0.id == model.selectedWorkspaceProjectID }
    }

    var body: some View {
        workspaceRail
        .task {
            if initialRecent { showingRecent = true }
            model.refreshWorkspaces()
        }
        .sheet(isPresented: $showingNativeImport) { NativeSessionImportView() }
        .sheet(isPresented: $showingNewProject) {
            WorkspaceProjectEditor { title, instructions, folders in
                model.createWorkspaceProject(title: title, instructions: instructions, folderURLs: folders)
            }
        }
        .sheet(isPresented: $showingProjectManager) { WorkspaceProjectManager() }
        .sheet(item: $settingsProject) { project in
            WorkspaceBoundaryReviewView(projectID: project.id)
        }
        .sheet(isPresented: $showingNewChat) {
            WorkspaceChatEditor { title, purpose, kind in
                model.createWorkspaceChat(title: title, kind: kind, purpose: purpose)
            }
        }
        .sheet(item: $editingChat) { chat in
            WorkspaceChatEditor(chat: chat) { title, purpose, kind in
                var updated = chat
                updated.title = title
                updated.purpose = purpose
                updated.kind = kind
                return model.updateWorkspaceChat(updated)
            }
        }
        .sheet(item: $assigningConversation) { conversation in
            WorkspaceConversationAssignmentEditor(conversation: conversation)
        }
    }

    private var workspaceRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scope, new chat and the list are one block: the chats you can
            // open sit directly under the scope that holds them.
            HStack(spacing: 2) {
                Menu {
                    Button {
                        showingRecent = true
                    } label: {
                        Label("Recent across projects", systemImage: showingRecent ? "checkmark" : "clock.arrow.circlepath")
                    }
                    Divider()
                    Button("Unassigned") { showingRecent = false; model.selectWorkspaceProject(nil) }
                    ForEach(visibleProjects) { project in
                        Button {
                            showingRecent = false
                            model.selectWorkspaceProject(project.id)
                        } label: {
                            Label(project.title, systemImage: !showingRecent && project.id == model.selectedWorkspaceProjectID ? "checkmark" : "folder")
                        }
                    }
                    Divider()
                    if let selectedProject {
                        Button("Project settings…", systemImage: "gearshape") { settingsProject = selectedProject }
                            .disabled(model.isWorkspaceSelectionBusy)
                    }
                    Button("New project…", systemImage: "folder.badge.plus") { showingNewProject = true }
                    Button("Manage projects…", systemImage: "slider.horizontal.3") { showingProjectManager = true }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showingRecent ? "clock.arrow.circlepath" : selectedProject == nil ? "tray" : "folder")
                            .font(.caption)
                            .foregroundStyle(showingRecent ? ActivityGlassPalette.ember
                                             : selectedProject == nil ? Color.secondary : ActivityGlassPalette.violet)
                        Text(showingRecent ? "Recent" : selectedProject?.title ?? "Unassigned")
                            .font(.callout.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help(showingRecent ? "The latest chats from every project, each one showing where it lives"
                      : selectedProject.map { "Project · \($0.instructions.isEmpty ? "No project instructions" : $0.instructions)" }
                      ?? "Chats and voice records that belong to no project")
                .disabled(model.isWorkspaceSelectionBusy)
                Button("New chat", systemImage: "square.and.pencil") {
                    if selectedProject == nil { model.newChat() } else { showingNewChat = true }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(selectedProject == nil ? "Start a new chat" : "New chat in this project")
                .disabled(model.isWorkspaceSelectionBusy)
            }
            .padding(.horizontal, 9).padding(.top, 7).padding(.bottom, 5)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if showingRecent {
                        recentSection
                    } else if selectedProject != nil {
                        chatSection("Primary", kind: .primary)
                        chatSection("Temporary", kind: .temporary)
                        let archived = model.workspaceChats.filter { $0.archivedAt != nil }
                        if !archived.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Button {
                                    showingArchived.toggle()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: showingArchived ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 8, weight: .bold))
                                        sectionTitle("Archived", count: archived.count)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Archived chats keep every message; nothing is deleted")
                                if showingArchived {
                                    ForEach(archived) { chat in chatRow(chat) }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            sectionTitle("Saved", count: model.unassignedChatConversations.count)
                            if model.unassignedChatConversations.isEmpty { emptyList("Nothing saved here yet") }
                            ForEach(model.unassignedChatConversations) { conversation in
                                let voice = conversation.title == "Voice"
                                railRow(title: conversation.title,
                                        trailing: conversation.updatedAt.formatted(.dateTime.day().month(.abbreviated)),
                                        symbol: voice ? "waveform" : "bubble.left",
                                        tint: voice ? ActivityGlassPalette.ember : ActivityGlassPalette.slate,
                                        selected: model.selectedChatConversationID == conversation.id,
                                        hint: voice ? "Saved voice history · read-only" : "Saved conversation, no project") {
                                    model.openUnassignedConversation(conversation.id)
                                }
                                .contextMenu {
                                    if !voice {
                                        Button("Move to project…", systemImage: "folder") {
                                            assigningConversation = conversation
                                        }
                                        .disabled(model.isWorkspaceSelectionBusy)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
            }

            if let message = model.workspaceMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
            }
            if model.isWorkspaceSelectionBusy {
                Label("Finish the current turn to switch chats.", systemImage: "hourglass")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            HStack(spacing: 10) {
                Button("Manage projects…", systemImage: "slider.horizontal.3") { showingProjectManager = true }
                    .help("Rename, hide or edit projects and their folders")
                Button("Import native chats…", systemImage: "square.and.arrow.down") { showingNativeImport = true }
                    .help("Review and save supported Codex or Claude Code text locally. No agent control or file access.")
                Spacer(minLength: 0)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.isWorkspaceSelectionBusy)
            // Breathing room under the last control, so the activity dock never
            // sits directly against it.
            .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 9)
        }
    }

    /// Chats from several projects in one list. Each row carries its project,
    /// so the scope is visible without leaving the shared view.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Recent", count: model.recentWorkspaceChats.count)
                .help("The latest chats across every visible project")
            if model.recentWorkspaceChats.isEmpty {
                emptyList("No project chats yet")
            }
            ForEach(model.recentWorkspaceChats) { recent in
                railRow(
                    title: recent.chat.title,
                    trailing: nil,
                    chip: Self.chipLabel(recent.project.title),
                    chipTint: Self.projectTint(recent.project),
                    symbol: recent.chat.kind == .primary ? "pin.fill" : "bubble.left",
                    tint: Self.projectTint(recent.project),
                    selected: model.selectedWorkspaceChatID == recent.chat.id,
                    hint: "\(recent.project.title) · \(recent.chat.purpose.isEmpty ? "No purpose set" : recent.chat.purpose) · \(recent.chat.lastActivityAt.formatted(date: .abbreviated, time: .shortened))"
                ) {
                    model.openWorkspaceChat(recent.chat.id)
                }
                .contextMenu {
                    Button("Show this project", systemImage: "folder") {
                        showingRecent = false
                        model.selectWorkspaceProject(recent.project.id)
                    }
                    .disabled(model.isWorkspaceSelectionBusy)
                    Button("Edit workspace title or purpose…", systemImage: "pencil") { editingChat = recent.chat }
                }
            }
        }
    }

    /// Project names are clipped here, not by the layout, so the chip has one
    /// predictable width and the chat title keeps the rest of the row.
    static func chipLabel(_ title: String, limit: Int = 14) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }

    /// A stable hue per project, taken from the first byte of its identifier so
    /// the same project keeps its colour across launches.
    private static func projectTint(_ project: WorkspaceProject) -> Color {
        let palette: [Color] = [ActivityGlassPalette.violet, ActivityGlassPalette.slate, .cyan,
                                ActivityGlassPalette.ember, ActivityGlassPalette.attention, .mint]
        return palette[Int(project.id.uuid.0) % palette.count]
    }

    private func chatSection(_ title: String, kind: WorkspaceChat.Kind) -> some View {
        let chats = model.workspaceChats.filter { $0.kind == kind && $0.archivedAt == nil }
        return VStack(alignment: .leading, spacing: 2) {
            sectionTitle(title, count: chats.count)
                .help(kind == .temporary
                      ? "Temporary chats archive after seven inactive days; their messages stay saved"
                      : "Primary chats stay pinned to this project")
            if chats.isEmpty { emptyList(kind == .primary ? "No primary chats" : "No temporary chats") }
            ForEach(chats) { chat in chatRow(chat) }
        }
    }

    private func chatRow(_ chat: WorkspaceChat) -> some View {
        let archived = chat.archivedAt != nil
        return railRow(
            title: chat.title,
            trailing: chat.lastActivityAt.formatted(.dateTime.day().month(.abbreviated)),
            symbol: archived ? "archivebox" : chat.kind == .primary ? "pin.fill" : "bubble.left",
            tint: archived ? .secondary : chat.kind == .primary ? ActivityGlassPalette.violet : ActivityGlassPalette.slate,
            selected: model.selectedWorkspaceChatID == chat.id,
            hint: chat.purpose.isEmpty ? (archived ? "Archived · read-only" : nil) : chat.purpose
        ) {
            model.openWorkspaceChat(chat.id)
        }
        .contextMenu {
            Button("Edit workspace title or purpose…", systemImage: "pencil") { editingChat = chat }
            Button(chat.kind == .primary ? "Make temporary" : "Make primary", systemImage: chat.kind == .primary ? "pin.slash" : "pin") {
                var updated = chat
                updated.kind = chat.kind == .primary ? .temporary : .primary
                model.updateWorkspaceChat(updated)
            }
            Divider()
            Button(archived ? "Restore chat" : "Archive chat", systemImage: archived ? "arrow.uturn.backward" : "archivebox") {
                model.setWorkspaceChatArchived(chat.id, archived: !archived)
            }
        }
    }

    /// Every chat in this rail is one line: symbol, title, and the last date.
    /// The purpose and state are on hover, so the list stays dense.
    private func railRow(title: String, trailing: String?, chip: String? = nil,
                         chipTint: Color = .secondary, symbol: String, tint: Color,
                         selected: Bool, hint: String?, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? tint : Color.secondary)
                    .frame(width: 13)
                Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let chip {
                    // Sized by its own text, never by a flexible frame: a short
                    // project name must not cost the title any width.
                    Text(chip)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(chipTint)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(chipTint.opacity(0.16)))
                        .layoutPriority(1)
                }
                if let trailing {
                    Text(trailing).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(selected ? 0.18 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorkspaceSelectionBusy)
        .help(hint ?? title)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, 7).padding(.top, 2)
    }

    private func emptyList(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 7).padding(.vertical, 3)
    }

}

/// Local chat, app-owned Codex conversations, and imported read-only evidence
/// remain separate sources. Changing source never adopts a native identity.
struct ChatDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var backend: WorkspaceChatBackend = .local
    @State private var pendingBackend: WorkspaceChatBackend?
    @State private var pendingBackendChatID: UUID?
    @State private var confirmingCloud = false
    @State private var showingSettings = false
    @State private var showingInspector = false
    @State private var importedHistory: WorkspaceSessionLink?
    @State private var selectionError: String?

    private var nativeLinks: [WorkspaceSessionLink] {
        model.selectedWorkspaceChatID.map { model.nativeSessionLinks(for: $0) } ?? []
    }

    var body: some View {
        if let chatID = model.selectedWorkspaceChatID, let chatModel = model.chatModel {
            AgentChatView(chat: chatModel, chatID: chatID,
                          canSend: model.selectedWorkspaceChat?.archivedAt == nil)
                .navigationTitle(model.selectedWorkspaceChat?.title ?? "Chat")
                .toolbar {
                    Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                        .disabled(model.isWorkspaceSelectionBusy).accessibilityIdentifier("chat.new")
                    if !nativeLinks.isEmpty {
                        Menu("Imported History", systemImage: "clock.arrow.circlepath") {
                            ForEach(nativeLinks) { link in
                                Button(link.displayName) { importedHistory = link }
                                    .accessibilityIdentifier("chat.import.\(link.id)")
                            }
                        }.accessibilityIdentifier("chat.imports")
                    }
                    Button("Chat Details", systemImage: "info.circle") { showingInspector = true }
                        .accessibilityIdentifier("chat.details")
                }
                .sheet(isPresented: $showingInspector) {
                    WorkspaceInspectorView(chatID: chatID,
                        backend: WorkspaceChatBackend(rawValue: chatModel.provider.rawValue) ?? .local,
                        directAgentChat: true)
                }
                .sheet(item: $importedHistory) { link in
                    VStack {
                        Button("Done") { importedHistory = nil }
                            .keyboardShortcut(.cancelAction).accessibilityIdentifier("chat.import.done")
                        NativeSessionSourceView(link: link)
                    }.padding().frame(width: 760, height: 600)
                }
        } else {
            legacyContent
        }
    }

    private var legacyContent: some View {
        VStack(spacing: 0) {
            if model.selectedWorkspaceChatID != nil {
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        ForEach([WorkspaceChatBackend.claude, .codex, .local]) { provider in
                            Button { requestBackend(provider) } label: {
                                Text(provider.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                                    .foregroundStyle(backend == provider ? Color.accentColor : .secondary)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(backend == provider ? Color.accentColor.opacity(0.17) : .clear))
                            }
                            .accessibilityLabel(provider.title)
                            .accessibilityAddTraits(backend == provider ? .isSelected : [])
                            .help(provider.title)
                            .disabled(model.isWorkspaceSelectionBusy)
                        }
                        Divider().frame(height: 17).padding(.horizontal, 2)
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape").frame(width: 30, height: 26)
                        }
                        .accessibilityLabel("AI Settings")
                        .help("Settings for \(backend.title)")
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 11).fill(.quaternary.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.08)))
                    Spacer()
                    if !nativeLinks.isEmpty {
                        Menu {
                            ForEach(nativeLinks) { link in
                                Button("\(link.provider == .codex ? "Codex" : "Claude") · \(link.displayName)") { importedHistory = link }
                            }
                        } label: { Label("Imported History", systemImage: "clock.arrow.circlepath") }
                        .help("Read-only imported chats; never attached automatically")
                    }
                    Button("Chat Details", systemImage: "info.circle") { showingInspector = true }
                        .labelStyle(.iconOnly).help("Chat context and captures")
                }.padding(.horizontal, 16).padding(.vertical, 9)
                Divider()
            }
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.orange).padding(8) }
            ChatView(backend: backend, openBackendSettings: { showingSettings = true })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingSettings, onDismiss: {
            NotificationCenter.default.post(name: .init("aitvaras.chatBackendSettingsChanged"), object: nil)
        }) {
            if let id = model.selectedWorkspaceChatID {
                ChatBackendSettingsView(chatID: id, initialBackend: backend)
            }
        }
        .sheet(isPresented: $showingInspector) {
            if let id = model.selectedWorkspaceChatID { WorkspaceInspectorView(chatID: id, backend: backend) }
        }
        .sheet(item: $importedHistory) { link in
            VStack(spacing: 0) {
                HStack { Text("Imported History · Read Only").font(.headline); Spacer()
                    Button("Done") { importedHistory = nil }.keyboardShortcut(.cancelAction)
                }.padding()
                NativeSessionSourceView(link: link)
            }.frame(width: 760, height: 600)
        }
        .confirmationDialog("Share this chat's history with \(pendingBackend == .codex ? "OpenAI" : "Anthropic")?",
                            isPresented: $confirmingCloud, titleVisibility: .visible) {
            Button("Share History and Use \(pendingBackend?.title ?? "Cloud")") { resolvePendingBackend(shareHistory: true) }
            Button("Use \(pendingBackend?.title ?? "Cloud") Without History") { resolvePendingBackend(shareHistory: false) }
            Button("Cancel", role: .cancel) { pendingBackend = nil; pendingBackendChatID = nil }
        } message: {
            Text(consentMessage)
        }
        .onChange(of: model.selectedWorkspaceChatID, initial: true) { restoreBackend() }
    }

    /// The history decision is asked once per chat and remembered either way;
    /// it decides whether Codex is caught up on Send (D30), in both modes.
    private func requestBackend(_ next: WorkspaceChatBackend) {
        guard !model.isWorkspaceSelectionBusy, next != backend else { return }
        if next == .claude, !model.claudeWorkspace.authenticated {
            // The first Send checks the account before asking a history choice.
            // Selecting a provider alone never manufactures account consent.
            applyBackend(next, shareHistory: nil)
            return
        }
        if WorkspaceChatBackend.requiresHistoryConfirmation(from: backend, to: next), historyDecision(for: next) == nil {
            pendingBackend = next; pendingBackendChatID = model.selectedWorkspaceChatID; confirmingCloud = true
        } else { applyBackend(next, shareHistory: nil) }
    }
    private func resolvePendingBackend(shareHistory: Bool) {
        if let pendingBackend, pendingBackendChatID == model.selectedWorkspaceChatID {
            applyBackend(pendingBackend, shareHistory: shareHistory)
        }
        pendingBackend = nil
        pendingBackendChatID = nil
    }
    private func historyDecision(for provider: WorkspaceChatBackend) -> Bool? {
        guard let id = model.selectedWorkspaceChatID,
              let value = try? model.stores?.value(forKey: WorkspaceChatBackend.key(id, "shareHistory.\(provider.rawValue)")) else { return nil }
        if provider == .claude {
            guard model.claudeWorkspace.authenticated, let namespace = model.claudeWorkspace.profileNamespace,
                  (try? model.stores?.value(forKey: WorkspaceChatBackend.key(id, "shareHistory.claude.profile"))) == namespace else { return nil }
        }
        return value == "1"
    }
    private var consentMessage: String {
        let budget = Stores.workspaceSharedHistoryCharacters.formatted()
        let provider = pendingBackend ?? .codex
        let native = provider == .codex && (model.selectedWorkspaceChatID.map { model.codexNativeWorkspace.prefersNative(chatID: $0) } ?? false)
        let excluded = "Imported histories, captures, other chats and memories are never included. Switching itself sends nothing; you can change this in AI Settings."
        return native
            ? "With each Send, the linked Codex desktop chat is caught up on messages from this chat it has not seen (up to \(budget) characters). They travel inside your message, so they also appear in Codex desktop. \(excluded)"
            : "With each Send, \(provider.title) is caught up on messages from this chat it has not seen (up to \(budget) characters), along with the project title, instructions and chat purpose. If Project settings allow it, \(provider.title) can also read approved folders. \(excluded)"
    }
    private func applyBackend(_ next: WorkspaceChatBackend, shareHistory: Bool?) {
        guard let id = model.selectedWorkspaceChatID, let stores = model.stores else { return }
        do {
            var values = [WorkspaceChatBackend.key(id, "backend"): next.rawValue]
            if let shareHistory {
                if next == .claude {
                    guard model.claudeWorkspace.authenticated, let namespace = model.claudeWorkspace.profileNamespace else {
                        selectionError = "Check the Claude account before choosing history sharing. Nothing was sent."
                        return
                    }
                    values[WorkspaceChatBackend.key(id, "shareHistory.claude")] = shareHistory ? "1" : "0"
                    values[WorkspaceChatBackend.key(id, "shareHistory.claude.profile")] = namespace
                } else { values[WorkspaceChatBackend.key(id, "shareHistory.\(next.rawValue)")] = shareHistory ? "1" : "0" }
            }
            try stores.setValues(values)
            backend = next
            selectionError = nil
            model.codexWorkspace.load(chatID: id)
            model.codexNativeWorkspace.load(chatID: id)
            model.claudeWorkspace.load(chatID: id)
        } catch { selectionError = "Provider choice could not be saved. Nothing was sent." }
    }
    private func restoreBackend() {
        confirmingCloud = false; pendingBackend = nil; pendingBackendChatID = nil
        guard let id = model.selectedWorkspaceChatID else { backend = .local; return }
        do {
            let saved = try model.stores?.value(forKey: WorkspaceChatBackend.key(id, "backend"))
            let restored = saved.flatMap(WorkspaceChatBackend.init(rawValue:)) ?? .local
            // Either answer to the history question is a decision; only an
            // Aitvaras-only Codex chat that was never asked falls back to Local.
            let decided = try model.stores?.value(forKey: WorkspaceChatBackend.key(id, "shareHistory.\(restored.rawValue)")) != nil
            let native = restored == .codex && model.codexNativeWorkspace.prefersNative(chatID: id)
            backend = restored == .codex && !decided && !native ? .local : restored
            model.codexWorkspace.load(chatID: id)
            model.codexNativeWorkspace.load(chatID: id)
            model.claudeWorkspace.load(chatID: id)
            selectionError = nil
        } catch { backend = .local; selectionError = "Provider choice could not be restored. Nothing was sent." }
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
                Text("Saved with this project. Shared project knowledge is not connected yet.")
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
                    Text("Optional, read-only registration. No file tools or indexing are active yet. Cloud access is not enabled.")
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
            WorkspaceBoundaryReviewView(projectID: project.id, onDone: { reviewingProject = nil })
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage projects").font(.title2.weight(.semibold))
                Text("Hiding a project keeps its chats and folders. Open Settings to change instructions and AI providers.")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.workspaceProjects.isEmpty {
                            Text("No projects yet. Create one from the workspace selector.")
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
                                        Label("\(path) · read-only registration", systemImage: "folder")
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Text("Imported histories stay read-only. Codex supports text chat; file tools and shared knowledge are not available yet.")
                    .font(.caption).foregroundStyle(.secondary)
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

private struct WorkspaceChatEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var purpose: String
    @State private var kind: WorkspaceChat.Kind
    private let editing: Bool
    let save: (String, String, WorkspaceChat.Kind) -> Bool

    init(chat: WorkspaceChat? = nil, save: @escaping (String, String, WorkspaceChat.Kind) -> Bool) {
        _title = State(initialValue: chat?.title ?? "")
        _purpose = State(initialValue: chat?.purpose ?? "")
        _kind = State(initialValue: chat?.kind ?? .temporary)
        editing = chat != nil
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing ? "Edit chat" : "New chat").font(.title2.weight(.semibold))
            TextField("Chat title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Purpose (optional)", text: $purpose, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            Picker("Chat type", selection: $kind) {
                Text("Primary").tag(WorkspaceChat.Kind.primary)
                Text("Temporary").tag(WorkspaceChat.Kind.temporary)
            }.pickerStyle(.segmented)
            Label(kind == .primary ? "Primary chats stay pinned to this project." : "Temporary chats archive after 7 days of inactivity.", systemImage: kind == .primary ? "pin.fill" : "clock")
                .font(.caption).foregroundStyle(.secondary)
            Text("Text-only local chat. Project files, shared knowledge and native sessions connect in the next checkpoints.")
                .font(.caption).foregroundStyle(.secondary)
            WorkspaceValidationMessage()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Create chat") {
                    if save(title.trimmingCharacters(in: .whitespacesAndNewlines), purpose, kind) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
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
            Text("Preserves the original messages. This organizes an existing local conversation; it does not import native sessions or index files.")
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
