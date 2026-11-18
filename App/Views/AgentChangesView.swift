import SwiftUI
import AppKit
import AitvarasAgents

/// Explicitly opened inspector for the selected checkout.
struct AgentChangesView: View {
    @Bindable var chat: ChatModel
    let owner: UUID
    let changes: ChangesState
    @State private var selectedPath: String?
    @State private var message = ""
    @State private var discarding: ChangesState?
    @State private var lineSelection = AgentDiffSelection()
    @State private var lineFrames: [Int: CGRect] = [:]
    @State private var draggingLines = false
    private var selectedLines: Set<Int> { lineSelection.selected }
    private var selected: AgentFileChange? {
        changes.files.first { $0.path == selectedPath } ?? changes.files.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button { Task { await chat.refreshChanges() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(chat.gitBusy)
                    .accessibilityLabel("Refresh changes").accessibilityIdentifier("chat.changes.refresh")
                Text("\(changes.files.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        ForEach(changes.files) { file in
                            Button { selectedPath = file.path } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: file.statusSymbol)
                                        .foregroundStyle(.secondary).help(file.statusLabel)
                                        .accessibilityLabel(file.statusLabel)
                                    Text(file.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(6).contentShape(Rectangle())
                                .background(selected?.path == file.path ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                        }
                    }.accessibilityIdentifier("chat.changes.files")
                    if let selected {
                        Divider().padding(.vertical, 8)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                if selected.diffUnavailable {
                                    Text("Binary or large file — preview unavailable.").foregroundStyle(.secondary)
                                } else {
                                    ForEach(AgentDiffContext.lines(selected.diff)) { line in
                                        if line.kind == .header { Text(line.text.isEmpty ? " " : line.text).foregroundStyle(.secondary) }
                                        else {
                                            HStack(spacing: 8) {
                                                Text(String(line.newLine ?? line.oldLine ?? 0)).foregroundStyle(.secondary).frame(minWidth: 28, alignment: .trailing)
                                                Text((line.kind == .added ? "+" : line.kind == .removed ? "-" : " ") + line.text)
                                                    .foregroundStyle(line.kind == .added ? Color.green : line.kind == .removed ? Color.red : Color.primary)
                                            }.padding(.horizontal, 4).contentShape(Rectangle())
                                            .background(selectedLines.contains(line.id) ? Color.accentColor.opacity(0.18) : .clear)
                                            .background {
                                                GeometryReader { geometry in
                                                    Color.clear.preference(key: DiffLineFrames.self,
                                                        value: [line.id: geometry.frame(in: .named("diff.lines"))])
                                                }
                                            }
                                            .accessibilityAddTraits(.isButton)
                                            .accessibilityAction { lineSelection.select(line.id, in: AgentDiffContext.lines(selected.diff)) }
                                            .contextMenu {
                                                Button("Add to message") { addLines(selectedLines.contains(line.id) ? selectedLines : [line.id], file: selected) }
                                            }
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(name: "diff.lines")
                            .onPreferenceChange(DiffLineFrames.self) { lineFrames = $0 }
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("diff.lines"))
                                .onChanged { value in
                                    let lines = AgentDiffContext.lines(selected.diff)
                                    if !draggingLines {
                                        guard let start = lineID(at: value.startLocation) else { return }
                                        draggingLines = true
                                        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                                        lineSelection.select(start, in: lines, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
                                    }
                                    if value.translation != .zero, let end = lineID(at: value.location) {
                                        lineSelection.select(end, in: lines, extending: true)
                                    }
                                }
                                .onEnded { _ in draggingLines = false })
                            .font(.caption.monospaced())
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .topLeading)
                        }.accessibilityIdentifier("chat.changes.diff")
                        Button("Add to message") { addLines(selectedLines, file: selected) }
                            .disabled(selectedLines.isEmpty || selected.diffUnavailable)
                            .accessibilityIdentifier("chat.changes.addToMessage")
                    } else {
                        Text("No changes").foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .padding(12).frame(minWidth: 230, idealWidth: 270, maxWidth: 320)
        .accessibilityIdentifier("chat.changes.panel")
        .onChange(of: selected?.path) { resetLineSelection() }
        .onChange(of: selected?.diff) { resetLineSelection() }
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
    private func lineID(at point: CGPoint) -> Int? {
        lineFrames.first { $0.value.minY <= point.y && point.y < $0.value.maxY }?.key
    }
    private func resetLineSelection() {
        lineSelection = .init(); draggingLines = false; lineFrames = [:]
    }
    private func addLines(_ lines: Set<Int>, file: AgentFileChange) {
        if let context = AgentDiffContext.message(path: file.path, diff: file.diff, selected: lines) { chat.addDiffContext(context, owner: owner) }
    }
}

private struct DiffLineFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
