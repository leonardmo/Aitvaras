import SwiftUI
import AitvarasAgents

struct AgentMessageQueueView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var chat: ChatModel
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { Color(white: dark ? 0.93 : 0.13) }
    @State private var expanded = false

    var body: some View {
        let queue = chat.messageQueue
        if let chatID = chat.chatID, !queue.messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if queue.messages.count > 1 {
                        Button {
                            expanded.toggle()
                        } label: {
                            Label("\(queue.messages.count) queued", systemImage: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chat.queue.expand")
                    } else {
                        Label("Queued", systemImage: "tray").font(.caption.weight(.medium))
                    }
                    if let status = pauseLabel {
                        Text(status).font(.caption2).foregroundStyle(ink.opacity(0.68)).lineLimit(1).help(status)
                    }
                    Spacer(minLength: 0)
                    if queue.pause != nil {
                        Button("Resume") { Task { await chat.resumeMessageQueue() } }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .disabled(chat.isBusy || chat.editingQueuedMessage)
                            .accessibilityIdentifier("chat.queue.resume")
                    }
                }
                if queue.messages.count == 1 || expanded {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(Array(queue.messages.enumerated()), id: \.element.id) { index, message in
                                row(message, index: index, chatID: chatID, queue: queue)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: min(82, CGFloat(queue.messages.count) * 25 + CGFloat(max(0, queue.messages.count - 1)) * 3))
                }
            }
            .padding(6)
            .foregroundStyle(ink)
            .background(Color(white: dark ? 0.145 : 0.95), in: .rect(cornerRadius: 9))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.queue")
            .onChange(of: chatID) { expanded = false }
        }
    }

    private var pauseLabel: String? {
        switch chat.messageQueue.pause {
        case .stopped: "Paused after Stop"
        case .failed: "Paused after a failed turn"
        case .quota: "Waiting for usage reset"
        case .restarted: "Paused after restart"
        case .approval: "Paused after a turn ended with an approval"
        case .delivery: "Paused after a delivery problem"
        case nil: chat.state?.pendingCards.isEmpty == false ? "Waiting for approval" : nil
        }
    }

    private func row(_ message: AgentQueuedMessage, index: Int, chatID: UUID, queue: AgentMessageQueue) -> some View {
        let locked = queue.editingID == message.id || queue.dispatchingID == message.id
        let text = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Attachment"
        let stopAndSend = message.provider == .local && chat.isBusy
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(ink.opacity(0.46))
                .help("Drag to reorder")
            Text(text).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(message.attachmentKinds.prefix(3).enumerated()), id: \.offset) { _, kind in
                Image(systemName: kind == .image ? "photo" : "paperclip")
                    .foregroundStyle(ink.opacity(0.68)).accessibilityLabel(kind == .image ? "Image attachment" : "Attachment")
            }
            if queue.editingID == message.id {
                Text("Editing").foregroundStyle(ink.opacity(0.68))
            } else if queue.dispatchingID == message.id {
                ProgressView().controlSize(.mini).accessibilityLabel("Sending")
            } else {
                rowButton(stopAndSend ? "Stop and send" : "Send now", icon: stopAndSend ? "stop.circle" : "bolt",
                          id: "now", enabled: chat.canSendQueuedNow) { await chat.sendQueuedMessageNow(message) }
                rowButton("Edit", icon: "pencil", id: "edit", enabled: !chat.editingQueuedMessage) { await chat.editQueuedMessage(message) }
                rowButton("Delete", icon: "xmark", id: "delete", enabled: true) { await chat.removeQueuedMessage(message) }
            }
        }
        .font(.caption)
        .padding(.horizontal, 5)
        .frame(height: 25)
        .background(Color(white: dark ? 0.19 : 0.99), in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: message.id.uuidString as NSString) }
        .dropDestination(for: String.self) { items, _ in
            guard !locked, let raw = items.first, let source = UUID(uuidString: raw),
                  queue.messages.contains(where: { $0.id == source }), source != message.id else { return false }
            Task { await chat.moveQueuedMessage(source, to: message.id, chatID: chatID) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.queue.row.\(index)")
        .accessibilityAction(named: "Move up") {
            guard index > 0 else { return }
            Task { await chat.moveQueuedMessage(message.id, to: queue.messages[index - 1].id, chatID: chatID) }
        }
        .accessibilityAction(named: "Move down") {
            guard index + 1 < queue.messages.count else { return }
            Task { await chat.moveQueuedMessage(message.id, to: queue.messages[index + 1].id, chatID: chatID) }
        }
    }

    private func rowButton(_ title: String, icon: String, id: String, enabled: Bool, action: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: icon).foregroundStyle(ink.opacity(0.76))
                .frame(width: 20, height: 21).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(title).accessibilityLabel(title).accessibilityIdentifier("chat.queue.\(id)")
    }
}
