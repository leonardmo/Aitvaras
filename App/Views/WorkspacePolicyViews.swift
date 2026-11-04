import AppKit
import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasAgent

/// Manual, event-driven inspection. Nothing here reads project files, calls a
/// provider, or attaches saved evidence to a model prompt.
struct WorkspaceInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    var backend: WorkspaceChatBackend = .local
    var directAgentChat = false
    @State private var packet: WorkspaceContextPacket?
    @State private var captures: [CaptureRecord] = []
    @State private var error: String?
    @State private var fileReadEnabled = false
    @State private var tab = "context"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Chat Details").font(.title2.weight(.semibold))
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: reload).labelStyle(.iconOnly)
                    .accessibilityIdentifier("chat.details.refresh")
            }
            Picker("Details", selection: $tab) {
                Text("Context").tag("context")
                Text("Captures (\(captures.count))").tag("captures")
            }.pickerStyle(.segmented).accessibilityIdentifier("chat.details.tab")
            if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Form {
                if tab == "context", let packet {
                    Section {
                        LabeledContent("Provider", value: backend.title)
                        LabeledContent("Destination", value: backend == .local ? "This Mac" : backend == .codex ? "OpenAI, when you send" : directAgentChat ? "Anthropic, when you send" : "Not available yet")
                        LabeledContent("History", value: "Messages created in this chat")
                        if !directAgentChat {
                            LabeledContent("Project", value: packet.policyStatus == .reviewed ? "Settings saved" : "Settings need saving")
                            if backend == .codex { LabeledContent("Project files", value: fileReadEnabled ? "Read-only, on request" : "Not shared") }
                        }
                    }
                    Section("Context") {
                        Text("Project instructions and this chat's messages provide context.")
                            .font(.callout)
                        DisclosureGroup("Exact project context") {
                            Text(packet.promptText).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).padding(.vertical, 6)
                            if packet.manifest.wasClipped {
                                Label("Long project instructions were shortened.", systemImage: "scissors").font(.caption)
                            }
                        }.accessibilityIdentifier("chat.details.context")
                        DisclosureGroup("What stays excluded") {
                            Text(directAgentChat
                                ? "Imported chats, linked captures, other chats and shared memories are not attached. Local is text-only; provider tools follow the selected mode."
                                : fileReadEnabled && backend == .codex
                                ? "Imported chats, captures, other chats and shared memories. No shell or file writes."
                                : "Imported chats, file contents, captures, other chats and shared memories. No file tools are enabled.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.accessibilityIdentifier("chat.details.exclusions")
                    }
                } else if tab == "captures" {
                    Section {
                        if captures.isEmpty { Text("No captures linked to this chat.").foregroundStyle(.secondary) }
                        ForEach(captures) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title).font(.headline)
                                    Text(record.startedAt, format: .dateTime.day().month().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open") { CaptureWindows.shared.showResult(record: record, model: model) }
                                    .accessibilityIdentifier("chat.details.capture.\(record.id)")
                            }
                        }
                        Text("Linked captures stay local and are not attached to messages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chat.details.done") }
        }
        .padding(20).frame(width: 570, height: 500)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .aitvarasCaptureRecordsChanged).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() {
        do {
            guard let stores = model.stores else { throw WorkspacePolicyError.invalidPolicy }
            packet = try stores.workspaceContextPacket(chatID: chatID)
            fileReadEnabled = try packet.map { try stores.workspacePolicy(projectID: $0.projectID)?.allowsFileAccess == true } ?? false
            captures = try stores.workspaceCaptures(chatID: chatID)
            error = nil
        } catch {
            packet = nil; captures = []
            self.error = "Chat details could not be loaded. Try Refresh."
        }
    }
}

