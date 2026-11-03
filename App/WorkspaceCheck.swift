import Foundation
import AitvarasCore
import AitvarasStore

/// Synthetic app-level checks complement package tests without opening a real
/// profile, preparing models, connecting services, or capturing devices.
@MainActor
enum WorkspaceCheck {
    static func prepareAndCheck(_ model: AppModel, scenario: String) throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try model.prepareMonitoringFixture("idle")
        guard let stores = model.stores else { throw CheckError.failed("fixture store") }
        let legacy = Conversation(title: "Chat")
        try stores.saveConversation(legacy)
        let original = StoredMessage(conversationID: legacy.id, role: "user", content: "Synthetic saved conversation for assignment checks.")
        try stores.appendMessage(original)
        let voice = Conversation(title: "Voice")
        try stores.saveConversation(voice)
        try stores.appendMessage(StoredMessage(conversationID: voice.id, role: "user", content: "Synthetic voice history."))

        try require(model.createWorkspaceProject(title: "Example studies", instructions: "Explain ideas clearly. Cite evidence when available.",
            folderURLs: [URL(fileURLWithPath: "/tmp/aitvaras-example-course")]), "create project")
        guard let projectID = model.selectedWorkspaceProjectID else { throw CheckError.failed("project selection") }
        try require(model.selectedChatConversationID == nil && model.messages.isEmpty, "empty project isolation")
        model.startVoiceViaHotkey()
        try require(!model.voiceEnabled && model.workspaceMessage != nil, "project hotkey refuses legacy voice")
        try require(!model.createWorkspaceChat(title: " ", kind: .primary, purpose: ""), "blank name rejection")
        try require(model.createWorkspaceChat(title: "Example course", kind: .primary,
            purpose: "A permanent home for this course's questions and later captures."), "primary chat")
        guard let primaryID = model.selectedWorkspaceChatID, let localID = model.selectedChatConversationID else {
            throw CheckError.failed("chat identity")
        }
        try stores.appendMessage(StoredMessage(conversationID: localID, role: "user", content: "What will this workspace remember?"))
        try stores.appendMessage(StoredMessage(conversationID: localID, role: "assistant",
            content: "This checkpoint saves our conversation under the project. Shared retrieval and native session imports are the next steps."))
        model.openWorkspaceChat(primaryID)
        let ids = model.messages.map(\.id)
        model.isResponding = true
        model.openUnassignedConversation(legacy.id)
        try require(model.selectedWorkspaceChatID == primaryID && model.messages.map(\.id) == ids, "busy chat switch")
        model.isResponding = false

        model.setWorkspaceChatArchived(primaryID, archived: true)
        try require(model.selectedWorkspaceChat?.archivedAt != nil && (try stores.messageCount(in: localID)) == 2,
            "archive retains text")
        model.setWorkspaceChatArchived(primaryID, archived: false)
        model.openUnassignedConversation(voice.id)
        try require(model.selectedUnassignedVoiceHistory && !model.send("Do not alter a saved voice transcript"), "voice read-only")
        try require(!model.assignUnassignedConversation(voice.id, projectID: projectID,
            title: "Voice", kind: .primary, purpose: ""), "voice assignment refused")
        model.openUnassignedConversation(legacy.id)
        try require(model.assignUnassignedConversation(legacy.id, projectID: projectID,
            title: "Imported local discussion", kind: .temporary, purpose: "Assigned without copying messages."), "legacy assignment")
        try require(model.selectedChatConversationID == legacy.id && (try stores.messages(in: legacy.id)).first?.id == original.id,
            "original message identity")
        try require(!(try stores.unassignedConversations()).contains { $0.id == legacy.id }, "assignment removed from unassigned")

        model.openWorkspaceChat(primaryID)
        model.selectedWorkspaceProjectID = nil
        model.selectedWorkspaceChatID = nil
        model.chatConversationID = nil
        model.messages = []
        model.restoreWorkspaceSelection()
        try require(model.selectedWorkspaceChatID == primaryID && model.selectedChatConversationID == localID,
            "selection restoration")

        let hidden = try stores.createWorkspaceProject(title: "Hidden example project")
        var hiddenValue = hidden
        hiddenValue.isVisible = false
        try stores.saveWorkspaceProject(hiddenValue)
        _ = try stores.createWorkspaceChat(projectID: projectID, title: "Another primary discussion", kind: .primary)
        let archived = try stores.createWorkspaceChat(projectID: projectID, title: "Earlier example", kind: .temporary)
        try stores.setWorkspaceChatArchived(id: archived.id, archived: true)
        model.refreshWorkspaces()
        model.workspaceMessage = nil

