import SwiftUI
import AitvarasStore

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !model.suggestions.isEmpty {
                suggestionBar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.messages.isEmpty {
                            emptyState
                        }
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(20)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            inputBar
        }
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
            }
            ToolbarItem {
                Button(model.voiceEnabled ? "Stop Voice" : "Voice",
                       systemImage: model.voiceEnabled ? "mic.fill" : "mic") {
                    model.toggleVoice()
                }
                .tint(model.voiceEnabled ? .red : nil)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hi, I'm Aitvaras.")
                .font(.title2.weight(.semibold))
            Text("Everything I do runs on this Mac. Ask me something, give me a task, or press ⌥Space for my companion window. Du kannst auch einfach auf Deutsch schreiben.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 60)
    }

    private var suggestionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Aitvaras…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
            if model.isResponding {
                Button("Stop", systemImage: "stop.circle.fill") { model.cancelTurn() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill") { send() }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(.bar)
    }

    private func send() {
        model.send(draft)
        draft = ""
        inputFocused = true
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
