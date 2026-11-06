import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

@Suite struct UnifiedChatMigrationTests {
    @Test func v27UpgradeAndRepeatedOpenPreserveSavedEvidenceAndCaptureTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unified-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.sqlite")
        let fixture: LegacyChatFixture
        let before: [String: [Row]]
        let visible: [AgentTranscriptEntry]
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            fixture = try LegacyChatFixture(stores)
            before = try legacyRows(stores)
            visible = try stores.agentEntries(chatID: fixture.chat.id)
            // Reconstruct the pre-unified schema, retaining populated legacy
            // tables, then let the production migration chain perform the upgrade.
            try stores.db.queue.write { db in
                for table in ["agentHistoryObservation", "agentWorktree", "agentHandover", "agentTurn", "agentTranscriptEntry", "agentChatSession"] {
                    try db.drop(table: table)
                }
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier IN (?, ?, ?, ?, ?)",
                    arguments: ["v28-agent-chat-journal", "v29-agent-handover", "v30-agent-followup-inputs", "v31-agent-worktrees", "v32-agent-history-reconciliation"])
            }
        }
        for _ in 0..<2 {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            #expect(try legacyRows(stores) == before)
            #expect(try stores.agentEntries(chatID: fixture.chat.id) == visible)
            #expect(try stores.workspaceCaptureTarget(recordID: fixture.capture.id)?.chatID == fixture.chat.id)
            #expect(try stores.workspaceChat(id: fixture.chat.id)?.localConversationID == fixture.chat.localConversationID)
            #expect(try stores.agentSession(chatID: fixture.chat.id, provider: .claude) == nil)
            #expect(try stores.agentSession(chatID: fixture.chat.id, provider: .codex) == nil)
            #expect(try stores.db.queue.read { try AgentTranscriptEntry.fetchCount($0) } == 0)
            #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
        }
    }

    @Test func missingSeparateProfileAndExecutableStillReadEveryLegacySource() async throws {
        let stores = try inMemoryStores()
        let fixture = try LegacyChatFixture(stores)
        // The injected provider is a real process adapter pointing at a missing
        // executable and profile. Opening saved history must never invoke it.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-provider-\(UUID())")
        let backend = ClaudeBackend(executable: missing, environment: ["HOME": missing.path, "PATH": ""],
                                    overrides: ["CLAUDE_CONFIG_DIR": missing.path])
        let before = try legacyRows(stores)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let state = try await manager.state(chatID: fixture.chat.id)
        for text in ["Local saved answer", "Owned Codex answer", "Owned Claude answer", "Linked native answer", "Unattributed Claude evidence", "Partial old answer"] {
            #expect(state.entries.contains { $0.text == text })
        }
        let unknown = try #require(state.entries.first { $0.text == "Partial old answer" })
        #expect(unknown.payloadJSON.flatMap(JSONValue.parse)?["completed"]?.boolValue == false)
        #expect(unknown.payloadJSON.flatMap(JSONValue.parse)?["state"]?.stringValue == "outcomeUnknown")
        #expect(state.entries.contains { $0.id == fixture.link.id && $0.kind == "importedHistory" })
        #expect(!state.isRunning)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try legacyRows(stores) == before)
        try await manager.shutdown()
    }

    @Test(arguments: [NativeSessionProvider.claude, .codex])
    func importedSnapshotsKeepAllRowsRevisionsAndNeverBecomeContext(provider: NativeSessionProvider) throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example imports")
        var page = NativeTranscriptPage(session: .init(provider: provider, externalID: "imported", title: "Saved source"),
            messages: (0..<200).map { .init(externalID: "message-\($0)", role: .assistant, text: "Imported evidence \($0)") },
            nextCursor: "more", coverage: "Saved text", direction: .newer)
        let chat = try stores.importWorkspaceNativeSession(pages: [page], projectID: project.id, reviewed: true)
        let link = try #require(try stores.workspaceSessionLinks(chatID: chat.id).first)
        page.messages[0].text = "Corrected imported evidence"
        try stores.mergeWorkspaceNativePage(linkID: link.id, page: page, requestCursor: nil)
        var last = page
        last.messages = [.init(externalID: "message-200", role: .assistant, text: "Last saved page")]
        last.nextCursor = nil
        try stores.mergeWorkspaceNativePage(linkID: link.id, page: last, requestCursor: "more")
        let saved = try stores.workspaceNativeMessages(linkID: link.id, limit: 200)
            + stores.workspaceNativeMessages(linkID: link.id, offset: 200)
        let revisions = try stores.workspaceNativeRevisions(messageID: saved[0].id)
        let entries = try stores.agentEntries(chatID: chat.id)
        let source = try #require(entries.first)
        #expect(entries.count == 1 && source.id == link.id)
        #expect(source.importedMessages.map(\.id) == saved.map(\.id))
        #expect(source.importedMessages.map(\.text) == saved.map(\.text))
        #expect(source.importedMessages.first?.payloadJSON.flatMap(JSONValue.parse)?["revision"] == .number(2))
        #expect(revisions.map(\.revision) == [1, 2])
        #expect(try stores.agentEntries(chatID: chat.id) == entries)
        for entry in [source, source.importedMessages[0]] {
            #expect(throws: AgentStoreError.invalidValue) { try stores.saveAgentEntry(entry) }
        }
        for provider in [AgentProvider.claude, .codex, .local] {
            let session = AgentChatSession(chatID: chat.id, provider: provider, cwd: "/tmp", model: "fixture")
            try stores.saveAgentSession(session)
            #expect(try stores.agentContext(session: session) == nil)
        }
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.workspaceNativeRevisions(messageID: saved[0].id) == revisions)
        #expect(throws: AgentStoreError.missingChat) { try stores.agentEntries(chatID: UUID()) }
    }

    @Test func scopeGuardsSurviveLegacyReadArchiveAndNewProviderSession() throws {
        let stores = try inMemoryStores()
        let fixture = try LegacyChatFixture(stores)
        let other = try stores.createWorkspaceChat(projectID: fixture.chat.projectID, title: "Other chat")
        try stores.appendMessage(.init(conversationID: other.localConversationID, role: "user", content: "Other chat canary"))
        let before = try legacyRows(stores)
        let session = AgentChatSession(chatID: fixture.chat.id, provider: .local, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(session)
        let context = try #require(try stores.agentContext(session: session))
        for excluded in ["Imported evidence", "Capture evidence", "Other chat canary", "Unattributed Claude evidence", "Partial old answer"] {
            #expect(!context.text.contains(excluded))
        }
        #expect(context.entryCount == 6) // local, owned Codex/Claude, linked native
        #expect(try stores.agentEntries(chatID: other.id).map(\.text) == ["Other chat canary"])
        let visible = try stores.agentEntries(chatID: fixture.chat.id)
        try stores.setWorkspaceChatArchived(id: fixture.chat.id, archived: true)
        #expect(try stores.agentEntries(chatID: fixture.chat.id) == visible)
        #expect(throws: AgentSessionManagerError.chatUnavailable) { try stores.requireAgentChatAvailable(chatID: fixture.chat.id) }
        let event = ActivityEvent(kind: .conversationArchived, summary: "Must stay scoped")
        #expect(try !stores.archiveConversation(event, fingerprint: "legacy-scope", facts: [MemoryFact(text: "Must stay scoped")],
                                               sourceConversationID: fixture.chat.localConversationID))
        #expect(try !stores.hasSeen(connectorID: "archiver", itemID: "legacy-scope"))
        #expect(try stores.db.queue.read { try MemoryFact.fetchCount($0) } == 0)
        // Archive changes local metadata only; every source row stays intact.
        let after = try legacyRows(stores)
        for table in before.keys where table != "workspaceChat" { #expect(after[table] == before[table]) }
    }
}