        // Native import: reviewed read-only text, kept out of the local chat.
        let other = try stores.createWorkspaceProject(title: "Test")
        // A short project name next to a long one, so snapshots show both chip
        // widths and a title cannot be squeezed out by the chip again.
        _ = try stores.createWorkspaceChat(projectID: other.id, title: "Short scope chat", kind: .temporary)
        let source = NativeSessionSummary(provider: .codex, externalID: "synthetic-native-session",
            title: "Synthetic native chat", directory: "/tmp/aitvaras-example-course",
            updatedAt: .now, activity: "Synthetic fixture, never a live provider")
        let page = NativeTranscriptPage(session: source,
            messages: (0..<120).map {
                NativeTextMessage(externalID: "synthetic-\($0)",
                    role: $0.isMultiple(of: 2) ? .user : .assistant,
                    text: "Synthetic native transcript line \($0).")
            },
            nextCursor: "synthetic-cursor-2", coverage: "Synthetic fixture page 1", direction: .newer)
        model.nativeWorkspace.stageSyntheticPreview([page])
        try require(!model.importPreviewedNativeSession(projectID: hidden.id, kind: .primary, reviewedRevision: model.nativeWorkspace.previewRevision),
            "hidden project import refused")
        try require(!model.nativeWorkspace.previewPages.isEmpty, "refused import keeps the reviewed preview")
        try require(model.importPreviewedNativeSession(projectID: projectID, kind: .primary, reviewedRevision: model.nativeWorkspace.previewRevision), "native import")
        guard let nativeChatID = model.selectedWorkspaceChatID else { throw CheckError.failed("native chat selection") }
        guard let link = model.nativeSessionLinks(for: nativeChatID).first else { throw CheckError.failed("native link") }
        try require(model.nativeSessionLinks(for: nativeChatID).count == 1 && link.provider == .codex
            && link.externalID == source.externalID, "native identity")
        try require(model.messages.isEmpty && (try stores.messageCount(in: model.selectedChatConversationID ?? localID)) == 0,
            "imported source stays out of the local chat")
        try require(model.nativeSnapshot(linkID: link.id)?.nextCursor == "synthetic-cursor-2", "saved continuation cursor")
        try require(model.nativeMessages(linkID: link.id).count == NativeWorkspaceModel.savedPageSize
            && model.nativeHasMoreSavedMessages(linkID: link.id), "saved text pages locally")
        model.loadMoreSavedNativeMessages(linkID: link.id)
        try require(model.nativeMessages(linkID: link.id).count == 120
            && !model.nativeHasMoreSavedMessages(linkID: link.id), "saved text fully shown")
        try require(!model.importPreviewedNativeSession(projectID: projectID, kind: .primary, reviewedRevision: model.nativeWorkspace.previewRevision),
            "import needs a fresh reviewed preview")
        model.nativeWorkspace.stageSyntheticPreview([page])
        try require(!model.importPreviewedNativeSession(projectID: other.id, kind: .primary, reviewedRevision: model.nativeWorkspace.previewRevision),
            "same native session is not re-homed into another project")
        try require(WorkspaceRailView.chipLabel("Test") == "Test"
            && WorkspaceRailView.chipLabel(String(repeating: "x", count: 40)).count == 14,
            "project chips keep one predictable width")
        model.nativeWorkspace.clearPreview()
        model.openWorkspaceChat(primaryID)
        try require(model.nativeSessionLinks(for: primaryID).isEmpty, "local chats have no native source")
        let policyReview = try stores.workspacePolicyReview(projectID: projectID)
        let policy = try stores.reviewWorkspacePolicy(projectID: projectID,
            allowedProviders: [.local, .claude, .codex], expectedRevision: policyReview.revision)
        let context = try stores.workspaceContextPacket(chatID: primaryID)
        try require(policy.status == .reviewed && !policy.allowsCloudExecution && !policy.allowsFileAccess,
            "review does not grant execution")
        try require(context.localOnly && context.promptText.contains("Explain ideas clearly")
            && !context.promptText.contains("Synthetic native transcript line"), "inspectable context separation")
        let capture = CaptureRecord(startedAt: .now, title: "Synthetic linked lecture", scope: "Synthetic microphone",
            audio: "mic", consentConfirmed: true, transcript: "CAPTURE_CONTEXT_EXCLUSION_CANARY")
        try stores.saveCaptureRecord(capture, workspaceChatID: primaryID)
        try require(try stores.workspaceCaptures(chatID: primaryID).map(\.id) == [capture.id], "linked capture visible")
        try require(!(try stores.workspaceContextPacket(chatID: primaryID)).promptText.contains("CAPTURE_CONTEXT_EXCLUSION_CANARY"),
            "capture linking is not prompt inclusion")
        model.workspaceMessage = nil

        if scenario == "empty" {
            try require(model.createWorkspaceProject(title: "New example project", instructions: "", folderURLs: []), "empty selection")
        } else if scenario == "archived" {
            model.openWorkspaceChat(archived.id)
        } else if scenario == "unassigned" {
            model.openUnassignedConversation(voice.id)
        }
        print("[workspace-check] PASS: scope, validation, selection, archive/voice preservation, native evidence separation, reviewed policy ceiling, context manifest and linked capture exclusion")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw CheckError.failed(label) }
    }
    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let label): "Synthetic workspace check failed: \(label)" }
        }
    }
}
