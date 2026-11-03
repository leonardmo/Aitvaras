import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

/// A single-level project settings page. Discovery is an explicit, read-only
/// action; linking records a relationship, never a native permission grant.
struct CodexProjectLinkView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    var showsConnection = true
    var onLinked: (() -> Void)? = nil
    @State private var projects: [NativeProjectSnapshot] = []
    @State private var selection: NativeProjectIdentity?
    @State private var selectedSnapshot: NativeProjectSnapshot?
    @State private var link: WorkspaceCodexProjectLink?
    @State private var localFolders: [WorkspaceFolder] = []
    @State private var localRootReviews: [WorkspaceCodexRootReview] = []
    @State private var selectedRootReviews: [WorkspaceCodexRootReview] = []
    @State private var nextCursor: String?
    @State private var didLoad = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var reader = CodexSessionReader()

    private var busy: Bool { model.nativeWorkspace.isBusy }
    private var selected: NativeProjectSnapshot? { selectedSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(linkTitle, systemImage: link?.state == .linked ? "link.circle.fill" : "link")
                            .font(.headline)
                        Spacer()
                        if let link {
                            Button("Unlink") { unlink(link) }.disabled(busy)
                        }
                    }
                    if let link {
                        Text(link.approvedSnapshot.name).font(.callout.weight(.medium))
                        Label("Link chats in AI Settings → Codex", systemImage: "bubble.left.and.bubble.right")
                            .font(.caption).foregroundStyle(.secondary)
                        if link.approvedSnapshot.identity.profileNamespace != reader.profileNamespace {
                            Label("This link belongs to a different Codex profile", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(Array(link.observedRoots.enumerated()), id: \.offset) { _, root in
                            Label(root.path, systemImage: root.availability == .available ? "folder" : "folder.badge.questionmark")
                                .font(.caption).textSelection(.enabled)
                        }
                    } else {
                        Text("Use the same project in Aitvaras and Codex.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            GroupBox("Codex project") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button(didLoad ? "Refresh projects" : "Browse Codex projects", systemImage: "arrow.clockwise") {
                            start { await loadProjects(reset: true) }
                        }.disabled(busy)
                        if busy {
                            ProgressView().controlSize(.small)
                            Spacer()
                            Button("Stop") { task?.cancel() }
                        }
                    }
                    if didLoad && projects.isEmpty {
                        ContentUnavailableView("No Codex projects found", systemImage: "folder",
                            description: Text("Create a project in Codex, then refresh."))
                            .frame(height: 125)
                    }
                    if !projects.isEmpty {
                        Picker("Project", selection: $selection) {
                            Text("Choose a project").tag(Optional<NativeProjectIdentity>.none)
                            ForEach(projects) { project in
                                Text(project.name).tag(Optional(project.identity))
                            }
                        }
                        .disabled(busy)
                        .onChange(of: selection) { _, value in
                            selectedSnapshot = nil; selectedRootReviews = []
                            if let value { start { await readProject(value) } }
                        }
                    }
                    if nextCursor != nil {
                        Button("Load more") { start { await loadProjects(reset: false) } }.disabled(busy)
                    }
                    if let selected {
                        rootComparison(selected)
                        Button(link == nil ? "Link project" : "Save reviewed link") { start { await save(selected) } }
                            .buttonStyle(.borderedProminent).disabled(busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }

            if showsConnection { CodexNativeConnectionSection() }
            if let message {
                Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-project-link-message")
            }
        }
        .task { await reloadSaved() }
        .onDisappear { task?.cancel() }
    }

    private var linkTitle: String {
        guard let link else { return "Not linked" }
        if link.approvedSnapshot.identity.profileNamespace != reader.profileNamespace { return "Different Codex profile" }
        switch link.state {
        case .linked: return "Project linked"
        case .conflict: return "Project changed · review folders"
        case .reviewRequired: return "Folders need review"
        }
    }

    private func rootComparison(_ project: NativeProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex folders", systemImage: "folder").font(.callout.weight(.semibold))
            ForEach(Array(selectedRootReviews.enumerated()), id: \.offset) { _, root in
                HStack {
                    Label(root.path, systemImage: root.availability != .available ? "exclamationmark.triangle" : matchesLocal(root) ? "checkmark.circle" : "folder.badge.plus")
                        .textSelection(.enabled)
                    Spacer()
                    if root.availability != .available { Text("Unavailable").foregroundStyle(.orange) }
                }.font(.caption)
            }
            let extra = localRootReviews.filter { local in !selectedRootReviews.contains { sameFolder(local, $0) } }
            if !extra.isEmpty {
                DisclosureGroup("\(extra.count) Aitvaras-only folder\(extra.count == 1 ? "" : "s")") {
                    ForEach(Array(extra.enumerated()), id: \.offset) { _, folder in Text(folder.path).font(.caption).textSelection(.enabled) }
                }.font(.caption)
            }
            Text("Folders are unchanged. Each chat's working folder and permissions are reviewed in AI Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }

    private func sameFolder(_ lhs: WorkspaceCodexRootReview, _ rhs: WorkspaceCodexRootReview) -> Bool {
        lhs.availability == .available && rhs.availability == .available && lhs.canonicalPath == rhs.canonicalPath
            && lhs.filesystemIdentity != nil && lhs.filesystemIdentity == rhs.filesystemIdentity
    }

    private func matchesLocal(_ root: WorkspaceCodexRootReview) -> Bool {
        localRootReviews.contains { sameFolder($0, root) }
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !busy else { return }
        task?.cancel()
        task = Task { @MainActor in await operation() }
    }

    private func reloadSaved() async {
        do {
            guard let stores = model.stores else { return }
            link = try stores.workspaceCodexProjectLink(projectID: projectID)
            localFolders = try stores.workspaceFolders(projectID: projectID)
            let local = NativeProjectSnapshot(identity: .init(provider: .codex, profileNamespace: reader.profileNamespace,
                externalID: "local-comparison"), name: "Local comparison", roots: localFolders.map { .init(path: $0.path) })
            localRootReviews = await Task.detached(priority: .utility) { Stores.workspaceCodexRootReviews(for: local) }.value
            if let existing = link, existing.approvedSnapshot.identity.profileNamespace != reader.profileNamespace,
               existing.state != .reviewRequired {
                link = try stores.invalidateWorkspaceCodexProject(linkID: existing.id, expectedRevision: existing.revision)
            } else if let existing = link, existing.approvedSnapshot.identity.profileNamespace == reader.profileNamespace {
                let observed = existing.observedSnapshot
                let roots = await Task.detached(priority: .utility) { Stores.workspaceCodexRootReviews(for: observed) }.value
                try Task.checkCancellation()
                link = try stores.observeWorkspaceCodexProject(linkID: existing.id, snapshot: observed,
                    observedRoots: roots, expectedRevision: existing.revision)
            }
        } catch { message = "Saved project link could not be loaded. Nothing was changed." }
    }

    private func loadProjects(reset: Bool) async {
        let cursor = reset ? nil : nextCursor
        guard reset || cursor != nil else { return }
        do {
            try await model.nativeWorkspace.operations.run(title: "Browse Codex projects", provider: .codex,
                referenceID: projectID.uuidString, dataAccess: "Native project names and folder metadata",
                dataDestination: "Local project settings; no model invocation") {
                let page = try await reader.listProjects(cursor: cursor)
                try Task.checkCancellation()
                if reset { projects = []; selection = nil; selectedSnapshot = nil; selectedRootReviews = [] }
                let seen = Set(projects.map(\.identity))
                projects += page.projects.filter { !seen.contains($0.identity) }
                nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
                didLoad = true
                message = nil
            }
        } catch is CancellationError { message = "Project discovery stopped." }
        catch { message = "Codex projects could not be read. Check that Codex is installed, then retry." }
    }

    private func readProject(_ identity: NativeProjectIdentity) async {
        do {
            try await model.nativeWorkspace.operations.run(title: "Inspect Codex project", provider: .codex,
                referenceID: projectID.uuidString, dataAccess: "Selected native project folder metadata",
                dataDestination: "Local project comparison; no model invocation") {
                let snapshot = try await reader.readProject(id: identity.externalID)
                let roots = await Task.detached(priority: .utility) { Stores.workspaceCodexRootReviews(for: snapshot) }.value
                try Task.checkCancellation()
                guard snapshot.identity == identity, selection == identity else { return }
                selectedSnapshot = snapshot
                selectedRootReviews = roots
                if let existing = link, existing.approvedSnapshot.identity == snapshot.identity, let stores = model.stores {
                    link = try stores.observeWorkspaceCodexProject(linkID: existing.id, snapshot: snapshot,
                        observedRoots: roots, expectedRevision: existing.revision)
                }
                message = nil
            }
        } catch is CancellationError { message = "Project inspection stopped." }
        catch { message = "This Codex project could not be read. Refresh projects and try again." }
    }

    private func save(_ snapshot: NativeProjectSnapshot) async {
        guard !busy, let stores = model.stores else { return }
        if let link, link.approvedSnapshot.identity != snapshot.identity {
            message = "Unlink the current project before choosing another. Native projects are never deleted."
            return
        }
        do {
            try await model.nativeWorkspace.operations.run(title: "Link Codex project", provider: .codex,
                referenceID: projectID.uuidString, dataAccess: "Reviewed native project metadata and folder identity",
                dataDestination: "Local relationship; no native changes or execution") {
                let latest = try await reader.readProject(id: snapshot.identity.externalID)
                let roots = await Task.detached(priority: .utility) { Stores.workspaceCodexRootReviews(for: latest) }.value
                try Task.checkCancellation()
                guard latest == snapshot else {
                    if let existing = link, existing.approvedSnapshot.identity == latest.identity {
                        link = try stores.observeWorkspaceCodexProject(linkID: existing.id, snapshot: latest,
                            observedRoots: roots, expectedRevision: existing.revision)
                    }
                    selectedSnapshot = nil; selection = nil; selectedRootReviews = []
                    throw WorkspaceCodexLinkError.staleReview
                }
                guard roots == selectedRootReviews, selectedSnapshot == snapshot else {
                    throw WorkspaceCodexLinkError.staleReview
                }
                if let link {
                    self.link = try stores.reviewWorkspaceCodexProject(linkID: link.id, expectedRevision: link.revision,
                        reviewedSnapshot: snapshot, reviewedRoots: roots)
                } else {
                    link = try stores.linkWorkspaceCodexProject(projectID: projectID, snapshot: snapshot,
                        reviewedRoots: roots, reviewed: true)
                }
                message = link?.state == .linked ? "Project linked locally. Native chats and permissions are unchanged."
                    : "Relationship saved, but folders are unavailable. Native execution remains disabled."
                onLinked?()
            }
        } catch is CancellationError {
            // The database mutation has no suspension point: cancellation cannot
            // turn a committed relationship into an unknown provider action.
            await reloadSaved()
            message = "Link review stopped. The saved relationship is shown above."
        } catch {
            message = "Project link was not saved. Refresh and review the current folders."
        }
    }

    private func unlink(_ existing: WorkspaceCodexProjectLink) {
        guard !busy, let stores = model.stores else { return }
        let runID = model.activityReporter?.begin(ActivityRun(referenceID: projectID.uuidString,
            category: .connection, title: "Unlink Codex project", stage: "Removing local relationship",
            executionLocation: "This Mac", dataAccess: "Local project relationship",
            dataDestination: "Local settings; native project and chats retained"))
        do {
            try stores.unlinkWorkspaceCodexProject(linkID: existing.id, expectedRevision: existing.revision)
            link = nil
            onLinked?()
            message = "Local link removed. The Codex project and chats were kept."
            if let runID { model.activityReporter?.finish(id: runID, state: .succeeded, outcome: "Local relationship removed; native records retained") }
        } catch {
            message = "The link changed. Reopen Project settings before unlinking."
            if let runID { model.activityReporter?.finish(id: runID, state: .failed, outcome: "Unlink not saved; previous relationship retained") }
        }
    }

}
