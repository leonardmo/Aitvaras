import SwiftUI
import AitvarasAgents

/// The inspector exists only while the selected checkout has changes.
struct AgentChangesView: View {
    @Bindable var chat: ChatModel
    let owner: UUID
    let changes: ChangesState
    @State private var selectedPath: String?
    @State private var message = ""
    @State private var discarding: ChangesState?
    private var selected: AgentFileChange? {
        changes.files.first { $0.path == selectedPath } ?? changes.files.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button { Task { await chat.refreshChanges() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(chat.gitBusy)
                    .accessibilityLabel("Refresh changes").accessibilityIdentifier("chat.changes.refresh")
                Text("\(changes.files.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            List(changes.files, selection: $selectedPath) { file in
                HStack(spacing: 6) {
                    Text(file.status.trimmingCharacters(in: .whitespaces)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(file.path).font(.callout).lineLimit(1).truncationMode(.middle)
                }.tag(file.path)
            }
            .listStyle(.inset).frame(minHeight: 70, idealHeight: 120, maxHeight: 170)
            .accessibilityIdentifier("chat.changes.files")
            if let selected {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if selected.diffUnavailable {
                            Text("Binary or large file — preview unavailable.").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(selected.diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.primary)
                            }
                        }
                    }.font(.caption.monospaced()).textSelection(.enabled).padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("chat.changes.diff")
            }
            TextField("Commit message", text: $message, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat.changes.message")
            HStack {
                Button("Discard", role: .destructive) { discarding = changes }
                    .disabled(!chat.canDiscardChanges)
                    .accessibilityIdentifier("chat.changes.discard")
                Spacer()
                if chat.gitBusy { ProgressView().controlSize(.mini) }
                Button("Commit") {
                    let text = message
                    Task { await chat.applyGitChanges(changes, owner: owner, message: text) }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("chat.changes.commit")
            }.controlSize(.small).disabled(chat.isBusy || chat.gitBusy)
        }
        .padding(12).frame(minWidth: 230, idealWidth: 290)
        .accessibilityIdentifier("chat.changes")
        .confirmationDialog("Discard changes in this chat’s worktree?", isPresented: Binding(
            get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                guard let expected = discarding else { return }
                discarding = nil
                Task { await chat.applyGitChanges(expected, owner: owner, message: nil) }
            }.accessibilityIdentifier("chat.changes.discard.confirm")
            Button("Cancel", role: .cancel) { discarding = nil }
        }
    }
}
