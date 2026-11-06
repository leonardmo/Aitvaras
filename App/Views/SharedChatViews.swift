import SwiftUI
import AitvarasStore

// Local chat and the companion share these rows independently of legacy adapters.

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
