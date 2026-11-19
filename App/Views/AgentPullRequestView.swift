import SwiftUI
import AppKit
import AitvarasAgents

struct AgentPullRequestSheet: View {
    @Bindable var chat: ChatModel
    let owner: UUID
    let initial: ForgeRequestDraft
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create \(initial.kind.requestName)").font(.headline)
            Text("\(initial.branch) → \(initial.base) · \(initial.host)/\(initial.repo)").font(.caption).foregroundStyle(.secondary)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).frame(minHeight: 160).border(.secondary.opacity(0.3))
                .accessibilityLabel("Request description")
            Picker("State", selection: $draft) { Text("Ready for review").tag(false); Text("Draft").tag(true) }
                .pickerStyle(.segmented)
            Text("Create publishes this title and description to your Git host. Merge on the website.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = chat.forgeError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if chat.forgeBusy { ProgressView().controlSize(.small) }
                Button("Create") {
                    var value = initial; value.title = title; value.body = bodyText
                    Task { if await chat.createPullRequest(value, isDraft: draft, owner: owner) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(chat.forgeBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("chat.pullRequest.create.confirm")
            }
        }.padding(20).frame(width: 520)
            .onAppear { title = initial.title; bodyText = initial.body }
    }
}

struct AgentPullRequestBar: View {
    @Bindable var chat: ChatModel
    @ViewBuilder private var watchIndicator: some View {
        if chat.pullRequestBinding?.watch == true {
            Image(systemName: "eye")
                .accessibilityLabel("Watching pull request")
                .help(chat.pullRequestCheckedAt.map { "Last checked " + $0.formatted(date: .abbreviated, time: .shortened) }
                    ?? "Waiting for the first Auto-fix check")
        }
    }
    static func mergeLabel(_ value: ForgePullRequest.Mergeable) -> String? {
        switch value {
        case .yes: "Mergeable"
        case .no: "Not mergeable"
        case .conflicting: "Conflicts"
        case .unknown: nil
        }
    }
    var body: some View {
        if let pr = chat.pullRequest {
            HStack(spacing: 7) {
                Text("#\(pr.number) · \(pr.state.rawValue)").font(.caption)
                let passing = chat.pullRequestChecks.filter { $0.status == .passing }.count
                let failing = chat.pullRequestChecks.filter { $0.status == .failing }
                let pending = chat.pullRequestChecks.filter { $0.status == .pending }.count
                Gauge(value: Double(passing), in: 0...Double(max(1, chat.pullRequestChecks.count))) {
                    Text("Checks")
                }.gaugeStyle(.accessoryCircularCapacity).tint(failing.isEmpty ? .green : .red).scaleEffect(0.55).frame(width: 24, height: 24)
                    .accessibilityLabel("\(passing) passing, \(failing.count) failing, \(pending) pending checks")
                    .help("\(passing) passing · \(failing.count) failing · \(pending) pending\n" + failing.map(\.name).joined(separator: "\n"))
                Text(chat.pullRequestChecks.isEmpty ? "No checks"
                     : failing.isEmpty ? "\(passing)/\(chat.pullRequestChecks.count) passed"
                     : "\(failing.count) failing").font(.caption2).monospacedDigit().lineLimit(1).fixedSize()
                    .help("\(passing) passing · \(failing.count) failing · \(pending) pending")
                if let review = pr.reviewDecision, !review.isEmpty { Text(review.replacingOccurrences(of: "_", with: " ").lowercased()).font(.caption2) }
                if let label = Self.mergeLabel(pr.mergeable) {
                    Text(label).font(.caption2).lineLimit(1).fixedSize().foregroundStyle(pr.mergeable == .yes ? Color.secondary : Color.orange)
                }
                if chat.canToggleAutoFix {
                    Toggle("Auto-fix", isOn: Binding(get: { chat.pullRequestBinding?.watch == true },
                        set: { on in Task { await chat.setAutoFix(on) } }))
                        .toggleStyle(.switch).controlSize(.mini).font(.caption2)
                        .disabled(chat.autoFixBusy)
                        .accessibilityIdentifier("chat.pullRequest.autoFix")
                }
                watchIndicator
                Button { Task { await chat.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh request").accessibilityLabel("Refresh request")
                Button { if (try? ProviderSignIn.validate(pr.url)) != nil { NSWorkspace.shared.open(pr.url) } } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on \(pr.forge.title)").accessibilityLabel("Open request in browser")
                if let error = chat.forgeError { Image(systemName: "exclamationmark.triangle").help(error) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("chat.pullRequest.bar")
        } else if let binding = chat.pullRequestBinding {
            HStack(spacing: 7) {
                Text("#\(binding.number) · status unavailable").font(.caption)
                watchIndicator
                Button { Task { await chat.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh request").accessibilityLabel("Refresh request")
                Button { if (try? ProviderSignIn.validate(binding.url)) != nil { NSWorkspace.shared.open(binding.url) } } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on \(binding.forge.title)").accessibilityLabel("Open request in browser")
                if let error = chat.forgeError { Image(systemName: "exclamationmark.triangle").help(error) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("chat.pullRequest.bar")
        }
    }
}
