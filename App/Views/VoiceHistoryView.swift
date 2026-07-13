import SwiftUI
import AitvarasStore

/// Chat-style transcript of everything spoken with Aitvaras — its own tab
/// so the activity log stays about actions, not conversation.
struct VoiceHistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var turns: [StoredMessage] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if turns.isEmpty {
                        ContentUnavailableView(
                            "No voice conversations yet",
                            systemImage: "waveform",
                            description: Text("Press the mic on the companion (⌥Space) and start talking."))
                            .padding(.top, 80)
                    }
                    ForEach(turns) { message in
                        VoiceTurnBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: turns.last?.id) {
                if let last = turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("Voice")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { reload() }
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasActivityChanged)) { _ in
            reload()
        }
    }

    private func reload() {
        guard let stores = model.stores else { return }
        let conversationID = AppModel.voiceConversationID(stores: stores)
        turns = (try? stores.messages(in: conversationID)) ?? []
    }
}

private struct VoiceTurnBubble: View {
    let message: StoredMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        if message.role == "tool" {
            toolNotes
        } else {
            bubble
        }
    }

    /// What she DID during the turn — compact, between the two bubbles.
    private var toolNotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(message.content.split(separator: "\n"), id: \.self) { note in
                Label(String(note), systemImage: "gearshape")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: isUser ? "mic.fill" : "waveform")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(message.content.trimmingCharacters(in: .whitespacesAndNewlines))
                .textSelection(.enabled)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isUser ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                )
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
