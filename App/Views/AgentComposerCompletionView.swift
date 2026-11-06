import SwiftUI
import AitvarasAgents

/// One popover, with a search field and flat, keyboard-accessible results.
struct AgentComposerCompletionView: View {
    @Bindable var chat: ChatModel
    let trigger: AgentComposerTrigger
    let dismiss: () -> Void
    @State private var query = ""
    @State private var commands: [AgentCommand] = []
    @State private var files: [AgentFileMention] = []
    @State private var loading = true
    @State private var unavailable = false
    @State private var selected = 0
    @FocusState private var searching: Bool

    private var filteredCommands: [AgentCommand] {
        commands.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query) }
    }
    private var count: Int { trigger.kind == .file ? files.count : filteredCommands.count }
    var body: some View {
        VStack(spacing: 8) {
            TextField(trigger.kind == .file ? "Find a project file" : "Find a command", text: $query)
                .textFieldStyle(.roundedBorder).focused($searching)
                .accessibilityIdentifier("chat.completion.search")
                .onKeyPress(.downArrow) { selected = min(max(0, count - 1), selected + 1); return .handled }
                .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
                .onKeyPress(.return) { choose(selected); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            if loading { ProgressView().controlSize(.small).frame(height: 32) }
            else if unavailable || count == 0 {
                Text(unavailable ? "\(trigger.kind == .file ? "Files" : "Commands") unavailable" : "No matches")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 32)
                    .accessibilityIdentifier("chat.completion.empty")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(0..<count, id: \.self) { index in
                                Button { choose(index) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(trigger.kind == .file ? files[index].name : "/" + filteredCommands[index].name)
                                            .lineLimit(1).truncationMode(.middle)
                                        if trigger.kind == .command {
                                            Text(filteredCommands[index].description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(selected == index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain).id(index)
                                .accessibilityIdentifier("chat.completion.item.\(index)")
                            }
                        }
                    }.frame(maxHeight: 240)
                    .onChange(of: selected) { proxy.scrollTo(selected) }
                }
            }
        }
        .padding(12).frame(width: 340)
        .accessibilityIdentifier("chat.completion")
        .onAppear { query = trigger.query; searching = true }
        .task(id: "\(chat.chatID?.uuidString ?? "").\(chat.provider.rawValue)") {
            if trigger.kind == .command {
                do { commands = try await chat.commands(); loading = false }
                catch { if !Task.isCancelled { unavailable = true; loading = false } }
            }
        }
        .task(id: query) {
            selected = 0
            guard trigger.kind == .file else { return }
            loading = true; unavailable = false
            do {
                try await Task.sleep(for: .milliseconds(100))
                let values = try await chat.files(query: query)
                try Task.checkCancellation()
                files = values; loading = false
            } catch { if !Task.isCancelled { unavailable = true; loading = false } }
        }
    }
    private func choose(_ index: Int) {
        guard !loading, !unavailable, index >= 0, index < count else { return }
        let insertion = trigger.kind == .file ? files[index].insertion : filteredCommands[index].insertion
        guard let text = trigger.selecting(insertion, in: chat.draft) else { dismiss(); return }
        var selection = chat.composerSelection
        if trigger.kind == .file {
            if !selection.mentions.contains(files[index]) { selection.mentions.append(files[index]) }
        } else { selection.command = filteredCommands[index] }
        chat.composerSelection = selection
        chat.draft = text
        dismiss()
    }
}
