import SwiftUI
import AitvarasAgents

/// One transcript and composer, observing the application-owned chat manager.
struct AgentChatView: View {
    @Bindable var chat: ChatModel
    let chatID: UUID
    var canSend = true
    var workspaceError: String? = nil
    @State private var answers: [String: String] = [:]

    @State private var atBottom = true
    @State private var bottomVisible = true
    @State private var scrolling = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(chat.state?.entries ?? []) { entry in
                            AgentTranscriptView(entry: entry).id(entry.id)
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
        .onChange(of: chatID) { answers = [:] }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            TextField("Message", text: $chat.draft, axis: .vertical)
                .lineLimit(2...6).textFieldStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("chat.composer.input")
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    if !chat.isBusy && canSend { Task { await chat.send() } }
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
                if chat.isBusy {
                    Button { Task { await chat.stop() } } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop").accessibilityIdentifier("chat.stop")
                } else {
                    Button { Task { await chat.send() } } label: { Image(systemName: "arrow.up") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend || chat.signingIn != nil || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send").accessibilityIdentifier("chat.composer.send")
                }
            }
            .controlSize(.small).menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }
    private var outcomeError: String? {
        if case .failed = chat.state?.outcome { return "The response did not complete." }
        return nil
    }
    private var modeTitle: String {
        switch chat.mode { case .ask: "Ask"; case .acceptEdits: "Accept edits"; case .plan: "Plan"; case .auto: "Auto" }
    }

    @ViewBuilder private func requestCard(_ request: AgentRequest, index: Int) -> some View {
        if case .questions(let questions) = request.kind {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(questions, id: \.id) { question in
                    Text(question.prompt)
                    if question.isSecret {
                        SecureField("Answer", text: answer(question.id))
                            .accessibilityIdentifier("chat.question.\(index).\(question.id)")
                    } else {
                        TextField("Answer", text: answer(question.id))
                            .accessibilityIdentifier("chat.question.\(index).\(question.id)")
                    }
                }
                Button("Submit") {
                    let response = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [answers[$0.id] ?? ""]) })
                    let owner = chatID
                    Task { _ = await chat.respond(chatID: owner, to: request, with: .answers(response)) }
                }.accessibilityIdentifier("chat.request.\(index).submit")
                Button("Deny") {
                    let owner = chatID
                    Task { _ = await chat.respond(chatID: owner, to: request, with: .deny) }
                }.accessibilityIdentifier("chat.request.\(index).deny")
            }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        } else {
            AgentApprovalCard(request: request, identifier: "chat.request.\(index)") { [owner = chatID] response in
                await chat.respond(chatID: owner, to: request, with: response)
            }
        }
    }
    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
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
