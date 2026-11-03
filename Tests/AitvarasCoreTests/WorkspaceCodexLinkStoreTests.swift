import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

func removeWorkspaceCodexLinkMigrationForTest(_ db: Database) throws {
    try removeWorkspaceCodexNativeMigrationForTest(db)
    for trigger in ["workspaceCodexChatIdentityImmutable", "workspaceCodexProjectIdentityImmutable", "workspaceCodexProjectHidden", "workspaceCodexChatArchived"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    for table in ["workspaceCodexNativeAuthorization", "workspaceCodexChatLink", "workspaceCodexProjectLink"] {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v22-workspace-codex-links'")
}

@Suite struct WorkspaceCodexLinkStoreTests {
    private func snapshot(host: String = "synthetic-host", profile: String = "synthetic-profile", id: String = "synthetic-project",
                          paths: [String] = ["/synthetic/secondary", "/synthetic/main"]) -> NativeProjectSnapshot {
        .init(identity: .init(provider: .codex, hostID: host, profileNamespace: profile, externalID: id),
              name: "Same synthetic title", roots: paths.map { .init(path: $0) })
    }

    private func roots(_ snapshot: NativeProjectSnapshot, suffix: String = "") -> [WorkspaceCodexRootReview] {
        snapshot.roots.enumerated().map { index, root in
            .init(path: root.path, canonicalPath: root.path, filesystemIdentity: "synthetic-device:\(index)\(suffix)", availability: .available)
        }
    }

    private func setup(_ stores: Stores) throws -> (WorkspaceProject, WorkspaceChat, WorkspaceCodexProjectLink, WorkspaceCodexChatLink) {
        let project = try stores.createWorkspaceProject(title: "Synthetic local project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic local chat")
        let native = snapshot()
        let link = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: roots(native), reviewed: true)
        let chatLink = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id,
            nativeProjectIdentity: native.identity, nativeThreadID: "synthetic-thread", workingDirectory: "/synthetic/main/worktree",
            expectedProjectRevision: link.revision, reviewed: true)
        return (project, chat, link, chatLink)
    }

    @Test func profileAndHostQualifiedIdentitiesDoNotAliasSameTitles() throws {
        let stores = try inMemoryStores()
        let snapshots = [snapshot(), snapshot(host: "other-synthetic-host"), snapshot(profile: "other-synthetic-profile")]
        for native in snapshots {
            let project = try stores.createWorkspaceProject(title: "Same synthetic title")
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Same synthetic title")
            let link = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: roots(native), reviewed: true)
            #expect(link.approvedSnapshot == native)
            #expect(link.approvedRoots.map(\.path) == ["/synthetic/secondary", "/synthetic/main"])
            let thread = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id,
                nativeProjectIdentity: native.identity, nativeThreadID: "same-synthetic-thread", workingDirectory: "/synthetic/main",
                expectedProjectRevision: link.revision, reviewed: true)
            #expect(thread.hostID == native.identity.hostID && thread.profileNamespace == native.identity.profileNamespace)
        }
        let duplicate = try stores.createWorkspaceProject(title: "Different title")
        #expect(throws: WorkspaceCodexLinkError.alreadyLinked) {
            try stores.linkWorkspaceCodexProject(projectID: duplicate.id, snapshot: snapshots[0], reviewedRoots: roots(snapshots[0]), reviewed: true)
        }
    }

    @Test func projectReviewDoesNotGrantNativeToolsOrAlterIsolatedPolicy() throws {
        let stores = try inMemoryStores()
        let (project, chat, link, nativeChat) = try setup(stores)
        #expect(link.state == .linked)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
        #expect(try stores.workspaceFolders(projectID: project.id).isEmpty)
        #expect(try stores.workspacePolicy(projectID: project.id) == nil)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceFrontierSessions(chatID: chat.id).isEmpty)
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.workspaceProject(id: project.id)?.allowsCloud == false)
    }

    @Test func explicitReviewAndExactOrderedRootsAreRequired() throws {
        let stores = try inMemoryStores(), native = snapshot()
        let project = try stores.createWorkspaceProject(title: "Synthetic")
        #expect(throws: WorkspaceCodexLinkError.reviewRequired) {
            try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: roots(native), reviewed: false)
        }
        #expect(throws: WorkspaceCodexLinkError.invalidValue) {
            try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: roots(native).reversed(), reviewed: true)
        }
        #expect(try stores.workspaceCodexProjectLink(projectID: project.id) == nil)
        let unverified = native.roots.map { WorkspaceCodexRootReview(path: $0.path) }
        let link = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: unverified, reviewed: true)
        #expect(link.state == .reviewRequired)
        #expect(Stores.workspaceCodexRootReviews(for: native) == unverified)
    }

    @Test func explicitCwdCannotBeInferredOrEscapeRootsAndProjectMembershipMustMatch() throws {
        let stores = try inMemoryStores()
        let (project, _, link, existing) = try setup(stores)
        #expect(existing.workingDirectory == "/synthetic/main/worktree")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Second chat")
        for cwd in ["", "relative", "/synthetic/main/../outside", "/synthetic/main-other", "/synthetic"] {
            #expect(throws: (any Error).self) {
                try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id,
                    nativeProjectIdentity: link.approvedSnapshot.identity, nativeThreadID: "synthetic-second-thread",
                    workingDirectory: cwd, expectedProjectRevision: link.revision, reviewed: true)
            }
        }
        #expect(throws: WorkspaceCodexLinkError.identityMismatch) {
            try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id,
                nativeProjectIdentity: snapshot(profile: "different-profile").identity, nativeThreadID: "synthetic-second-thread",
                workingDirectory: "/synthetic/main", expectedProjectRevision: link.revision, reviewed: true)
        }
        let otherProject = try stores.createWorkspaceProject(title: "Other project")
        let otherChat = try stores.createWorkspaceChat(projectID: otherProject.id, title: "Other chat")
        #expect(throws: WorkspaceCodexLinkError.unavailableChat) {
            try stores.linkWorkspaceCodexChat(chatID: otherChat.id, projectLinkID: link.id,
                nativeProjectIdentity: link.approvedSnapshot.identity, nativeThreadID: "synthetic-second-thread",
                workingDirectory: "/synthetic/main", expectedProjectRevision: link.revision, reviewed: true)
        }
        #expect(try stores.workspaceCodexChatLink(chatID: chat.id) == nil)
    }

    @Test func conflictsPreserveBothSnapshotsInvalidateConsentAndRejectStaleSaves() throws {
        let stores = try inMemoryStores()
        let (_, _, link, chat) = try setup(stores)
        let consent = try stores.authorizeWorkspaceCodexNativeTools(chatLinkID: chat.id, expectedProjectRevision: link.revision,
            expectedChatRevision: chat.revision, effectiveConfigurationFingerprint: "synthetic-config-v1",
            reviewedPolicySummary: "Synthetic normal native tools; native approvals remain required", reviewed: true)
        #expect(consent.mode == "nativeCodex")
        let changed = snapshot(paths: ["/synthetic/main", "/synthetic/secondary", "/synthetic/new-root"])
        let conflict = try stores.observeWorkspaceCodexProject(linkID: link.id, snapshot: changed,
            observedRoots: roots(changed), expectedRevision: link.revision)
        #expect(conflict.state == .conflict && conflict.revision == 2)
        #expect(conflict.approvedSnapshot == link.approvedSnapshot && conflict.observedSnapshot == changed)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: chat.id) == nil)
        #expect(throws: WorkspaceCodexLinkError.staleRevision) {
            try stores.unlinkWorkspaceCodexProject(linkID: link.id, expectedRevision: link.revision)
        }
        #expect(throws: WorkspaceCodexLinkError.staleReview) {
            try stores.reviewWorkspaceCodexProject(linkID: link.id, expectedRevision: conflict.revision,
                reviewedSnapshot: link.approvedSnapshot, reviewedRoots: link.approvedRoots)
        }
        #expect(try stores.workspaceCodexProjectLink(projectID: link.projectID) == conflict)
        let approved = try stores.reviewWorkspaceCodexProject(linkID: link.id, expectedRevision: conflict.revision,
            reviewedSnapshot: changed, reviewedRoots: roots(changed))
        #expect(approved.state == .linked && approved.approvedSnapshot == changed && approved.revision == 3)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: chat.id) == nil)
    }

    @Test func retargetedFilesystemIdentityAndChangeThenRevertStayUnapproved() throws {
        let stores = try inMemoryStores()
        let (_, _, link, _) = try setup(stores)
        let changed = try stores.observeWorkspaceCodexProject(linkID: link.id, snapshot: link.observedSnapshot,
            observedRoots: roots(link.observedSnapshot, suffix: "-retargeted"), expectedRevision: link.revision)
        #expect(changed.state == .conflict)
        let reverted = try stores.observeWorkspaceCodexProject(linkID: link.id, snapshot: link.approvedSnapshot,
            observedRoots: link.approvedRoots, expectedRevision: changed.revision)
        #expect(reverted.state == .conflict && reverted.revision == 3)
        let invalidated = try stores.invalidateWorkspaceCodexProject(linkID: link.id, expectedRevision: reverted.revision)
        let repeated = try stores.observeWorkspaceCodexProject(linkID: link.id, snapshot: link.observedSnapshot,
            observedRoots: link.approvedRoots, expectedRevision: invalidated.revision)
        #expect(repeated == invalidated && repeated.state == .reviewRequired)
    }

    @Test func unlinkRemovesOnlyRelationshipsAndConsent() throws {
        let stores = try inMemoryStores()
        let (project, chat, link, nativeChat) = try setup(stores)
        let imported = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-imported-thread", displayName: "Historical source"))
        let message = StoredMessage(conversationID: chat.localConversationID, role: "user", content: "Synthetic local message")
        try stores.appendMessage(message)
        _ = try stores.authorizeWorkspaceCodexNativeTools(chatLinkID: nativeChat.id, expectedProjectRevision: link.revision,
            expectedChatRevision: nativeChat.revision, effectiveConfigurationFingerprint: "synthetic-config",
            reviewedPolicySummary: "Synthetic policy", reviewed: true)
        try stores.unlinkWorkspaceCodexProject(linkID: link.id, expectedRevision: link.revision)
        #expect(try stores.workspaceCodexProjectLink(projectID: project.id) == nil)
        #expect(try stores.workspaceCodexChatLink(chatID: chat.id) == nil)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
        #expect(try stores.workspaceProject(id: project.id) != nil)
        #expect(try stores.workspaceChat(id: chat.id) != nil)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).map(\.id) == [imported.id])
        #expect(try stores.messages(in: chat.localConversationID).map(\.id) == [message.id])
    }

    @Test func isolatedOwnedIdentitiesCannotBeAdoptedAndIdentityCannotBeReassigned() throws {
        let stores = try inMemoryStores()
        let (project, _, link, nativeChat) = try setup(stores)
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic isolated chat")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        let context = try stores.workspaceContextPacket(chatID: chat.id)
        let owned = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: context.promptText)
        let bound = try stores.bindWorkspaceFrontierSession(id: owned.id, externalID: "synthetic-owned-thread")
        #expect(throws: WorkspaceCodexLinkError.isolatedIdentity) {
            try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id,
                nativeProjectIdentity: link.approvedSnapshot.identity, nativeThreadID: "synthetic-owned-thread",
                workingDirectory: "/synthetic/main", expectedProjectRevision: link.revision, reviewed: true)
        }
        #expect(try stores.workspaceFrontierSession(id: owned.id) == bound)
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceCodexChatLink SET externalID = 'synthetic-reassigned' WHERE id = ?", arguments: [nativeChat.id]) }
        }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceCodexProjectLink SET profileNamespace = 'synthetic-reassigned' WHERE id = ?", arguments: [link.id]) }
        }
    }

    @Test func archivalAndVisibilityChangesRevokeNativeConsentWithoutRevival() throws {
        let stores = try inMemoryStores()
        let (project, chat, link, nativeChat) = try setup(stores)
        func authorize() throws {
            _ = try stores.authorizeWorkspaceCodexNativeTools(chatLinkID: nativeChat.id, expectedProjectRevision: link.revision,
                expectedChatRevision: nativeChat.revision, effectiveConfigurationFingerprint: "synthetic-settings",
                reviewedPolicySummary: "Synthetic normal native tools", reviewed: true)
        }
        try authorize()
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
        #expect(throws: WorkspaceCodexLinkError.reviewRequired) { try authorize() }
        try stores.setWorkspaceChatArchived(id: chat.id, archived: false)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
        try authorize()
        var hidden = project; hidden.isVisible = false
        try stores.saveWorkspaceProject(hidden)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
        try stores.saveWorkspaceProject(project)
        #expect(try stores.workspaceCodexNativeAuthorization(chatLinkID: nativeChat.id) == nil)
    }

    @Test func localFolderRetargetAndCwdSymlinkEscapeRequireReview() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("synthetic-codex-link-\(UUID())")
        defer { try? fm.removeItem(at: temporary) }
        let original = temporary.appendingPathComponent("original"), replacement = temporary.appendingPathComponent("replacement")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
        let root = temporary.appendingPathComponent("root")
        try fm.createSymbolicLink(at: root, withDestinationURL: original)
        try fm.createSymbolicLink(at: original.appendingPathComponent("escape"), withDestinationURL: replacement)
        let native = snapshot(host: "local", paths: [root.path])
        let reviewed = Stores.workspaceCodexRootReviews(for: native)
        #expect(reviewed.first?.canonicalPath == original.resolvingSymlinksInPath().path)
        let stores = try inMemoryStores(), project = try stores.createWorkspaceProject(title: "Synthetic")
        let link = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: native, reviewedRoots: reviewed, reviewed: true)
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic")
        #expect(throws: WorkspaceCodexLinkError.invalidWorkingDirectory) {
            try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id, nativeProjectIdentity: native.identity,
                nativeThreadID: "synthetic-thread", workingDirectory: root.appendingPathComponent("escape").path,
                expectedProjectRevision: link.revision, reviewed: true)
        }
        try fm.removeItem(at: root)
        try fm.createSymbolicLink(at: root, withDestinationURL: replacement)
        #expect(throws: WorkspaceCodexLinkError.staleReview) {
            try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: link.id, nativeProjectIdentity: native.identity,
                nativeThreadID: "synthetic-thread", workingDirectory: root.path, expectedProjectRevision: link.revision, reviewed: true)
        }
    }

    @Test func migrationIsAdditiveAndDoesNotAdoptExistingSessions() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-codex-migration-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("synthetic.sqlite")
        let projectID: UUID, chatID: UUID, conversationID: UUID, importedID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let project = try stores.createWorkspaceProject(title: "Synthetic preserved project")
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic preserved chat")
            let imported = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
                externalID: "synthetic-old-import", displayName: "Synthetic import"))
            projectID = project.id; chatID = chat.id; conversationID = chat.localConversationID; importedID = imported.id
            try stores.db.queue.write { try removeWorkspaceCodexLinkMigrationForTest($0) }
        }
        let upgraded = Stores(db: try AitvarasDatabase(url: url))
        #expect(try upgraded.workspaceProject(id: projectID)?.title == "Synthetic preserved project")
        #expect(try upgraded.workspaceChat(id: chatID)?.localConversationID == conversationID)
        #expect(try upgraded.workspaceSessionLinks(chatID: chatID).map(\.id) == [importedID])
        #expect(try upgraded.workspaceCodexProjectLink(projectID: projectID) == nil)
        #expect(try upgraded.workspaceCodexChatLink(chatID: chatID) == nil)
        #expect(try upgraded.db.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v22-workspace-codex-links'") } == 1)
    }
}
