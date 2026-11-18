import SwiftUI

struct AgentEditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    let resend: @MainActor (String) async -> Bool
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit & resend").font(.title2.weight(.semibold))
            TextEditor(text: $text).font(.body).frame(minHeight: 160).disabled(busy)
            if failed { Text("This message could not be forked. Your edited text is kept here.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.mini) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Send") { busy = true; Task { failed = !(await resend(text)); busy = false } }.buttonStyle(.borderedProminent)
                    .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520, height: 290)
            .accessibilityIdentifier("chat.editMessage")
            .interactiveDismissDisabled(busy)
    }
}
