import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasEngines
import AitvarasConnectors

enum WorkspaceChatBackend: String, CaseIterable, Identifiable {
    case local, codex, claude
    var id: String { rawValue }
    var title: String { switch self { case .local: "Local"; case .codex: "Codex"; case .claude: "Claude" } }
    var isCloud: Bool { self != .local }
    static func requiresHistoryConfirmation(from: Self, to: Self) -> Bool { to.isCloud && from != to }
    static func key(_ chatID: UUID, _ setting: String) -> String { "workspace.chat.\(chatID).\(setting)" }
    @MainActor static func codexModel(_ model: AppModel, chatID: UUID) -> String {
        let saved = try? model.stores?.value(forKey: key(chatID, "codex.model"))
        if let saved, !saved.isEmpty { return saved }
        return codexModels(model, chatID: chatID).first?.id ?? ""
    }
    @MainActor static func codexModels(_ model: AppModel, chatID: UUID) -> [CodexInteractiveModel] {
        model.codexNativeWorkspace.prefersNative(chatID: chatID) ? model.codexNativeWorkspace.models : model.codexWorkspace.models
    }
    @MainActor static func codexEffort(_ model: AppModel, chatID: UUID, modelID: String) -> String? {
        guard let saved = try? model.stores?.value(forKey: key(chatID, "codex.effort")),
              codexModels(model, chatID: chatID).first(where: { $0.id == modelID })?.efforts.contains(saved) == true else { return nil }
        return saved
    }
    @MainActor static func claudeModel(_ model: AppModel, chatID: UUID) -> String {
        let saved = try? model.stores?.value(forKey: key(chatID, "claude.model"))
        return saved.flatMap { $0.isEmpty ? nil : $0 } ?? model.claudeWorkspace.models.first?.id ?? ""
    }
    @MainActor static func claudeEffort(_ model: AppModel, chatID: UUID, modelID: String) -> String? {
        guard let saved = try? model.stores?.value(forKey: key(chatID, "claude.effort")),
              model.claudeWorkspace.models.first(where: { $0.id == modelID })?.efforts.contains(saved) == true else { return nil }
        return saved
    }
}

/// Kept as the synthetic fixture entry point; production uses the same ChatView.
struct CodexInteractiveView: View {
    let chatID: UUID
    var body: some View { ChatView(backend: .codex).onAppear { AppModel.shared.codexWorkspace.load(chatID: chatID) } }
}

