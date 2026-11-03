import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

@Suite struct WorkspacePolicyTests {
    @Test func claudeReadGrantIsIndependentAndInvalidatesWithProjectChanges() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic Claude project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic chat")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.saveWorkspaceProjectSettings(projectID: project.id, title: project.title,
            instructions: "", folders: [.init(path: "/synthetic/approved")], allowedProviders: [.codex, .claude],
            expectedContextRevision: review.revision, expectedPolicyRevision: nil, expectedProjectTitle: project.title,
            allowClaudeFileRead: true)
        #expect(policy.allowsClaudeFileAccess && !policy.allowsFileAccess && !policy.allowsTools)
        #expect(try stores.workspaceClaudeReadRoots(chatID: chat.id, expectedPolicyRevision: policy.revision) == ["/synthetic/approved"])
        #expect(try stores.workspaceCodexReadRoots(chatID: chat.id, expectedPolicyRevision: policy.revision).isEmpty)
        let current = try stores.workspacePolicyReview(projectID: project.id)
        let renewed = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex, .claude],
            expectedRevision: current.revision)
        #expect(!renewed.allowsClaudeFileAccess)
        #expect(try stores.workspaceClaudeReadRoots(chatID: chat.id, expectedPolicyRevision: renewed.revision).isEmpty)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.workspaceClaudeReadRoots(chatID: chat.id, expectedPolicyRevision: policy.revision)
        }
    }

    @Test func codexFileReadGrantIsExplicitRevisionBoundAndProjectScoped() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Read project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Chat")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.saveWorkspaceProjectSettings(projectID: project.id, title: project.title,
            instructions: "", folders: [.init(path: "/synthetic/approved")], allowedProviders: [.codex],
            expectedContextRevision: review.revision, expectedPolicyRevision: nil, expectedProjectTitle: project.title,
            allowCodexFileRead: true)
        #expect(policy.allowsFileAccess)
        #expect(!policy.allowsTools && !policy.allowsCloudExecution && !policy.allowsGlobalRAG)
        #expect(try stores.workspaceCodexReadRoots(chatID: chat.id, expectedPolicyRevision: policy.revision) == ["/synthetic/approved"])
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let session = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        _ = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Read the project")
        let current = try stores.workspacePolicyReview(projectID: project.id)
        let renewed = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: current.revision)
        #expect(!renewed.allowsFileAccess)
        #expect(try stores.workspaceCodexReadRoots(chatID: chat.id, expectedPolicyRevision: renewed.revision).isEmpty)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.workspaceCodexReadRoots(chatID: chat.id, expectedPolicyRevision: policy.revision)
        }
        try stores.replaceWorkspaceFolders(projectID: project.id, folders: [.init(path: "/synthetic/changed")])
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.workspaceCodexReadRoots(chatID: chat.id, expectedPolicyRevision: renewed.revision)
        }
    }

    @Test func oneSaveApprovesExactSettingsWithoutGrantingFileOrToolAccess() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let before = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.saveWorkspaceProjectSettings(projectID: project.id, title: "Updated example",
            instructions: "Explain clearly", folders: [.init(path: "/synthetic/course")],
            allowedProviders: [.local, .codex], expectedContextRevision: before.revision, expectedPolicyRevision: nil, expectedProjectTitle: project.title)
        #expect(policy.status == .reviewed)
        #expect(policy.instructions == "Explain clearly")
        #expect(policy.reviewedFolders.map(\.path) == ["/synthetic/course"])
        #expect(policy.allowedProviders.contains(.codex))
        #expect(!policy.allowsFileAccess && !policy.allowsTools && !policy.allowsCloudExecution && !policy.allowsGlobalRAG)
        #expect(try stores.workspaceProject(id: project.id)?.title == "Updated example")
    }

    @Test func staleSettingsSavePreservesAllMetadataAndProviderChoices() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", instructions: "Original")
        let before = try stores.workspacePolicyReview(projectID: project.id)
        let newer = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local], expectedRevision: before.revision)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.saveWorkspaceProjectSettings(projectID: project.id, title: "Must not save", instructions: "Must not save",
                folders: [.init(path: "/synthetic/refused")], allowedProviders: [.codex],
                expectedContextRevision: before.revision, expectedPolicyRevision: nil, expectedProjectTitle: project.title)
        }
        #expect(try stores.workspaceProject(id: project.id)?.instructions == "Original")
        #expect(try stores.workspaceFolders(projectID: project.id).isEmpty)
        #expect(try stores.workspacePolicy(projectID: project.id)?.revision == newer.revision)
        var edited = project; edited.instructions = "Changed elsewhere"
        try stores.saveWorkspaceProject(edited)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.saveWorkspaceProjectSettings(projectID: project.id, title: "Must not save", instructions: "Must not save",
                folders: [], allowedProviders: [.codex], expectedContextRevision: before.revision, expectedPolicyRevision: newer.revision, expectedProjectTitle: project.title)
        }
        #expect(try stores.workspaceProject(id: project.id)?.instructions == "Changed elsewhere")
    }

    @Test func settingsCannotOverwriteAConcurrentProjectRename() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Original")
        let snapshot = try stores.workspacePolicyReview(projectID: project.id)
        project.title = "Renamed elsewhere"
        try stores.saveWorkspaceProject(project)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.saveWorkspaceProjectSettings(projectID: project.id, title: "Stale editor title", instructions: "",
                folders: [], allowedProviders: [.codex], expectedContextRevision: snapshot.revision,
                expectedPolicyRevision: nil, expectedProjectTitle: "Original")
        }
        #expect(try stores.workspaceProject(id: project.id)?.title == "Renamed elsewhere")
        #expect(try stores.workspacePolicy(projectID: project.id) == nil)
    }

    @Test func freshProjectsHaveNoReviewAndNoAdditionalCapabilities() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Course")
        #expect(try stores.workspacePolicy(projectID: project.id) == nil)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        #expect(packet.policyStatus == .unreviewed)
        #expect(packet.localOnly)
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex, .claude], expectedRevision: review.revision)
        #expect(Set(policy.allowedProviders) == Set([.local, .codex, .claude]))
        #expect(!policy.allowsCloudExecution && !policy.allowsTools && !policy.allowsFileAccess && !policy.allowsGlobalRAG)
        #expect(try stores.workspaceProject(id: project.id)?.allowsCloud == false)
    }

    @Test func contextIsBoundedAndNeverIncludesOtherEvidence() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", instructions: String(repeating: "x", count: 12_000), folders: [.init(path: "/synthetic/FILE_PATH_CANARY")])
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Course", purpose: "Selected purpose")
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "HISTORY_CANARY"))
        try stores.saveMemory(Memory(content: "GLOBAL_MEMORY_CANARY", category: "fact"))
        let capture = record(text: "CAPTURE_CANARY")
        try stores.saveCaptureRecord(capture, workspaceChatID: chat.id)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        #expect(packet.promptText.count == WorkspaceTextContext.maximumCharacters)
        #expect(packet.manifest.wasClipped)
        #expect(packet.promptText.hasSuffix(WorkspaceTextContext.clippingMarker))
        for canary in ["FILE_PATH_CANARY", "HISTORY_CANARY", "GLOBAL_MEMORY_CANARY", "CAPTURE_CANARY"] {
            #expect(!packet.promptText.contains(canary))
        }
        #expect(packet.manifest.includedCharacters == packet.promptText.count)
        #expect(packet.manifest.excludedCategories.contains("Native provider transcripts"))
    }

    @Test func reviewUsesExactMetadataAndChangeRevertDoesNotReviveIt() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Example", instructions: "Original", folders: [.init(path: "/synthetic/original")])
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local], expectedRevision: review.revision)
        project.instructions = "Changed"
        try stores.saveWorkspaceProject(project)
        project.instructions = "Original"
        try stores.saveWorkspaceProject(project)
        #expect(try stores.workspacePolicy(projectID: project.id)?.status == .stale)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        }
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.replaceWorkspaceFolders(projectID: project.id, folders: [], expectedPolicyRevision: review.revision)
        }
        #expect(try stores.workspaceFolders(projectID: project.id).count == 1)
        let fresh = try stores.workspacePolicyReview(projectID: project.id)
        let saved = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [], expectedRevision: fresh.revision)
        #expect(saved.status == .reviewed && saved.revision == 2 && saved.allowedProviders == [.local])
    }

    @Test(arguments: ["path", "access", "identity", "remove"])
    func directFolderChangesInvalidateReview(field: String) throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: "/synthetic/original")])
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local], expectedRevision: review.revision)
        try stores.db.queue.write { db in
            switch field {
            case "path": try db.execute(sql: "UPDATE workspaceFolder SET path = '/synthetic/changed'")
            case "access": try db.execute(sql: "UPDATE workspaceFolder SET access = 'readWrite'")
            case "identity": try db.execute(sql: "UPDATE workspaceFolder SET id = ?", arguments: [UUID()])
            default: try db.execute(sql: "DELETE FROM workspaceFolder")
            }
        }
        #expect(try stores.workspacePolicy(projectID: project.id)?.status == .stale)
    }

    @Test func malformedPolicyFailsClosed() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Course")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [], expectedRevision: review.revision)
        try stores.db.queue.write { try $0.execute(sql: "UPDATE workspacePolicy SET allowedProvidersJSON = '[\"unknown\"]'") }
        #expect(throws: WorkspacePolicyError.invalidPolicy) { try stores.workspaceContextPacket(chatID: chat.id) }
    }

    @Test(arguments: ["temporary", "archived", "hidden", "missing"])
    func invalidCaptureTargetsRollBackRecordAndEvent(reason: String) throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Example")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Target", kind: reason == "temporary" ? .temporary : .primary)
        if reason == "archived" { try stores.setWorkspaceChatArchived(id: chat.id, archived: true) }
        if reason == "hidden" { project.isVisible = false; try stores.saveWorkspaceProject(project) }
        let value = record()
        let event = ActivityEvent(kind: .captureFinished, summary: "Synthetic capture")
        #expect(throws: WorkspacePolicyError.invalidCaptureTarget) {
            try stores.saveCaptureRecord(value, workspaceChatID: reason == "missing" ? UUID() : chat.id, recording: event)
        }
        #expect(try stores.captureRecord(id: value.id) == nil)
        #expect(try stores.db.queue.read { try ActivityEvent.fetchOne($0, key: event.id) } == nil)
    }

    @Test func captureLinkIsStableAcrossArchiveSummaryAndSameTitleTargets() throws {
        let stores = try inMemoryStores()
        var project = try stores.createWorkspaceProject(title: "Example")
        let first = try stores.createWorkspaceChat(projectID: project.id, title: "Same")
        let other = try stores.createWorkspaceChat(projectID: project.id, title: "Same")
        var value = record()
        try stores.saveCaptureRecord(value, workspaceChatID: first.id)
        let link = try #require(try stores.workspaceCaptureTarget(recordID: value.id))
        try stores.setWorkspaceChatArchived(id: first.id, archived: true)
        project.isVisible = false; try stores.saveWorkspaceProject(project)
        value.transcript = "Finalized"
        try stores.saveCaptureRecord(value, workspaceChatID: first.id)
        value.summary = "Summary"
        try stores.saveCaptureRecord(value, workspaceChatID: nil)
        #expect(try stores.workspaceCaptureTarget(recordID: value.id) == link)
        #expect(try stores.workspaceCaptures(chatID: first.id).first?.summary == "Summary")
        #expect(try stores.workspaceCaptures(chatID: other.id).isEmpty)
        value.transcript = "Must roll back"
        #expect(throws: WorkspacePolicyError.immutableCaptureTarget) {
            try stores.saveCaptureRecord(value, workspaceChatID: other.id)
        }
        #expect(try stores.captureRecord(id: value.id)?.transcript == "Finalized")
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceCaptureTarget SET chatID = ?", arguments: [other.id]) }
        }
        try stores.deleteCaptureRecord(value.id)
        #expect(try stores.workspaceCaptureTarget(recordID: value.id) == nil)
    }

    @Test func v19UpgradeKeepsExistingWorkspaceCaptureAndLegacyData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        var projectID: UUID!; var chatID: UUID!
        let capture = record()
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let project = try stores.createWorkspaceProject(title: "Existing", instructions: "Preserve", folders: [.init(path: "/synthetic/existing")])
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Existing course")
            projectID = project.id; chatID = chat.id
            try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Existing message"))
            try stores.saveCaptureRecord(capture)
            try stores.setValue("preserve", forKey: "synthetic.setting")
            try stores.db.queue.write { db in
                try removeWorkspaceFrontierMigrationForTest(db)
                for trigger in ["workspacePolicyProjectInsert", "workspacePolicyInstructionsUpdate", "workspacePolicyFolderInsert", "workspacePolicyFolderDelete", "workspacePolicyFolderUpdate", "workspaceCaptureTargetImmutable"] {
                    try db.execute(sql: "DROP TRIGGER \(trigger)")
                }
                for table in ["workspaceCaptureTarget", "workspacePolicy", "workspacePolicyState"] { try db.drop(table: table) }
                try db.execute(sql: "DROP INDEX workspaceChatIdentityProject")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v20-workspace-policy-capture-targets'")
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.workspacePolicy(projectID: projectID) == nil)
        #expect(try stores.workspaceCaptureTarget(recordID: capture.id) == nil)
        #expect(try stores.captureRecord(id: capture.id) == capture)
        let chat = try #require(try stores.workspaceChat(id: chatID))
        #expect(try stores.messages(in: chat.localConversationID).first?.content == "Existing message")
        #expect(try stores.workspaceFolders(projectID: projectID).first?.path == "/synthetic/existing")
        #expect(try stores.value(forKey: "synthetic.setting") == "preserve")
    }

    private func record(text: String = "Synthetic transcript") -> CaptureRecord {
        CaptureRecord(startedAt: Date(timeIntervalSince1970: 1_000), endedAt: Date(timeIntervalSince1970: 1_060),
            title: "Synthetic lecture", scope: "Microphone", audio: "mic", consentConfirmed: true, transcript: text)
    }
}
