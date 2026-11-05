import SwiftUI
import AppKit
import AitvarasStore
import AitvarasEngines
import AitvarasConnectors

/// Captures exactly what a first-Send consent decision may resume.
struct ClaudeComposerSendIntent: Equatable {
    let chatID: UUID
    let profileNamespace: String
    let prompt: String
    let modelID: String
    let effort: String?
    func isCurrent(chatID: UUID?, profileNamespace: String?, backend: WorkspaceChatBackend) -> Bool {
        backend == .claude && self.chatID == chatID && self.profileNamespace == profileNamespace
    }
}

struct ChatView: View {
    @Environment(AppModel.self) private var model
    var backend: WorkspaceChatBackend = .local
    var openBackendSettings: (() -> Void)? = nil
    @State private var draft = ""
    @State private var conversationDrafts: [UUID: String] = [:]
    @State private var unselectedDraft = ""
    @FocusState private var inputFocused: Bool
    @State private var submitting = false
    @State private var composerModelID = ""
    @State private var composerEffort = ""
    @State private var choiceError: String?
    @State private var localModel = MLXEngine.assignedModel(for: .chat)
    @State private var installedLocalModels: [String] = []
    @State private var pendingClaudeSend: ClaudeComposerSendIntent?
    @State private var confirmingClaudeHistory = false

    private var usesNativeCodex: Bool {
        guard let chatID = model.selectedWorkspaceChatID else { return false }
        return model.codexNativeWorkspace.prefersNative(chatID: chatID)
    }
    private var codexBusy: Bool {
        usesNativeCodex
            ? model.codexNativeWorkspace.isBusy || model.codexNativeWorkspace.nativeWorkActive
            : model.codexWorkspace.isBusy
    }
    private var codexModels: [CodexInteractiveModel] {
        usesNativeCodex ? model.codexNativeWorkspace.models : model.codexWorkspace.models
    }
    private var providerModels: [CodexInteractiveModel] { backend == .claude ? model.claudeWorkspace.models : codexModels }
    private var providerBusy: Bool { backend == .claude ? model.claudeWorkspace.isBusy : backend == .codex && codexBusy }
    private var codexProjectIssue: String? { usesNativeCodex ? model.codexNativeWorkspace.projectIssue : model.codexWorkspace.projectIssue }

    var body: some View {
        observedContent.toolbar { chatToolbar }
            .confirmationDialog("Share this chat's history with Claude?", isPresented: $confirmingClaudeHistory, titleVisibility: .visible) {
                Button("Share History and Send") { resolveClaudeHistory(share: true) }
                Button("Send Without History") { resolveClaudeHistory(share: false) }
                Button("Cancel", role: .cancel) { pendingClaudeSend = nil }
            } message: {
                Text("Sharing catches this Claude account up on this chat's unseen messages when you send. Imported histories, captures, other chats and memories stay excluded. You can change this in AI Settings.")
            }
    }

    private var observedContent: some View {
        selectionContent
            .onChange(of: model.codexWorkspace.models) { refreshComposerChoices() }
            .onChange(of: model.claudeWorkspace.models) { refreshComposerChoices() }
            .onChange(of: model.codexNativeWorkspace.models) { refreshComposerChoices() }
            .onChange(of: model.codexNativeWorkspace.chatLink) { refreshComposerChoices() }
            .onChange(of: backend) { clearPendingClaudeSend(); refreshComposerChoices() }
            .onChange(of: model.claudeWorkspace.profileNamespace) { _, namespace in
                if let pendingClaudeSend,
                   !pendingClaudeSend.isCurrent(chatID: model.selectedWorkspaceChatID, profileNamespace: namespace, backend: backend) {
                    clearPendingClaudeSend()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("aitvaras.chatBackendSettingsChanged"))) { _ in
                refreshComposerChoices()
                installedLocalModels = MLXEngine.installedModels()
                localModel = MLXEngine.assignedModel(for: .chat)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard backend == .claude, model.claudeWorkspace.authenticated,
                      model.automaticWorkAllowed(.connectors),
                      let chatID = model.selectedWorkspaceChatID else { return }
                Task { await model.claudeWorkspace.refreshHistory(chatID: chatID, trigger: .automatic) }
            }
    }

