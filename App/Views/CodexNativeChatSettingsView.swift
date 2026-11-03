import SwiftUI
import AitvarasCore
import AitvarasStore

/// Embedded in AI Settings, not a second sheet. Browsing and inspecting never
/// link a chat; the final button is the explicit native-tools authorization.
struct CodexNativeChatSettingsView: View {
    @Environment(AppModel.self) private var model
    let chatID: UUID
    @State private var selectedThreadID = ""
    @State private var newChat = false
    @State private var preparedThreadID: String?
    @State private var workingDirectory = ""
    @State private var modelID = ""
    @State private var effort = ""
    @State private var choiceError: String?

    private var native: CodexNativeWorkspaceModel { model.codexNativeWorkspace }
    private var projectID: UUID? { model.selectedWorkspaceChat?.projectID }

    var body: some View {
        CodexNativeConnectionSection()
        if native.projectLink == nil || native.projectLink?.state != .linked {
            Section("Codex project") {
                if let projectID {
                    CodexProjectLinkView(projectID: projectID, showsConnection: false) {
                        native.load(chatID: chatID)
                    }
                } else {
                    Text("Choose a project chat first.").foregroundStyle(.secondary)
                }
            }
        } else if let link = native.chatLink, link.chatID == chatID {
            Section("Linked chat") {
                HStack {
                    Label(native.linkReview?.title ?? "Codex chat", systemImage: "link")
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await native.refreshHistory() } }
                        .labelStyle(.iconOnly).help("Refresh native history and permissions")
                }
                if let review = native.linkReview {
                    permissionReview(review)
                    Button("Use these permissions") {
                        Task { _ = await native.linkReviewedChat(chatID: chatID) }
                    }.disabled(!review.canContinue)
                }
                else {
                    Label(link.workingDirectory, systemImage: "folder").font(.caption).textSelection(.enabled)
                }
                Button("Review permissions") { Task { await native.reviewChat(threadID: link.externalID) } }
                Text("One native history in both apps. Local and Claude messages are not copied into Codex.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(native.isBusy)
            modelSettings
        } else {
            Section("Codex chat") {
                HStack {
                    Text(native.projectLink?.approvedSnapshot.name ?? "Linked project").font(.callout.weight(.medium))
                    Spacer()
                    Button("Browse chats", systemImage: "bubble.left.and.bubble.right") {
                        guard let projectID else { return }
                        Task { await native.browseChats(projectID: projectID) }
                    }.disabled(!native.isConnected || native.isBusy)
                }
                if !native.threadChoices.isEmpty {
                    Picker("Chat", selection: $selectedThreadID) {
                        Text("Choose a chat").tag("")
                        ForEach(native.threadChoices) { choice in
                            Text(choice.title).tag(choice.id)
                        }
                    }.disabled(native.isBusy)
                    .onChange(of: selectedThreadID) {
                        guard !selectedThreadID.isEmpty else { return }
                        newChat = false
                        preparedThreadID = nil
                        Task { await native.reviewChat(threadID: selectedThreadID) }
                    }
                }
                Button(newChat ? "Choose an existing chat" : "New Codex chat", systemImage: newChat ? "list.bullet" : "plus") {
                    newChat.toggle()
                    selectedThreadID = ""
                    preparedThreadID = nil
                }.disabled(!native.isConnected || native.isBusy)
                if newChat {
                    Picker("Working folder", selection: $workingDirectory) {
                        Text("Choose a folder").tag("")
                        ForEach(native.projectLink?.approvedSnapshot.roots.map(\.path) ?? [], id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .disabled(native.isBusy)
                    .onChange(of: workingDirectory) { preparedThreadID = nil }
                    Button("Prepare new chat") {
                        let previousID = native.linkReview?.threadID
                        Task {
                            await native.prepareNewChat(chatID: chatID, workingDirectory: workingDirectory)
                            if let review = native.linkReview, review.threadID != previousID, native.errorMessage == nil {
                                preparedThreadID = review.threadID
                            }
                        }
                    }.disabled(workingDirectory.isEmpty || native.isBusy)
                }
                if let review = native.linkReview,
                   newChat ? review.threadID == preparedThreadID : review.threadID == selectedThreadID {
                    permissionReview(review)
                    Button("Link this chat") {
                        Task { _ = await native.linkReviewedChat(chatID: chatID) }
                    }.buttonStyle(.borderedProminent).disabled(!review.canContinue || native.isBusy)
                }
            }
        }
        if let issue = native.projectIssue, issue != native.errorMessage {
            Section { Label(issue, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func permissionReview(_ review: CodexNativeChatReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(review.workingDirectory, systemImage: "folder")
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(review.workingDirectory)
            LabeledContent("Sandbox", value: review.sandbox)
            LabeledContent("Approvals", value: review.approvalPolicy)
            LabeledContent("Network", value: review.networkAccess)
            if review.writableRoots.isEmpty {
                LabeledContent("File writes", value: "No writable folders")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Writable folders").fontWeight(.medium)
                    ForEach(review.writableRoots, id: \.self) { path in
                        Label(path, systemImage: "folder.badge.gearshape")
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
                    }
                }
            }
            DisclosureGroup("Native tools") {
                Text(review.toolSummary).foregroundStyle(.secondary)
            }
            if let warning = review.warning {
                Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Text("Native Codex tools apply. Requests that need approval appear in this chat.")
                .foregroundStyle(.secondary)
        }.font(.caption).padding(.vertical, 4)
    }

    private var modelSettings: some View {
        Section("This chat") {
            Picker("Model", selection: $modelID) {
                if native.models.isEmpty { Text("Connect to load models").tag("") }
                if !modelID.isEmpty && !native.models.contains(where: { $0.id == modelID }) { Text(modelID).tag(modelID) }
                ForEach(native.models) { Text($0.displayName).tag($0.id) }
            }
            Picker("Reasoning", selection: $effort) {
                Text("Default").tag("")
                ForEach(native.models.first(where: { $0.id == modelID })?.efforts ?? [], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            if let choiceError { Text(choiceError).font(.caption).foregroundStyle(.orange) }
        }
        .disabled(native.isBusy)
        .onAppear { refreshChoices() }
        .onChange(of: native.models) { refreshChoices() }
        .onChange(of: modelID) {
            if !(native.models.first(where: { $0.id == modelID })?.efforts.contains(effort) ?? false) { effort = "" }
            saveChoices()
        }
        .onChange(of: effort) { saveChoices() }
    }

    private func refreshChoices() {
        modelID = WorkspaceChatBackend.codexModel(model, chatID: chatID)
        effort = WorkspaceChatBackend.codexEffort(model, chatID: chatID, modelID: modelID) ?? ""
    }

    private func saveChoices() {
        do {
            try model.stores?.setValues([
                WorkspaceChatBackend.key(chatID, "codex.model"): modelID,
                WorkspaceChatBackend.key(chatID, "codex.effort"): effort
            ])
            choiceError = nil
        } catch { choiceError = "These choices could not be saved." }
    }
}

struct CodexNativeConnectionSection: View {
    @Environment(AppModel.self) private var model
    @State private var endpoint = ""

    var body: some View {
        Section("Shared Codex connection") {
            HStack {
                Image(systemName: model.codexNativeWorkspace.isConnected ? "circle.fill" : "circle")
                    .font(.system(size: 9)).foregroundStyle(model.codexNativeWorkspace.isConnected ? Color.green : Color.secondary)
                Text(model.codexNativeWorkspace.isConnected ? "Connected" : "Not connected")
                Spacer()
                if model.codexNativeWorkspace.isBusy { ProgressView().controlSize(.small) }
                Button(model.codexNativeWorkspace.isConnected ? "Reconnect" : "Connect") {
                    model.codexNativeWorkspace.endpoint = endpoint
                    Task { await model.codexNativeWorkspace.connect() }
                }.disabled(model.codexNativeWorkspace.isBusy)
            }
            DisclosureGroup("Connection details") {
                TextField("Optional local WebSocket endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Text("Leave empty for Codex's shared connection. Codex is not started, restarted or reconfigured.")
                    .font(.caption).foregroundStyle(.secondary)
                if let status = model.codexNativeWorkspace.status {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.font(.caption)
            if let error = model.codexNativeWorkspace.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }.onAppear { endpoint = model.codexNativeWorkspace.endpoint }
    }
}

struct CodexNativeApprovalView: View {
    @Environment(AppModel.self) private var model
    let approval: CodexNativeApproval
    @State private var expanded = false
    @State private var responding = false
    @State private var selectedAnswers: [String: String] = [:]
    @State private var writtenAnswers: [String: String] = [:]

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: approval.questions.map { question in
            let written = writtenAnswers[question.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            return (question.id, written.isEmpty ? selectedAnswers[question.id, default: ""] : written)
        })
    }
    private var answersComplete: Bool {
        !approval.questions.isEmpty && answers.values.allSatisfy { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(approval.title, systemImage: !approval.questions.isEmpty ? "questionmark.bubble" : approval.kind.contains("fileChange") ? "doc.badge.gearshape" : "terminal")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(approval.questions.isEmpty ? "Approval required" : "Your answer needed").font(.caption).foregroundStyle(.orange)
            }
            Text(approval.detail).font(.system(.caption, design: .monospaced))
                .lineLimit(expanded ? nil : 4).textSelection(.enabled)
            ForEach(approval.questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.title).font(.callout.weight(.medium))
                    if !question.options.isEmpty {
                        Picker(question.title, selection: Binding(
                            get: { selectedAnswers[question.id, default: ""] },
                            set: { selectedAnswers[question.id] = $0; writtenAnswers[question.id] = "" }
                        )) {
                            ForEach(question.options, id: \.self) { Text($0).tag($0) }
                            Text("Write an answer").tag("")
                        }.pickerStyle(.radioGroup).labelsHidden().font(.callout)
                    }
                    TextField("Your answer", text: Binding(
                        get: { writtenAnswers[question.id, default: ""] },
                        set: { writtenAnswers[question.id] = $0; selectedAnswers[question.id] = "" }
                    ), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                }
            }.disabled(responding)
            HStack {
                if approval.detail.count > 180 || approval.detail.contains("\n") {
                    Button(expanded ? "Show less" : "Show details") { expanded.toggle() }.buttonStyle(.plain).font(.caption)
                }
                Spacer()
                Button("Deny") { respond(allow: false) }
                if approval.questions.isEmpty {
                    Button("Allow once") { respond(allow: true) }
                        .buttonStyle(.borderedProminent).disabled(!approval.canAllow)
                } else {
                    Button("Send answers") { sendAnswers() }
                        .buttonStyle(.borderedProminent).disabled(!approval.canAllow || !answersComplete)
                }
            }.disabled(responding)
        }
        .padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
    }

    private func respond(allow: Bool) {
        guard !responding else { return }
        responding = true
        Task {
            await model.codexNativeWorkspace.respond(approvalID: approval.id, allow: allow)
            responding = false
        }
    }

    private func sendAnswers() {
        guard !responding, answersComplete else { return }
        let submitted = answers
        responding = true
        Task {
            await model.codexNativeWorkspace.respond(approvalID: approval.id, allow: true, answers: submitted)
            responding = false
        }
    }
}