/// Synthetic pre-unified evidence, including a separate provider profile that
/// is deliberately never created on disk. No login or credential migration.
private struct LegacyChatFixture {
    let chat: WorkspaceChat
    let link: WorkspaceSessionLink
    let capture: CaptureRecord

    init(_ stores: Stores) throws {
        let project = try stores.createWorkspaceProject(title: "Example legacy project")
        var page = NativeTranscriptPage(session: .init(provider: .claude, externalID: "imported", title: "Imported source"),
            messages: [.init(externalID: "imported-answer", role: .assistant, text: "Imported evidence")], coverage: "Saved text")
        chat = try stores.importWorkspaceNativeSession(pages: [page], projectID: project.id, reviewed: true)
        link = try #require(try stores.workspaceSessionLinks(chatID: chat.id).first)
        page.messages[0].text = "Imported evidence revised"
        try stores.mergeWorkspaceNativePage(linkID: link.id, page: page, requestCursor: nil)
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "assistant", content: "Local saved answer"))
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex, .claude], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let codex = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "fixture", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        _ = try stores.bindWorkspaceFrontierSession(id: codex.id, externalID: "old-owned-codex")
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: codex.id, prompt: "Owned Codex question")
        turn.state = .running; turn.providerTurnID = "old-turn"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.state = .completed; turn.outputText = "Owned Codex answer"; turn.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(turn)
        let claude = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "missing-separate-profile",
            model: "fixture", effort: nil, expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        let bound = try stores.bindWorkspaceClaudeSession(id: claude.id, externalID: UUID().uuidString)
        var reply = try stores.beginWorkspaceClaudeTurn(sessionID: claude.id, prompt: "Owned Claude question")
        reply.state = .running; reply.providerTurnID = "old-claude-turn"
        try stores.saveWorkspaceClaudeTurn(reply)
        reply.state = .completed; reply.outputText = "Owned Claude answer"; reply.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(reply)
        try stores.replaceWorkspaceClaudeProjection(sessionID: claude.id, expectedProfileNamespace: bound.profileNamespace,
            snapshot: .init(sessionID: bound.externalID!, profileNamespace: bound.profileNamespace,
                messages: [.init(id: UUID().uuidString, role: "assistant", text: "Unattributed Claude evidence")], complete: true, observedAt: .now))
        var partial = try stores.beginWorkspaceClaudeTurn(sessionID: claude.id, prompt: "Uncertain old input")
        partial.state = .running; partial.outputText = "Partial old answer"
        try stores.saveWorkspaceClaudeTurn(partial)
        _ = try stores.reconcileUnfinishedWorkspaceClaudeTurns()
        let nativeProject = NativeProjectSnapshot(identity: .init(provider: .codex, hostID: "fixture-host",
            profileNamespace: "fixture", externalID: "native-project"), name: "Example", roots: [.init(path: "/synthetic/native")])
        let projectLink = try stores.linkWorkspaceCodexProject(projectID: project.id, snapshot: nativeProject,
            reviewedRoots: [.init(path: "/synthetic/native", canonicalPath: "/synthetic/native", filesystemIdentity: "fixture-device:1", availability: .available)], reviewed: true)
        let native = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: projectLink.id,
            nativeProjectIdentity: nativeProject.identity, nativeThreadID: "linked-thread", workingDirectory: "/synthetic/native",
            expectedProjectRevision: projectLink.revision, reviewed: true)
        _ = try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: native.id,
            snapshot: .init(id: "linked-thread", name: "Example", projectID: "native-project", cwd: "/synthetic/native", status: "idle", raw: [:],
                turns: [.init(id: "linked-turn", status: "completed", order: 0, raw: [:])],
                items: [.init(id: "reply", turnID: "linked-turn", kind: "agentMessage", order: 0,
                              raw: ["item": ["id": "reply", "type": "agentMessage", "text": "Linked native answer"]])], complete: true),
            expectedProjectRevision: projectLink.revision, expectedChatRevision: native.revision, expectedProjectionRevision: nil)
        capture = CaptureRecord(startedAt: .now, endedAt: .now, title: "Example capture", scope: "Microphone", audio: "mic",
                                consentConfirmed: true, transcript: "Capture evidence")
        try stores.saveCaptureRecord(capture, workspaceChatID: chat.id)
    }
}

private func legacyRows(_ stores: Stores) throws -> [String: [Row]] {
    try stores.db.queue.read { db in
        let tables = ["workspaceProject", "workspaceChat", "conversation", "storedMessage", "workspaceSessionLink",
            "workspaceNativeSnapshot", "workspaceNativeMessage", "workspaceNativeRevision", "workspacePolicy", "workspacePolicyState",
            "workspaceFrontierSession", "workspaceFrontierTurn", "workspaceClaudeSession", "workspaceClaudeTurn",
            "workspaceClaudeHistoryObservation", "workspaceClaudeMessageIdentity", "workspaceHandover", "workspaceCaptureTarget",
            "workspaceCodexProjectLink", "workspaceCodexChatLink", "workspaceCodexNativeItem", "workspaceCodexNativeProjection",
            "workspaceCodexNativeObservation", "workspaceCodexNativeOperation", "workspaceCodexNativeOperationEvent", "captureRecord"]
        return try Dictionary(uniqueKeysWithValues: tables.map { ($0, try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY rowid")) })
    }
}
