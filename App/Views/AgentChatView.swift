import SwiftUI
import AitvarasAgents

/// M2 shell. Provider-specific adapters and their views remain compiled until
/// migration; this surface only observes the application-owned chat manager.
struct AgentChatView: View {
    @Bindable var chat: ChatModel
    let chatID: UUID
    var canSend = true
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(chat.state?.entries ?? []) { entry in
                            if entry.kind == "handover" {
                                DisclosureGroup("Context sent to \(entry.provider.rawValue.capitalized)") {
                                    Text(entry.text).font(.caption).textSelection(.enabled)
                                }
                                .accessibilityIdentifier("chat.handover.\(entry.id)")
                            } else if entry.kind == "thinking" || entry.kind == "tool" {
                                DisclosureGroup(entry.kind == "thinking" ? "Thinking" : entry.text) {
                                    Text(entry.payloadJSON ?? entry.text).font(.caption).textSelection(.enabled)
                                }
                                .accessibilityIdentifier("chat.entry.\(entry.id)")
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.kind == "user" ? "You" : entry.provider.rawValue.capitalized)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(entry.text).textSelection(.enabled)
                                }
                                .id(entry.id)
                            }
                        }
                        ForEach(Array((chat.state?.pendingCards ?? []).enumerated()), id: \.offset) { index, request in
                            requestCard(request, index: index)
                        }
                        Color.clear.frame(height: 1).id("chat.end")
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("chat.transcript")
                .onChange(of: chat.state?.entries) { proxy.scrollTo("chat.end", anchor: .bottom) }
            }
            if let error = chat.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            } else if case .failed = chat.state?.outcome {
                Text("The response did not complete.").font(.caption).foregroundStyle(.red).padding(8)
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    ForEach([AgentProvider.claude, .codex, .local], id: \.self) { provider in
                        Button(provider.rawValue.capitalized) { chat.setProvider(provider) }
                            .tint(chat.provider == provider ? Color.accentColor : Color.secondary)
                            .accessibilityAddTraits(chat.provider == provider ? .isSelected : [])
                            .accessibilityIdentifier("chat.provider.\(provider.rawValue)")
                    }
                    Spacer()
                    if chat.isBusy {
                        Button("Stop", systemImage: "stop.fill") { Task { await chat.stop() } }
                            .accessibilityIdentifier("chat.stop")
                    }
                }
                HStack {
                    TextField("Model", text: $chat.model).accessibilityIdentifier("chat.model")
                    TextField("Effort", text: $chat.effort).accessibilityIdentifier("chat.effort")
                    Picker("Mode", selection: $chat.mode) {
                        Text("Ask").tag(AgentMode.ask)
                        Text("Accept edits").tag(AgentMode.acceptEdits)
                        Text("Plan").tag(AgentMode.plan)
                        Text("Auto").tag(AgentMode.auto)
                    }.accessibilityIdentifier("chat.mode")
                }
                .disabled(chat.isBusy || chat.provider == .local)
                HStack(alignment: .bottom) {
                    TextField("Message", text: $chat.draft, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("chat.composer.input")
                        .onSubmit { Task { await chat.send() } }
                    Button("Send", systemImage: "arrow.up") { Task { await chat.send() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(chat.isBusy || !canSend || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("chat.composer.send")
                }
                .disabled(!canSend)
            }.padding(16)
        }
        .task(id: chatID) { chat.select(chatID) }
        .task { await chat.refreshStatus() }
        .onChange(of: chatID) { answers = [:] }
    }

    private func requestCard(_ request: AgentRequest, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch request.kind {
            case .questions(let questions):
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
                    Task { await chat.respond(to: request, with: .answers(response)) }
                }.accessibilityIdentifier("chat.request.\(index).submit")
            default:
                Text(requestTitle(request)).font(.headline)
                Button("Allow") { Task { await chat.respond(to: request, with: .allow(updatedInput: nil)) } }
                    .accessibilityIdentifier("chat.request.\(index).allow")
            }
            Button("Deny") { Task { await chat.respond(to: request, with: .deny) } }
                .accessibilityIdentifier("chat.request.\(index).deny")
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func answer(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
    private func requestTitle(_ request: AgentRequest) -> String {
        switch request.kind {
        case .permission(let tool), .preToolUse(let tool): return "Allow \(tool.name)?\n\(tool.input.jsonString)"
        case .permissions(let value): return "Allow permissions?\n\(value.jsonString)"
        case .plan(let text): return text
        default: return "Provider request"
        }
    }
}
