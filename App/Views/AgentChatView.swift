import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AitvarasAgents
import AitvarasAgent
import AitvarasStore
import AitvarasCore

/// One transcript and composer, observing the application-owned chat manager.
struct AgentChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var chat: ChatModel
    let chatID: UUID
    var canSend = true
    var workspaceError: String? = nil
    var compact = false

    @State private var showingChanges = false
    @State private var editingMessage: AgentTranscriptEntry?
    @State private var displayedWorktree: AgentWorktree?
    @State private var visibilityID = UUID()
    @State private var gitProject = false
    @State private var atBottom = true
    @State private var bottomVisible = true
    @State private var scrolling = false
    @State private var composerFocusRequest: UUID?
    @State private var transcriptHeight: CGFloat = 0

    private var gatewayApprovals: [GatewayApprovalRequest] {
        model.gatewayInlineApprovals.filter { $0.invocation.presentation == .inline(chatID: chatID) }
    }

    var body: some View {
        HSplitView {
            transcript.frame(minWidth: 300)
            if !compact, showingChanges, let changes = chat.changes {
                AgentChangesView(chat: chat, owner: chatID, changes: changes).id(chatID)
            }
        }
        .environment(\.chatResourceScope, chat.resourceScope)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !compact {
                VStack(spacing: 0) {
                    if let project = currentProject, model.selectedWorkspaceChatID == chatID {
                        projectHeader(project)
                    }
                    GatewaySuggestionBar()
                }
            }
        }
        .toolbar {
            AgentWakeBadge(manager: model.agentSessionManager, chatID: chatID)
            if !compact, chat.pullRequest != nil || chat.pullRequestBinding != nil {
                AgentPullRequestBar(chat: chat)
            }
            if !compact {
                Button { showingChanges.toggle() } label: {
                    Label("\(chat.changes?.files.count ?? 0)", systemImage: "doc.text")
                        .labelStyle(.titleAndIcon).monospacedDigit()
                }
                .help(showingChanges ? "Hide changes" : "Show changes").accessibilityLabel("Changes")
                .accessibilityValue("\(chat.changes?.files.count ?? 0) changed files")
                .accessibilityIdentifier("chat.changes")
            }
            Button { chat.prepareSideQuestion(); composerFocusRequest = UUID() } label: {
                Label("Side question", systemImage: "questionmark.bubble").labelStyle(.iconOnly)
            }
            .disabled(!chat.canAskSideQuestion)
            .help(chat.canAskSideQuestion ? "Ask about this chat without adding a message" : AgentConversationText.sideQuestionUnavailable)
            .accessibilityIdentifier("chat.sideQuestion.action")
        }
        .task(id: chatID) {
            showingChanges = false
            guard model.selectedWorkspaceChatID == chatID else { return }
            chat.select(chatID)
            await chat.refreshNativePreview()
            await chat.refreshChanges()
            await chat.refreshPullRequest()
            while !compact, !Task.isCancelled {
                await chat.refreshChanges()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .task(id: model.selectedWorkspaceChatID) {
            displayedWorktree = model.selectedWorkspaceChatID == chatID
                ? (try? model.stores?.agentWorktree(chatID: chatID)) : nil
        }
        .onAppear { chat.showChat(chat.chatID, surface: visibilityID); if compact { composerFocusRequest = UUID() } }
        .onDisappear { chat.showChat(nil, surface: visibilityID) }
        .onChange(of: chatID) { chat.showChat(chat.chatID, surface: visibilityID) }
        .task(id: chat.newProjectID) {
            gitProject = false
            guard chat.chatID == nil, let projectID = chat.newProjectID,
                  let folder = try? model.stores?.workspaceFolders(projectID: projectID).first else { return }
            gitProject = (try? await GitWorkspace().repository(at: URL(fileURLWithPath: folder.path))) != nil
        }
        .onChange(of: model.companionFocusRequest) {
            if compact { composerFocusRequest = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chat.markChatOpened(chatID)
                Task { await chat.refreshNativePreview() }
            }
        }
        .sheet(item: $editingMessage) { entry in
            AgentEditMessageSheet(text: entry.displayText) { text in
                let completed = await chat.fork(entry, editedText: text)
                if completed { editingMessage = nil }
                return completed
            }
        }
    }

    private var currentProject: WorkspaceProject? {
        guard let projectID = model.selectedWorkspaceChat?.projectID else { return nil }
        return model.workspaceProjects.first { $0.id == projectID }
    }

    private func projectHeader(_ project: WorkspaceProject) -> some View {
        HStack(spacing: 12) {
            Button {
                SettingsNavigation.open(.project(project.id, section: .general))
            } label: {
                Label(project.title, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project settings")
            .accessibilityValue(project.title)
            .accessibilityIdentifier("chat.header.project")
            .help("Open Project Settings for \(project.title)")

            if let worktree = displayedWorktree, worktree.chatID == chatID {
                Label(worktree.branch, systemImage: "arrow.triangle.branch")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Worktree")
                    .accessibilityValue(worktree.branch)
                    .accessibilityIdentifier("chat.header.worktree")
                    .help(worktree.worktreePath)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var transcript: some View {
        let entries = chat.displayEntries
        let isRunning = chat.state?.isRunning == true
        let rows = AgentTranscriptRow.rows(entries.filter { !planCardShows($0) },
                                          activeInputID: isRunning ? chat.state?.inputID : nil)
        let latestActivityID = rows.last { row in
            if case .activity = row { return true }
            return false
        }?.id
        let pendingItemIDs = Set((chat.state?.pendingCards ?? []).compactMap(\.scope.itemID))
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(rows) { row in
                            switch row {
                            case .entry(let entry):
                                transcriptRow(entry, streaming: chat.state?.isStreaming(entryID: entry.id) == true).id(entry.id)
                            case .activity(_, let entries, let isLive):
                                AgentActivityPanel(entries: entries, isLive: isLive, isLatest: row.id == latestActivityID) { entry, featured in
                                    transcriptRow(entry, streaming: chat.state?.isStreaming(entryID: entry.id) == true,
                                                  commandFeatured: featured,
                                                  commandAwaitingApproval: isLive && entry.toolItemID.map(pendingItemIDs.contains) == true)
                                }
                            }
                        }
                        if isRunning, case .entry(let last)? = rows.last,
                           ["user", "wakeup", "continued", "automaticContinuation"].contains(last.kind),
                           (chat.state?.pendingCards ?? []).isEmpty, gatewayApprovals.isEmpty {
                            AgentWorkingLabel()
                        }
                        ForEach(Array((chat.state?.pendingCards ?? []).enumerated()), id: \.element.identity) { index, request in
                            requestCard(request, index: index)
                        }
                        ForEach(gatewayApprovals) { request in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Allow \(request.toolName)?").font(.headline)
                                if let reason = request.reason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                                DisclosureGroup("Arguments") {
                                    Text(verbatim: request.arguments.jsonString)
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                }
                                HStack {
                                    Button("Deny") { Task { await model.decideGatewayApproval(request, allow: false) } }
                                    Button("Allow once") { Task { await model.decideGatewayApproval(request, allow: true) } }
                                }
                                if request.canAlwaysAllow {
                                    Button("Always allow in this project") {
                                        Task { await model.decideGatewayApproval(request, allow: true, forProject: true) }
                                    }
                                    .accessibilityIdentifier("chat.gateway.approval.\(request.id).alwaysAllow")
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                        SettingsProposalCards(chatID: chatID)
                        Color.clear.frame(height: 1).id("chat.end")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 20).frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 60
                } action: { _, value in
                    bottomVisible = value
                    if scrolling { atBottom = value }
                }
                .onScrollPhaseChange { _, phase in
                    scrolling = phase != .idle && phase != .animating
                    if phase == .idle && bottomVisible { atBottom = true }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.transcript")
                .onChange(of: rows) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: chat.state?.pendingCards) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: gatewayApprovals.map(\.id)) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: model.settingsProposals.filter { $0.source.chatID == chatID }.map(\.id)) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: chatID) { atBottom = true; proxy.scrollTo("chat.end", anchor: .bottom) }
            }
            VStack(spacing: 6) {
                if chat.chatID == nil, model.workspaceProjects.allSatisfy({ !$0.isVisible }) {
                    Text("Choose a project to send a message.").font(.caption).foregroundStyle(composerMessageColor)
                }
                if chat.sideQuestionVisible {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Side question").font(.caption.weight(.semibold))
                            if chat.sideQuestionBusy { ProgressView().controlSize(.mini) }
                            Spacer()
                            Button { chat.dismissSideQuestion() } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss side question")
                                .accessibilityIdentifier("chat.sideQuestion.dismiss")
                        }
                        if let answer = chat.sideQuestionAnswer {
                            ScrollView { ChatMarkdown(text: answer).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 180).accessibilityIdentifier("chat.sideQuestion.answer")
                        }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 760).padding(.horizontal, 16)
                        .accessibilityIdentifier("chat.sideQuestion.panel")
                }
                AgentChatComposer(chat: chat, chatID: chatID, canSend: canSend, gitProject: gitProject,
                                  focusRequest: $composerFocusRequest,
                                  heightLimit: max(38, transcriptHeight - (compact ? 100 : 168)), compact: compact)
                if composerMessage != nil || !canSend {
                    HStack(spacing: 8) {
                        if let error = composerMessage {
                            Text(error).font(.caption).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if chat.signingIn != nil {
                                ProgressView().controlSize(.mini)
                                Button("Cancel") { chat.cancelSignIn() }
                                    .accessibilityIdentifier("chat.signin.cancel")
                            } else if let provider = chat.composerAuthProvider {
                                Button { chat.signIn(provider) } label: {
                                    Text("Sign in")
                                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(colorScheme == .dark ? Color.white : Color.black,
                                                    in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("chat.signin")
                            }
                        } else if !canSend {
                            Image(systemName: "archivebox")
                                .accessibilityLabel("Archived")
                                .accessibilityIdentifier("chat.archived.status")
                            Spacer(minLength: 0)
                            Button("Restore") { model.setWorkspaceChatArchived(chatID, archived: false) }
                                .accessibilityIdentifier("chat.restore")
                        }
                    }
                    .foregroundStyle(composerMessageColor)
                    .controlSize(.small).frame(minHeight: 28)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chat.error")
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { transcriptHeight = $0 }
        .task(id: chatID) { await chat.refreshStatus() }
        .task(id: "\(chatID).\(chat.choice.id).\(chat.signingIn == nil)") { await chat.loadModels() }
    }
    private func transcriptRow(_ entry: AgentTranscriptEntry, streaming: Bool,
                               commandFeatured: Bool = false, commandAwaitingApproval: Bool = false) -> some View {
        let fork: (() -> Void)?
        if entry.provider == .claude, entry.kind == "assistant" { fork = { _ = Task { await chat.fork(entry) } } }
        else { fork = nil }
        let edit: (() -> Void)?
        if entry.provider == .claude, entry.kind == "user", entry.sessionID != nil,
           !chat.isBusy, !chat.gitBusy, !chat.conversationBusy {
            let previous = chat.displayEntries.prefix { $0.id != entry.id }.last { $0.kind == "assistant" }
            let editable = previous.map {
                $0.provider == .claude && $0.sessionID == entry.sessionID
                    && $0.nativeMessageID.flatMap(UUID.init(uuidString:)) != nil
            } ?? true
            edit = editable ? { editingMessage = entry } : nil
        } else { edit = nil }
        return AgentTranscriptView(entry: entry, streaming: streaming, commandFeatured: commandFeatured,
            commandAwaitingApproval: commandAwaitingApproval, quote: { chat.replyWithQuote(entry, selection: $0); composerFocusRequest = UUID() },
            fork: fork, forkEnabled: !chat.isBusy && !chat.gitBusy && !chat.conversationBusy && entry.sessionID != nil && entry.nativeMessageID.flatMap(UUID.init(uuidString:)) != nil,
            edit: edit, recovery: { action in chat.recover(entry, action: action) },
            recoveryEnabled: !chat.isBusy && !chat.conversationBusy && chat.signingIn == nil && canSend
                && chat.state?.canRecover(entry) == true,
            recoveryError: chat.recoveryErrors[entry.id], autoContinue: chat.autoContinueRow(entry),
            autoContinueChange: { chat.setAutoContinue(entry, option: $0) },
            autoContinueUpdating: chat.isUpdatingAutoContinue(entry))
    }

    private var composerMessageColor: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12)
    }
    private var composerMessage: String? {
        let stop = chat.state?.currentStoppedTurn
        let deliveredStop = stop?.choice == chat.choice && stop?.delivery != .prepared
        if let provider = chat.selectedSignInProvider, !deliveredStop { return "Sign in to \(provider.rawValue.capitalized)" }
        return chat.error ?? workspaceError ?? outcomeError ?? chat.state?.mcpSetup?.notice
    }
    private var outcomeError: String? {
        if chat.state?.showsComposerFailure == true, case .failed(let failure) = chat.state?.outcome {
            return AgentFailure.sendMessage(for: failure, provider: chat.state?.entries.last?.provider ?? chat.provider)
        }
        return nil
    }
    @ViewBuilder private func requestCard(_ request: AgentRequest, index: Int) -> some View {
        switch request.kind {
        case .questions:
            AgentQuestionCard(request: request, index: index) { [owner = chatID] response in
                await chat.respond(chatID: owner, to: request, with: response)
            }
        case .plan:
            AgentPlanCard(request: request, identifier: "chat.request.\(index)") { [owner = chatID] response in
                await chat.respond(chatID: owner, to: request, with: response)
            }
        default:
            AgentApprovalCard(request: request, identifier: "chat.request.\(index)", grantAvailable: chat.canAlwaysAllow(chatID: chatID, request: request), alwaysAllow: { [owner = chatID] in
                await chat.alwaysAllow(chatID: owner, request: request)
            }) { [owner = chatID] response in
                await chat.respond(chatID: owner, to: request, with: response)
            }
        }
    }
    private func planCardShows(_ entry: AgentTranscriptEntry) -> Bool {
        (chat.state?.pendingCards ?? []).contains { request in
            if case .plan = request.kind {
                return entry.nativeMessageID != nil && entry.nativeMessageID == request.scope.itemID
                    && entry.provider == request.scope.session?.provider
            }
            return false
        }
    }

}

/// The overview has a bounded preview. Only an explicit expansion lays out the timeline.
private struct AgentActivityPanel<Row: View>: View {
    let entries: [AgentTranscriptEntry]
    let isLive: Bool
    let isLatest: Bool
    @ViewBuilder var row: (AgentTranscriptEntry, Bool) -> Row
    @State private var showTimeline = false

    var body: some View {
        let tools = entries.filter { $0.kind == "tool" }
        let runningCommand = tools.last { $0.commandTranscript?.status == .running }
        let lastCommand = tools.last { $0.commandTranscript != nil }
        let failedCommand = lastCommand?.commandTranscript?.status == .failed ? lastCommand : nil
        let previewTool = runningCommand ?? failedCommand ?? tools.last
        let commandOutcomes = tools.compactMap(\.commandOutcome)
        let failedCommands = commandOutcomes.count(where: { $0 == .failed })
        let successfulCommands = commandOutcomes.count - failedCommands
        VStack(alignment: .leading, spacing: 6) {
            AgentActivityDisclosure(expanded: $showTimeline) {
                HStack(spacing: 6) {
                    if isLive && isLatest { AgentWorkingLabel() }
                    else { Label("Activity", systemImage: "text.bubble") }
                    Spacer(minLength: 6)
                    if successfulCommands > 0 {
                        Label(successfulCommands == 1 ? "1 command succeeded" : "\(successfulCommands) commands succeeded",
                              systemImage: "checkmark.circle")
                    }
                    if failedCommands > 0 {
                        Label(failedCommands == 1 ? "1 command failed" : "\(failedCommands) commands failed",
                              systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                    if !tools.isEmpty {
                        Text(tools.count == 1 ? "1 tool call" : "\(tools.count) tool calls")
                    }
                }
            }
            .accessibilityIdentifier("chat.activity.timeline")

            if showTimeline {
                ForEach(AgentActivityStep.group(entries)) { step in
                    AgentActivityStepView(step: step) { entry in
                        row(entry, isLatest && entry.id == previewTool?.id)
                    }
                }
            } else {
                if isLive, let update = entries.last(where: { $0.kind == "assistant" || $0.kind == "thinking" }) {
                    Text(verbatim: AgentActivityStep.preview(update.text))
                        .font(.callout)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let tool = previewTool { row(tool, isLatest).id(tool.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.teal.opacity(0.24))
                .allowsHitTesting(false)
        }
    }
}

private struct AgentActivityStepView<Row: View>: View {
    let step: AgentActivityStep
    @ViewBuilder var row: (AgentTranscriptEntry) -> Row
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if step.isToolActivity {
                details
            } else {
                AgentActivityDisclosure(expanded: $showDetails) {
                    Text("Model updates")
                }
                if showDetails {
                    details
                } else {
                    Text(verbatim: step.updatePreview)
                        .font(.callout)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 12)
    }

    private var details: some View {
        ForEach(step.entries) { entry in row(entry) }
    }
}

struct AgentActivityDisclosure<Label: View>: View {
    @Binding var expanded: Bool
    @ViewBuilder var label: Label

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
                label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

private struct AgentWorkingLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).accessibilityHidden(true)
            Text("Working…")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

struct ChatGauge: View {
    @Environment(\.colorScheme) private var colorScheme
    let value: Double
    let title: String
    let identifier: String
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.3), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, value)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text("\(Int(min(1, max(0, value)) * 100))")
                .font(.system(size: 8, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12))
        }.frame(width: 22, height: 22)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .help("\(title): \(Int(min(1, max(0, value)) * 100))%")
            .accessibilityLabel(title).accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
            .accessibilityIdentifier(identifier)
    }
}

struct AgentProviderSettingsView: View {
    @Bindable var chat: ChatModel
    @AppStorage(ChatPresentation.preferenceKey, store: AitvarasPreferences.current) private var formattingGuidance = true
    @State private var addingProfile = false
    @State private var editingProfile: AgentProviderProfile?
    @State private var newProfileName = ""
    var body: some View {
        Form {
            if let error = chat.profileError { Text(error).foregroundStyle(.orange) }
            Section("Chat replies") {
                Toggle("Suggest concise formatting and visuals to models", isOn: $formattingGuidance)
            }
            Section("Claude profiles") {
                ForEach(chat.claudeProfiles) { profile in
                    HStack(spacing: 10) {
                        Text(profile.badge).font(.caption.bold()).frame(width: 28, height: 28)
                            .background(profileColour(profile).opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(chat.statusLabel(profile.choice)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let value = chat.profileLimits[profile.choice]?.compactMap(\.utilization).filter(\.isFinite).max() {
                            ChatGauge(value: value, title: "Usage", identifier: "chat.settings.gauge.\(profile.choice.id)")
                        }
                        if chat.signingInChoice == profile.choice {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { chat.cancelSignIn() }
                        } else if chat.profileStatuses[profile.choice]?.authentication == .signedOut {
                            Button("Sign in") { chat.signIn(profile.choice) }.disabled(chat.signingIn != nil)
                        }
                        Menu {
                            Button("Edit…") { editingProfile = profile }
                            Button("Move up") { chat.moveClaudeProfile(profile, by: -1) }
                                .disabled(chat.claudeProfiles.first?.id == profile.id)
                            Button("Move down") { chat.moveClaudeProfile(profile, by: 1) }
                                .disabled(chat.claudeProfiles.last?.id == profile.id)
                            if profile.id != AgentProviderProfile.defaultClaudeID {
                                Button("Delete profile", role: .destructive) { chat.deleteClaudeProfile(profile) }
                                    .disabled(chat.isBusy || chat.signingIn != nil)
                            }
                        } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden)
                    }.accessibilityElement(children: .contain)
                        .accessibilityIdentifier("chat.settings.\(profile.choice.id)")
                }
                Button("Add Claude profile…", systemImage: "plus") { newProfileName = ""; addingProfile = true }
                Text("Profiles share local skills, plugins and settings. User MCP servers stay separate; use Aitvaras global MCP servers to share them.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Deleting a profile keeps chats and CLI data. Its chats use default Claude on their next send.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach([AgentProvider.codex, .local], id: \.self) { provider in
                HStack(spacing: 12) {
                    Image(systemName: statusIcon(provider)).foregroundStyle(statusColor(provider))
                        .accessibilityLabel(statusLabel(provider))
                        .accessibilityIdentifier("chat.settings.status.\(provider.rawValue)")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.rawValue.capitalized)
                        if provider == .local { Text(chat.localProviderDetail).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let value = chat.providerLimits[provider]?.compactMap(\.utilization).filter(\.isFinite).max() {
                        ChatGauge(value: value, title: "Usage", identifier: "chat.settings.gauge.\(provider.rawValue)")
                    }
                    if chat.signingIn == provider {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { chat.cancelSignIn() }
                    } else if provider != .local, chat.statuses[provider]?.authentication == .signedOut {
                        Button("Sign in") { chat.signIn(provider) }
                            .disabled(chat.signingIn != nil)
                            .accessibilityIdentifier("chat.signin")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat.settings.\(provider.rawValue)")
            }
        }
        .formStyle(.grouped).task { await chat.refreshStatus() }
        .alert("Add Claude profile", isPresented: $addingProfile) {
            TextField("Name", text: $newProfileName)
            Button("Add") { chat.addClaudeProfile(name: newProfileName) }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sign in with the CLI after adding the profile. New profiles use Opus (newest) and Medium effort.") }
        .sheet(item: $editingProfile) { profile in
            ClaudeProfileEditor(profile: profile) { chat.updateClaudeProfile($0) }
        }
    }
    private func profileColour(_ profile: AgentProviderProfile) -> Color {
        switch profile.colour { case "blue": .blue; case "green": .green; case "purple": .purple; case "red": .red; default: .orange }
    }
    private func statusIcon(_ provider: AgentProvider) -> String {
        guard let status = chat.statuses[provider] else { return "circle.dotted" }
        return status.installed && (status.authentication == .subscription || status.authentication == .local)
            ? "checkmark.circle.fill" : "exclamationmark.circle"
    }
    private func statusColor(_ provider: AgentProvider) -> Color {
        guard let status = chat.statuses[provider] else { return .secondary }
        return status.installed && (status.authentication == .subscription || status.authentication == .local) ? .green : .orange
    }
    private func statusLabel(_ provider: AgentProvider) -> String {
        guard let status = chat.statuses[provider] else { return "Unknown" }
        if !status.installed { return "Not installed" }
        if status.authentication == .unavailable { return "Unavailable" }
        return status.authentication == .subscription || status.authentication == .local ? "Ready" : "Signed out"
    }
}

private struct AgentChatComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var chat: ChatModel
    let chatID: UUID
    let canSend: Bool
    let gitProject: Bool
    @Binding var focusRequest: UUID?
    let heightLimit: CGFloat
    let compact: Bool
    @State private var choosingProject = false
    @State private var choosingAttachments = false
    @State private var attachmentTarget: (chatID: UUID, provider: AgentProvider)?
    @State private var completion: AgentComposerTrigger?
    @State private var completionAcceptance = 0
    @State private var showingCompletion = false
    @State private var contentHeight: CGFloat = 38
    @State private var manualHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?

    private let minimumHeight: CGFloat = 38
    private var automaticLimit: CGFloat { compact ? 94 : 136 }
    private var editorHeight: CGFloat {
        min(editorHeightLimit, max(minimumHeight, manualHeight ?? min(contentHeight, automaticLimit)))
    }
    private var editorHeightLimit: CGFloat {
        max(minimumHeight, heightLimit - (chat.messageQueue.messages.isEmpty ? 0 : 115))
    }

    var body: some View {
        VStack(spacing: 8) {
            resizeHandle
            AgentMessageQueueView(chat: chat)
            if chat.editingQueuedMessage {
                HStack {
                    Label("Editing queued message", systemImage: "pencil").font(.caption)
                        .foregroundStyle(composerMessageColor)
                    Spacer(minLength: 0)
                    Button("Cancel") { Task { await chat.finishQueuedEdit(save: false) } }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(composerMessageColor.opacity(0.78))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(composerMessageColor.opacity(0.07), in: Capsule())
                        .accessibilityIdentifier("chat.queue.cancelEdit")
                }
            }
            if !chat.composerSelection.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chat.composerSelection.attachments) { file in
                            HStack(spacing: 4) {
                                if file.kind == .image, let thumbnail = NSImage(data: file.data) {
                                    Image(nsImage: thumbnail).resizable().scaledToFit()
                                        .frame(width: 24, height: 18)
                                        .clipShape(.rect(cornerRadius: 3))
                                        .accessibilityHidden(true)
                                } else {
                                    Image(systemName: file.kind == .image ? "photo" : "doc")
                                }
                                Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
                                Button { chat.composerSelection.attachments.removeAll { $0.id == file.id } } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(file.name)")
                                .accessibilityIdentifier("chat.attachment.remove.\(file.id)")
                            }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                            .accessibilityIdentifier("chat.attachment.\(file.id)")
                        }
                    }
                }.scrollIndicators(.hidden).accessibilityIdentifier("chat.attachments")
            }
            composerEditor.frame(height: editorHeight)
            ViewThatFits(in: .horizontal) {
                composerBar(iconOnly: false)
                composerBar(iconOnly: true)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil, perform: receiveAttachments)
        .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            defer { attachmentTarget = nil }
            guard case .success(let urls) = result, let target = attachmentTarget else { return }
            Task { for url in urls { await chat.attach(url, chatID: target.chatID, provider: target.provider) } }
        }
        .onChange(of: chatID) { showingCompletion = false; completion = nil }
        .onChange(of: chat.choice) { showingCompletion = false; completion = nil }
        .task(id: chat.composerInsertionRevision) { focusRequest = UUID() }
        .onChange(of: showingCompletion) { if !showingCompletion { focusRequest = UUID() } }
    }

    private var resizeHandle: some View {
        Capsule().fill(.secondary.opacity(0.45))
            .frame(width: 30, height: 3)
            .frame(maxWidth: .infinity).frame(height: 13)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartHeight ?? editorHeight
                    dragStartHeight = start
                    manualHeight = min(editorHeightLimit, max(minimumHeight, start - value.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil })
            .onTapGesture(count: 2) { manualHeight = nil }
            .help("Drag to resize. Double-click to reset to automatic height.")
            .accessibilityElement()
            .accessibilityIdentifier("chat.composer.resize")
            .accessibilityLabel("Composer height")
            .accessibilityValue("\(Int(editorHeight)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: manualHeight = min(editorHeightLimit, editorHeight + 24)
                case .decrement: manualHeight = max(minimumHeight, editorHeight - 24)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Reset automatic height") { manualHeight = nil }
    }

    private var composerEditor: some View {
        let hint = chat.composerSelection.command?.argumentPlaceholder(in: chat.draft)
        return ComposerMarkdownEditor(text: chat.draft, enabled: canSend, focusRequest: focusRequest, hint: hint,
            change: { chat.editDraft($0) }, measure: { contentHeight = $0 },
            onReturn: handleReturn, onPaste: pasteAttachments)
            .onChange(of: chat.draft) {
                completion = chat.provider == .local ? nil : AgentComposerTrigger.detect(chat.draft)
                showingCompletion = completion != nil
            }
            .popover(isPresented: $showingCompletion, arrowEdge: .top) {
                if let completion {
                    AgentComposerCompletionView(chat: chat, trigger: completion,
                        dismiss: { showingCompletion = false }, acceptanceRequest: completionAcceptance)
                }
            }
    }

    private func handleReturn(_ modifiers: NSEvent.ModifierFlags, hasMarkdownEdit: Bool) -> Bool {
        let send = modifiers.contains(.command)
        if !send {
            if modifiers.contains(.shift) || modifiers.contains(.option) { return false }
            if showingCompletion { completionAcceptance += 1; return true }
            if hasMarkdownEdit { return false }
        }
        if chat.canSubmit && canSend && chat.hasInput { Task { await chat.send(immediately: send) } }
        return true
    }

    private func pasteAttachments(_ pasteboard: NSPasteboard) -> Bool {
        guard canSend, chat.provider != .local else { return false }
        let images = ComposerClipboardImage.read(from: pasteboard)
        if !images.isEmpty {
            prepareImages(images)
            return true
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let owner = chat.composerOwnerID
        let provider = chat.provider
        Task { for url in urls.prefix(AgentAttachment.maximumCount) { await chat.attach(url, chatID: owner, provider: provider) } }
        return true
    }

    private func composerBar(iconOnly: Bool) -> some View {
        HStack(spacing: iconOnly ? 4 : 8) {
            attachButton(narrow: iconOnly)
            if chat.chatID == nil { projectControl(iconOnly: iconOnly) }
            AgentComposerPicker(chat: chat, iconOnly: iconOnly).disabled(chat.editingQueuedMessage)
            AgentComposerPermissionsControl(chat: chat, iconOnly: iconOnly)
            Spacer(minLength: 4)
            composerActions(narrow: iconOnly)
        }
        .controlSize(.small)
    }

    private func composerActions(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 2 : 8) {
            gaugeSlot(contextValue, title: "Context", identifier: "chat.gauge.context", narrow: narrow)
            if let windows = chat.profileLimits[chat.choice], !windows.isEmpty {
                ComposerUsageLimits(windows: windows, narrow: narrow)
            }
            if chat.state?.isRunning == true {
                Button { Task { await chat.stop() } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .frame(width: narrow ? 24 : 30, height: narrow ? 24 : 30)
                        .background(colorScheme == .dark ? Color.white : Color.black, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop").accessibilityIdentifier("chat.stop")
            }
            if chat.state?.isRunning != true || chat.hasInput {
                Button { Task { await chat.send() } } label: {
                    Image(systemName: chat.editingQueuedMessage ? "checkmark" : chat.willQueueMessage ? "tray.and.arrow.down" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(sendEnabled ? Color.white : Color.secondary)
                        .frame(width: narrow ? 24 : 30, height: narrow ? 24 : 30)
                        .background(sendEnabled ? Color.accentColor : Color.secondary.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!sendEnabled)
                .help(chat.editingQueuedMessage ? "Save queued edit" : chat.willQueueMessage ? "Queue message (Command–Return to send now)" : "Send")
                .accessibilityLabel(chat.editingQueuedMessage ? "Save queued edit" : chat.willQueueMessage ? "Queue message" : "Send")
                .accessibilityIdentifier("chat.composer.send")
            }
        }.fixedSize()
    }

    private func projectControl(iconOnly: Bool) -> some View {
        Button { choosingProject.toggle() } label: {
            ComposerControlLabel(
                title: projectTitle,
                icon: chat.useWorktree ? "arrow.triangle.branch" : "folder",
                iconOnly: iconOnly,
                maximumTitleWidth: 135
            )
        }
        .buttonStyle(.plain)
        .disabled(chat.creatingChat)
        .help(chat.useWorktree ? "\(projectTitle) · new worktree" : projectTitle)
        .accessibilityLabel("Project")
        .accessibilityValue(chat.useWorktree ? "\(projectTitle), new worktree" : projectTitle)
        .accessibilityIdentifier("chat.project")
        .popover(isPresented: $choosingProject, arrowEdge: .top) { projectPicker }
        .onChange(of: chat.composerOwnerID) { choosingProject = false }
    }

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project").font(.headline)
            let projects = model.workspaceProjects.filter(\.isVisible)
            if !projects.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(projects) { project in
                            ComposerPickerRow(title: project.title, selected: chat.newProjectID == project.id,
                                              icon: "folder") {
                                chat.newProjectID = project.id
                                choosingProject = false
                            }
                            .accessibilityIdentifier("chat.project.choose.\(project.id)")
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if gitProject {
                Toggle("Use a worktree", systemImage: "arrow.triangle.branch", isOn: $chat.useWorktree)
                    .toggleStyle(.checkbox)
                    .help("Create a separate checkout for this chat when you send the first message.")
                    .accessibilityIdentifier("chat.new.worktree")
            }
            Divider()
            Button("Add project…", systemImage: "plus") {
                choosingProject = false
                model.chooseChatProjectFolder()
            }.buttonStyle(.link)
            if let projectID = chat.newProjectID {
                Button("Project Settings", systemImage: "gearshape") {
                    choosingProject = false
                    SettingsNavigation.open(.project(projectID, section: .general))
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("chat.project.settings")
            }
        }
        .controlSize(.regular)
        .padding(14)
        .frame(width: 275)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.project.options")
    }

    private var sendEnabled: Bool { canSend && chat.canSubmit }
    private var contextValue: Double? {
        chat.currentContextFraction
    }
    private func gaugeSlot(_ value: Double?, title: String, identifier: String, narrow: Bool) -> some View {
        Group {
            if let value { ChatGauge(value: value, title: title, identifier: identifier) }
            else { Color.clear.accessibilityHidden(true) }
        }.frame(width: narrow ? 22 : 26, height: 26)
    }
    private func attachButton(narrow: Bool) -> some View {
        Button {
            attachmentTarget = (chat.composerOwnerID, chat.provider)
            showingCompletion = false; choosingAttachments = true
        } label: {
            Image(systemName: "paperclip").font(.system(size: 15, weight: .medium))
                .foregroundStyle(composerMessageColor)
                .frame(width: narrow ? 18 : 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!canSend || chat.provider == .local)
        .help("Attach files").accessibilityLabel("Attach files")
        .accessibilityIdentifier("chat.composer.attach")
    }
    private var projectTitle: String {
        model.workspaceProjects.first { $0.id == chat.newProjectID }?.title ?? "Choose project"
    }
    private func receiveAttachments(_ providers: [NSItemProvider]) -> Bool {
        guard canSend, chat.provider != .local else { return false }
        let owner = chat.composerOwnerID
        let provider = chat.provider
        for item in providers {
            if item.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = item.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                        Task { @MainActor in chat.attachmentLoadFailed(chatID: owner, provider: provider) }; return
                    }
                    Task { @MainActor in await chat.attach(url, chatID: owner, provider: provider) }
                }
            } else if let type = ComposerClipboardImage.types.first(where: { item.hasItemConformingToTypeIdentifier($0.identifier) })
                ?? (item.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? .image : nil) {
                _ = item.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else {
                        Task { @MainActor in chat.attachmentLoadFailed(chatID: owner, provider: provider) }; return
                    }
                    Task { @MainActor in
                        await chat.attachImage(data, chatID: owner, provider: provider)
                    }
                }
            }
        }
        return true
    }
    private func prepareImages(_ images: [Data]) {
        let owner = chat.composerOwnerID
        let provider = chat.provider
        Task {
            for data in images { await chat.attachImage(data, chatID: owner, provider: provider) }
        }
    }
    private var composerMessageColor: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12)
    }
}

private struct AgentComposerPermissionsControl: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var chat: ChatModel
    let iconOnly: Bool

    @State private var isPresented = false
    @State private var showsIntegrationHelp = false

    private var selection: AgentChatPermissions { chat.permissions }
    private var isFullAccessVisible: Bool {
        selection == .fullAccess || chat.activePermissions == .fullAccess
    }
    private var selectionTitle: String {
        chat.permissionsApplyNextTurn ? "\(title(selection)) from next turn" : title(selection)
    }

    var body: some View {
        let ink = colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.15)
        Button {
            if !isPresented { showsIntegrationHelp = false }
            isPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                if isFullAccessVisible {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.orange)
                } else {
                    Image(systemName: symbol).foregroundStyle(ink.opacity(0.72))
                }
                if !iconOnly { Text(title(selection)).lineLimit(1) }
                if !iconOnly || chat.permissionsApplyNextTurn {
                    Image(systemName: chat.permissionsApplyNextTurn ? "clock" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.66))
                }
            }
            .font(.caption)
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(isFullAccessVisible ? Color.orange.opacity(0.22) : ink.opacity(0.05), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selectionTitle)
        .accessibilityLabel("Permissions")
        .accessibilityValue(selectionTitle)
        .accessibilityIdentifier("chat.mode")
        .disabled(chat.creatingChat)
        .popover(isPresented: $isPresented, arrowEdge: .top) { panel }
        .onChange(of: chat.composerOwnerID) { isPresented = false }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chat permissions").font(.headline)
            HStack(spacing: 6) {
                permissionOption("Auto", id: "preset.auto", selected: selection == .auto, icon: "bolt") {
                    chat.permissions = .auto
                }
                permissionOption("Full access", id: "preset.fullAccess", selected: selection == .fullAccess,
                                 icon: "exclamationmark.triangle.fill") {
                    chat.permissions = .fullAccess
                }
                permissionOption("Plan", id: "preset.plan", selected: selection.isPlan, icon: "list.bullet.clipboard") {
                    chat.permissions = .plan
                }
            }
            if isFullAccessVisible {
                Label("Full access permits commands outside the workspace sandbox. Project and safety rules can still require approval.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Commands").font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    permissionOption("Ask", id: "commands.ask", selected: !selection.isPlan && selection.commands == .ask) {
                        customize { $0.commands = .ask }
                    }
                    permissionOption("Auto (workspace)", id: "commands.auto", selected: !selection.isPlan && selection.commands == .auto) {
                        customize { $0.commands = .auto }
                    }
                    permissionOption("Unrestricted", id: "commands.unrestricted", selected: !selection.isPlan && selection.commands == .unrestricted) {
                        customize { $0.commands = .unrestricted }
                    }
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("Commands")
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("MCP tools").font(.subheadline.weight(.semibold))
                    Button { showsIntegrationHelp.toggle() } label: {
                        Image(systemName: showsIntegrationHelp ? "info.circle.fill" : "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("About MCP tool permissions")
                    .accessibilityLabel("About MCP tool permissions")
                    .accessibilityValue(showsIntegrationHelp ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("chat.permissions.mcp.help")
                }
                if showsIntegrationHelp {
                    Text("An MCP integration can give an agent tools from another app. Project and safety rules still apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    permissionOption("Ask", id: "mcp.ask", selected: !selection.isPlan && selection.mcp == .ask) {
                        customize { $0.mcp = .ask }
                    }
                    permissionOption("Auto", id: "mcp.auto", selected: !selection.isPlan && selection.mcp == .auto) {
                        customize { $0.mcp = .auto }
                    }
                    permissionOption("Unprompted", id: "mcp.unprompted", selected: !selection.isPlan && selection.mcp == .unprompted) {
                        customize { $0.mcp = .unprompted }
                    }
                }
            }.accessibilityElement(children: .contain).accessibilityLabel("MCP tools")
            Divider()
            providerDetails
        }
        .padding(16)
        .frame(width: 444)
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.permissions")
    }

    private func permissionOption(_ label: String, id: String, selected: Bool, icon: String? = nil,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(icon == "exclamationmark.triangle.fill" ? Color.orange : Color.primary)
                }
                Text(label)
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 29)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("chat.permissions.\(id)")
    }

    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(chat.title(chat.choice)).font(.subheadline.weight(.semibold))
            if chat.permissionsApplyNextTurn {
                Label(selectionTitle, systemImage: "clock").foregroundStyle(Color.accentColor)
                if let active = chat.activePermissions {
                    Text("Current turn uses \(title(active)).").foregroundStyle(.secondary)
                }
            }
            if let status = chat.profileStatuses[chat.choice], !status.capabilities.contains(.tools),
               status.installed, status.authentication == .local {
                Text("This Local setup runs without command or MCP tools.").foregroundStyle(.secondary)
            } else {
                Text(commandDetail).foregroundStyle(.secondary)
                Text(mcpDetail).foregroundStyle(.secondary)
            }
            if let status = chat.profileStatuses[chat.choice],
               !status.installed || [.signedOut, .unsupported, .unavailable].contains(status.authentication) {
                Text(chat.statusLabel(chat.choice)).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var commandDetail: String {
        if selection.isPlan { return "Commands stay read-only during planning." }
        if chat.choice.provider == .local {
            switch selection.commands {
            case .ask: return "Commands run in the workspace sandbox with approval."
            case .auto: return "Commands stay in the workspace sandbox. Recognized outside directories and critical actions require approval."
            case .unrestricted: return "Commands can run outside the workspace sandbox without approval. Network access stays on this Mac."
            }
        }
        if chat.choice.provider == .codex {
            switch selection.commands {
            case .ask: return "Codex applies its approval rules to command execution."
            case .auto: return "Commands stay in the workspace sandbox. Broader access and recognized critical actions require approval."
            case .unrestricted: return "Commands can run outside the workspace sandbox. Codex user and managed rules can still apply."
            }
        }
        switch selection.commands {
        case .ask: return "Command execution requires approval."
        case .auto: return "Commands stay in the workspace sandbox. Broader access and critical actions require approval."
        case .unrestricted: return "Commands can run outside the workspace sandbox without approval."
        }
    }

    private var mcpDetail: String {
        if selection.isPlan { return "Planning limits MCP tools to reads." }
        switch selection.mcp {
        case .ask: return "MCP calls require approval."
        case .auto: return "Asks for critical actions and tools with unclear effects."
        case .unprompted: return "Enabled tools can run without approval where project and safety rules allow."
        }
    }

    private func customize(_ change: (inout AgentChatPermissions) -> Void) {
        var updated = selection.isPlan ? .auto : selection
        change(&updated)
        chat.permissions = updated
    }

    private func title(_ permissions: AgentChatPermissions) -> String {
        if permissions.isPlan { return "Plan" }
        if permissions == .auto { return "Auto" }
        if permissions == .fullAccess { return "Full access" }
        if permissions == .ask { return "Ask" }
        return "Custom"
    }

    private var symbol: String {
        if selection.isPlan { return "list.bullet.clipboard" }
        if selection == .auto { return "bolt" }
        if selection == .ask { return "hand.raised" }
        return "slider.horizontal.3"
    }
}

