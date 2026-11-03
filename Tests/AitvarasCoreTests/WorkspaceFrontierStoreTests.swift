import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

func removeWorkspaceFrontierMigrationForTest(_ db: Database) throws {
    try removeWorkspaceClaudeMigrationForTest(db)
    try removeWorkspaceCodexLinkMigrationForTest(db)
    for trigger in ["workspaceFrontierChatInsert", "workspaceFrontierChatContextUpdate", "workspaceFrontierProjectContextUpdate"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    for table in ["workspaceFrontierTurn", "workspaceFrontierSession", "workspaceFrontierContextState"] { try db.drop(table: table) }
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v21-workspace-frontier-sessions'")
    // v24 alters the turn table; replaying v21 must replay it as well.
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v24-frontier-turn-failure-reason'")
}

@Suite struct WorkspaceFrontierStoreTests {
    private func setup(_ stores: Stores) throws -> (WorkspaceProject, WorkspaceChat, WorkspaceFrontierSession) {
        let project = try stores.createWorkspaceProject(title: "Synthetic project", instructions: "Metadata instructions")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Same title", purpose: "Selected purpose")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let session = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: "medium",
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        return (project, chat, session)
    }

    @Test func ownedIdentityIsSeparateFromChatHistoryAndSameTitleChats() throws {
        let stores = try inMemoryStores()
        let (project, chat, session) = try setup(stores)
        let other = try stores.createWorkspaceChat(projectID: project.id, title: chat.title)
        #expect(session.id != chat.id && session.id != chat.localConversationID)
        #expect(session.externalID == nil && session.provider == .codex)
        #expect(session.reviewedContext == (try stores.workspaceContextPacket(chatID: chat.id)).promptText)
        #expect(try stores.workspaceFrontierSessions(chatID: other.id).isEmpty)
        #expect(try stores.messages(in: chat.localConversationID).isEmpty)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceProject(id: project.id)?.allowsCloud == false)
        #expect(try stores.workspacePolicy(projectID: project.id)?.allowsTools == false)
    }

    @Test func creationRejectsUnreviewedStaleApprovalAndRevokedProvider() throws {
        let stores = try inMemoryStores()
        let (project, chat, session) = try setup(stores)
        #expect(throws: WorkspaceFrontierError.staleContext) {
            try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
                expectedPolicyRevision: session.policyRevision, reviewedContext: "Stale approved text")
        }
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [], expectedRevision: review.revision)
        #expect(throws: WorkspaceFrontierError.reviewRequired) { try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Hello") }
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        #expect(throws: WorkspaceFrontierError.staleContext) { try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Hello") }
        let unreviewed = try stores.createWorkspaceProject(title: "Unreviewed")
        let target = try stores.createWorkspaceChat(projectID: unreviewed.id, title: "Target")
        #expect(throws: WorkspaceFrontierError.reviewRequired) {
            try stores.createWorkspaceFrontierSession(chatID: target.id, model: "synthetic-model", effort: nil,
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
        #expect(throws: (any Error).self) { try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Hello") }
        #expect(try stores.workspaceFrontierSession(id: session.id) == session)
    }

    @Test func immutableBindingRejectsImportedOrAlreadyOwnedIDs() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-imported", displayName: "Imported"))
        #expect(throws: WorkspaceFrontierError.importedIdentity) {
            try stores.bindWorkspaceFrontierSession(id: session.id, externalID: "synthetic-imported")
        }
        _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex,
            externalID: "synthetic-remote-imported", hostID: "synthetic-remote", displayName: "Imported remotely"))
        #expect(throws: WorkspaceFrontierError.importedIdentity) {
            try stores.bindWorkspaceFrontierSession(id: session.id, externalID: "synthetic-remote-imported")
        }
        let bound = try stores.bindWorkspaceFrontierSession(id: session.id, externalID: "synthetic-owned")
        #expect(try stores.bindWorkspaceFrontierSession(id: session.id, externalID: "synthetic-owned") == bound)
        #expect(throws: WorkspaceFrontierError.immutableIdentity) {
            try stores.bindWorkspaceFrontierSession(id: session.id, externalID: "synthetic-reassigned")
        }
        let other = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: session.policyRevision, reviewedContext: session.reviewedContext)
        #expect(throws: WorkspaceFrontierError.immutableIdentity) {
            try stores.bindWorkspaceFrontierSession(id: other.id, externalID: "synthetic-owned")
        }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceFrontierSession SET reviewedContext = 'changed' WHERE id = ?", arguments: [session.id]) }
        }
    }

    @Test func reservationsBlockDuplicateAndValidatePrompt() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        for bad in [" \n", String(repeating: "x", count: 24_001), "bad\0value"] {
            #expect(throws: WorkspaceFrontierError.invalidValue) { try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: bad) }
        }
        let prompt = "  Preserve exactly\n"
        let turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: prompt)
        #expect(turn.state == .prepared && turn.promptText == prompt)
        #expect(throws: WorkspaceFrontierError.unresolvedTurn) { try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Duplicate") }
        #expect(throws: (any Error).self) {
            try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceFrontierTurn SET promptText = 'changed' WHERE id = ?", arguments: [turn.id]) }
        }
    }

    @Test func undeliveredFailureIsDistinctFromAnUnknownOutcomeAndKeepsItsReason() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)

        // Failed before the provider acknowledged anything: nothing was sent.
        var undelivered = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Never left")
        #expect(throws: WorkspaceFrontierError.invalidTransition) {
            try stores.recordWorkspaceFrontierTurnFailure(id: undelivered.id, reason: "Too early")
        }
        undelivered.state = .failed; undelivered.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(undelivered)
        try stores.recordWorkspaceFrontierTurnFailure(id: undelivered.id, reason: "  Sign in first.  ")
        #expect(try stores.workspaceFrontierTurnFailureReason(id: undelivered.id) == "Sign in first.")

        // A failed undelivered turn does not block the session the way an
        // unknown outcome does, so the same thread can carry on.
        var uncertain = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Maybe left")
        uncertain.state = .running
        try stores.saveWorkspaceFrontierTurn(uncertain)
        uncertain.state = .outcomeUnknown; uncertain.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(uncertain)
        try stores.recordWorkspaceFrontierTurnFailure(id: uncertain.id, reason: String(repeating: "x", count: 900))
        #expect(try stores.workspaceFrontierTurnFailureReason(id: uncertain.id)?.count
                == Stores.maximumFrontierFailureReasonCharacters)
        #expect(throws: WorkspaceFrontierError.unresolvedTurn) {
            try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Blocked by the unknown one")
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
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Hello")
        turn.state = .completed; turn.endedAt = .now
        #expect(throws: WorkspaceFrontierError.invalidTransition) { try stores.saveWorkspaceFrontierTurn(turn) }
        turn.state = .running; turn.endedAt = nil; turn.providerTurnID = "synthetic-turn"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.state = .cancellationRequested; turn.outputText = "Partial output"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.state = .completed; turn.endedAt = .now
        #expect(throws: WorkspaceFrontierError.invalidTransition) { try stores.saveWorkspaceFrontierTurn(turn) }
        turn.state = .cancelled
        try stores.saveWorkspaceFrontierTurn(turn)
        try stores.saveWorkspaceFrontierTurn(turn) // exact idempotent checkpoint
        turn.state = .completed
        #expect(throws: WorkspaceFrontierError.invalidTransition) { try stores.saveWorkspaceFrontierTurn(turn) }
        #expect(try stores.workspaceFrontierTurn(id: turn.id)?.state == .cancelled)
        #expect(try stores.workspaceFrontierTurn(id: turn.id)?.outputText == "Partial output")
        _ = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Explicit follow-up")
    }

    @Test func actualCompletionAfterCancellationRequiresExplicitAcknowledgement() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Hello")
        turn.state = .running; turn.providerTurnID = "synthetic-turn"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.providerTurnID = "changed"
        #expect(throws: WorkspaceFrontierError.immutableIdentity) { try stores.saveWorkspaceFrontierTurn(turn) }
        turn.providerTurnID = "synthetic-turn"; turn.state = .cancellationRequested
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.state = .completed; turn.endedAt = .now; turn.inputTokens = 10; turn.outputTokens = 20
        try stores.saveWorkspaceFrontierTurn(turn, allowCompletedAfterCancellation: true)
        let saved = try #require(try stores.workspaceFrontierTurn(id: turn.id))
        #expect(saved.state == .completed && saved.providerTurnID == turn.providerTurnID)
        #expect(saved.inputTokens == 10 && saved.outputTokens == 20)
        let savedEnd = try #require(saved.endedAt)
        let requestedEnd = try #require(turn.endedAt)
        #expect(abs(savedEnd.timeIntervalSince(requestedEnd)) < 0.001)
    }

    @Test(arguments: [WorkspaceFrontierTurnState.prepared, .running, .cancellationRequested, .outcomeUnknown, .interrupted])
    func unresolvedFrontierWorkPreventsAutomaticChatArchival(state: WorkspaceFrontierTurnState) throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        var temporary = chat
        temporary.kind = .temporary
        try stores.saveWorkspaceChat(temporary)
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Synthetic work")
        if state == .running || state == .cancellationRequested || state == .outcomeUnknown {
            turn.state = .running
            try stores.saveWorkspaceFrontierTurn(turn)
        }
        turn.state = state
        if state.isTerminal { turn.endedAt = .now }
        try stores.saveWorkspaceFrontierTurn(turn)
        try stores.db.queue.write { try $0.execute(sql: "UPDATE workspaceChat SET lastActivityAt = ? WHERE id = ?",
            arguments: [Date.now.addingTimeInterval(-9 * 86_400), chat.id]) }
        #expect(try stores.archiveExpiredWorkspaceChats() == 0)
        #expect(try stores.workspaceChat(id: chat.id)?.archivedAt == nil)
    }

    @Test func terminalTimeUsesDatabasePrecisionWithoutAllowingEarlierOutcomes() throws {
        let stores = try inMemoryStores()
        let (_, _, session) = try setup(stores)
        var fast = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Synthetic fast outcome")
        fast.state = .failed
        fast.endedAt = fast.startedAt.addingTimeInterval(-0.0005)
        try stores.saveWorkspaceFrontierTurn(fast)
        let saved = try #require(try stores.workspaceFrontierTurn(id: fast.id))
        #expect(saved.endedAt == saved.startedAt)
        var invalid = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Synthetic invalid time")
        invalid.state = .failed
        invalid.endedAt = invalid.startedAt.addingTimeInterval(-0.01)
        #expect(throws: WorkspaceFrontierError.invalidValue) { try stores.saveWorkspaceFrontierTurn(invalid) }
    }

    @Test func explicitStartupReconciliationNeverReplaysAndPreservesOutput() throws {
        let stores = try inMemoryStores()
        let (_, chat, session) = try setup(stores)
        let reserved = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Reserved")
        let second = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: session.policyRevision, reviewedContext: session.reviewedContext)
        var delivered = try stores.beginWorkspaceFrontierTurn(sessionID: second.id, prompt: "Maybe delivered")
        delivered.state = .running; delivered.outputText = "Partial"
        try stores.saveWorkspaceFrontierTurn(delivered)
        #expect(try stores.reconcileUnfinishedWorkspaceFrontierTurns() == 2)
        #expect(try stores.reconcileUnfinishedWorkspaceFrontierTurns() == 0)
        #expect(try stores.workspaceFrontierTurn(id: reserved.id)?.state == .interrupted)
        #expect(try stores.workspaceFrontierTurn(id: delivered.id)?.state == .outcomeUnknown)
        #expect(try stores.workspaceFrontierTurn(id: delivered.id)?.outputText == "Partial")
        for owned in [session, second] {
            #expect(throws: WorkspaceFrontierError.unresolvedTurn) { try stores.beginWorkspaceFrontierTurn(sessionID: owned.id, prompt: "Must not replay") }
        }
    }

    @Test func v20MigrationPersistenceAndDeletionPreserveOriginalHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frontier-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.sqlite")
        let projectID: UUID, chatID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let project = try stores.createWorkspaceProject(title: "Existing")
            let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Existing")
            projectID = project.id; chatID = chat.id
            try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Keep original"))
            _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .codex, externalID: "synthetic-native", displayName: "Keep native"))
            try stores.db.queue.write { try removeWorkspaceFrontierMigrationForTest($0) }
        }
        let sessionID: UUID, turnID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            #expect(try stores.workspaceFrontierSessions(chatID: chatID).isEmpty)
            let review = try stores.workspacePolicyReview(projectID: projectID)
            let policy = try stores.reviewWorkspacePolicy(projectID: projectID, allowedProviders: [.codex], expectedRevision: review.revision)
            let session = try stores.createWorkspaceFrontierSession(chatID: chatID, model: "synthetic-model", effort: nil,
                expectedPolicyRevision: policy.revision, reviewedContext: stores.workspaceContextPacket(chatID: chatID).promptText)
            sessionID = session.id
            turnID = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Retained turn").id
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        #expect(try stores.workspaceFrontierTurn(id: turnID)?.state == .prepared) // initialization never reconciles implicitly
        #expect(throws: (any Error).self) { try stores.db.queue.write { try $0.execute(sql: "DELETE FROM workspaceFrontierSession WHERE id = ?", arguments: [sessionID]) } }
        #expect(throws: (any Error).self) { try stores.db.queue.write { try $0.execute(sql: "DELETE FROM workspaceChat WHERE id = ?", arguments: [chatID]) } }
        try stores.setWorkspaceChatArchived(id: chatID, archived: true)
        #expect(try stores.workspaceFrontierTurns(sessionID: sessionID).count == 1)
        let chat = try #require(try stores.workspaceChat(id: chatID))
        #expect(try stores.messages(in: chat.localConversationID).first?.content == "Keep original")
        #expect(try stores.workspaceSessionLinks(chatID: chatID).first?.externalID == "synthetic-native")
    }
}
