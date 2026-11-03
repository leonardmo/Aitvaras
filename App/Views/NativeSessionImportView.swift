import SwiftUI
import AitvarasCore
import AitvarasStore

/// Discovery and text retention are explicit user actions, never launch tasks.
struct NativeSessionImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var kind: WorkspaceChat.Kind = .primary
    @State private var reviewedRevision: UUID?
    @State private var reviewedProjectID: UUID?

    private var native: NativeWorkspaceModel { model.nativeWorkspace }
    private var projects: [WorkspaceProject] { model.workspaceProjects.filter(\.isVisible) }
    private var canImport: Bool {
        reviewedRevision == native.previewRevision && reviewedProjectID == projectID
            && projectID.map { id in projects.contains { $0.id == id } } == true
            && !native.isBusy && !model.isWorkspaceSelectionBusy
            && native.previewSession?.provider == native.provider && !native.previewMessages.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import native chats").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { native.cancelBrowserOperation(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Preview one native chat, then choose where its loaded text will be saved. Native clients and local chats stay separate.")
                .foregroundStyle(.secondary)
            discoveryControls
            NativeImportStatusView()
            Divider()
            HStack(alignment: .top, spacing: 16) {
                sessionList.frame(width: 270)
                Divider()
                preview.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            destination
        }
        .padding(22)
        .frame(minWidth: 820, idealWidth: 920, minHeight: 650, idealHeight: 780)
        .onAppear {
            if projects.contains(where: { $0.id == model.selectedWorkspaceProjectID }) {
                projectID = model.selectedWorkspaceProjectID
            }
        }
        .onChange(of: native.provider) { reviewedRevision = nil }
        .onChange(of: native.previewRevision) { reviewedRevision = nil }
        .onChange(of: projectID) { reviewedRevision = nil; reviewedProjectID = nil }
        .onChange(of: kind) { reviewedRevision = nil; reviewedProjectID = nil }
        .onDisappear { native.cancelBrowserOperation() }
    }

    private var discoveryControls: some View {
        @Bindable var settings = native
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(NativeSessionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }.frame(width: 220)
                Button("Check setup") { Task { await native.checkCapabilities() } }
                Button("List chats") { Task { await native.loadSessions() } }
                if native.provider == .codex {
                    Toggle("Archived", isOn: $settings.archived).toggleStyle(.checkbox)
                }
                Spacer()
                if native.isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(native.isBusy)
            ForEach(native.capabilities.filter { $0.provider == native.provider }, id: \.provider) { capability in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(capability.provider.displayName): \(capabilityLabel(capability.state))\(capability.version.map { " · \($0)" } ?? "")")
                        .font(.caption.weight(.semibold))
                    Text(capability.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if capability.provider == .claude && capability.state == .missingSDK {
                        Text("Downloads the pinned official SDK from the npm registry. No chat text or recordings are sent.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Set up official Claude Code SDK…") { Task { await native.installClaudeSDK() } }
                            .disabled(native.isBusy)
                    }
                }
            }
            Text("Checks and history reads run only when you click. Claude web/cloud history is not supported. Native folders are grouping labels, not saved Aitvaras projects or folder permissions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Native chats").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if native.sessions.isEmpty {
                        Text("Click List chats to discover supported local history. Nothing is imported automatically.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(native.sessions) { session in
                        Button {
                            reviewedRevision = nil
                            Task { await native.preview(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.title).font(.callout.weight(.medium)).lineLimit(2)
                                if let directory = session.directory {
                                    Text("Native folder group: \(directory)")
                                        .lineLimit(2).truncationMode(.middle)
                                }
                                Text("\(session.hostID) · \(session.externalID)")
                                    .lineLimit(1).truncationMode(.middle)
                                if session.parentExternalID != nil { Text(parentLabel(session.parentRelationship?.rawValue)) }
                                if let updatedAt = session.updatedAt {
                                    Text("Updated \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                }
                                Text(session.activity)
                                Label("Preview text", systemImage: "eye")
                            }
                            .font(.caption).foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(native.previewSession?.id == session.id ? 0.12 : 0.035), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).disabled(native.isBusy)
                    }
                    if native.sessionNextCursor != nil {
                        Button("Load more chats") { Task { await native.loadSessions(reset: false) } }
                            .disabled(native.isBusy)
                    }
                }
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let session = native.previewSession {
                Text(session.title).font(.headline).textSelection(.enabled)
                Text("\(session.provider.displayName) · \(session.hostID) · \(session.externalID)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let parent = session.parentExternalID {
                    Text("\(parentLabel(session.parentRelationship?.rawValue)): \(parent)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(native.previewCoverage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(native.previewMessages.count) loaded text messages · Preview only")
                    .font(.caption.weight(.medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if native.previewMessages.isEmpty {
                            Text("No supported user or assistant text is loaded. This chat cannot be imported yet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(native.previewMessages) { message in
                            NativeTranscriptTextView(role: message.role.rawValue, text: message.text)
                        }
                        if native.previewNextCursor != nil {
                            Button("Load more preview text") {
                                reviewedRevision = nil
                                Task { await native.loadMorePreview() }
                            }.disabled(native.isBusy)
                        }
                    }.padding(.trailing, 8)
                }
            } else {
                ContentUnavailableView("Choose a chat to preview", systemImage: "text.bubble", description: Text("Previewing does not import it or grant permission to run an agent."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Picker("Save in project", selection: $projectID) {
                    Text("Choose a project…").tag(Optional<UUID>.none)
                    ForEach(projects) { project in Text(project.title).tag(Optional(project.id)) }
                }.frame(maxWidth: 360)
                Picker("Chat kind", selection: $kind) {
                    Text("Primary").tag(WorkspaceChat.Kind.primary)
                    Text("Temporary").tag(WorkspaceChat.Kind.temporary)
                }.frame(width: 210)
                Spacer()
            }
            if projects.isEmpty {
                Text("Create a project in the workspace first, then return here. There are no visible projects to choose.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("You choose the destination each time. Several native folder groups can go into the same existing project; titles never determine the mapping.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I reviewed the loaded text and agree to store these messages locally in this project.", isOn: Binding(
                get: { reviewedRevision == native.previewRevision && reviewedProjectID == projectID },
                set: {
                    reviewedRevision = $0 ? native.previewRevision : nil
                    reviewedProjectID = $0 ? projectID : nil
                }))
                .toggleStyle(.checkbox)
                .disabled(native.previewSession == nil || native.previewMessages.isEmpty || native.isBusy)
            HStack(alignment: .center, spacing: 16) {
                Text("Only loaded text is saved. No folder, tool, cloud, automatic refresh, native rename, resume or control permission is granted.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import loaded text") {
                    guard let projectID, reviewedProjectID == projectID, let reviewedRevision else { return }
                    if model.importPreviewedNativeSession(projectID: projectID, kind: kind, reviewedRevision: reviewedRevision) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(!canImport)
            }
            if let message = model.workspaceMessage {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private func capabilityLabel(_ state: NativeSessionCapability.State) -> String {
        switch state {
        case .ready: "Ready for supported history"
        case .missingRuntime: "Native app runtime not found"
        case .missingSDK: "SDK setup needed"
        case .unsupported: "Not supported"
        case .unavailable: "Unavailable"
        }
    }
}

private struct NativeImportStatusView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let status = model.nativeWorkspace.status {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = model.nativeWorkspace.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.nativeWorkspace.isBusy {
                Button(model.nativeWorkspace.isCancelling ? "Stopping safely…" : "Stop native history operation", systemImage: "stop.circle") {
                    model.nativeWorkspace.operations.cancelActive()
                }
                .disabled(model.nativeWorkspace.isCancelling)
                .font(.caption)
            }
        }
    }
}

struct NativeSessionSourceView: View {
    @Environment(AppModel.self) private var model
    let link: WorkspaceSessionLink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(link.displayName).font(.headline).textSelection(.enabled)
                    Spacer()
                    Button("Refresh complete history", systemImage: "arrow.clockwise") {
                        Task { await model.refreshNativeSession(linkID: link.id, loadMore: false) }
                    }.disabled(model.nativeWorkspace.isBusy)
                }
                Text("\(link.provider == .codex ? "Codex" : "Claude Code") · \(link.hostID) · \(link.externalID)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Imported snapshots are read-only and separate from Local chat. They are not fed into its model yet. A complete refresh reads all currently available text pages and saves only after verification. Failed or cancelled refreshes keep the previous snapshot. Show more saved text only displays text already on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let snapshot = model.nativeSnapshot(linkID: link.id) {
                    if let complete = snapshot.lastCompleteRefreshAt {
                        Text("Complete history checked: \(complete.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                    } else {
                        Text("No verified complete refresh yet · selected pages saved locally").font(.caption)
                    }
                    Text("Last saved page check: \(snapshot.lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(snapshot.coverage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let directory = snapshot.directory {
                        Text("Native folder group: \(directory)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let parent = snapshot.parentExternalID {
                        Text("\(parentLabel(snapshot.parentRelationship)): \(parent)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    Text("No saved text snapshot yet. Refresh to read this source.").font(.caption).foregroundStyle(.secondary)
                }
                NativeImportStatusView()
                if let message = model.workspaceMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }.padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    let messages = model.nativeMessages(linkID: link.id)
                    if messages.isEmpty {
                        Text("No supported text is saved for this source.").foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        NativeTranscriptTextView(role: String(describing: message.role), text: message.text)
                    }
                    if model.nativeHasMoreSavedMessages(linkID: link.id) {
                        Button("Show more saved text") {
                            model.loadMoreSavedNativeMessages(linkID: link.id)
                        }
                        .help("Show another page already saved on this Mac. Does not read the native provider.")
                    }
                    if model.nativeSnapshot(linkID: link.id)?.nextCursor != nil {
                        Button("Read and save more source text") {
                            Task { await model.refreshNativeSession(linkID: link.id, loadMore: true) }
                        }.disabled(model.nativeWorkspace.isBusy)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.background)
        .navigationTitle(link.displayName)
    }
}

private func parentLabel(_ relationship: String?) -> String {
    switch relationship {
    case "fork": "Fork parent"
    case "spawn": "Spawned by chat"
    default: "Parent reference · relationship unverified"
    }
}

private struct NativeTranscriptTextView: View {
    let role: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(role.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
