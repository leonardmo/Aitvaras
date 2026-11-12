import SwiftUI
import AitvarasEngines

/// Unassigned local chat and saved voice history. Project chats use AgentChatView.
/// This reader has no dependency on the retained provider adapters.
struct LocalChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var localModel = MLXEngine.assignedModel(for: .chat)
    @State private var installedModels: [String] = []
    @FocusState private var inputFocused: Bool

    private var readOnly: Bool {
        model.selectedChatConversationID == nil || model.selectedUnassignedVoiceHistory
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.selectedUnassignedVoiceHistory {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let chat = model.chatModel { AgentApprovalSuggestionsView(chat: chat).frame(width: 320) }
                        ForEach(model.suggestions) { SuggestionCard(suggestion: $0) }
                    }.padding(.horizontal, 16)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.selectedWorkspaceProjectID != nil {
                            Text("Choose or create a chat in this project.").foregroundStyle(.secondary)
                        } else if model.messages.isEmpty {
                            Text("Hi, I'm Aitvaras.").font(.title2.weight(.semibold))
                        }
                        if model.earlierChatMessagesAreHidden {
                            Text("Earlier messages remain saved locally.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { MessageBubble(message: $0).id($0.id) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("chat.transcript")
                .onChange(of: model.messages.last?.text) {
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if model.selectedUnassignedVoiceHistory {
                Label("Saved voice history", systemImage: "waveform").font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                composer
            }
        }
        .navigationTitle("Chat")
        .toolbar {
            Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                .disabled(model.isWorkspaceSelectionBusy).accessibilityIdentifier("chat.new")
            if model.selectedWorkspaceProjectID == nil {
                Button(model.voiceEnabled ? "Stop Voice" : "Voice", systemImage: model.voiceEnabled ? "mic.fill" : "mic") {
                    model.toggleVoice()
                }.accessibilityIdentifier("chat.voice")
            }
        }
        .onChange(of: model.selectedChatConversationID) { old, new in
            if let old { drafts[old] = draft }
            draft = new.flatMap { drafts[$0] } ?? ""
        }
        .onAppear {
            installedModels = MLXEngine.installedModels()
            localModel = MLXEngine.assignedModel(for: .chat)
        }
        .onChange(of: localModel) { MLXEngine.assign(model: localModel, to: .chat) }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom) {
                TextField("Message Aitvaras…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...6).focused($inputFocused)
                    .onSubmit(send).accessibilityIdentifier("chat.composer.input")
                if model.isResponding {
                    Button("Stop", systemImage: "stop.circle.fill") { model.cancelTurn() }
                        .accessibilityIdentifier("chat.composer.stop")
                }
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .disabled(model.isResponding || model.microphoneInUseByVoice || model.localAgentReplyActive || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat.composer.send")
            }.buttonStyle(.plain).labelStyle(.iconOnly)
            HStack {
                Picker("Local model", selection: $localModel) {
                    if !installedModels.contains(localModel) { Text(localModel.isEmpty ? "No model installed" : localModel).tag(localModel) }
                    ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().controlSize(.small).frame(maxWidth: 250)
                    .disabled(installedModels.isEmpty || model.isWorkspaceSelectionBusy || model.localAgentReplyActive)
                    .accessibilityIdentifier("chat.model")
                Spacer(minLength: 0)
                ChatMeterBar()
            }
        }
        .padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 13))
        .padding(16).disabled(readOnly)
    }
    private func send() {
        if model.send(draft) { draft = "" }
        inputFocused = true
    }
}
