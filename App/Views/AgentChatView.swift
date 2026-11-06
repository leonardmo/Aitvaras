import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AitvarasAgents
import AitvarasStore

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
    @State private var visibilityID = UUID()
    @State private var gitProject = false
    @State private var atBottom = true
    @State private var bottomVisible = true
    @State private var scrolling = false
    @State private var choosingAttachments = false
    @State private var attachmentTarget: (chatID: UUID, provider: AgentProvider)?
    @State private var completion: AgentComposerTrigger?
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
            if !compact {
                Button { showingChanges.toggle() } label: {
                    Label("\(chat.changes?.files.count ?? 0)", systemImage: "doc.text")
                        .labelStyle(.titleAndIcon).monospacedDigit()
                }
                .help(showingChanges ? "Hide changes" : "Show changes").accessibilityLabel("Changes")
                .accessibilityValue("\(chat.changes?.files.count ?? 0) changed files")
                .accessibilityIdentifier("chat.changes")
            }
        }
        .task(id: chatID) {
            showingChanges = false
            guard model.selectedWorkspaceChatID == chatID else { return }
            chat.select(chatID)
            await chat.refreshNativePreview()
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
            if phase == .active { Task { await chat.refreshNativePreview() } }
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.displayEntries) { entry in
                            if !planCardShows(entry) { AgentTranscriptView(entry: entry).id(entry.id) }
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
                            } else if let provider = chat.authProvider {
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
        .task(id: "\(chatID).\(chat.provider.rawValue).\(chat.signingIn == nil)") { await chat.loadModels() }
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
            TextField("Message", text: $chat.draft, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.plain)
                .focused($composerFocused)
                .disabled(!canSend)
                .accessibilityIdentifier("chat.composer.input")
                .onPasteCommand(of: [.fileURL, .png, .jpeg, .tiff]) { providers in _ = receiveAttachments(providers) }
                .onChange(of: chat.draft) {
                    completion = chat.provider == .local ? nil : AgentComposerTrigger.detect(chat.draft)
                    showingCompletion = completion != nil
                }
                .popover(isPresented: $showingCompletion, arrowEdge: .top) {
                    if let completion {
                        AgentComposerCompletionView(chat: chat, trigger: completion) { showingCompletion = false }
                    }
                }
                .onKeyPress(.return, phases: .down) { press in
                    if showingCompletion { return .handled }
                    if press.modifiers.contains(.shift) { return .ignored }
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
        .onChange(of: chatID) { showingCompletion = false; completion = nil }
        .onChange(of: chat.provider) { showingCompletion = false; completion = nil }
        .onChange(of: showingCompletion) { if !showingCompletion { composerFocused = true } }
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
                        if chat.newProjectID == project.id { Label(project.title, systemImage: "checkmark") }
                        else { Text(project.title) }
                    }
                }
                Divider()
                Button("Add project…") { model.chooseChatProjectFolder() }
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
            .disabled(chat.chatID != nil || chat.creatingChat)
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
    @ViewBuilder private func providerControl(compact: Bool, narrow: Bool) -> some View {
        if compact {
            Menu {
                ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
                    Button { chat.setProvider(provider) } label: {
                        if chat.provider == provider { Label(provider.rawValue.capitalized, systemImage: "checkmark") }
                        else { Text(provider.rawValue.capitalized) }
                    }.accessibilityIdentifier("chat.provider.\(provider.rawValue)")
                }
            } label: { Text(chat.provider.rawValue.capitalized).lineLimit(1) }
            .frame(width: narrow ? 62 : 76)
            .menuIndicator(.visible)
            .help(chat.provider.rawValue.capitalized)
            .accessibilityIdentifier("chat.provider")
            .accessibilityLabel("Provider").accessibilityValue(chat.provider.rawValue.capitalized)
            .disabled(chat.isBusy || chat.creatingChat)
            .controlSize(.small).menuStyle(.borderlessButton)
        } else {
            Picker("Provider", selection: Binding(get: { chat.provider }, set: { chat.setProvider($0) })) {
                ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
                    Text(provider.rawValue.capitalized).tag(provider)
                        .accessibilityIdentifier("chat.provider.\(provider.rawValue)")
                }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 154)
            .accessibilityIdentifier("chat.provider")
            .accessibilityValue(chat.provider.rawValue.capitalized)
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
    private var sendEnabled: Bool { canSend && chat.canSubmit && chat.hasInput }
    private var contextValue: Double? {
        guard chat.state?.entries.last?.provider == chat.provider else { return nil }
        return ChatSettings.contextFraction(chat.state?.usage)
    }
    private var usageValue: Double? {
        chat.providerLimits[chat.provider]?.compactMap(\.utilization).filter(\.isFinite).max()
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
    private var composerMessage: String? { chat.error ?? workspaceError ?? outcomeError }
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
            AgentApprovalCard(request: request, identifier: "chat.request.\(index)") { [owner = chatID] response in
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

/// Native text rendering, including readable fenced code and Markdown inline
/// styles. Stable block indices keep incremental text in place while streaming.
struct ChatMarkdown: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, block in
                if index.isMultiple(of: 2) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(block.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            markdownLine(line)
                        }
                    }
                } else {
                    let code = block.firstIndex(of: "\n").map { String(block[block.index(after: $0)...]) } ?? block
                    ScrollView(.horizontal) {
                        Text(code).font(.callout.monospaced()).textSelection(.enabled).padding(10)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    @ViewBuilder private func markdownLine(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title2.weight(.semibold))
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.title3.weight(.semibold))
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.headline)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•"); inline(String(line.dropFirst(2)))
            }.padding(.leading, 6)
        } else if line.hasPrefix("> ") {
            inline(String(line.dropFirst(2))).foregroundStyle(.secondary).padding(.leading, 12)
        } else {
            inline(line.isEmpty ? " " : line)
        }
    }
    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .textSelection(.enabled)
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
    var body: some View {
        Form {
            ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
                HStack(spacing: 12) {
                    Image(systemName: statusIcon(provider)).foregroundStyle(statusColor(provider))
                        .accessibilityLabel(statusLabel(provider))
                        .accessibilityIdentifier("chat.settings.status.\(provider.rawValue)")
                    Text(provider.rawValue.capitalized)
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