struct WorkspaceBoundaryReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    var onDone: (() -> Void)? = nil
    @State private var review: WorkspacePolicyReview?
    @State private var policyRevision: Int?
    @State private var title = ""
    @State private var originalTitle = ""
    @State private var instructions = ""
    @State private var folderDrafts: [WorkspaceFolderDraft] = []
    @State private var allowClaude = false
    @State private var allowCodex = false
    @State private var allowCodexFileRead = false
    @State private var allowClaudeFileRead = false
    @State private var message: String?
    @State private var settingsTab = "general"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project settings").font(.title2.weight(.semibold))
            Picker("Project settings", selection: $settingsTab) {
                Text("General").tag("general")
                Text("Codex link").tag("codex")
            }.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if settingsTab == "codex" {
                        CodexProjectLinkView(projectID: projectID)
                    } else if review != nil {
                        TextField("Project name", text: $title).textFieldStyle(.roundedBorder)
                        GroupBox("Instructions") {
                            TextEditor(text: $instructions).font(.body).frame(height: 100).padding(4)
                        }
                        GroupBox("Folders") {
                            VStack(alignment: .leading, spacing: 10) {
                                if folderDrafts.isEmpty { Text("No folders registered").foregroundStyle(.secondary) }
                                ForEach(Array(folderDrafts.enumerated()), id: \.offset) { index, folder in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(folder.path).textSelection(.enabled)
                                            Text("Read-only when enabled for a provider")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Remove", systemImage: "minus.circle") {
                                            folderDrafts.remove(at: index)
                                        }.labelStyle(.iconOnly)
                                    }
                                }
                                HStack {
                                    Button("Add folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                                }
                                Text("Only these folders can be shared. Hidden files, common key files and links are excluded.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                        GroupBox("AI providers") {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Local model · available, text only", systemImage: "desktopcomputer")
                                Toggle("Codex", isOn: $allowCodex)
                                    .toggleStyle(.switch).controlSize(.small)
                                Toggle("Read project files", isOn: $allowCodexFileRead)
                                    .toggleStyle(.switch).controlSize(.small)
                                    .disabled(!allowCodex || folderDrafts.isEmpty)
                                Text("When enabled, Codex can request text from these folders and send it to OpenAI after you press Send. No writes or shell access. Captures and imported chats stay excluded.")
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("Data sent to Codex") {
                                    Text("Project/chat names, instructions, chat purpose, your message, recent messages created in this chat and Codex runtime metadata. Switching from Local asks before sharing history; nothing is sent until you press Send.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.font(.caption)
                                Divider()
                                Toggle("Claude", isOn: $allowClaude)
                                    .toggleStyle(.switch).controlSize(.small)
                                Toggle("Read project files", isOn: $allowClaudeFileRead)
                                    .toggleStyle(.switch).controlSize(.small)
                                    .disabled(!allowClaude || folderDrafts.isEmpty)
                                Text("Approved file excerpts go to Anthropic only during a message you send. No writes or shell access.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Choose a provider in the chat. Nothing starts automatically when you save these settings.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if settingsTab == "general" { Button("Reload", action: reload) }
                Spacer()
                Button(settingsTab == "general" ? "Cancel" : "Done", action: finish).keyboardShortcut(.cancelAction)
                if settingsTab == "general" {
                    Button("Save", action: saveReview).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(review == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorkspaceSelectionBusy)
                }
            }
        }.padding(24).frame(width: 620, height: 620)
        .task { reload() }
        .onChange(of: folderDrafts.isEmpty) { if folderDrafts.isEmpty { allowCodexFileRead = false; allowClaudeFileRead = false } }
        .onChange(of: allowCodex) { if !allowCodex { allowCodexFileRead = false } }
        .onChange(of: allowClaude) { if !allowClaude { allowClaudeFileRead = false } }
    }

    private func reload() {
        do {
            guard let stores = model.stores else { throw WorkspacePolicyError.invalidPolicy }
            let snapshot = try stores.workspacePolicyReview(projectID: projectID)
            let policy = try stores.workspacePolicy(projectID: projectID)
            guard let project = try stores.workspaceProject(id: projectID) else { throw WorkspacePolicyError.invalidPolicy }
            review = snapshot
            policyRevision = policy?.revision
            title = project.title; originalTitle = project.title; instructions = project.instructions
            folderDrafts = snapshot.folders.map { .init(path: $0.path, access: $0.access) }
            allowClaude = policy?.allowedProviders.contains(.claude) == true
            allowCodex = policy?.allowedProviders.contains(.codex) == true
            allowCodexFileRead = policy?.allowsFileAccess == true
            allowClaudeFileRead = policy?.allowsClaudeFileAccess == true
            message = policy?.status == .stale ? "Project settings changed. Save this version to use your selected providers." : nil
        } catch {
            review = nil
            message = "Project settings could not be loaded. Try Reload."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Register"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if !folderDrafts.contains(where: { $0.path == path }) { folderDrafts.append(.init(path: path)) }
            }
        }
    }

    private func finish() { if let onDone { onDone() } else { dismiss() } }

    private func saveReview() {
        guard !model.isWorkspaceSelectionBusy, let review, let stores = model.stores else { return }
        let id = model.activityReporter?.begin(ActivityRun(referenceID: projectID.uuidString, category: .system,
            title: "Save project settings", stage: "Saving instructions, folders and providers",
            executionLocation: "This Mac", dataAccess: "User-reviewed project metadata",
            dataDestination: "Local settings; no immediate file read or provider execution"))
        do {
            var providers: [WorkspaceSessionProvider] = [.local]
            if allowClaude { providers.append(.claude) }
            if allowCodex { providers.append(.codex) }
            _ = try stores.saveWorkspaceProjectSettings(projectID: projectID, title: title, instructions: instructions,
                folders: folderDrafts, allowedProviders: providers, expectedContextRevision: review.revision,
                expectedPolicyRevision: policyRevision, expectedProjectTitle: originalTitle,
                allowCodexFileRead: allowCodex && allowCodexFileRead,
                allowClaudeFileRead: allowClaude && allowClaudeFileRead)
            if let id { model.activityReporter?.finish(id: id, state: .succeeded, outcome: "Project provider and read-only file settings saved") }
            model.refreshWorkspaces()
            NotificationCenter.default.post(name: .init("aitvaras.projectSettingsSaved"), object: projectID)
            finish()
        } catch {
            if let id { model.activityReporter?.finish(id: id, state: .failed, outcome: "Boundary review not saved; reload current project metadata") }
            message = "Settings were not saved. The project may have changed elsewhere. Reload and try again."
        }
    }
}