    private var selectionContent: some View {
        chatContent
            .navigationTitle(model.selectedWorkspaceChat?.title ?? "Chat")
            .navigationSubtitle(selectedProjectTitle)
            .onChange(of: model.selectedChatConversationID) { oldID, newID in
                clearPendingClaudeSend()
                if let oldID { conversationDrafts[oldID] = draft }
                else { unselectedDraft = draft }
                draft = newID.flatMap { conversationDrafts[$0] } ?? (newID == nil ? unselectedDraft : "")
            }
            .task(id: model.selectedWorkspaceChatID) {
                if let chatID = model.selectedWorkspaceChatID {
                    model.codexNativeWorkspace.load(chatID: chatID)
                    model.claudeWorkspace.load(chatID: chatID)
                }
                refreshComposerChoices()
            }
    }

    private var selectedProjectTitle: String {
        model.workspaceProjects.first { $0.id == model.selectedWorkspaceProjectID }?.title ?? ""
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            if model.selectedWorkspaceProjectID == nil, !model.selectedUnassignedVoiceHistory, (!model.suggestions.isEmpty || model.chatModel?.approvalSuggestions.isEmpty == false) {
                suggestionBar
            }
            if let chat = model.selectedWorkspaceChat, model.messages.isEmpty || chat.archivedAt != nil {
                workspaceNotice(chat)
            }
            if model.selectedUnassignedVoiceHistory { voiceHistoryNotice }
            transcript
            if backend == .claude, model.selectedWorkspaceChatID != nil,
               !model.claudeWorkspace.authenticated, !model.claudeWorkspace.isBusy {
                HStack {
                    Label("Connect Claude to send messages", systemImage: "person.crop.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sign In…") { openBackendSettings?() }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            inputBar
        }
    }

    private var voiceHistoryNotice: some View {
        Label("Saved voice history · read-only. Start a new chat to continue.", systemImage: "waveform")
            .font(.caption).foregroundStyle(.secondary).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder private var transcript: some View {
        if let chatID = model.selectedWorkspaceChatID {
            WorkspaceChatTranscriptView(chatID: chatID)
        } else {
            localTranscript
        }
    }

    private var localTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) { localTranscriptContent }
                    .padding(20)
            }
            .onChange(of: model.messages.last?.text) {
                if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var localTranscriptContent: some View {
        if needsProjectChat { projectChatEmptyState }
        else if model.messages.isEmpty { emptyState }
        if !needsProjectChat, model.earlierChatMessagesAreHidden {
            Label("Showing the latest \(AppModel.visibleChatMessageLimit) messages. Earlier messages remain saved locally.",
                  systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        if !needsProjectChat {
            ForEach(model.messages) { message in MessageBubble(message: message).id(message.id) }
        }
    }

    @ToolbarContentBuilder private var chatToolbar: some ToolbarContent {
        ToolbarItem {
            Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                .disabled(model.isWorkspaceSelectionBusy)
        }
        ToolbarItem {
            if model.selectedWorkspaceProjectID == nil, !model.selectedUnassignedVoiceHistory {
                Button(model.voiceEnabled ? "Stop Voice" : "Voice",
                       systemImage: model.voiceEnabled ? "mic.fill" : "mic") {
                    model.toggleVoice()
                }
                .tint(model.voiceEnabled ? .red : nil)
            }
        }
    }

    private var needsProjectChat: Bool {
        model.selectedWorkspaceProjectID != nil && model.selectedWorkspaceChat == nil
    }

    private var projectChatEmptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Create a chat in this project", systemImage: "plus.bubble")
                .font(.title2.weight(.semibold))
            Text("Choose an existing chat in the workspace rail, or create a new temporary chat to begin.")
                .foregroundStyle(.secondary)
            Button("Create chat", systemImage: "plus") { model.newChat() }
                .disabled(model.isWorkspaceSelectionBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    private func workspaceNotice(_ chat: WorkspaceChat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project instructions apply to this chat. Files are not attached.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !chat.purpose.isEmpty {
                Text(chat.purpose).font(.callout).foregroundStyle(.secondary)
            }
            if chat.archivedAt != nil {
                HStack {
                    Label("Archived · read-only", systemImage: "archivebox")
                        .font(.callout)
                    Spacer()
                    Button("Restore chat") { model.setWorkspaceChatArchived(chat.id, archived: false) }
                        .disabled(model.isWorkspaceSelectionBusy)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    private var composerDisabled: Bool {
        model.selectedChatConversationID == nil || model.selectedWorkspaceChat?.archivedAt != nil
            || model.selectedUnassignedVoiceHistory || needsProjectChat
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi, I'm Aitvaras.")
                .font(.title2.weight(.semibold))
            Text(model.selectedWorkspaceChat == nil
                 ? "Ask me something, give me a task, or press ⌥Space for my companion window. Du kannst auch einfach auf Deutsch schreiben."
                 : "Start with a question or a task for this chat. Your conversation is saved in this project.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let chat = model.chatModel {
                    AgentApprovalSuggestionsView(chat: chat).frame(width: 320)
                }
                ForEach(model.suggestions) { suggestion in
                    SuggestionCard(suggestion: suggestion)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.quaternary.opacity(0.4))
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if usesNativeCodex {
                ForEach(model.codexNativeWorkspace.pendingApprovals) { approval in
                    CodexNativeApprovalView(approval: approval).padding(.horizontal, 10).padding(.top, 10)
                }
            }
            composerInputRow
            Divider().opacity(0.5)
            composerProviderControls
        }
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary.opacity(0.32)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.09)))
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 14)
    }

    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Aitvaras…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .disabled(submitting || providerBusy)
                    .lineLimit(1...8)
                    .focused($inputFocused)
                    .onSubmit(send)
                if model.isResponding || providerBusy {
                    Button("Stop", systemImage: "stop.circle.fill") {
                        if backend == .claude { Task { await model.claudeWorkspace.stop() } }
                        else if backend == .codex && usesNativeCodex { Task { await model.codexNativeWorkspace.stop() } }
                        else if model.codexWorkspace.isBusy { Task { await model.codexWorkspace.stop() } }
                        else { model.cancelTurn() }
                    }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .disabled(sendDisabled)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 13).padding(.vertical, 11)
            .disabled(composerDisabled)
    }

    private var sendDisabled: Bool {
        if submitting || draft.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if backend == .claude { return model.claudeWorkspace.projectIssue != nil }
        guard backend == .codex else { return false }
        return codexProjectIssue != nil || (usesNativeCodex && !model.codexNativeWorkspace.isConnected)
    }

    @ViewBuilder private var composerProviderControls: some View {
        switch backend {
        case .codex: codexComposerControls
        case .claude: claudeComposerControls
        case .local: localComposerControls
        }
    }

    private var composerModelSelection: Binding<String> {
        Binding(get: { composerModelID }, set: { value in
            composerModelID = value
            if !(providerModels.first(where: { $0.id == value })?.efforts.contains(composerEffort) ?? false) { composerEffort = "" }
            saveComposerChoices()
        })
    }

    private var composerEffortSelection: Binding<String> {
        Binding(get: { composerEffort }, set: { composerEffort = $0; saveComposerChoices() })
    }

    private var composerEfforts: [String] {
        providerModels.first(where: { $0.id == composerModelID })?.efforts ?? []
    }

    private var codexComposerControls: some View {
        HStack(spacing: 10) {
                    Picker("Model", selection: composerModelSelection) {
                        if codexModels.isEmpty { Text("Choose model").tag("") }
                        if !composerModelID.isEmpty && !codexModels.contains(where: { $0.id == composerModelID }) {
                            Text(composerModelID).tag(composerModelID)
                        }
                        ForEach(codexModels) { Text($0.displayName).tag($0.id) }
                    }
                    .frame(maxWidth: 190)
                    Picker("Reasoning", selection: composerEffortSelection) {
                        Text("Default").tag("")
                        ForEach(composerEfforts, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .frame(maxWidth: 130)
                    Spacer(minLength: 0)
                    codexMeters
                }
                .labelsHidden().controlSize(.small)
                .disabled(submitting || codexBusy)
                .padding(.horizontal, 13).padding(.vertical, 7)
    }

    private var claudeComposerControls: some View {
        HStack(spacing: 10) {
            Picker("Claude model", selection: composerModelSelection) {
                if providerModels.isEmpty { Text("Choose model").tag("") }
                if !composerModelID.isEmpty && !providerModels.contains(where: { $0.id == composerModelID }) { Text(composerModelID).tag(composerModelID) }
                ForEach(providerModels) { Text($0.displayName).tag($0.id) }
            }.frame(maxWidth: 190)
            Picker("Reasoning", selection: composerEffortSelection) {
                Text("Default").tag("")
                ForEach(composerEfforts, id: \.self) { Text($0.capitalized).tag($0) }
            }.frame(maxWidth: 130)
            Spacer(minLength: 0)
            claudeMeters
        }.labelsHidden().controlSize(.small).disabled(submitting || model.claudeWorkspace.isBusy)
            .padding(.horizontal, 13).padding(.vertical, 7)
    }

    private var claudeMeters: some View {
        let claude = model.claudeWorkspace
        let help = choiceError ?? claude.errorMessage ?? claude.projectIssue ?? claude.status ?? "Check Claude Code in AI Settings"
        let attention = choiceError != nil || claude.errorMessage != nil || claude.projectIssue != nil
        return HStack(spacing: 8) {
            Button { openBackendSettings?() } label: {
                Image(systemName: attention ? "exclamationmark.circle.fill" : claude.isBusy ? "hourglass" : "circle.fill")
                    .font(.system(size: 12)).foregroundStyle(attention ? Color.orange : claude.authenticated ? .green : .secondary)
                    .frame(width: 18, height: 20)
            }.buttonStyle(.plain).accessibilityLabel(help).help(help)
            compactGauge(value: claude.contextUsedTokens.flatMap { used in
                claude.contextLimitTokens.flatMap { $0 > 0 ? Double(used) / Double($0) : nil }
            }, symbol: "text.alignleft", help: claude.contextUsedTokens.map {
                "Claude context: \($0) tokens of \(claude.contextLimitTokens.map(String.init) ?? "unknown")"
            } ?? "Claude context usage unavailable")
            if claude.usageWindows.isEmpty { compactGauge(value: nil, symbol: "bolt", help: "Claude subscription quota unavailable from the official CLI") }
            else {
                ForEach(Array(claude.usageWindows.enumerated()), id: \.offset) { _, window in
                    compactGauge(value: window.usedPercent / 100,
                        symbol: window.durationMinutes.map { $0 > 1440 ? "calendar" : "clock" } ?? "bolt",
                        help: "Claude: \(Int(window.usedPercent.rounded()))% used\(window.durationMinutes.map { " · \($0)-minute window" } ?? "")\(window.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                }
            }
        }
    }

    private var localComposerControls: some View {
        HStack(spacing: 10) {
                    Picker("Local chat model", selection: $localModel) {
                        if !installedLocalModels.contains(localModel) { Text(localModel.isEmpty ? "No model installed" : localModel).tag(localModel) }
                        ForEach(installedLocalModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(maxWidth: 250)
                    .disabled(installedLocalModels.isEmpty || model.isWorkspaceSelectionBusy)
                    .help("Default model for local chats on this Mac")
                    Spacer(minLength: 0)
                    ChatMeterBar()
                }
                .onAppear { installedLocalModels = MLXEngine.installedModels(); localModel = MLXEngine.assignedModel(for: .chat) }
                .onChange(of: localModel) { MLXEngine.assign(model: localModel, to: .chat) }
                .padding(.horizontal, 13).padding(.vertical, 7)
    }

    private var codexStatusHelp: String {
        if usesNativeCodex {
            return choiceError ?? model.codexNativeWorkspace.errorMessage ?? model.codexNativeWorkspace.projectIssue
                ?? model.codexNativeWorkspace.status
                ?? (model.codexNativeWorkspace.isConnected ? "Native Codex ready" : "Connect Codex in AI Settings")
        }
        return choiceError ?? model.codexWorkspace.errorMessage ?? model.codexWorkspace.projectIssue
            ?? model.codexWorkspace.status
            ?? (model.codexWorkspace.authenticated ? "Codex ready" : "Sign in to Codex in AI Settings")
    }

    private var codexMeters: some View {
        let connected = usesNativeCodex ? model.codexNativeWorkspace.isConnected : model.codexWorkspace.authenticated
        let usedTokens = usesNativeCodex ? model.codexNativeWorkspace.contextUsedTokens : model.codexWorkspace.contextUsedTokens
        let limitTokens = usesNativeCodex ? model.codexNativeWorkspace.contextLimitTokens : model.codexWorkspace.contextLimitTokens
        let windows = usesNativeCodex ? model.codexNativeWorkspace.usageWindows : model.codexWorkspace.usageWindows
        return HStack(spacing: 8) {
            Button { openBackendSettings?() } label: {
                Image(systemName: codexNeedsAttention ? "exclamationmark.circle.fill" : codexBusy ? "hourglass" : "circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(codexNeedsAttention ? Color.orange : connected ? .green : .secondary)
                    .frame(width: 18, height: 20)
            }
            .buttonStyle(.plain).accessibilityLabel(codexStatusHelp).help(codexStatusHelp)
            compactGauge(value: usedTokens.flatMap { used in
                limitTokens.flatMap { $0 > 0 ? Double(used) / Double($0) : nil }
            }, symbol: "text.alignleft", help: usedTokens.map { "Context: \($0) tokens of \(limitTokens.map(String.init) ?? "unknown")" } ?? "Context usage unavailable")
            if windows.isEmpty {
                compactGauge(value: nil, symbol: "bolt", help: "Usage limits unavailable")
            } else {
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    compactGauge(value: window.usedPercent / 100, symbol: window.durationMinutes.map { $0 > 1440 ? "calendar" : "clock" } ?? "bolt", help: "\(Int(window.usedPercent.rounded()))% used\(window.durationMinutes.map { " · \($0)-minute window" } ?? "")\(window.resetsAt.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")")
                }
            }
        }
    }

    private var codexNeedsAttention: Bool {
        choiceError != nil || (usesNativeCodex
            ? model.codexNativeWorkspace.errorMessage != nil || model.codexNativeWorkspace.projectIssue != nil
            : model.codexWorkspace.errorMessage != nil || model.codexWorkspace.projectIssue != nil)
    }

    private func compactGauge(value: Double?, symbol: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 2)
                if let value {
                    Circle().trim(from: 0, to: min(1, max(0, value)))
                        .stroke(value >= 0.95 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Image(systemName: "questionmark").font(.system(size: 7, weight: .semibold))
                }
            }.frame(width: 20, height: 20)
        }.foregroundStyle(.secondary).accessibilityElement(children: .ignore).accessibilityLabel(help).help(help)
    }

    private func refreshComposerChoices() {
        guard let chatID = model.selectedWorkspaceChatID else { composerModelID = ""; composerEffort = ""; return }
        if backend == .claude {
            composerModelID = WorkspaceChatBackend.claudeModel(model, chatID: chatID)
            composerEffort = WorkspaceChatBackend.claudeEffort(model, chatID: chatID, modelID: composerModelID) ?? ""
            return
        }
        composerModelID = WorkspaceChatBackend.codexModel(model, chatID: chatID)
        composerEffort = WorkspaceChatBackend.codexEffort(model, chatID: chatID, modelID: composerModelID) ?? ""
    }

    private func saveComposerChoices() {
        guard let chatID = model.selectedWorkspaceChatID else { return }
        let provider = backend == .claude ? "claude" : "codex"
        do {
            try model.stores?.setValues([
                WorkspaceChatBackend.key(chatID, "\(provider).model"): composerModelID,
                WorkspaceChatBackend.key(chatID, "\(provider).effort"): composerEffort
            ])
            choiceError = nil
        } catch { choiceError = "These choices could not be saved. Try again in AI Settings." }
    }

    private func send() {
        guard model.selectedWorkspaceChat?.archivedAt == nil, !model.selectedUnassignedVoiceHistory, !needsProjectChat else { return }
        if backend == .claude, let chatID = model.selectedWorkspaceChatID {
            guard !submitting, !confirmingClaudeHistory, !model.claudeWorkspace.isBusy else { return }
            let prompt = draft
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            submitting = true
            Task {
                // Metadata refresh only: no automatic sign-in or account switch.
                if !model.claudeWorkspace.authenticated || model.claudeWorkspace.models.isEmpty { await model.claudeWorkspace.checkSetup() }
                guard backend == .claude, model.claudeWorkspace.authenticated, model.selectedWorkspaceChatID == chatID,
                      let namespace = model.claudeWorkspace.profileNamespace else {
                    submitting = false
                    if backend == .claude, model.selectedWorkspaceChatID == chatID { openBackendSettings?() }
                    return
                }
                let modelID = WorkspaceChatBackend.claudeModel(model, chatID: chatID)
                let effort = WorkspaceChatBackend.claudeEffort(model, chatID: chatID, modelID: modelID)
                let intent = ClaudeComposerSendIntent(chatID: chatID, profileNamespace: namespace, prompt: prompt, modelID: modelID, effort: effort)
                do {
                    if try model.claudeWorkspace.historyDecision(chatID: chatID, profileNamespace: namespace) == nil {
                        pendingClaudeSend = intent; confirmingClaudeHistory = true
                        submitting = false
                        return
                    }
                } catch {
                    choiceError = "The saved history choice could not be checked. Nothing was sent."
                    submitting = false; return
                }
                await submitClaude(intent)
                submitting = false
            }
            inputFocused = true
            return
        }
        if backend == .codex, let chatID = model.selectedWorkspaceChatID {
            guard !submitting, !codexBusy else { return }
            let prompt = draft
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if usesNativeCodex {
                submitting = true
                Task {
                    let modelID = WorkspaceChatBackend.codexModel(model, chatID: chatID)
                    let effort = WorkspaceChatBackend.codexEffort(model, chatID: chatID, modelID: modelID)
                    let accepted = await model.codexNativeWorkspace.sendFromComposer(prompt: prompt, chatID: chatID,
                        modelID: modelID, effort: effort)
                    if accepted, model.selectedWorkspaceChatID == chatID, draft == prompt { draft = "" }
                    submitting = false
                }
                inputFocused = true
                return
            }
            let previous = Set(model.codexWorkspace.turns.map(\.id))
            submitting = true
            Task {
                if !model.codexWorkspace.authenticated || model.codexWorkspace.models.isEmpty {
                    await model.codexWorkspace.checkSetup()
                }
                guard model.codexWorkspace.authenticated, model.selectedWorkspaceChatID == chatID else {
                    submitting = false
                    return
                }
                let modelID = WorkspaceChatBackend.codexModel(model, chatID: chatID)
                let effort = WorkspaceChatBackend.codexEffort(model, chatID: chatID, modelID: modelID)
                await model.codexWorkspace.sendFromComposer(prompt: prompt, chatID: chatID, modelID: modelID, effort: effort)
                // Keep the text when Codex never received it, so Send retries it.
                if draft == prompt, model.codexWorkspace.turns.contains(where: { !previous.contains($0.id)
                    && ($0.providerTurnID != nil || ![.failed, .cancelled].contains($0.state)) }) { draft = "" }
                submitting = false
            }
        } else if backend == .local, model.send(draft) {
            draft = ""
        }
        inputFocused = true
    }

    private func clearPendingClaudeSend() { pendingClaudeSend = nil; confirmingClaudeHistory = false }

    private func resolveClaudeHistory(share: Bool) {
        guard let intent = pendingClaudeSend,
              intent.isCurrent(chatID: model.selectedWorkspaceChatID, profileNamespace: model.claudeWorkspace.profileNamespace, backend: backend),
              model.claudeWorkspace.saveHistoryDecision(share, chatID: intent.chatID, profileNamespace: intent.profileNamespace) else {
            clearPendingClaudeSend(); return
        }
        clearPendingClaudeSend()
        submitting = true
        Task { await submitClaude(intent); submitting = false }
    }

    private func submitClaude(_ intent: ClaudeComposerSendIntent) async {
        guard intent.isCurrent(chatID: model.selectedWorkspaceChatID, profileNamespace: model.claudeWorkspace.profileNamespace, backend: backend),
              model.selectedWorkspaceChat?.archivedAt == nil else { return }
        let previous = Set(model.claudeWorkspace.turns.map(\.id))
        await model.claudeWorkspace.sendFromComposer(prompt: intent.prompt, chatID: intent.chatID, modelID: intent.modelID, effort: intent.effort)
        if model.selectedWorkspaceChatID == intent.chatID, draft == intent.prompt, model.claudeWorkspace.turns.contains(where: { !previous.contains($0.id)
            && ($0.providerTurnID != nil || ![.failed, .cancelled].contains($0.state)) }) { draft = "" }
    }
}

struct MessageBubble: View {
    let message: DisplayMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.reasoning.isEmpty {
                DisclosureGroup {
                    Text(message.reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label("Thoughts", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(message.toolNotes, id: \.self) { note in
                Text(note)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if !message.text.isEmpty {
                Text(LocalizedStringKey(message.text))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(message.role == .user ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                    )
            } else if message.isStreaming {
                ProgressView().controlSize(.small).padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

struct SuggestionCard: View {
    @Environment(AppModel.self) private var model
    let suggestion: Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text("\(suggestion.connectorID) · \(suggestion.toolName)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Button("Do it") { model.accept(suggestion) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Dismiss") { model.reject(suggestion) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.5)))
    }
}
