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
                Text("\(passing)✓ \(failing.count)× \(pending)…").font(.caption2).monospacedDigit()
                    .help("Passing / failing / pending")
                if let review = pr.reviewDecision, !review.isEmpty { Text(review.replacingOccurrences(of: "_", with: " ").lowercased()).font(.caption2) }
                Text(pr.mergeable.rawValue).font(.caption2).help("Mergeability")
                Button { Task { await chat.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh request").accessibilityLabel("Refresh request")
                Button { if (try? ProviderSignIn.validate(pr.url)) != nil { NSWorkspace.shared.open(pr.url) } } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on \(pr.forge.title)").accessibilityLabel("Open request in browser")
                if let error = chat.forgeError { Image(systemName: "exclamationmark.triangle").help(error) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("chat.pullRequest.bar")
        } else if let binding = chat.pullRequestBinding {
            HStack(spacing: 7) {
                Text("#\(binding.number) · status unavailable").font(.caption)
                Button { Task { await chat.refreshPullRequest() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh request").accessibilityLabel("Refresh request")
                Button { if (try? ProviderSignIn.validate(binding.url)) != nil { NSWorkspace.shared.open(binding.url) } } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Open on \(binding.forge.title)").accessibilityLabel("Open request in browser")
                if let error = chat.forgeError { Image(systemName: "exclamationmark.triangle").help(error) }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("chat.pullRequest.bar")
        }
    }
}