private struct ClaudeProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AgentProviderProfile
    let save: (AgentProviderProfile) -> Void
    var body: some View {
        Form {
            TextField("Name", text: $profile.name)
            TextField("Badge", text: $profile.badge)
            Picker("Colour", selection: $profile.colour) {
                ForEach(["orange", "blue", "green", "purple", "red"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            TextField("Default model", text: $profile.defaultModel)
            Picker("Default effort", selection: $profile.defaultEffort) {
                ForEach(["low", "medium", "high", "max"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save(profile); dismiss() }
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.name.count > 80 || profile.badge.isEmpty || profile.badge.count > 4 || profile.defaultModel.isEmpty)
            }
        }.padding().frame(width: 400)
    }
}


private struct AgentWakeBadge: View {
    let manager: AgentSessionManager?
    let chatID: UUID
    @State private var wakes: [AgentPendingWake] = []
    @State private var error: String?

    var body: some View {
        Group {
            if !wakes.isEmpty {
                Menu {
                    ForEach(wakes) { wake in
                        let time = wake.fireAt?.formatted(date: .omitted, time: .shortened) ?? "Running"
                        if wake.transportID == nil, wake.claimedAt == nil {
                            Button("Cancel \(wake.kind.title) · \(time)") {
                                Task {
                                    do { try await manager?.cancelWake(id: wake.id); await refresh() }
                                    catch { self.error = "Could not cancel wake-up." }
                                }
                            }
                        } else {
                            Text("\(wake.kind.title) · \(time) · CLI-owned")
                        }
                    }
                    if let error { Text(error) }
                } label: {
                    Label(label, systemImage: "clock").monospacedDigit()
                }
                .help(wakes.map { wake in
                    "\(wake.kind.title) · \(wake.fireAt?.formatted() ?? "Running") · \(wake.transportID == nil ? "Aitvaras" : "CLI-owned")"
                }.joined(separator: "\n"))
                .accessibilityIdentifier("chat.wakes")
            }
        }
        .task(id: chatID) {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    private var label: String {
        guard let next = wakes.compactMap(\.fireAt).min() else { return "Wakes" }
        return "Wakes " + next.formatted(date: .omitted, time: .shortened)
    }
    private func refresh() async {
        do { wakes = try await manager?.pendingWakes(chatID: chatID) ?? [] }
        catch { self.error = "Could not read pending wake-ups." }
    }
}

private extension AgentWakeKind {
    var title: String {
        switch self {
        case .wakeup: "Wake-up"
        case .cron: "Scheduled check"
        case .backgroundTask: "Background task"
        case .monitor: "Monitor"
        }
    }
}
