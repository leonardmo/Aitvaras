import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore

@Suite struct WorkspaceClaudeHistoryStoreTests {
    private let instant = Date(timeIntervalSince1970: 1_900_000_000)

    private func setup() throws -> (Stores, WorkspaceChat, WorkspaceClaudeSession) {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic history project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic history chat")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.claude], expectedRevision: review.revision)
        let session = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "synthetic-profile", model: "synthetic-model",
            effort: nil, expectedPolicyRevision: policy.revision, reviewedContext: stores.workspaceContextPacket(chatID: chat.id).promptText)
        return (stores, chat, try stores.bindWorkspaceClaudeSession(id: session.id, externalID: UUID().uuidString))
    }

    private func snapshot(_ session: WorkspaceClaudeSession, _ messages: [ClaudeOwnedHistoryMessage], offset: Double = 0) -> ClaudeOwnedHistorySnapshot {
        .init(sessionID: session.externalID!, profileNamespace: session.profileNamespace, messages: messages,
              complete: true, observedAt: instant.addingTimeInterval(offset))
    }

    private func save(_ stores: Stores, _ session: WorkspaceClaudeSession, _ messages: [ClaudeOwnedHistoryMessage], offset: Double = 0) throws {
        try stores.replaceWorkspaceClaudeProjection(sessionID: session.id, expectedProfileNamespace: session.profileNamespace,
            snapshot: snapshot(session, messages, offset: offset))
    }

    @Test func unchangedRefreshDoesNotDuplicateTranscriptStorage() throws {
        let (stores, _, session) = try setup()
        let messages = [ClaudeOwnedHistoryMessage(id: UUID().uuidString, role: "user", text: "Unchanged synthetic text")]
        try save(stores, session, messages)
        try save(stores, session, messages, offset: 20)
        #expect(try stores.workspaceClaudeProjection(sessionID: session.id)?.observedAt == instant)
        let count = try stores.db.queue.read { try Int.fetchOne($0,
            sql: "SELECT count(*) FROM workspaceClaudeHistoryObservation WHERE sessionID = ?", arguments: [session.id]) }
        #expect(count == 1)
    }

    @Test func externalWritesAreVisibleInCanonicalOrderButNeverCompletedContext() throws {
        let (stores, chat, session) = try setup()
        let first = UUID().uuidString, second = UUID().uuidString
        try save(stores, session, [.init(id: first, role: "user", text: "Written in official CLI"),
                                  .init(id: second, role: "assistant", text: "Observed reply")])
        let entries = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(entries.map(\.text) == ["Written in official CLI", "Observed reply"])
        #expect(entries.allSatisfy { $0.state == .outcomeUnknown && $0.observedAt == instant && $0.timestamp == instant })
        #expect(entries.allSatisfy { $0.sourceThread == WorkspaceThreadKey.claudeSession(session.id) })
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local) == nil)
        #expect(try stores.workspaceChatHistoryText(chatID: chat.id).isEmpty)
        #expect(try stores.workspaceClaudeTurns(sessionID: session.id).isEmpty)
        #expect(try stores.workspaceSessionLinks(chatID: chat.id).isEmpty)
    }

    @Test func exactUUIDsDeduplicateAndCanonicalCorrectionsReachCompletedHandover() throws {
        let (stores, chat, session) = try setup()
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Original input")
        try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: turn.id.uuidString.lowercased(), role: "user")
        turn.state = .running; turn.providerTurnID = UUID().uuidString
        try stores.saveWorkspaceClaudeTurn(turn)
        let a = UUID().uuidString, b = UUID().uuidString
        for id in [a, b] { try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: id, role: "assistant") }
        turn.state = .completed; turn.outputText = "Old streamed answer"; turn.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(turn)
        try save(stores, session, [.init(id: turn.id.uuidString, role: "user", text: "Canonical input"),
            .init(id: b, role: "assistant", text: "First canonical block"), .init(id: a, role: "assistant", text: "Second canonical block"),
            .init(id: UUID().uuidString, role: "assistant", text: "Old streamed answer")])
        let entries = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(entries.count == 3) // Same text under a different UUID is not deduplicated.
        #expect(entries.first { $0.id == "claude:\(turn.id.uuidString):user" }?.text == "Canonical input")
        let assistant = try #require(entries.first { $0.id == "claude:\(turn.id.uuidString):assistant" })
        #expect(assistant.text == "First canonical block\nSecond canonical block" && assistant.state == .completed)
        #expect(try stores.workspaceClaudeTurn(id: turn.id)?.outputText == "Old streamed answer")
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local))
        #expect(plan.entryCount == 2 && plan.text.contains("Canonical input") && plan.text.contains(assistant.text))
        #expect(!plan.text.contains("Old streamed answer"))
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: UUID(), anchor: .now)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local) == nil)
    }

    @Test func unknownOutcomesAndMissingAssistantIdentityNeverBecomeCompleted() throws {
        let (stores, chat, session) = try setup()
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Unknown delivery")
        try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: turn.id.uuidString, role: "user")
        turn.state = .running; turn.outputText = "Saved partial"
        try stores.saveWorkspaceClaudeTurn(turn)
        let assistant = UUID().uuidString
        try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: assistant, role: "assistant")
        _ = try stores.reconcileUnfinishedWorkspaceClaudeTurns()
        try save(stores, session, [.init(id: turn.id.uuidString, role: "user", text: turn.promptText),
                                  .init(id: assistant, role: "assistant", text: "History cannot certify completion")])
        let entries = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(entries.count == 2 && entries.last?.text == "Saved partial")
        #expect(try stores.workspaceClaudeTurn(id: turn.id)?.state == .outcomeUnknown)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local) == nil)
        #expect(throws: WorkspaceClaudeError.unresolvedTurn) { try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "No replay") }
    }

    @Test func incompleteAssistantProjectionRetainsWholeJournalAggregate() throws {
        let (stores, chat, session) = try setup()
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Input")
        turn.state = .running; turn.providerTurnID = UUID().uuidString
        try stores.saveWorkspaceClaudeTurn(turn)
        let first = UUID().uuidString
        for id in [first, UUID().uuidString] { try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: id, role: "assistant") }
        turn.state = .completed; turn.outputText = "Whole saved answer"; turn.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(turn)
        try save(stores, session, [.init(id: first, role: "assistant", text: "Only one block present")])
        let entries = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(entries.count == 2 && entries.last?.text == "Whole saved answer")
    }

    @Test func invalidOrWrongProfileSnapshotsKeepPreviousObservation() throws {
        let (stores, _, session) = try setup()
        let message = ClaudeOwnedHistoryMessage(id: UUID().uuidString, role: "user", text: "Keep")
        try save(stores, session, [message])
        let saved = try #require(try stores.workspaceClaudeProjection(sessionID: session.id))
        let invalid: [ClaudeOwnedHistorySnapshot] = [
            .init(sessionID: session.externalID!, profileNamespace: session.profileNamespace, messages: [message], complete: false, observedAt: instant),
            .init(sessionID: UUID().uuidString, profileNamespace: session.profileNamespace, messages: [message], complete: true, observedAt: instant),
            .init(sessionID: session.externalID!, profileNamespace: "other-profile", messages: [message], complete: true, observedAt: instant),
            snapshot(session, [message, message]), snapshot(session, [.init(id: "invalid", role: "user", text: "Bad")]),
            snapshot(session, [.init(id: UUID().uuidString, role: "system", text: "Bad")]),
            snapshot(session, [.init(id: message.id, role: "assistant", text: "Role changed")]),
            snapshot(session, [message], offset: -1)
        ]
        for bad in invalid {
            #expect(throws: (any Error).self) {
                try stores.replaceWorkspaceClaudeProjection(sessionID: session.id, expectedProfileNamespace: session.profileNamespace, snapshot: bad)
            }
            #expect(try stores.workspaceClaudeProjection(sessionID: session.id) == saved)
        }
        #expect(throws: (any Error).self) {
            try stores.replaceWorkspaceClaudeProjection(sessionID: session.id, expectedProfileNamespace: "other-profile", snapshot: saved)
        }
    }

    @Test func correctedSnapshotsRetainPriorEvidenceAndStableIDs() throws {
        let (stores, chat, session) = try setup()
        let id = UUID().uuidString
        try save(stores, session, [.init(id: id, role: "assistant", text: "Before")])
        let oldID = try #require(try stores.workspaceChatTimeline(chatID: chat.id).first?.id)
        try save(stores, session, [.init(id: id.lowercased(), role: "assistant", text: "After")], offset: 10)
        let entry = try #require(try stores.workspaceChatTimeline(chatID: chat.id).first)
        #expect(entry.id == oldID && entry.text == "After" && entry.observedAt == instant.addingTimeInterval(10))
        #expect(try stores.db.queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM workspaceClaudeHistoryObservation") } == 2)
        try save(stores, session, [], offset: 20)
        #expect(try stores.workspaceChatTimeline(chatID: chat.id).isEmpty)
        #expect(throws: WorkspaceClaudeError.immutableIdentity) {
            try save(stores, session, [.init(id: id, role: "user", text: "Cannot reuse UUID")], offset: 30)
        }
    }

    @Test func onlyAttributedExactHandoverEnvelopesAreRemoved() throws {
        let (stores, chat, session) = try setup()
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "Earlier context"))
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.claudeSession(session.id)))
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: session.id, prompt: "Actual message")
        try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: turn.id.uuidString, role: "user")
        turn.state = .running; turn.providerTurnID = UUID().uuidString
        try stores.saveWorkspaceClaudeTurn(turn)
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: turn.id, anchor: turn.startedAt)
        let wire = WorkspaceHandoverText.wire(handover: plan.text, message: turn.promptText)
        try save(stores, session, [.init(id: turn.id.uuidString, role: "user", text: wire),
                                  .init(id: UUID().uuidString, role: "user", text: wire)])
        let entries = try stores.workspaceChatTimeline(chatID: chat.id)
        #expect(entries.first { $0.id == "claude:\(turn.id.uuidString):user" }?.text == turn.promptText)
        #expect(entries.last?.text == wire) // Equal text without identity is never stripped.
        try save(stores, session, [.init(id: turn.id.uuidString, role: "user", text: wire + " changed")], offset: 1)
        #expect(try stores.workspaceChatTimeline(chatID: chat.id).first { $0.id == "claude:\(turn.id.uuidString):user" }?.text == wire + " changed")
    }

    @Test func unboundOrImportedIdentitiesCannotReceiveOwnedProjection() throws {
        let (stores, chat, session) = try setup()
        let unbound = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: session.profileNamespace,
            model: session.model, effort: nil, expectedPolicyRevision: session.policyRevision, reviewedContext: session.reviewedContext)
        let imported = UUID().uuidString
        _ = try stores.saveWorkspaceSessionLink(.init(chatID: chat.id, provider: .claude, externalID: imported, displayName: "Read-only imported"))
        let observation = ClaudeOwnedHistorySnapshot(sessionID: imported, profileNamespace: session.profileNamespace,
            messages: [.init(id: UUID().uuidString, role: "user", text: "Read only")], complete: true, observedAt: instant)
        for id in [unbound.id, session.id] {
            #expect(throws: WorkspaceClaudeError.immutableIdentity) {
                try stores.replaceWorkspaceClaudeProjection(sessionID: id, expectedProfileNamespace: session.profileNamespace, snapshot: observation)
            }
        }
        #expect(throws: WorkspaceClaudeError.importedIdentity) { try stores.bindWorkspaceClaudeSession(id: unbound.id, externalID: imported) }
        #expect(try stores.workspaceClaudeProjection(sessionID: unbound.id) == nil)
    }
}