struct ChatBackendSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    let initialBackend: WorkspaceChatBackend
    @State private var tab: WorkspaceChatBackend = .local
    @State private var modelID = ""
    @State private var effort = ""
    @State private var localModel = MLXEngine.assignedModel(for: .chat)
    @State private var installed: [String] = []
    @State private var message: String?
    @State private var connectionMode = "isolated"
    @State private var shareHistory = false
    @State private var claudeShareHistory = false
    @State private var claudeHistoryNeedsReview = false

    private var availableModels: [CodexInteractiveModel] {
        if tab == .claude { return model.claudeWorkspace.models }
        return connectionMode == "native" ? model.codexNativeWorkspace.models : model.codexWorkspace.models
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("AI Settings").font(.title2.weight(.semibold))
            Picker("Provider", selection: $tab) {
                ForEach(WorkspaceChatBackend.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Form {
                switch tab {
                case .codex: codexSettings
                case .local:
                    Section("Local model") {
                        Picker("Default chat model", selection: $localModel) {
                            if !installed.contains(localModel) { Text("Not installed").tag(localModel) }
                            ForEach(installed, id: \.self) { Text($0).tag($0) }
                        }.disabled(installed.isEmpty || model.isWorkspaceSelectionBusy)
                        Text("Applies to local chats on this Mac. Models load only when used.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .claude: claudeSettings
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.formStyle(.grouped)
            HStack {
                Text("Provider changes apply to the next message.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 600, height: 590)
        .onAppear {
            tab = initialBackend; installed = MLXEngine.installedModels()
            model.codexNativeWorkspace.load(chatID: chatID)
            connectionMode = model.codexNativeWorkspace.prefersNative(chatID: chatID) ? "native" : "isolated"
            shareHistory = (try? model.stores?.value(forKey: WorkspaceChatBackend.key(chatID, "shareHistory.codex"))) == "1"
            refreshClaudeHistoryChoice()
            model.claudeWorkspace.load(chatID: chatID)
            refreshChoices()
        }
        .onChange(of: shareHistory) {
            do { try model.stores?.setValue(shareHistory ? "1" : "0", forKey: WorkspaceChatBackend.key(chatID, "shareHistory.codex")) }
            catch { message = "The history choice could not be saved. Nothing was sent." }
        }
        .onChange(of: model.codexWorkspace.models) { refreshChoices() }
        .onChange(of: model.claudeWorkspace.models) { refreshChoices() }
        .onChange(of: tab) { refreshChoices() }
        .onChange(of: model.claudeWorkspace.profileNamespace) { refreshClaudeHistoryChoice() }
        .onChange(of: model.codexNativeWorkspace.models) { refreshChoices() }
        .onChange(of: connectionMode) {
            model.codexNativeWorkspace.chooseConnectionMode(chatID: chatID, native: connectionMode == "native")
            refreshChoices()
        }
        .onChange(of: localModel) { MLXEngine.assign(model: localModel, to: .chat) }
        .onChange(of: modelID) {
            if !(availableModels.first(where: { $0.id == modelID })?.efforts.contains(effort) ?? false) { effort = "" }
            saveChoices()
        }
        .onChange(of: effort) { saveChoices() }
    }

    private var claudeSettings: some View {
        Group {
            Section("Claude account") {
                Picker("Account profile", selection: Binding(get: { model.claudeWorkspace.accountMode }, set: { next in
                    Task { await model.claudeWorkspace.chooseAccountMode(next) }
                })) {
                    Text("Claude Code account").tag(ClaudeAccountMode.shared)
                    Text("Separate account").tag(ClaudeAccountMode.separate)
                }.pickerStyle(.segmented).labelsHidden().disabled(model.claudeWorkspace.isBusy)
                Text(model.claudeWorkspace.accountMode == .shared
                     ? "Shares the Claude Code login on this Mac, not the Claude app's login."
                     : "A separate login for Aitvaras. Your other Claude login stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Label(claudeConnectionTitle, systemImage: claudeConnectionIcon)
                        .foregroundStyle(model.claudeWorkspace.authenticated ? .green : .primary)
                    Spacer()
                    if model.claudeWorkspace.isBusy { ProgressView().controlSize(.small) }
                }
                if model.claudeWorkspace.connectionPhase == .waitingForBrowser {
                    Text("Finish in your browser. Aitvaras will verify the login automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Open Browser", systemImage: "safari") { model.claudeWorkspace.reopenSignInBrowser() }
                            .disabled(model.claudeWorkspace.signInBrowserURL == nil || model.claudeWorkspace.isStopping)
                        Button("Cancel") { Task { await model.claudeWorkspace.stop() } }
                            .disabled(model.claudeWorkspace.isStopping)
                    }
                } else if model.claudeWorkspace.authenticated {
                    Button("Check Connection", systemImage: "arrow.clockwise") { Task { await model.claudeWorkspace.checkSetup() } }
                        .disabled(model.claudeWorkspace.isBusy)
                } else {
                    Button(model.claudeWorkspace.requiresFreshSignIn ? "Reconnect Claude" : model.claudeWorkspace.connectionPhase == .failed ? "Try Sign-In Again" : "Sign in to Claude", systemImage: "person.crop.circle.badge.checkmark") {
                        Task { await model.claudeWorkspace.connectClaude() }
                    }.buttonStyle(.borderedProminent).disabled(model.claudeWorkspace.isBusy)
                    Text("Uses your Claude subscription. No API billing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.claudeWorkspace.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }
            Section("This chat") {
                Picker("Model", selection: $modelID) {
                    if availableModels.isEmpty { Text("Sign in first").tag("") }
                    if !modelID.isEmpty && !availableModels.contains(where: { $0.id == modelID }) { Text("Unavailable: \(modelID)").tag(modelID) }
                    ForEach(availableModels) { Text($0.displayName).tag($0.id) }
                }
                Picker("Reasoning", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(availableModels.first(where: { $0.id == modelID })?.efforts ?? [], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Catch Claude up on this chat's history", isOn: Binding(get: { claudeShareHistory }, set: saveClaudeHistoryChoice))
                    .disabled(!model.claudeWorkspace.authenticated || model.claudeWorkspace.profileNamespace == nil)
                Text(claudeShareHistory ? "Only this chat's unseen messages are shared on Send; each handover is shown in the timeline."
                     : "Claude receives only your message and reviewed project instructions. Earlier Local turns stay here.")
                    .font(.caption).foregroundStyle(.secondary)
                if claudeHistoryNeedsReview {
                    Text("History sharing needs a new choice for this account profile.").font(.caption).foregroundStyle(.orange)
                    Button("Keep history private") { saveClaudeHistoryChoice(false) }
                }
            }.disabled(model.claudeWorkspace.isBusy)
            Section {
                DisclosureGroup("Advanced") {
                    Button("Sign in using Terminal instead…") { model.claudeWorkspace.openOfficialSignIn() }
                        .disabled(model.claudeWorkspace.isBusy)
                    Text("For browser callbacks blocked by your network or account setup. Finish in Terminal, then use Sign in to Claude to verify.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Refresh Claude Code conversation") { Task { await model.claudeWorkspace.refreshHistory(chatID: chatID) } }
                        .disabled(!model.claudeWorkspace.canRefreshHistory)
                    if let status = model.claudeWorkspace.historyRefreshStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                    Text("Claude Code sessions only; Claude app/web chats are not synchronized. Imported chats stay read-only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var claudeConnectionTitle: String {
        switch model.claudeWorkspace.connectionPhase {
        case .idle: "Connect your Claude account"
        case .checking: "Checking account…"
        case .waitingForBrowser: model.claudeWorkspace.isStopping ? "Cancelling sign-in…" : "Waiting for browser sign-in"
        case .verifying: "Verifying sign-in…"
        case .connected: model.claudeWorkspace.accountLabel ?? "Claude connected"
        case .signedOut: "Not signed in"
        case .cancelled: "Sign-in cancelled"
        case .failed: "Connection needs attention"
        }
    }

    private var claudeConnectionIcon: String {
        switch model.claudeWorkspace.connectionPhase {
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .waitingForBrowser: "safari"
        default: "person.crop.circle"
        }
    }

    private func refreshClaudeHistoryChoice() {
        let allowed = (try? model.stores?.value(forKey: WorkspaceChatBackend.key(chatID, "shareHistory.claude"))) == "1"
        let granted = try? model.stores?.value(forKey: WorkspaceChatBackend.key(chatID, "shareHistory.claude.profile"))
        claudeShareHistory = allowed && model.claudeWorkspace.authenticated
            && granted != nil && granted == model.claudeWorkspace.profileNamespace
        claudeHistoryNeedsReview = allowed && !claudeShareHistory
    }

    private func saveClaudeHistoryChoice(_ value: Bool) {
        guard !value || (model.claudeWorkspace.authenticated && model.claudeWorkspace.profileNamespace != nil) else { return }
        do {
            try model.stores?.setValues([
                WorkspaceChatBackend.key(chatID, "shareHistory.claude"): value ? "1" : "0",
                WorkspaceChatBackend.key(chatID, "shareHistory.claude.profile"): model.claudeWorkspace.profileNamespace ?? ""
            ])
            claudeShareHistory = value; claudeHistoryNeedsReview = false; message = nil
        } catch { message = "The history choice could not be saved. Nothing was sent." }
    }

    private var codexSettings: some View {
        Group {
            Section("Connection") {
                Picker("This chat", selection: $connectionMode) {
                    Text("Aitvaras-only").tag("isolated")
                    Text("Linked Codex chat").tag("native")
                }.pickerStyle(.segmented).labelsHidden()
                // D30: the per-chat history decision, for either connection.
                Toggle("Catch Codex up on this chat's history", isOn: $shareHistory)
                Text(shareHistory
                     ? "With each Send, Codex receives messages from this chat it has not seen yet, such as Local turns, up to \(Stores.workspaceSharedHistoryCharacters.formatted()) characters. Each handover is shown in the chat."
                     : "Codex receives only what you type. Local turns in this chat stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if connectionMode == "isolated", model.codexNativeWorkspace.isLinked(chatID: chatID) {
                    Text("This chat is still linked. Switching keeps the native chat and its history.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Use Aitvaras-only") {
                        model.codexNativeWorkspace.unlinkChat(chatID: chatID)
                        model.codexNativeWorkspace.chooseConnectionMode(chatID: chatID, native: false)
                        refreshChoices()
                    }.disabled(model.codexNativeWorkspace.isBusy)
                }
            }
            if connectionMode == "native" {
                CodexNativeChatSettingsView(chatID: chatID)
            } else {
            Section("Account") {
                HStack {
                    Label(model.codexWorkspace.authenticated ? "Connected" : "Not connected",
                          systemImage: model.codexWorkspace.authenticated ? "checkmark.circle" : "person.crop.circle")
                    Spacer()
                    if model.codexWorkspace.isBusy { ProgressView().controlSize(.small) }
                    else {
                        Button(model.codexWorkspace.authenticated ? "Refresh" : "Connect") {
                            Task { await model.codexWorkspace.connectAccount() }
                        }
                    }
                }
                if model.codexWorkspace.isBusy, let status = model.codexWorkspace.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.codexWorkspace.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if model.codexWorkspace.authenticated && model.codexWorkspace.models.isEmpty {
                    Text("No models were returned. Refresh the account to retry.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("This chat") {
                Picker("Model", selection: $modelID) {
                    if availableModels.isEmpty { Text("Connect an account first").tag("") }
                    if !modelID.isEmpty && !availableModels.contains(where: { $0.id == modelID }) {
                        Text("Unavailable: \(modelID)").tag(modelID)
                    }
                    ForEach(availableModels) { Text($0.displayName).tag($0.id) }
                }
                Picker("Reasoning", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(availableModels.first(where: { $0.id == modelID })?.efforts ?? [], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
            }.disabled(model.codexWorkspace.isBusy)
            Section {
                Label("Messages are sent to OpenAI when you press Send.", systemImage: "arrow.up.right")
                    .font(.caption)
                DisclosureGroup("Data and access") {
                    Text("This chat's shared history and project instructions go to OpenAI when you send. Read-only project files are optional in Project settings. Imported chats and captures stay excluded; no shell or writes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }
        }
    }

    private func refreshChoices() {
        if tab == .claude {
            modelID = WorkspaceChatBackend.claudeModel(model, chatID: chatID)
            effort = WorkspaceChatBackend.claudeEffort(model, chatID: chatID, modelID: modelID) ?? ""
            return
        }
        modelID = WorkspaceChatBackend.codexModel(model, chatID: chatID)
        effort = WorkspaceChatBackend.codexEffort(model, chatID: chatID, modelID: modelID) ?? ""
    }
    private func saveChoices() {
        guard tab != .local else { return }
        let provider = tab == .claude ? "claude" : "codex"
        do {
            try model.stores?.setValues([
                WorkspaceChatBackend.key(chatID, "\(provider).model"): modelID,
                WorkspaceChatBackend.key(chatID, "\(provider).effort"): effort
            ])
            message = nil
        } catch { message = "These choices could not be saved. Try again." }
    }
}

/// One visible timeline regardless of the selected backend. Stored native
/// imports remain a separate read-only source and never enter this projection.
struct WorkspaceChatTranscriptView: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID
    @State private var saved: [WorkspaceChatTimelineEntry] = []
    @State private var limit = 200
    @State private var error: String?

    private var entries: [WorkspaceChatTimelineEntry] {
        let savedOrder = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($0.element.id, $0.offset) })
        var byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        for message in model.messages {
            let id = "local:\(message.id.uuidString)"
            let old = byID[id]
            guard old != nil || message.isStreaming else { continue }
            byID[id] = .init(id: id, role: message.role == .user ? "user" : "assistant", text: message.text,
                timestamp: old?.timestamp ?? .now, provider: "local")
        }
        for turn in model.codexWorkspace.turns {
            let base = "codex:\(turn.id.uuidString):"
            guard byID[base + "user"] != nil || !turn.state.isTerminal else { continue }
            byID[base + "user"] = .init(id: base + "user", role: "user", text: turn.promptText,
                timestamp: turn.startedAt, provider: "codex", sourceTurnID: turn.id, state: turn.state,
                notDelivered: turn.state == .failed && turn.providerTurnID == nil,
                failureReason: byID[base + "user"]?.failureReason)
            if !turn.outputText.isEmpty {
                byID[base + "assistant"] = .init(id: base + "assistant", role: "assistant", text: turn.outputText,
                    timestamp: turn.endedAt ?? turn.startedAt, provider: "codex", sourceTurnID: turn.id, state: turn.state)
            }
        }
        for turn in model.claudeWorkspace.turns {
            let base = "claude:\(turn.id.uuidString):"
            guard byID[base + "user"] != nil || !turn.state.isTerminal else { continue }
            byID[base + "user"] = .init(id: base + "user", role: "user", text: turn.promptText,
                timestamp: turn.startedAt, provider: "claude", sourceTurnID: turn.id, state: turn.state,
                notDelivered: turn.state == .failed && turn.providerTurnID == nil, failureReason: turn.failureReason)
            if !turn.outputText.isEmpty {
                byID[base + "assistant"] = .init(id: base + "assistant", role: "assistant", text: turn.outputText,
                    timestamp: turn.endedAt ?? turn.startedAt, provider: "claude", sourceTurnID: turn.id, state: turn.state)
            }
        }
        if model.codexNativeWorkspace.isLinked(chatID: chatID) {
            for entry in model.codexNativeWorkspace.liveEntries { byID[entry.id] = entry }
        }
        return byID.values.sorted {
            if $0.timestamp == $1.timestamp {
                if ($0.observedAt != nil) != ($1.observedAt != nil) { return $0.observedAt == nil }
                // The SDK supplies message order, not creation timestamps.
                // Preserve the snapshot's order instead of sorting UUIDs or
                // grouping all observed user messages before all assistants.
                if $0.observedAt != nil, $1.observedAt != nil,
                   let lhs = savedOrder[$0.id], let rhs = savedOrder[$1.id], lhs != rhs { return lhs < rhs }
                if $0.sourceTurnID == $1.sourceTurnID && $0.role != $1.role { return $0.role == "user" }
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if saved.count >= limit { Button("Load Earlier Messages") { limit += 200; reload() } }
                    if entries.isEmpty { ContentUnavailableView("Start chatting", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a provider and send a message.")) }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    ForEach(entries) { entry in
                        if entry.role == "handover" { handoverLine(entry) } else {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.role == "user" ? "You" : entry.provider == "codex" ? "Codex" : entry.provider == "claude" ? "Claude" : "Aitvaras")
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                if let observedAt = entry.observedAt {
                                    Text("Observed from Claude Code · \(observedAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if entry.notDelivered {
                                    Text("Not sent").font(.caption2).foregroundStyle(.orange)
                                        .help(entry.failureReason ?? "The provider never received this message.")
                                    if let reason = entry.failureReason {
                                        Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                } else if let state = entry.state, state != .completed && state != .running && state != .prepared {
                                    Text(state == .cancelled ? "Stopped" : state == .outcomeUnknown ? "Outcome not confirmed" : state == .cancellationRequested ? "Stopping…" : state == .interrupted ? "Interrupted" : "Failed")
                                        .font(.caption2).foregroundStyle(.orange)
                                        .help(entry.failureReason ?? "")
                                }
                            }
                            if entry.role != "user" && entry.role != "assistant" {
                                DisclosureGroup {
                                    Text(entry.text).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled).padding(.vertical, 6)
                                } label: {
                                    Label(entry.role == "reasoning" ? "Reasoning" : "Tool activity",
                                          systemImage: entry.role == "reasoning" ? "brain" : "terminal")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(LocalizedStringKey(entry.text)).textSelection(.enabled).padding(12)
                                    .background(entry.role == "user" ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 12))
                            }
                        }.frame(maxWidth: .infinity, alignment: entry.role == "user" ? .trailing : .leading).id(entry.id)
                        }
                    }
                }.padding(20)
            }
            .onChange(of: entries.last?.text) { if let id = entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: entries.count) { if let id = entries.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .onChange(of: chatID, initial: true) { reload() }
        .onChange(of: model.isResponding) { reload() }
        .onChange(of: model.codexWorkspace.isBusy) { reload() }
        .onChange(of: model.claudeWorkspace.isBusy) { reload() }
        .onChange(of: model.claudeWorkspace.transcriptRevision) { reload() }
        .onChange(of: model.codexNativeWorkspace.transcriptRevision) { reload() }
    }
    /// A handover is a record of what this chat shared, not a message: one
    /// quiet line that opens to the exact text that was sent (D30).
    private func handoverLine(_ entry: WorkspaceChatTimelineEntry) -> some View {
        DisclosureGroup {
            Text(entry.text).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).padding(.vertical, 6)
        } label: {
            Label(Self.handoverTitle(entry), systemImage: "arrow.uturn.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).id(entry.id)
        .help("The exact messages that went to \(WorkspaceHandoverText.providerName(entry.provider)) with your next message")
    }

    /// "Caught Codex up on 3 messages from Local", read from the block's header.
    static func handoverTitle(_ entry: WorkspaceChatTimelineEntry) -> String {
        let header = entry.text.prefix { $0 != "\n" }
        let parts = header.dropFirst(WorkspaceHandoverText.header.count).trimmingCharacters(in: CharacterSet(charactersIn: " ·]"))
            .components(separatedBy: " · ")
        let summary = parts.first?.replacingOccurrences(of: " since your last reply", with: "") ?? "earlier messages"
        let omitted = parts.first { $0.hasSuffix("earlier omitted") }.map { " (\($0))" } ?? ""
        return "Caught \(WorkspaceHandoverText.providerName(entry.provider)) up on \(summary)\(omitted)"
    }

    private func reload() {
        do { saved = try model.stores?.workspaceChatTimeline(chatID: chatID, limit: limit) ?? []; error = nil }
        catch { self.error = "Earlier messages could not be loaded. Nothing was deleted." }
    }
}
