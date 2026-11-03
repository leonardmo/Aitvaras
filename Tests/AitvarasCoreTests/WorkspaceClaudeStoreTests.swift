import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

func removeWorkspaceClaudeMigrationForTest(_ db: Database) throws {
    for table in ["workspaceClaudeMessageIdentity", "workspaceClaudeHistoryObservation"] {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v27-workspace-claude-owned-history'")
    for table in ["workspaceClaudeTurn", "workspaceClaudeSession"] {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v26-workspace-claude-sessions'")
}

@Suite struct WorkspaceClaudeStoreTests {
    private func setup(_ stores: Stores) throws -> (WorkspaceProject, WorkspaceChat, WorkspaceClaudeSession) {
        let project = try stores.createWorkspaceProject(title: "Synthetic project", instructions: "Metadata instructions")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Same title", purpose: "Selected purpose")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.claude], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let session = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: "medium",
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        return (project, chat, session)
    }

    @Test func ownedIdentityIsSeparateFromChatHistoryAndSameTitleChats() throws {
        let stores = try inMemoryStores()
        let (project, chat, session) = try setup(stores)
        let other = try stores.createWorkspaceChat(projectID: project.id, title: chat.title)
        #expect(session.id != chat.id && session.id != chat.localConversationID)
        #expect(session.externalID == nil && session.profileNamespace == "synthetic-profile")
        #expect(session.reviewedContext == (try stores.workspaceContextPacket(chatID: chat.id)).promptText)
        #expect(try stores.workspaceClaudeSessions(chatID: other.id, profileNamespace: "synthetic-profile").isEmpty)
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceProject(id: project.id)?.allowsCloud == false)
        #expect(try stores.workspacePolicy(projectID: project.id)?.allowsTools == false)
    }

    @Test func creationRejectsUnreviewedStaleApprovalAndRevokedProvider() throws {
        let stores = try inMemoryStores()
        let (project, chat, session) = try setup(stores)
        #expect(throws: WorkspaceClaudeError.staleContext) {
            try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: nil,
                expectedPolicyRevision: session.policyRevision, reviewedContext: "Stale approved text")
        }
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [], expectedRevision: review.revision)
        #expect(throws: WorkspaceClaudeError.reviewRequired) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Hello") }
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.claude], expectedRevision: review.revision)
        #expect(throws: WorkspaceClaudeError.staleContext) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Hello") }
        let unreviewed = try stores.createWorkspaceProject(title: "Unreviewed")
        let target = try stores.createWorkspaceChat(projectID: unreviewed.id, title: "Target")
        #expect(throws: WorkspaceClaudeError.reviewRequired) {
            try stores.createWorkspaceClaudeSession(chatID: target.id, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: nil,
                expectedPolicyRevision: 0, reviewedContext: "")
        }
    }

    @Test(arguments: ["instructions", "projectTitle", "chatTitle", "purpose", "folders", "hidden", "archived"])
    func metadataChangesAndRevertsNeverReviveSession(field: String) throws {
        let stores = try inMemoryStores()
        var (project, chat, session) = try setup(stores)
        switch field {
        case "instructions":
            let old = project.instructions; project.instructions = "Changed"; try stores.saveWorkspaceProject(project)
            project.instructions = old; try stores.saveWorkspaceProject(project)
        case "projectTitle":
            let old = project.title; project.title = "Changed"; try stores.saveWorkspaceProject(project)
            project.title = old; try stores.saveWorkspaceProject(project)
        case "chatTitle":
            let old = chat.title; chat.title = "Changed"; try stores.saveWorkspaceChat(chat)
            chat.title = old; try stores.saveWorkspaceChat(chat)
        case "purpose":
            let old = chat.purpose; chat.purpose = "Changed"; try stores.saveWorkspaceChat(chat)
            chat.purpose = old; try stores.saveWorkspaceChat(chat)
        case "folders":
            try stores.replaceWorkspaceFolders(projectID: project.id, folders: [.init(path: "/synthetic/review-folder")])
            try stores.replaceWorkspaceFolders(projectID: project.id, folders: [])
        case "hidden":
            project.isVisible = false; try stores.saveWorkspaceProject(project)
            project.isVisible = true; try stores.saveWorkspaceProject(project)
        default:
            try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
            try stores.setWorkspaceChatArchived(id: chat.id, archived: false)
        }
        #expect(throws: (any Error).self) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Hello") }
        #expect(try stores.workspaceClaudeSession(id: session.id) == session)
    }

    @Test func immutableBindingRejectsImportedOrAlreadyOwnedIDs() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .claude,
            externalID: "synthetic-imported", displayName: "Imported"))
        #expect(throws: WorkspaceClaudeError.importedIdentity) {
            try stores.bindWorkspaceClaudeSession(id: session.id, externalID: "synthetic-imported")
        }
        _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .claude,
            externalID: "synthetic-remote-imported", hostID: "synthetic-remote", displayName: "Imported remotely"))
        #expect(throws: WorkspaceClaudeError.importedIdentity) {
            try stores.bindWorkspaceClaudeSession(id: session.id, externalID: "synthetic-remote-imported")
        }
        let bound = try stores.bindWorkspaceClaudeSession(id: session.id, externalID: "synthetic-owned")
        #expect(try stores.bindWorkspaceClaudeSession(id: session.id, externalID: "synthetic-owned") == bound)
        #expect(throws: WorkspaceClaudeError.immutableIdentity) {
            try stores.bindWorkspaceClaudeSession(id: session.id, externalID: "synthetic-reassigned")
        }
        let other = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: nil,
            expectedPolicyRevision: session.policyRevision, reviewedContext: session.reviewedContext)
        #expect(throws: WorkspaceClaudeError.immutableIdentity) {
            try stores.bindWorkspaceClaudeSession(id: other.id, externalID: "synthetic-owned")
        }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceClaudeSession SET reviewedContext = 'changed' WHERE id = ?", arguments: [session.id]) }
        }
    }

    @Test func reservationsBlockDuplicateAndValidatePrompt() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        for bad in [" \n", String(repeating: "x", count: 24_001), "bad\0value"] {
            #expect(throws: WorkspaceClaudeError.invalidValue) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: bad) }
        }
        let prompt = "  Preserve exactly\n"
        let turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: prompt)
        #expect(turn.state == .prepared && turn.promptText == prompt)
        #expect(throws: WorkspaceClaudeError.unresolvedTurn) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Duplicate") }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceClaudeTurn SET promptText = 'changed' WHERE id = ?", arguments: [turn.id]) }
        }
    }

    @Test func undeliveredFailureIsDistinctFromAnUnknownOutcomeAndKeepsItsReason() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)

        // Failed before the provider acknowledged anything: nothing was sent.
        var undelivered = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Never left")
        #expect(throws: WorkspaceClaudeError.invalidTransition) {
            try stores.recordWorkspaceClaudeTurnFailure(id: undelivered.id, reason: "Too early")
        }
        undelivered.state = .failed; undelivered.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(undelivered)
        try stores.recordWorkspaceClaudeTurnFailure(id: undelivered.id, reason: "  Sign in first.  ")
        #expect(try stores.workspaceClaudeTurnFailureReason(id: undelivered.id) == "Sign in first.")

        // A failed undelivered turn does not block the session the way an
        // unknown outcome does, so the same thread can carry on.
        var uncertain = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Maybe left")
        uncertain.state = .running
        try stores.saveWorkspaceClaudeTurn(uncertain)
        uncertain.state = .outcomeUnknown; uncertain.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(uncertain)
        try stores.recordWorkspaceClaudeTurnFailure(id: uncertain.id, reason: String(repeating: "x", count: 900))
        #expect(try stores.workspaceClaudeTurnFailureReason(id: uncertain.id)?.count
                == Stores.maximumClaudeFailureReasonCharacters)
        #expect(throws: WorkspaceClaudeError.unresolvedTurn) {
            try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Blocked by the unknown one")
        }

        let entries = try stores.workspaceChatTimeline(chatID: chat.id).filter { $0.role == "user" }
        let never = try #require(entries.first { $0.text == "Never left" })
        let maybe = try #require(entries.first { $0.text == "Maybe left" })
        #expect(never.notDelivered && never.failureReason == "Sign in first.")
        #expect(!maybe.notDelivered && maybe.state == .outcomeUnknown)
        // Neither reaches model context; only completed turns do.
        #expect(!(try stores.workspaceChatHistoryText(chatID: chat.id)).contains("Never left"))
    }

    @Test func cancellationAndTerminalOutcomesRemainHonest() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Hello")
        turn.state = .completed; turn.endedAt = .now
        #expect(throws: WorkspaceClaudeError.invalidTransition) { try stores.saveWorkspaceClaudeTurn(turn) }
        turn.state = .running; turn.endedAt = nil; turn.providerTurnID = "synthetic-turn"
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.state = .cancellationRequested; turn.outputText = "Partial output"
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.state = .completed; turn.endedAt = .now
        #expect(throws: WorkspaceClaudeError.invalidTransition) { try stores.saveWorkspaceClaudeTurn(turn) }
        turn.state = .cancelled
        try stores.saveWorkspaceClaudeTurn(turn)
        try stores.saveWorkspaceClaudeTurn(turn) // exact idempotent checkpoint
        turn.state = .completed
        #expect(throws: WorkspaceClaudeError.invalidTransition) { try stores.saveWorkspaceClaudeTurn(turn) }
        #expect(try stores.workspaceClaudeTurn(id: turn.id)?.state == .cancelled)
        #expect(try stores.workspaceClaudeTurn(id: turn.id)?.outputText == "Partial output")
        _ = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Explicit follow-up")
    }

    @Test func actualCompletionAfterCancellationRequiresExplicitAcknowledgement() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Hello")
        turn.state = .running; turn.providerTurnID = "synthetic-turn"
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.providerTurnID = "changed"
        #expect(throws: WorkspaceClaudeError.immutableIdentity) { try stores.saveWorkspaceClaudeTurn(turn) }
        turn.providerTurnID = "synthetic-turn"; turn.state = .cancellationRequested
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.state = .completed; turn.endedAt = .now; turn.inputTokens = 10; turn.outputTokens = 20
        try stores.saveWorkspaceClaudeTurn(turn, allowCompletedAfterCancellation: true)
        let saved = try #require(try stores.workspaceClaudeTurn(id: turn.id))
        #expect(saved.state == .completed && saved.providerTurnID == turn.providerTurnID)
        #expect(saved.inputTokens == 10 && saved.outputTokens == 20)
        let savedEnd = try #require(saved.endedAt)
        let requestedEnd = try #require(turn.endedAt)
        #expect(abs(savedEnd.timeIntervalSince(requestedEnd)) < 0.001)
    }

    @Test(arguments: [WorkspaceFrontierTurnState.prepared, .running, .cancellationRequested, .outcomeUnknown, .interrupted])
    func unresolvedClaudeWorkPreventsAutomaticChatArchival(state: WorkspaceFrontierTurnState) throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        var temporary = chat
        temporary.kind = .temporary
        try stores.saveWorkspaceChat(temporary)
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Synthetic work")
        if state == .running || state == .cancellationRequested || state == .outcomeUnknown {
            turn.state = .running
            try stores.saveWorkspaceClaudeTurn(turn)
        }
        turn.state = state
        if state.isTerminal { turn.endedAt = .now }
        try stores.saveWorkspaceClaudeTurn(turn)
        try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ?",
            arguments: [Date.now.addingTimeInterval(-9 * 86_400), chat.id]) }
        #expect(try stores.archiveExpiredWorkspaceChats() == 0)
        #expect(try stores.workspaceChat(id: chat.id)?.archivedAt == nil)
    }

    @Test func terminalTimeUsesDatabasePrecisionWithoutAllowingEarlierOutcomes() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        var fast = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Synthetic fast outcome")
        fast.state = .failed
        fast.endedAt = fast.startedAt.addingTimeInterval(-0.0005)
        try stores.saveWorkspaceClaudeTurn(fast)
        let saved = try #require(try stores.workspaceClaudeTurn(id: fast.id))
        #expect(saved.endedAt == saved.startedAt)
        var invalid = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Synthetic invalid time")
        invalid.state = .failed
        invalid.endedAt = invalid.startedAt.addingTimeInterval(-0.01)
        #expect(throws: WorkspaceClaudeError.invalidValue) { try stores.saveWorkspaceClaudeTurn(invalid) }
    }

    @Test func explicitStartupReconciliationNeverReplaysAndPreservesOutput() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        let reserved = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Reserved")
        let second = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: nil,
            expectedPolicyRevision: session.policyRevision, reviewedContext: session.reviewedContext)
        var delivered = try stores.beginWorkspaceClaudeTurn(sessionID: second.id, prompt: "Maybe delivered")
        delivered.state = .running; delivered.outputText = "Partial"
        try stores.saveWorkspaceClaudeTurn(delivered)
        #expect(try stores.reconcileUnfinishedWorkspaceClaudeTurns() == 2)
        #expect(try stores.reconcileUnfinishedWorkspaceClaudeTurns() == 0)
        #expect(try stores.workspaceClaudeTurn(id: reserved.id)?.state == .interrupted)
        #expect(try stores.workspaceClaudeTurn(id: delivered.id)?.state == .outcomeUnknown)
        #expect(try stores.workspaceClaudeTurn(id: delivered.id)?.outputText == "Partial")
        for owned in [session, second] {
            #expect(throws: WorkspaceClaudeError.unresolvedTurn) { try stores.beginWorkspaceClaudeTurn(sessionID: owned.id, prompt: "Must not replay") }
        }
    }

    @Test func v25MigrationPersistenceAndDeletionPreserveOriginalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let projectID: UUID, chatID: UUID, codexTurnID: UUID, handoverID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let project = try stores.createWorkspaceProject(title: "Existing")
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Existing")
            projectID = project.id; chatID = chat.id
            try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Keep original"))
            _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .claude, externalID: "synthetic-native", displayName: "Keep native"))
            let review = try stores.workspacePolicyReview(projectID: project.id)
            let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
            let codex = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-codex", effort: nil,
                expectedPolicyRevision: policy.revision, reviewedContext: stores.workspaceContextPacket(chatID: chat.id).promptText)
            let handover = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.codexSession(codex.id)))
            var codexTurn = try stores.beginWorkspaceFrontierTurn(sessionID: codex.id, prompt: "Keep Codex input")
            codexTurn.state = .running; codexTurn.providerTurnID = "synthetic-codex-turn"
            try stores.saveWorkspaceFrontierTurn(codexTurn)
            codexTurn.state = .completed; codexTurn.outputText = "Keep Codex answer"; codexTurn.endedAt = .now
            try stores.saveWorkspaceFrontierTurn(codexTurn)
            codexTurnID = codexTurn.id
            handoverID = try stores.recordWorkspaceHandover(handover, chatID: chat.id, turnID: codexTurn.id, anchor: codexTurn.startedAt).id
            try stores.db.queue.write { try removeWorkspaceClaudeMigrationForTest($0) }
        }
        let sessionID: UUID, turnID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            #expect(try stores.workspaceClaudeSessions(chatID: chatID, profileNamespace: "synthetic-profile").isEmpty)
            let review = try stores.workspacePolicyReview(projectID: projectID)
            let policy = try stores.reviewWorkspacePolicy(projectID: projectID, allowedProviders: [.claude], expectedRevision: review.revision)
            let session = try stores.createWorkspaceClaudeSession(chatID: chatID, profileNamespace: "synthetic-profile", model: "synthetic-model", effort: nil,
                expectedPolicyRevision: policy.revision, reviewedContext: stores.workspaceContextPacket(chatID: chatID).promptText)
            sessionID = session.id
            turnID = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Retained turn").id
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.workspaceClaudeTurn(id: turnID)?.state == .prepared) // initialization never reconciles implicitly
        #expect(throws: (any Error).self) { try stores.db.queue.write { try $0.execute(sql: "DELETE FROM workspaceClaudeSession WHERE id = ?", arguments: [sessionID]) } }
        #expect(throws: (any Error).self) { try stores.db.queue.write { try $0.execute(sql: "DELETE FROM workspaceChat WHERE id = ?", arguments: [chatID]) } }
        try stores.setWorkspaceChatArchived(id: chatID, archived: true)
        #expect(try stores.workspaceClaudeTurns(sessionID: sessionID).count == 1)
        let chat = try #require(try stores.workspaceChat(id: chatID))
        #expect(try stores.messages(in: chat.localConversationID).first?.content == "Keep original")
        #expect(try stores.workspaceSessionLinks(chatID: chatID).first?.externalID == "synthetic-native")
        #expect(try stores.workspaceFrontierTurn(id: codexTurnID)?.outputText == "Keep Codex answer")
        #expect(try stores.workspaceHandovers(chatID: chatID).map(\.id) == [handoverID])
    }

    @Test func profilesPartitionDurableIdentityAndNeverReassignIt() throws {
        let stores = try inMemoryStores()
        let (_, chat, first) = try setup(stores)
        let second = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-other-profile",
            model: first.model, effort: nil, expectedPolicyRevision: first.policyRevision, reviewedContext: first.reviewedContext)
        _ = try stores.bindWorkspaceClaudeSession(id: first.id, externalID: "synthetic-shared-id")
        _ = try stores.bindWorkspaceClaudeSession(id: second.id, externalID: "synthetic-shared-id")
        #expect(try stores.workspaceClaudeSessions(chatID: chat.id, profileNamespace: first.profileNamespace).map(\.id) == [first.id])
        #expect(try stores.workspaceClaudeSessions(chatID: chat.id, profileNamespace: second.profileNamespace).map(\.id) == [second.id])
        #expect(try stores.workspaceClaudeSessions(chatID: chat.id, profileNamespace: "synthetic-empty-profile").isEmpty)
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceClaudeSession SET profileNamespace = ? WHERE id = ?",
                arguments: [second.profileNamespace, first.id]) }
        }
        for bad in ["", " ", "bad\nprofile"] {
            #expect(throws: WorkspaceClaudeError.invalidValue) {
                try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: bad,
                    model: first.model, effort: nil, expectedPolicyRevision: first.policyRevision, reviewedContext: first.reviewedContext)
            }
        }
    }

    private func complete(_ stores: Stores, session: WorkspaceClaudeSession, prompt: String, reply: String) throws -> WorkspaceClaudeTurn {
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: prompt)
        turn.state = .running; turn.providerTurnID = "synthetic-turn-\(turn.id)"
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.state = .completed; turn.outputText = reply; turn.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(turn)
        return try #require(try stores.workspaceClaudeTurn(id: turn.id))
    }

    @Test func logicalChatContinuityAttributesProvidersAndAdvancesClaudeWatermarks() throws {
        let stores = try inMemoryStores()
        let (project, chat, initial) = try setup(stores)
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.claude, .codex], expectedRevision: review.revision)
        let claude = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: initial.profileNamespace,
            model: initial.model, effort: nil, expectedPolicyRevision: policy.revision, reviewedContext: initial.reviewedContext)
        let codex = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-codex", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: initial.reviewedContext)
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Local start",
            createdAt: Date.now.addingTimeInterval(-20)))
        let claudeKey = WorkspaceThreadKey.claudeSession(claude.id)
        let incoming = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: claudeKey))
        let reply = try complete(stores, session: claude, prompt: "Claude question", reply: "Claude answer")
        try stores.recordWorkspaceHandover(incoming, chatID: chat.id, turnID: reply.id, anchor: reply.startedAt.addingTimeInterval(-0.001))
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: claudeKey) == nil)
        let codexKey = WorkspaceThreadKey.codexSession(codex.id)
        let outgoing = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: codexKey))
        #expect(outgoing.entryCount == 3 && outgoing.providers.contains("claude") && outgoing.providers.contains("local"))
        #expect(outgoing.text.contains("[assistant · Claude] Claude answer"))
        var codexTurn = try stores.beginWorkspaceFrontierTurn(sessionID: codex.id, prompt: "Codex follow-up")
        codexTurn.state = .running; codexTurn.providerTurnID = "synthetic-codex-turn"
        try stores.saveWorkspaceFrontierTurn(codexTurn)
        codexTurn.state = .completed; codexTurn.outputText = "Codex answer"; codexTurn.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(codexTurn)
        try stores.recordWorkspaceHandover(outgoing, chatID: chat.id, turnID: codexTurn.id, anchor: codexTurn.startedAt.addingTimeInterval(-0.001))
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: codexKey) == nil)
        let returning = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: claudeKey))
        #expect(returning.entryCount == 2 && returning.providers == ["codex"])
        let timeline = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(timeline.contains { $0.provider == "claude" && $0.sourceThread == claudeKey && $0.text == "Claude answer" })
        #expect(timeline.contains { $0.provider == "codex" && $0.sourceThread == codexKey && $0.text == "Codex answer" })
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).isEmpty)
        let history = try stores.workspaceChatHistoryText(chatID: chat.id)
        #expect(history.contains("[assistant / claude]\nClaude answer") && history.contains("[assistant / codex]\nCodex answer"))
    }

    @Test func handoverStreamsAllClaudeMessagesWithStableTiesAndExcludesUnknownOutput() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        // More than the UI's 200-entry limit, all at the same instant. The
        // transcript and full-history cursor must use precisely the same order.
        let instant = Date.now.addingTimeInterval(-60)
        try stores.db.queue.write { db in
            for index in 0..<150 {
                try db.execute(sql: """
                    INSERT INTO workspaceClaudeTurn(id, sessionID, state, promptText, outputText, providerTurnID, startedAt, endedAt)
                    VALUES (?, ?, 'completed', ?, ?, ?, ?, ?)
                    """, arguments: [UUID(), session.id, "Synthetic question \(index)", "Synthetic answer \(index)",
                        "synthetic-turn-\(index)", instant, instant])
            }
        }
        var uncertain = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Unknown question")
        uncertain.state = .running; uncertain.outputText = "Unknown partial output"
        try stores.saveWorkspaceClaudeTurn(uncertain)
        _ = try stores.reconcileUnfinishedWorkspaceClaudeTurns()
        let target = WorkspaceThreadKey.codexSession(UUID())
        let full = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: target, maximumCharacters: 50_000))
        #expect(full.entryCount == 300 && full.omittedCount == 0 && full.providers == ["claude"])
        #expect(!full.text.contains("Unknown"))
        let timeline = try stores.workspaceChatTimeline(chatID: chat.id, limit: 500).filter { $0.state == .completed }
        let expected = timeline.map { "[\($0.role) · Claude] \($0.text)" }.joined(separator: "\n")
        #expect(full.text.contains(expected))
        let bounded = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: target, maximumCharacters: 1_000))
        #expect(bounded.entryCount + bounded.omittedCount == 300 && bounded.omittedCount > 0)
        try stores.recordWorkspaceHandover(full, chatID: chat.id, turnID: UUID(), anchor: .now)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: target) == nil)
    }
}
