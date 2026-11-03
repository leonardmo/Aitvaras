import Foundation
import Testing
import AitvarasCore
import AitvarasStore

@Suite struct WorkspaceHandoverTests {
    private func setup(_ stores: Stores) throws -> (WorkspaceChat, WorkspaceFrontierSession) {
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic chat")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        let policy = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let session = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        return (chat, session)
    }

    private func local(_ stores: Stores, _ chat: WorkspaceChat, _ role: String, _ text: String, at offset: TimeInterval) throws {
        try stores.appendMessage(StoredMessage(conversationID: chat.localConversationID, role: role, content: text,
                                               createdAt: Date.now.addingTimeInterval(offset)))
    }

    /// A completed, provider-acknowledged turn on `session`, as Codex would leave it.
    private func codexTurn(_ stores: Stores, _ session: WorkspaceFrontierSession, _ prompt: String, _ reply: String) throws -> WorkspaceFrontierTurn {
        var turn = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: prompt)
        turn.state = .running; turn.providerTurnID = "synthetic-\(UUID().uuidString.prefix(8))"
        try stores.saveWorkspaceFrontierTurn(turn)
        turn.outputText = reply; turn.state = .completed; turn.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(turn)
        return turn
    }

    @Test func aNewThreadIsCaughtUpOnEverythingOthersWrote() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        let thread = WorkspaceThreadKey.codexSession(session.id)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread) == nil)

        try local(stores, chat, "user", "What is a gradient?", at: -20)
        try local(stores, chat, "assistant", "The direction of steepest increase.", at: -10)
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread))
        #expect(plan.entryCount == 2 && plan.omittedCount == 0 && plan.providers == ["local"])
        #expect(plan.text.hasPrefix(WorkspaceHandoverText.header + " · 2 messages from Local since your last reply"))
        #expect(plan.text.contains("[user · Local] What is a gradient?\n[assistant · Local] The direction of steepest increase."))
        #expect(plan.text.hasSuffix(WorkspaceHandoverText.footer))
    }

    @Test func onlyWhatTheThreadMissedTravelsAfterADeliveredHandover() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        let thread = WorkspaceThreadKey.codexSession(session.id)
        try local(stores, chat, "user", "Earlier local question", at: -30)
        try local(stores, chat, "assistant", "Earlier local answer", at: -20)

        let first = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread))
        let turn = try codexTurn(stores, session, "First Codex question", "First Codex answer")
        try stores.recordWorkspaceHandover(first, chatID: chat.id, turnID: turn.id, anchor: turn.startedAt.addingTimeInterval(-0.001))
        // Nothing new since: the thread is up to date, and its own turn never comes back to it.
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread) == nil)

        try local(stores, chat, "user", "Local follow-up", at: 30)
        try local(stores, chat, "assistant", "Local follow-up answer", at: 40)
        let next = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread))
        #expect(next.entryCount == 2)
        #expect(next.text.contains("Local follow-up") && !next.text.contains("Earlier local question")
                && !next.text.contains("First Codex"))

        // A second thread for the same chat (say, after a model change) gets
        // the whole conversation, including the first thread's turns.
        let review = try stores.workspacePolicy(projectID: chat.projectID)!
        let other = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "synthetic-model", effort: "low",
            expectedPolicyRevision: review.revision, reviewedContext: session.reviewedContext)
        let caughtUp = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.codexSession(other.id)))
        #expect(caughtUp.entryCount == 6 && caughtUp.providers.contains("codex") && caughtUp.providers.contains("local"))
        #expect(caughtUp.text.contains("[user · Codex] First Codex question"))
    }

    @Test func messagesWithTheSameTimestampFollowTheTimelineNotTheirIDs() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        let thread = WorkspaceThreadKey.codexSession(session.id)
        // Same millisecond; the earlier message has the larger random ID.
        let instant = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 - 30).rounded())
        try stores.appendMessage(StoredMessage(id: UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000000")!,
            conversationID: chat.localConversationID, role: "user", content: "Same-instant question", createdAt: instant))
        try stores.appendMessage(StoredMessage(id: UUID(uuidString: "00000000-0000-4000-8000-000000000000")!,
            conversationID: chat.localConversationID, role: "assistant", content: "Same-instant answer", createdAt: instant))
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread))
        #expect(plan.entryCount == 2)
        let turn = try codexTurn(stores, session, "Next", "Reply")
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: turn.id, anchor: turn.startedAt.addingTimeInterval(-0.001))
        // Both were handed over; neither may come back.
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread) == nil)
    }

    @Test func undeliveredAndUncertainTurnsAreNeverHandedOver() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        var never = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Never left")
        never.state = .failed; never.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(never)
        var maybe = try stores.beginWorkspaceFrontierTurn(sessionID: session.id, prompt: "Maybe left")
        maybe.state = .running; try stores.saveWorkspaceFrontierTurn(maybe)
        maybe.state = .outcomeUnknown; maybe.endedAt = .now; try stores.saveWorkspaceFrontierTurn(maybe)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local) == nil)
    }

    @Test func overBudgetKeepsTheNewestAndCountsTheRest() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        for index in 0..<12 {
            try local(stores, chat, index.isMultiple(of: 2) ? "user" : "assistant",
                      "Message \(index) " + String(repeating: "x", count: 3_000), at: Double(index - 20))
        }
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id,
            threadKey: WorkspaceThreadKey.codexSession(session.id), maximumCharacters: 10_000))
        #expect(plan.text.count <= 10_000)
        #expect(plan.omittedCount > 0 && plan.entryCount + plan.omittedCount == 12)
        #expect(plan.text.contains("Message 11 ") && !plan.text.contains("Message 0 "))
        #expect(plan.text.contains("· \(plan.omittedCount) earlier omitted"))
    }

    @Test func handoversShowInTheTimelineAndAreRecordedOnce() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        try local(stores, chat, "user", "Local question", at: -10)
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.codexSession(session.id)))
        let turn = try codexTurn(stores, session, "Codex question", "Codex answer")
        let anchor = turn.startedAt.addingTimeInterval(-0.001)
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: turn.id, anchor: anchor)
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: turn.id, anchor: anchor)
        #expect(try stores.workspaceHandovers(chatID: chat.id).count == 1)

        let roles = try stores.workspaceChatTimeline(chatID: chat.id).map(\.role)
        #expect(roles == ["user", "handover", "user", "assistant"])
        // The handover is a record of what was shared, not conversation: the
        // Codex turn is handed on, the block that travelled with it is not.
        let onward = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: WorkspaceThreadKey.local))
        #expect(onward.entryCount == 2 && onward.text.contains("[user · Codex] Codex question"))
        #expect(!onward.text.contains("Local question"))

        let changed = WorkspaceHandoverPlan(threadKey: plan.threadKey, text: plan.text + " changed", entryCount: 1,
            omittedCount: 0, providers: ["local"], throughTimestamp: plan.throughTimestamp, throughEntryID: plan.throughEntryID)
        #expect(throws: WorkspaceFrontierError.immutableIdentity) {
            try stores.recordWorkspaceHandover(changed, chatID: chat.id, turnID: turn.id, anchor: anchor)
        }
    }

    @Test func aHandoverBlockIsStrippedFromTheMessageItTravelledWith() {
        let block = "\(WorkspaceHandoverText.header) · 1 message from Local since your last reply · oldest first]\n[user · Local] hi\n\(WorkspaceHandoverText.footer)"
        let wire = WorkspaceHandoverText.wire(handover: block, message: "What next?")
        #expect(wire == block + "\nWhat next?")
        #expect(WorkspaceHandoverText.stripped(wire) == wire)
        #expect(WorkspaceHandoverText.stripped(wire, recordedHandover: block, originalMessage: "What next?") == "What next?")
        #expect(WorkspaceHandoverText.stripped(wire, recordedHandover: block, originalMessage: "Different message") == wire)
        #expect(WorkspaceHandoverText.stripped("Plain message") == "Plain message")
        #expect(WorkspaceHandoverText.wire(handover: nil, message: "Only this") == "Only this")
    }

    @Test func embeddedFooterAndMarkerLookingUserTextArePreserved() {
        let pasted = "\(WorkspaceHandoverText.header)]\nExample\n\(WorkspaceHandoverText.footer)\nDo not hide this."
        #expect(WorkspaceHandoverText.stripped(pasted) == pasted)
        let block = "\(WorkspaceHandoverText.header)]\n[user · Local] \(pasted)\n\(WorkspaceHandoverText.footer)"
        let wire = WorkspaceHandoverText.wire(handover: block, message: pasted)
        #expect(WorkspaceHandoverText.stripped(wire, recordedHandover: block, originalMessage: pasted) == pasted)
        #expect(WorkspaceHandoverText.stripped(wire + " edited", recordedHandover: block, originalMessage: pasted) == wire + " edited")
    }

    @Test func longGapsCountEveryOmittedMessageBeyondTheOldWindow() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        for index in 0..<1_005 {
            try local(stores, chat, "user", "Synthetic history \(index)", at: Double(index - 2_000))
        }
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id,
            threadKey: WorkspaceThreadKey.codexSession(session.id), maximumCharacters: 1_000))
        #expect(plan.entryCount + plan.omittedCount == 1_005)
        #expect(plan.omittedCount > 400 && plan.text.count <= 1_000)
        #expect(plan.text.contains("Synthetic history 1004"))
        let turn = try codexTurn(stores, session, "Continue", "Synthetic response")
        try stores.recordWorkspaceHandover(plan, chatID: chat.id, turnID: turn.id, anchor: turn.startedAt)
        #expect(try stores.workspaceHandoverPlan(chatID: chat.id,
            threadKey: WorkspaceThreadKey.codexSession(session.id)) == nil)
    }

    @Test func ownThreadTrafficCannotDisplaceAnOlderMissedMessage() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        try local(stores, chat, "user", "Older missed local message", at: -1_000)
        for _ in 0..<205 { _ = try codexTurn(stores, session, "Own question", "Own answer") }
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id,
            threadKey: WorkspaceThreadKey.codexSession(session.id)))
        #expect(plan.entryCount == 1 && plan.omittedCount == 0)
        #expect(plan.text.contains("Older missed local message") && !plan.text.contains("Own question"))
    }

    @Test func missingWatermarkFallsBackToTimeAndIncludesTies() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try setup(stores)
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        for (offset, text) in [(-1.0, "Older"), (0.0, "Timestamp tie"), (1.0, "Newer")] {
            try stores.appendMessage(StoredMessage(conversationID: chat.localConversationID, role: "user",
                content: text, createdAt: instant.addingTimeInterval(offset)))
        }
        let thread = WorkspaceThreadKey.codexSession(session.id)
        let watermark = WorkspaceHandoverPlan(threadKey: thread, text: "Synthetic prior handover", entryCount: 1,
            omittedCount: 0, providers: ["local"], throughTimestamp: instant, throughEntryID: "local:missing-entry")
        try stores.recordWorkspaceHandover(watermark, chatID: chat.id, turnID: UUID(), anchor: instant)
        let plan = try #require(try stores.workspaceHandoverPlan(chatID: chat.id, threadKey: thread))
        #expect(plan.entryCount == 2 && plan.text.contains("Timestamp tie") && plan.text.contains("Newer"))
        #expect(!plan.text.contains("Older"))
    }
}
