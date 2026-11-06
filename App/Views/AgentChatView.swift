import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AitvarasAgents

/// One transcript and composer, observing the application-owned chat manager.
struct AgentChatView: View {
    @Environment(AppModel.self) private var model
    @Bindable var chat: ChatModel
    let chatID: UUID
    var canSend = true
    var workspaceError: String? = nil

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
            transcript.frame(minWidth: 330)
            if let changes = chat.changes, changes.hasChanges {
                AgentChangesView(chat: chat, owner: chatID, changes: changes).id(chatID)
            }
        }
        .task(id: chatID) {
            chat.select(chatID)
            while !Task.isCancelled {
                await chat.refreshChanges()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.state?.entries ?? []) { entry in
                            if !planCardShows(entry) { AgentTranscriptView(entry: entry).id(entry.id) }
                        }
                        ForEach(Array((chat.state?.pendingCards ?? []).enumerated()), id: \.element.identity) { index, request in
                            requestCard(request, index: index)
                        }
                        Color.clear.frame(height: 1).id("chat.end")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(20).frame(maxWidth: .infinity)
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
                .accessibilityIdentifier("chat.transcript")
                .onChange(of: chat.state?.entries) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: chat.state?.pendingCards) {
                    if atBottom { proxy.scrollTo("chat.end", anchor: .bottom) }
                }
                .onChange(of: chatID) { atBottom = true; proxy.scrollTo("chat.end", anchor: .bottom) }
            }
            VStack(spacing: 6) {
                composer
                // Reserved height keeps the transcript steady when an error appears.
                HStack(spacing: 8) {
                    if let error = chat.error ?? workspaceError ?? outcomeError {
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                        if chat.signingIn != nil {
                            ProgressView().controlSize(.mini)
                            Button("Cancel") { chat.cancelSignIn() }
                                .accessibilityIdentifier("chat.signin.cancel")
                        } else if let provider = chat.authProvider {
                            Button("Sign in") { chat.signIn(provider) }
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
                .controlSize(.small).frame(height: 24)
                .accessibilityIdentifier("chat.error")
            }
            .frame(maxWidth: 760).padding(.horizontal, 16).padding(.top, 8)
        }
        .task(id: chatID) { chat.select(chatID) }
        .task { await chat.refreshStatus() }
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
                    if chat.canSubmit && canSend { Task { await chat.send() } }
                    return .handled
                }
            HStack(spacing: 5) {
                Picker("Provider", selection: Binding(get: { chat.provider }, set: { chat.setProvider($0) })) {
                    ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
                        Text(provider.rawValue.capitalized).tag(provider)
                            .accessibilityIdentifier("chat.provider.\(provider.rawValue)")
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 154)
                .accessibilityIdentifier("chat.provider")
                .disabled(chat.isBusy)
                if !chat.models.isEmpty {
                    Menu {
                        Picker("Model", selection: $chat.model) {
                            ForEach(chat.models, id: \.id) { Text($0.name).tag($0.id) }
                        }.pickerStyle(.inline)
                    } label: {
                        Text(chat.selectedModel?.name ?? "Model").lineLimit(1)
                    }
                    .frame(minWidth: 36, maxWidth: 100)
                    .accessibilityIdentifier("chat.model")
                    .disabled(chat.isBusy)
                }
                if let model = chat.selectedModel, !model.efforts.isEmpty, chat.provider != .local {
                    Menu {
                        Picker("Effort", selection: $chat.effort) {
                            Text("Default").tag("")
                            ForEach(model.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                        }.pickerStyle(.inline)
                    } label: { Text(chat.effort.isEmpty ? "Effort" : chat.effort.capitalized).lineLimit(1) }
                    .frame(minWidth: 32, maxWidth: 60)
                    .accessibilityIdentifier("chat.effort").disabled(chat.isBusy)
                }
            }
            .controlSize(.small).menuStyle(.borderlessButton)
            HStack(spacing: 5) {
                Button {
                    guard let owner = chat.chatID else { return }
                    attachmentTarget = (owner, chat.provider)
                    showingCompletion = false; choosingAttachments = true
                } label: { Image(systemName: "paperclip") }
                    .disabled(!canSend || chat.provider == .local)
                    .help("Attach files").accessibilityLabel("Attach files")
                    .accessibilityIdentifier("chat.composer.attach")
                if chat.provider != .local {
                    Menu {
                        Picker("Mode", selection: $chat.mode) {
                            Text("Ask").tag(AgentMode.ask)
                            Text("Accept edits").tag(AgentMode.acceptEdits)
                            Text("Plan").tag(AgentMode.plan)
                            Text("Auto").tag(AgentMode.auto)
                        }.pickerStyle(.inline)
                    } label: { Text(modeTitle).lineLimit(1) }
                    .frame(minWidth: 30, maxWidth: 76)
                    .accessibilityIdentifier("chat.mode").disabled(chat.isBusy)
                }
                Spacer(minLength: 0)
                if chat.state?.entries.last?.provider == chat.provider,
                   let value = ChatSettings.contextFraction(chat.state?.usage) {
                    ChatGauge(value: value, title: "Context", identifier: "chat.gauge.context")
                }
                if let value = chat.providerLimits[chat.provider]?.compactMap(\.utilization).filter(\.isFinite).max() {
                    ChatGauge(value: value, title: "Usage", identifier: "chat.gauge.usage")
                }
                Button { Task { await chat.stop() } } label: { Image(systemName: "stop.fill") }
                    .opacity(chat.isBusy ? 1 : 0).disabled(!chat.isBusy)
                    .accessibilityHidden(!chat.isBusy)
                    .accessibilityLabel("Stop").accessibilityIdentifier("chat.stop")
                Button { Task { await chat.send() } } label: { Image(systemName: "arrow.up") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend || !chat.canSubmit || !chat.hasInput)
                    .accessibilityLabel("Send").accessibilityIdentifier("chat.composer.send")
            }
            .controlSize(.small).menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
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
    private func receiveAttachments(_ providers: [NSItemProvider]) -> Bool {
        guard canSend, chat.provider != .local, let owner = chat.chatID else { return false }
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
    private var outcomeError: String? {
        if case .failed = chat.state?.outcome { return "The response did not complete." }
        return nil
    }
    private var modeTitle: String {
        switch chat.mode { case .ask: "Ask"; case .acceptEdits: "Accept edits"; case .plan: "Plan"; case .auto: "Auto" }
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
    let value: Double
    let title: String
    let identifier: String
    var body: some View {
        Gauge(value: min(1, max(0, value))) { Text(title) }
            .gaugeStyle(.accessoryCircularCapacity).labelsHidden()
            .scaleEffect(0.55).frame(width: 22, height: 22)
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
                    } else if provider != .local {
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
        return status.authentication == .subscription || status.authentication == .local ? "Ready" : "Signed out"
    }
}
