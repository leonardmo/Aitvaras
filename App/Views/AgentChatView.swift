import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AitvarasAgents
import AitvarasStore

private struct AgentSetupDestination: Identifiable {
    let id: UUID
    let directory: URL?
}

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

    @State private var showingProfiles = false
    @State private var showingChanges = false
    @State private var editingMessage: AgentTranscriptEntry?
    @State private var agentSetupDestination: AgentSetupDestination?
    @State private var visibilityID = UUID()
    @State private var gitProject = false
    @State private var atBottom = true
    @State private var bottomVisible = true
    @State private var scrolling = false
    @State private var choosingAttachments = false
    @State private var attachmentTarget: (chatID: UUID, provider: AgentProvider)?
    @State private var completion: AgentComposerTrigger?
    @State private var completionAcceptance = 0
    @State private var composerTextSelection: TextSelection?
    @State private var showingCompletion = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        HSplitView {
            transcript.frame(minWidth: 300)
            if !compact, showingChanges, let changes = chat.changes {
                AgentChangesView(chat: chat, owner: chatID, changes: changes).id(chatID)
            }
        }
        .toolbar {
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
            Button { chat.prepareSideQuestion(); composerFocused = true } label: {
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
        .onAppear { chat.showChat(chat.chatID, surface: visibilityID); if compact { composerFocused = true } }
        .onDisappear { chat.showChat(nil, surface: visibilityID) }
        .onChange(of: chatID) { chat.showChat(chat.chatID, surface: visibilityID) }
        .task(id: chat.newProjectID) {
            gitProject = false
            guard chat.chatID == nil, let projectID = chat.newProjectID,
                  let folder = try? model.stores?.workspaceFolders(projectID: projectID).first else { return }
            gitProject = (try? await GitWorkspace().repository(at: URL(fileURLWithPath: folder.path))) != nil
        }
        .onChange(of: model.companionFocusRequest) {
            if compact { composerFocused = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chat.markChatOpened(chatID)
                Task { await chat.refreshNativePreview() }
            }
        }
        .sheet(item: $agentSetupDestination) { destination in
            WorkspaceBoundaryReviewView(projectID: destination.id, agentDirectory: destination.directory, initialTab: "agent")
                .environment(model)
        }
        .sheet(item: $editingMessage) { entry in
            AgentEditMessageSheet(text: entry.displayText) { text in
                let completed = await chat.fork(entry, editedText: text)
                if completed { editingMessage = nil }
                return completed
            }
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.displayEntries) { entry in
                            if !planCardShows(entry) {
                                transcriptRow(entry).id(entry.id)
                            }
                        }
                        ForEach(Array((chat.state?.pendingCards ?? []).enumerated()), id: \.element.identity) { index, request in
                            requestCard(request, index: index)
                        }
                        Color.clear.frame(height: 1).id("chat.end")
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 20).frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
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
                .onChange(of: chat.displayEntries) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: chat.state?.pendingCards) {
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
                composer
                if composerMessage != nil || !canSend || chat.state?.outcome == .interrupted {
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
                        } else if chat.state?.outcome == .interrupted {
                            Image(systemName: "pause.circle")
                                .help("Interrupted · Send to continue")
                                .accessibilityLabel("Interrupted. Send to continue.")
                                .accessibilityIdentifier("chat.interrupted")
                            Spacer(minLength: 0)
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
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12)) }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .task(id: chatID) { await chat.refreshStatus() }
        .sheet(isPresented: $showingProfiles) { AgentProviderSettingsView(chat: chat).frame(minWidth: 560, minHeight: 400) }
        .task(id: "\(chatID).\(chat.choice.id).\(chat.signingIn == nil)") { await chat.loadModels() }
    }
    private func transcriptRow(_ entry: AgentTranscriptEntry) -> some View {
        let fork: (() -> Void)?
        if entry.provider == .claude, entry.kind == "assistant" { fork = { _ = Task { await chat.fork(entry) } } }
        else { fork = nil }
        let edit: (() -> Void)?
        let previous = chat.displayEntries.prefix { $0.id != entry.id }.last { $0.kind == "assistant" }
        let editableAnchor = previous.map { $0.provider == .claude && $0.sessionID == entry.sessionID && $0.nativeMessageID.flatMap(UUID.init(uuidString:)) != nil } ?? true
        if entry.provider == .claude, entry.kind == "user", entry.sessionID != nil, editableAnchor,
           !chat.isBusy, !chat.gitBusy, !chat.conversationBusy { edit = { editingMessage = entry } }
        else { edit = nil }
        return AgentTranscriptView(entry: entry, quote: { chat.replyWithQuote(entry, selection: $0); composerFocused = true },
            fork: fork, forkEnabled: !chat.isBusy && !chat.gitBusy && !chat.conversationBusy && entry.sessionID != nil && entry.nativeMessageID.flatMap(UUID.init(uuidString:)) != nil,
            edit: edit)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !chat.composerSelection.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(chat.composerSelection.attachments) { file in
                            HStack(spacing: 4) {
                                Image(systemName: file.kind == .image ? "photo" : "doc")
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
            TextField("Message", text: Binding(get: { chat.draft }, set: { chat.editDraft($0) }),
                      selection: $composerTextSelection, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.plain)
                .focused($composerFocused)
                .disabled(!canSend)
                .background(alignment: .topLeading) {
                    if let command = chat.composerSelection.command, let hint = command.argumentPlaceholder(in: chat.draft) {
                        HStack(spacing: 0) {
                            Text(command.insertion + " ").hidden()
                            Text(hint).foregroundStyle(.tertiary).lineLimit(1)
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("chat.composer.input")
                .accessibilityHint(chat.composerSelection.command?.argumentPlaceholder(in: chat.draft) ?? "")
                .onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff]) { providers in _ = receiveAttachments(providers) }
                .onChange(of: chat.draft) {
                    completion = chat.provider == .local ? nil : AgentComposerTrigger.detect(chat.draft)
                    showingCompletion = completion != nil
                }
                .popover(isPresented: $showingCompletion, arrowEdge: .top) {
                    if let completion {
                        AgentComposerCompletionView(chat: chat, trigger: completion, dismiss: { showingCompletion = false }, acceptanceRequest: completionAcceptance)
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    // Let the input method commit its marked text first. This
                    // must precede completion acceptance as well as sending.
                    if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        insertComposerNewline()
                        return .handled
                    }
                    if showingCompletion { completionAcceptance += 1; return .handled }
                    if chat.canSubmit && canSend && chat.hasInput { Task { await chat.send() } }
                    return .handled
                }
            ViewThatFits(in: .horizontal) {
                composerBar(compactProvider: false, compactProject: false, compactDetails: false)
                composerBar(compactProvider: true, compactProject: false, compactDetails: false)
                composerBar(compactProvider: true, compactProject: true, compactDetails: false)
                composerBar(compactProvider: true, compactProject: true, compactDetails: true)
            }
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff], isTargeted: nil, perform: receiveAttachments)
        .fileImporter(isPresented: $choosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            defer { attachmentTarget = nil }
            guard case .success(let urls) = result, let target = attachmentTarget else { return }
            Task { for url in urls { await chat.attach(url, chatID: target.chatID, provider: target.provider) } }
        }
        .onChange(of: chatID) { showingCompletion = false; completion = nil; placeComposerCaret() }
        .onChange(of: chat.choice) { showingCompletion = false; completion = nil; placeComposerCaret() }
        .task(id: chat.composerInsertionRevision) { await focusComposerAfterInsertion() }
        .onChange(of: showingCompletion) {
            if !showingCompletion {
                Task { await focusComposerAfterInsertion() }
            }
        }
    }
    private func insertComposerNewline() {
        let selected: NSRange?
        if let selection = composerTextSelection, case .selection(let range) = selection.indices {
            selected = NSRange(range, in: chat.draft)
        } else { selected = nil }
        let edit = AgentComposerCaret.insertingNewline(in: chat.draft, selection: selected)
        chat.editDraft(edit.text)
        composerTextSelection = TextSelection(insertionPoint: String.Index(utf16Offset: edit.caret.location, in: edit.text))
    }
    @MainActor private func focusComposerAfterInsertion() async {
        let revision = chat.composerInsertionRevision
        let draft = chat.draft
        // Clear the old binding before focus: TextField can select the entire
        // externally replaced value when its field editor becomes first responder.
        composerTextSelection = nil
        composerFocused = true
        await Task.yield()
        guard !Task.isCancelled, !showingCompletion,
              revision == chat.composerInsertionRevision, draft == chat.draft else { return }
        placeComposerCaret()
    }
    private func placeComposerCaret() {
        let range = AgentComposerCaret.afterInsertion(chat.draft)
        composerTextSelection = TextSelection(insertionPoint: String.Index(utf16Offset: range.location, in: chat.draft))
    }
    private func composerBar(compactProvider: Bool, compactProject: Bool, compactDetails: Bool) -> some View {
        HStack(spacing: compactDetails ? 2 : 10) {
            HStack(spacing: compactDetails ? 2 : 6) {
                attachButton(narrow: compactDetails)
                projectControls(iconOnly: compactProject)
                providerControl(compact: compactProvider, narrow: compactDetails)
                modelControls(iconOnly: compactDetails)
            }.fixedSize(horizontal: !compactDetails, vertical: false)
            Spacer(minLength: 0)
            composerActions(narrow: compactDetails)
        }
        .controlSize(.small).menuStyle(.borderlessButton)
    }

    private func composerActions(narrow: Bool) -> some View {
        HStack(spacing: narrow ? 2 : 8) {
            gaugeSlot(contextValue, title: "Context", identifier: "chat.gauge.context", narrow: narrow)
            gaugeSlot(usageValue, title: "Usage", identifier: "chat.gauge.usage", narrow: narrow)
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
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(sendEnabled ? Color.white : Color.secondary)
                        .frame(width: narrow ? 24 : 30, height: narrow ? 24 : 30)
                        .background(sendEnabled ? Color.accentColor : Color.secondary.opacity(0.16), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!sendEnabled)
                .accessibilityLabel("Send").accessibilityIdentifier("chat.composer.send")
            }
        }.fixedSize()
    }

    private func projectControls(iconOnly: Bool) -> some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(model.workspaceProjects.filter(\.isVisible)) { project in
                    Button { chat.newProjectID = project.id } label: {
                        if chat.currentProjectID == project.id { Label(project.title, systemImage: "checkmark") }
                        else { Text(project.title) }
                    }
                    .disabled(chat.chatID != nil || chat.creatingChat)
                }
                Divider()
                Button("Add project…") { model.chooseChatProjectFolder() }
                    .disabled(chat.chatID != nil || chat.creatingChat)
                Button("Agent setup…") {
                    if let projectID = chat.currentProjectID { agentSetupDestination = .init(id: projectID, directory: chat.projectDirectory) }
                }
                    .disabled(chat.currentProjectID == nil)
                    .accessibilityIdentifier("chat.project.agentSetup")
                if iconOnly, chat.chatID == nil, gitProject {
                    Toggle("Use worktree", isOn: $chat.useWorktree)
                        .disabled(chat.creatingChat)
                        .accessibilityIdentifier("chat.new.worktree")
                }
            } label: {
                HStack(spacing: 4) {
                    if iconOnly { Image(systemName: chat.useWorktree ? "arrow.triangle.branch" : "folder") }
                    else {
                        if chat.useWorktree { Image(systemName: "arrow.triangle.branch") }
                        Text(projectTitle).lineLimit(1)
                    }
                }
            }
            .menuStyle(.borderlessButton).buttonStyle(.plain)
            .menuIndicator(.visible)
            .frame(width: iconOnly ? 32 : 100).help(projectTitle)
            .accessibilityLabel("Project").accessibilityValue(projectTitle)
            .accessibilityIdentifier("chat.project")
            if !iconOnly {
                Button { chat.useWorktree.toggle() } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 13, weight: .medium)).frame(width: 24, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.useWorktree ? Color.accentColor : Color.secondary)
                .background(chat.useWorktree ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .help("Use worktree").accessibilityLabel("Use worktree")
                .accessibilityValue(chat.useWorktree ? "On" : "Off")
                .accessibilityIdentifier("chat.new.worktree")
                .opacity(chat.chatID == nil && gitProject ? 1 : 0)
                .disabled(chat.chatID != nil || !gitProject || chat.creatingChat)
                .accessibilityHidden(chat.chatID != nil || !gitProject)
            }
        }.frame(width: iconOnly ? 32 : 127)
    }
    @ViewBuilder private var providerMenuEntries: some View {
        ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
            Section(provider.rawValue.capitalized) {
                ForEach(Array(chat.allChoices.enumerated()).filter { $0.element.provider == provider }, id: \.element.id) { index, entry in
                    if index < 9 {
                        profileMenuButton(entry)
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
                    } else { profileMenuButton(entry) }
                }
            }
        }
        Divider()
        Button("Edit profiles…") { showingProfiles = true }
    }
    private func profileMenuButton(_ entry: AgentProviderChoice) -> some View {
        Button { chat.setChoice(entry) } label: {
            Label("\(chat.title(entry)) · \(chat.statusLabel(entry))", systemImage: entry == chat.choice ? "checkmark" : "person.crop.circle")
        }.accessibilityIdentifier("chat.provider.\(entry.id)")
    }
    @ViewBuilder private func providerControl(compact: Bool, narrow: Bool) -> some View {
        if compact {
            Menu { providerMenuEntries } label: { Text(chat.title(chat.choice)).lineLimit(1) }
                .frame(width: narrow ? 62 : 76)
                .menuIndicator(.visible).help(chat.title(chat.choice))
                .accessibilityIdentifier("chat.provider")
                .accessibilityLabel("Provider profile").accessibilityValue(chat.title(chat.choice))
                .disabled(chat.isBusy || chat.creatingChat).controlSize(.small).menuStyle(.borderlessButton)
        } else {
            HStack(spacing: 1) {
                ForEach(chat.inlineChoices) { entry in
                    Button { chat.setChoice(entry) } label: {
                        Text(chat.title(entry)).font(.caption).lineLimit(1).frame(maxWidth: .infinity).frame(height: 22)
                            .background(entry == chat.choice ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain).help(chat.title(entry))
                        .accessibilityIdentifier("chat.provider.\(entry.id)")
                        .accessibilityAddTraits(entry == chat.choice ? .isSelected : [])
                }
                Menu { providerMenuEntries } label: { Text("More").font(.caption) }
                    .menuIndicator(.hidden).fixedSize()
            }.padding(2).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).frame(width: 190)
                .accessibilityIdentifier("chat.provider").accessibilityValue(chat.title(chat.choice))
                .disabled(chat.isBusy || chat.creatingChat)
        }
    }
    private func modelControls(iconOnly: Bool) -> some View {
        HStack(spacing: iconOnly ? 2 : 6) {
            Menu {
                Picker("Model", selection: $chat.model) {
                    ForEach(chat.models, id: \.id) { Text(chat.modelTitle($0)).tag($0.id) }
                }.pickerStyle(.inline)
            } label: {
                Text(chat.modelTitle).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: iconOnly ? 60 : 100, idealWidth: 100, maxWidth: 100)
            .menuIndicator(.visible)
            .help(chat.modelTitle)
            .accessibilityLabel("Model").accessibilityValue(chat.modelTitle)
            .accessibilityIdentifier("chat.model")
            .disabled(chat.isBusy || chat.creatingChat || chat.models.isEmpty)
            Group {
                if let model = chat.selectedModel, !model.efforts.isEmpty, chat.provider != .local {
                    Menu {
                        Picker("Effort", selection: $chat.effort) {
                            Text("Default").tag("")
                            ForEach(model.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                        }.pickerStyle(.inline)
                    } label: {
                        if iconOnly { Image(systemName: "brain") }
                        else { Text(chat.effort.isEmpty ? "Effort" : chat.effort.capitalized).lineLimit(1) }
                    }
                    .menuIndicator(.visible)
                    .frame(maxWidth: .infinity)
                    .help("Effort: \(chat.effort.isEmpty ? "Default" : chat.effort.capitalized)")
                    .accessibilityLabel("Effort").accessibilityValue(chat.effort.isEmpty ? "Default" : chat.effort.capitalized)
                    .accessibilityIdentifier("chat.effort").disabled(chat.isBusy || chat.creatingChat)
                } else { Color.clear.frame(height: 16).accessibilityHidden(true) }
            }.frame(width: iconOnly ? 32 : 54)
            Group {
                if chat.provider != .local || chat.statuses[.local]?.capabilities.contains(.approvals) == true {
                    Menu {
                        Picker("Mode", selection: $chat.mode) {
                            Text("Ask").tag(AgentMode.ask)
                            Text("Accept edits").tag(AgentMode.acceptEdits)
                            Text("Plan").tag(AgentMode.plan)
                            Text("Auto").tag(AgentMode.auto)
                        }.pickerStyle(.inline)
                    } label: {
                        if iconOnly { Image(systemName: modeSymbol) }
                        else { Text(modeTitle).lineLimit(1) }
                    }
                    .menuIndicator(.visible)
                    .frame(maxWidth: .infinity)
                    .help("Mode: \(modeTitle)")
                    .accessibilityLabel("Mode").accessibilityValue(modeTitle)
                    .accessibilityIdentifier("chat.mode").disabled(chat.isBusy || chat.creatingChat)
                } else { Color.clear.frame(height: 16).accessibilityHidden(true) }
            }.frame(width: iconOnly ? 32 : 64)
        }
        .controlSize(.small).menuStyle(.borderlessButton)
    }
    private var sendEnabled: Bool { canSend && chat.canSubmit }
    private var contextValue: Double? {
        chat.currentContextFraction
    }
    private var usageValue: Double? {
        chat.profileLimits[chat.choice]?.compactMap(\.utilization).filter(\.isFinite).max()
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
        let id = model.selectedWorkspaceChat?.projectID ?? chat.newProjectID
        return model.workspaceProjects.first { $0.id == id }?.title ?? "Choose project"
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
            } else if let type = [UTType.png, .jpeg, .tiff].first(where: { item.hasItemConformingToTypeIdentifier($0.identifier) }) {
                _ = item.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else {
                        Task { @MainActor in chat.attachmentLoadFailed(chatID: owner, provider: provider) }; return
                    }
                    Task { @MainActor in
                        if type == .tiff {
                            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                                chat.attachmentLoadFailed(chatID: owner, provider: provider); return
                            }
                            chat.attach(data: png, name: "Image.png", chatID: owner, provider: provider)
                        } else {
                            chat.attach(data: data, name: type == .png ? "Image.png" : "Image.jpg", chatID: owner, provider: provider)
                        }
                    }
                }
            }
        }
        return true
    }
    private var composerMessageColor: Color {
        colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.12)
    }
    private var composerMessage: String? {
        if let provider = chat.selectedSignInProvider { return "Sign in to \(provider.rawValue.capitalized)" }
        return chat.error ?? workspaceError ?? outcomeError ?? chat.state?.mcpSetup?.notice
    }
    private var outcomeError: String? {
        if case .failed(let failure) = chat.state?.outcome {
            return AgentFailure.sendMessage(for: failure, provider: chat.state?.entries.last?.provider ?? chat.provider)
        }
        return nil
    }
    private var modeTitle: String {
        switch chat.mode { case .ask: "Ask"; case .acceptEdits: "Accept edits"; case .plan: "Plan"; case .auto: "Auto" }
    }
    private var modeSymbol: String {
        switch chat.mode {
        case .ask: "hand.raised"
        case .acceptEdits: "pencil"
        case .plan: "list.bullet.clipboard"
        case .auto: "bolt"
        }
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
    @State private var addingProfile = false
    @State private var editingProfile: AgentProviderProfile?
    @State private var newProfileName = ""
    var body: some View {
        Form {
            if let error = chat.profileError { Text(error).foregroundStyle(.orange) }
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
