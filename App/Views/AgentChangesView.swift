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
    @State private var pushConfirmation: PushConfirmation?
    private struct PushConfirmation {
        let expected: ChangesState?
        let message: String
        let directory: URL
        let branch: String
    }
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
                Button { Task { await chat.refreshChanges(); await chat.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(chat.gitBusy)
                    .accessibilityLabel("Refresh changes").accessibilityIdentifier("chat.changes.refresh")
                Text("\(changes.files.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            branchHeader
            if chat.canCreatePullRequest {
                Button("Create \(chat.forgeKind?.requestName ?? "pull request")…") {
                    Task { await chat.preparePullRequest() }
                }.disabled(chat.forgeBusy || chat.gitBusy || chat.isBusy)
                    .accessibilityIdentifier("chat.changes.createPullRequest")
            }
            if let error = chat.forgeError {
                Text(error).font(.caption).foregroundStyle(.secondary).help(error)
            }
            if chat.forgeNeedsSignIn, let kind = chat.forgeKind, let host = chat.branchStatus?.remoteHost {
                ForgeSignInButton(kind: kind, host: host) { await chat.refreshPullRequest() }
            }
            if let reason = chat.pushDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(reason)
            }
            if let error = chat.gitError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(1).help(error)
                    .accessibilityIdentifier("chat.changes.error")
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
            VStack(spacing: 6) {
                HStack {
                    Button("Discard", role: .destructive) { discarding = changes }
                        .disabled(!chat.canDiscardChanges || !changes.hasChanges)
                        .accessibilityIdentifier("chat.changes.discard")
                    Spacer()
                    if chat.gitBusy { ProgressView().controlSize(.mini) }
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("Commit and push") {
                        pushConfirmation = .init(expected: changes, message: message, directory: changes.directory, branch: chat.branchStatus?.branch ?? "")
                    }
                    .disabled(!changes.hasChanges || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.pushDisabledReason != nil)
                    .accessibilityIdentifier("chat.changes.commitAndPush")
                    Button("Commit") {
                        let text = message
                        Task { await chat.applyGitChanges(changes, owner: owner, message: text) }
                    }
                    .disabled(!changes.hasChanges || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat.changes.commit")
                }
            }.controlSize(.small).disabled(chat.isBusy || chat.gitBusy)
        }
        .padding(12).frame(minWidth: 230, idealWidth: 270, maxWidth: 320)
        .accessibilityIdentifier("chat.changes.panel")
        .sheet(isPresented: Binding(get: { chat.forgeDraft != nil }, set: { if !$0 { chat.dismissForgeDraft() } })) {
            if let draft = chat.forgeDraft { AgentPullRequestSheet(chat: chat, owner: owner, initial: draft) }
        }
        .onChange(of: changes.hasChanges) { _, hasChanges in
            // A successful commit empties the change set; start the next one blank.
            if !hasChanges { message = "" }
        }
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
    private var branchHeader: some View {
        HStack(spacing: 6) {
            if let branch = chat.branchStatus {
                Label(branch.detached ? "Detached HEAD" : branch.branch, systemImage: "arrow.triangle.branch")
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .help(branch.branch).accessibilityIdentifier("chat.changes.branch")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    if branch.upstream == nil {
                        Text("Not pushed yet")
                    } else if branch.ahead == 0, branch.behind == 0 {
                        Image(systemName: "checkmark.circle").accessibilityLabel("Up to date")
                    } else {
                        if branch.ahead > 0 { Label("\(branch.ahead)", systemImage: "arrow.up") }
                        if branch.behind > 0 { Label("\(branch.behind)", systemImage: "arrow.down") }
                    }
                }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .help(branch.upstream.map { "Upstream: " + $0 + " · ↑ \(branch.ahead) · ↓ \(branch.behind)" } ?? "Not pushed yet")
                    .accessibilityIdentifier("chat.changes.upstream")
            }
            Button("Push") { pushConfirmation = .init(expected: nil, message: "", directory: changes.directory, branch: chat.branchStatus?.branch ?? "") }
                .controlSize(.small)
                .disabled(chat.isBusy || chat.gitBusy || chat.pushDisabledReason != nil)
                .help(chat.pushDisabledReason ?? "Push the current branch to origin")
                .accessibilityIdentifier("chat.changes.push")
        }
        .confirmationDialog("Push this branch to origin?", isPresented: Binding(
            get: { pushConfirmation != nil }, set: { if !$0 { pushConfirmation = nil } }), titleVisibility: .visible) {
            Button(pushConfirmation?.expected == nil ? "Push" : "Commit and push") {
                guard let pending = pushConfirmation else { return }
                pushConfirmation = nil
                Task {
                    if let expected = pending.expected {
                        await chat.applyGitChanges(expected, owner: owner, message: pending.message, pushAfterCommit: true, expectedBranch: pending.branch)
                    } else { await chat.pushGitBranch(owner: owner, directory: pending.directory, branch: pending.branch) }
                }
            }.accessibilityIdentifier("chat.changes.push.confirm")
            Button("Cancel", role: .cancel) { pushConfirmation = nil }
        } message: {
            Text("Publish \(pushConfirmation?.branch ?? "this branch")\(chat.branchStatus?.remoteHost.map { " to " + $0 } ?? "") with your configured Git credentials.")
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
