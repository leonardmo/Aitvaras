import AppKit
import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasAgent
import AitvarasAgents

/// Manual, event-driven inspection. Nothing here reads project files, calls a
/// provider, or attaches saved evidence to a model prompt.
struct WorkspaceInspectorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let chatID: UUID
    var provider: AgentProvider = .local
    @State private var packet: WorkspaceContextPacket?
    @State private var captures: [CaptureRecord] = []
    @State private var error: String?
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
                        LabeledContent("Provider", value: provider.rawValue.capitalized)
                        LabeledContent("Destination", value: provider == .local ? "This Mac" : "Selected provider, when you send")
                        LabeledContent("History", value: "Messages created in this chat")
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
                            Text("Imported chats, linked captures, other chats and shared memories are not attached. Local is text-only; provider tools follow the selected mode.")
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
    var section: ProjectSettingsSection = .general
    var embedded = false
    var navigationRevision: UUID? = nil
    var hasUnsavedChanges: (Bool) -> Void = { _ in }

    private struct Draft: Equatable {
        var title = ""
        var instructions = ""
        var folders: [WorkspaceFolderDraft] = []
        var allowClaude = false
        var allowCodex = false
        var allowCodexFileRead = false
        var allowClaudeFileRead = false
    }

    @State private var review: WorkspacePolicyReview?
    @State private var policyRevision: Int?
    @State private var draft = Draft()
    @State private var savedDraft: Draft?
    @State private var message: String?
    @State private var failed = false

    private struct ScrollTarget: Equatable {
        let revision: UUID?
        let section: ProjectSettingsSection
        let ready: Bool
    }
    private var scrollTarget: ScrollTarget {
        .init(revision: navigationRevision, section: section, ready: review != nil)
    }

    private var project: WorkspaceProject? { model.workspaceProjects.first { $0.id == projectID } }
    private var changed: Bool { savedDraft.map { $0 != draft } ?? false }
    private var directory: URL? {
        savedDraft?.folders.first.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !embedded {
                Text("Project settings").font(.title2.weight(.semibold)).padding()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 19) {
                        if review != nil {
                            sectionCard(.general, icon: "slider.horizontal.3") { generalSettings }.id(ProjectSettingsSection.general)
                            sectionCard(.folders, icon: "folder") { folderSettings }.id(ProjectSettingsSection.folders)
                        }
                        sectionCard(.servers, icon: "point.3.connected.trianglepath.dotted") {
                            ProjectMCPSettingsView(projectID: projectID, directory: directory)
                        }.id(ProjectSettingsSection.servers)
                        sectionCard(.agent, icon: "terminal") {
                            AgentSetupSection(projectID: projectID, directory: directory, showsServerDefinitions: false)
                        }.settingsAnchor("project.agentSetup").id(ProjectSettingsSection.agent)
                        sectionCard(.codex, icon: "link") {
                            CodexProjectLinkView(projectID: projectID, showsConnection: false)
                                .id(savedDraft?.folders.map(\.path))
                            Button("Provider settings", systemImage: "arrow.up.right") { SettingsNavigation.open(.page(.providers)) }
                        }.settingsAnchor("project.codexLink").id(ProjectSettingsSection.codex)
                        sectionCard(.gateway, icon: "wrench.and.screwdriver") {
                            WorkspaceGatewayToolScopesView(projectID: projectID)
                        }.settingsAnchor("project.gatewayTools").id(ProjectSettingsSection.gateway)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(20)
                }
                .task(id: scrollTarget) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(section, anchor: .top)
                    if let id = SettingsNavigation.shared.highlightedID {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            Divider()
            HStack {
                if let message {
                    Label(message, systemImage: failed ? "exclamationmark.circle" : "info.circle")
                        .font(.callout).foregroundStyle(failed ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("workspace.settings.message")
                }
                Spacer()
                if failed || review == nil { Button("Reload", action: reload) }
                else if changed { Button("Discard edits", action: reload) }
                if !embedded { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button("Save", action: saveReview)
                    .buttonStyle(.borderedProminent)
                    .disabled(review == nil || (!changed && !failed) ||
                              draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorkspaceSelectionBusy)
                    .accessibilityIdentifier("workspace.settings.save")
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(minWidth: embedded ? 0 : 620, minHeight: embedded ? 0 : 620)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.settings")
        .task { reload() }
        .onChange(of: changed, initial: true) { _, value in hasUnsavedChanges(value) }
        .onChange(of: draft.folders.isEmpty) {
            if draft.folders.isEmpty {
                draft.allowCodexFileRead = false
                draft.allowClaudeFileRead = false
            }
        }
        .onChange(of: draft.allowCodex) { if !draft.allowCodex { draft.allowCodexFileRead = false } }
        .onChange(of: draft.allowClaude) { if !draft.allowClaude { draft.allowClaudeFileRead = false } }
    }

    private func sectionCard<Content: View>(_ section: ProjectSettingsSection, icon: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(section.title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.settings.\(section.rawValue)")
    }

    @ViewBuilder private var generalSettings: some View {
        TextField("Project name", text: $draft.title)
            .textFieldStyle(.roundedBorder)
            .settingsAnchor("project.name")
        LabeledContent("Instructions") {
            TextEditor(text: $draft.instructions)
                .font(.body)
                .frame(height: 80)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
        .settingsAnchor("project.instructions")
        if let project {
            Toggle("Show in Chat sidebar", isOn: Binding(get: { project.isVisible }, set: { visible in
                var updated = project
                updated.isVisible = visible
                model.updateWorkspaceProject(updated)
            }))
            .settingsAnchor("project.visibility")
            .disabled(model.isWorkspaceSelectionBusy)
            Toggle("Default project for new chats", isOn: Binding(get: { model.defaultChatProjectID == projectID },
                set: { model.setDefaultChatProject($0 ? projectID : nil) }))
            .settingsAnchor("project.default")
            .disabled(!project.isVisible)
            Text("Sidebar and default-project settings take effect immediately.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var folderSettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            if draft.folders.isEmpty {
                Text("No folders registered").foregroundStyle(.secondary)
            }
            ForEach(Array(draft.folders.enumerated()), id: \.element.path) { index, folder in
                HStack {
                    Label(folder.path, systemImage: "folder")
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Remove folder", systemImage: "minus.circle") {
                        draft.folders.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove this folder from the project")
                    .accessibilityLabel("Remove \(URL(fileURLWithPath: folder.path).lastPathComponent)")
                    .accessibilityIdentifier("workspace.settings.folder.remove.\(index)")
                }
            }
            Button("Add folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                .accessibilityIdentifier("workspace.settings.folder.add")
            Text("Folder changes apply to new chats and future turns. A running turn keeps its working folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .settingsAnchor("project.folders")

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Provider access").font(.callout.weight(.semibold))
                SettingsHint("A provider can request read-only excerpts from approved folders after you send a message. Hidden files, common key files and links are excluded. These switches never grant writes or shell access.")
            }
            Toggle("Enable Codex", isOn: $draft.allowCodex).toggleStyle(.switch).controlSize(.small)
            Toggle("Codex can read project files", isOn: $draft.allowCodexFileRead)
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!draft.allowCodex || draft.folders.isEmpty)
            Toggle("Enable Claude", isOn: $draft.allowClaude).toggleStyle(.switch).controlSize(.small)
            Toggle("Claude can read project files", isOn: $draft.allowClaudeFileRead)
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!draft.allowClaude || draft.folders.isEmpty)
        }
        .settingsAnchor("project.folderAccess")
    }

    private func reload() {
        do {
            guard let stores = model.stores else { throw WorkspacePolicyError.invalidPolicy }
            let snapshot = try stores.workspacePolicyReview(projectID: projectID)
            let policy = try stores.workspacePolicy(projectID: projectID)
            guard let project = try stores.workspaceProject(id: projectID) else { throw WorkspacePolicyError.invalidPolicy }
            review = snapshot
            policyRevision = policy?.revision
            draft = Draft(title: project.title, instructions: project.instructions,
                          folders: snapshot.folders.map { .init(path: $0.path, access: $0.access) },
                          allowClaude: policy?.allowedProviders.contains(.claude) == true,
                          allowCodex: policy?.allowedProviders.contains(.codex) == true,
                          allowCodexFileRead: policy?.allowsFileAccess == true,
                          allowClaudeFileRead: policy?.allowsClaudeFileAccess == true)
            savedDraft = draft
            failed = policy?.status == .stale
            message = failed ? "Project settings changed. Save this version to use your selected providers." : nil
        } catch {
            review = nil
            failed = true
            message = "Project settings could not be loaded. Try Reload."
        }
    }

    private func chooseFolder() {
        #if DEBUG
        if SelfDriver.requested, AitvarasPaths.isIsolated,
           let project = ProcessInfo.processInfo.environment["AITVARAS_SELF_DRIVE_PROJECT"],
           ProcessInfo.processInfo.environment["AITVARAS_SELF_DRIVE_FOLDERS"] == "1" {
            let folder = URL(fileURLWithPath: project, isDirectory: true).appendingPathComponent("sample-folder", isDirectory: true)
            if (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                registerFolders([folder])
            }
            return
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Register"
        if panel.runModal() == .OK { registerFolders(panel.urls) }
    }

    private func registerFolders(_ urls: [URL]) {
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if !draft.folders.contains(where: { $0.path == path }) { draft.folders.append(.init(path: path)) }
        }
    }

    private func saveReview() {
        guard !model.isWorkspaceSelectionBusy, let review, let savedDraft, let stores = model.stores else { return }
        let id = model.activityReporter?.begin(ActivityRun(referenceID: projectID.uuidString, category: .system,
            title: "Save project settings", stage: "Saving instructions, folders and providers",
            executionLocation: "This Mac", dataAccess: "User-reviewed project metadata",
            dataDestination: "Local settings; no immediate file read or provider execution"))
        do {
            var providers: [WorkspaceSessionProvider] = [.local]
            if draft.allowClaude { providers.append(.claude) }
            if draft.allowCodex { providers.append(.codex) }
            _ = try stores.saveWorkspaceProjectSettings(projectID: projectID, title: draft.title, instructions: draft.instructions,
                folders: draft.folders, allowedProviders: providers, expectedContextRevision: review.revision,
                expectedPolicyRevision: policyRevision, expectedProjectTitle: savedDraft.title,
                allowCodexFileRead: draft.allowCodex && draft.allowCodexFileRead,
                allowClaudeFileRead: draft.allowClaude && draft.allowClaudeFileRead)
            if let id { model.activityReporter?.finish(id: id, state: .succeeded, outcome: "Project provider and read-only file settings saved") }
            model.chatModel?.refreshResourceScope(projectID: projectID)
            model.refreshWorkspaces()
            NotificationCenter.default.post(name: .init("aitvaras.projectSettingsSaved"), object: projectID)
            reload()
            if review != nil, !failed { message = "Project settings saved." }
        } catch {
            if let id { model.activityReporter?.finish(id: id, state: .failed, outcome: "Boundary review not saved; reload current project metadata") }
            failed = true
            message = "Settings were not saved. Reload before trying again."
        }
    }
}

private struct WorkspaceGatewayToolScopesView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var saved: GatewayToolScopeSettings?
    @State private var scopes: Set<GatewayToolScope> = []
    @State private var knowledgeSources: [KnowledgeSourceConfiguration] = []
    @State private var linkedSourceIDs: Set<String> = []
    @State private var message: String?

    var body: some View {
        GroupBox("Aitvaras tools") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Allow agents launched for this project to use your Aitvaras profile tools. The provider can receive tool results. Knowledge uses the sources you link below, and gateway activity stays within this project.")
                    .font(.callout)
                ForEach(GatewayToolScope.allCases.filter { $0 != .settings }) { scope in
                    Toggle(scope == .mail ? "Mail (read only)" : scope.rawValue.capitalized,
                           isOn: Binding(get: { scopes.contains(scope) }, set: { enabled in
                        if enabled { scopes.insert(scope) } else { scopes.remove(scope) }
                    }))
                    .disabled(saved == nil)
                    .accessibilityIdentifier("workspace.gateway.scope.\(scope.rawValue)")
                }
                if scopes.contains(.knowledge) {
                    Text("Linked Knowledge sources").font(.headline)
                    if knowledgeSources.isEmpty {
                        Text("Add a source in Knowledge first.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(knowledgeSources) { source in
                        Toggle(source.name, isOn: Binding(get: { linkedSourceIDs.contains(source.id) }, set: { enabled in
                            if enabled { linkedSourceIDs.insert(source.id) } else { linkedSourceIDs.remove(source.id) }
                        }))
                        .help(source.path)
                    }
                }
                HStack {
                    Button("Reload", action: reload)
                    Spacer()
                    Button("Save tool access", action: save)
                        .disabled(saved == nil || (saved?.scopes == scopes && saved?.knowledgeSourceIDs == linkedSourceIDs))
                        .accessibilityIdentifier("workspace.gateway.save")
                }
                if let message { Text(message).font(.callout) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .task(id: projectID) { reload() }
    }

    private func reload() {
        do {
            guard let stores = model.stores else { throw WorkspacePolicyError.invalidPolicy }
            let settings = try stores.gatewayToolScopeSettings(projectID: projectID)
            let sources = try stores.configuredKnowledgeSources()
            saved = settings
            scopes = settings.scopes
            knowledgeSources = sources
            linkedSourceIDs = settings.knowledgeSourceIDs.intersection(sources.map(\.id))
            message = nil
        } catch {
            saved = nil
            scopes = []
            knowledgeSources = []
            linkedSourceIDs = []
            message = "Tool access could not be loaded. Try Reload."
        }
    }

    private func save() {
        guard let stores = model.stores, let saved else { return }
        do {
            self.saved = try stores.saveGatewayToolScopes(projectID: projectID, scopes: scopes, expectedRevision: saved.revision,
                                                          knowledgeSourceIDs: linkedSourceIDs)
            message = "Tool access saved."
        } catch {
            message = "Tool access could not be saved. Reload and try again."
        }
    }
}
