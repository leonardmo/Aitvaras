import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

@Suite struct AgentHandoverTests {
    @Test func allLegacySourcesAndLongGapsShareOneBoundedReceipt() throws {
        let stores = try inMemoryStores()
        let (chat, claude) = try agentStoreChat(stores)
        let target = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(target)
        // More than the UI's old 200-row page: every eligible row is counted.
        for index in 0..<240 {
            try stores.db.queue.write { try StoredMessage(conversationID: chat.localConversationID, role: "user", content: "legacy \(index) " + String(repeating: "ä🦊", count: 100)).insert($0) }
        }
        try completedTurn(stores, session: claude, prompt: "normalized question", reply: "normalized answer")
        let other = try agentStoreChat(stores, provider: .local)
        try stores.db.queue.write { try StoredMessage(conversationID: other.0.localConversationID, role: "user", content: "other chat excluded").insert($0) }
        let context = try #require(try stores.agentContext(session: target))
        #expect(context.entryCount + context.omittedCount == 242)
        #expect(context.omittedCount > 0)
        #expect(context.text.utf8.count <= 16_000)
        #expect(context.text.contains("normalized answer"))
        #expect(!context.text.contains("other chat excluded"))
        #expect(context.sources?.count == 242)
        let visible = try stores.agentEntries(chatID: chat.id)
        #expect(visible.filter(\.isLegacyProjection).count == 240)
        #expect(try stores.agentEntries(chatID: chat.id).map(\.id) == visible.map(\.id))
        try acknowledge(stores, session: target, context: context)
        #expect(try stores.agentContext(session: target) == nil)
        // Local is stateless and includes completed Local history every time.
        let local = AgentChatSession(chatID: chat.id, provider: .local, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(local)
        #expect(try stores.agentContext(session: local)?.sources?.count == 242)
    }

    @Test func legacyOwnedClaudeCodexAndLinkedNativeMessagesEnterCatchUp() throws {
        let stores = try inMemoryStores()
        let (chat, target) = try agentStoreChat(stores, provider: .codex)
        let nativeProject = NativeProjectSnapshot(identity: .init(provider: .codex, hostID: "fixture-host",
            profileNamespace: "fixture", externalID: "native-project"), name: "Example", roots: [.init(path: "/synthetic/native")])
        let projectLink = try stores.linkWorkspaceCodexProject(projectID: chat.projectID, snapshot: nativeProject,
            reviewedRoots: [.init(path: "/synthetic/native", canonicalPath: "/synthetic/native", filesystemIdentity: "fixture-device:1", availability: .available)], reviewed: true)
        let link = try stores.linkWorkspaceCodexChat(chatID: chat.id, projectLinkID: projectLink.id,
            nativeProjectIdentity: nativeProject.identity, nativeThreadID: "legacy-thread", workingDirectory: "/synthetic/native",
            expectedProjectRevision: projectLink.revision, reviewed: true)
        let snapshot = CodexNativeThreadSnapshot(id: "legacy-thread", name: "Example", projectID: "native-project", cwd: "/synthetic/native",
            status: "idle", raw: [:], turns: [.init(id: "native-turn", status: "completed", order: 0, raw: [:])], items: [
                .init(id: "reply", turnID: "native-turn", kind: "agentMessage", order: 0,
                      raw: ["item": ["id": "reply", "type": "agentMessage", "text": "linked native answer"]])], complete: true)
        _ = try stores.replaceWorkspaceCodexNativeProjection(chatLinkID: link.id, snapshot: snapshot,
            expectedProjectRevision: projectLink.revision, expectedChatRevision: link.revision, expectedProjectionRevision: nil)
        let review = try stores.workspacePolicyReview(projectID: chat.projectID)
        let policy = try stores.reviewWorkspacePolicy(projectID: chat.projectID, allowedProviders: [.claude, .codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        let codex = try stores.createWorkspaceFrontierSession(chatID: chat.id, model: "fixture", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        var frontier = try stores.beginWorkspaceFrontierTurn(sessionID: codex.id, prompt: "legacy codex question")
        frontier.state = .running; frontier.providerTurnID = "legacy-turn"
        try stores.saveWorkspaceFrontierTurn(frontier)
        frontier.state = .completed; frontier.outputText = "legacy codex answer"; frontier.endedAt = .now
        try stores.saveWorkspaceFrontierTurn(frontier)
        let claude = try stores.createWorkspaceClaudeSession(chatID: chat.id, profileNamespace: "fixture", model: "fixture", effort: nil,
            expectedPolicyRevision: policy.revision, reviewedContext: packet.promptText)
        var turn = try stores.beginWorkspaceClaudeTurn(sessionID: claude.id, prompt: "legacy claude question")
        turn.state = .running; turn.providerTurnID = "legacy-claude-turn"
        try stores.saveWorkspaceClaudeTurn(turn)
        turn.state = .completed; turn.outputText = "legacy claude answer"; turn.endedAt = .now
        try stores.saveWorkspaceClaudeTurn(turn)
        let context = try #require(try stores.agentContext(session: target))
        #expect(context.entryCount == 5)
        #expect(context.text.contains("linked native answer"))
        #expect(context.text.contains("legacy codex answer")) // same provider, another native session
        #expect(context.text.contains("legacy claude answer"))
        #expect(try stores.agentEntries(chatID: chat.id).filter(\.isLegacyProjection).count == 5)
        #expect(try stores.workspaceFrontierTurn(id: frontier.id)?.outputText == "legacy codex answer")
        #expect(try stores.workspaceClaudeTurn(id: turn.id)?.outputText == "legacy claude answer")
        #expect(try stores.workspaceCodexNativeItems(chatID: chat.id).map(\.nativeItemID) == ["reply"])
    }

    @Test func correctedAndDeletedNativeHistoryInvalidatesAcknowledgedContext() throws {
        let stores = try inMemoryStores()
        var (chat, source) = try agentStoreChat(stores)
        source.sessionID = .init(provider: .claude, profile: "default", nativeID: "native")
        try stores.saveAgentSession(source)
        let target = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(target)
        try stores.reconcileAgentHistory(session: source, entries: [historyEntry(source, "one", "user", "question"), historyEntry(source, "two", "assistant", "old answer")])
        try acknowledge(stores, session: target, context: try #require(try stores.agentContext(session: target)))
        #expect(try stores.agentContext(session: target) == nil)
        try stores.reconcileAgentHistory(session: source, entries: [historyEntry(source, "one", "user", "question"), historyEntry(source, "two", "assistant", "corrected answer")])
        let correction = try #require(try stores.agentContext(session: target))
        #expect(correction.text.contains("replaces earlier handover context"))
        #expect(correction.text.contains("corrected answer"))
        #expect(!correction.text.contains("old answer"))
        try acknowledge(stores, session: target, context: correction)
        try stores.reconcileAgentHistory(session: source, entries: [])
        let deletion = try #require(try stores.agentContext(session: target))
        #expect(deletion.entryCount == 0)
        #expect(deletion.text.contains("Canonical history correction"))
        try acknowledge(stores, session: target, context: deletion)
        #expect(try stores.agentContext(session: target) == nil)
        #expect(try stores.agentEntries(chatID: chat.id).isEmpty)
    }

    @Test func legacyPositionalReceiptRepeatsAndNativeReorderSendsCorrection() throws {
        let stores = try inMemoryStores()
        var (chat, source) = try agentStoreChat(stores)
        source.sessionID = .init(provider: .claude, profile: "default", nativeID: "native")
        try stores.saveAgentSession(source)
        let target = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(target)
        let first = historyEntry(source, "first", "assistant", "first answer")
        let second = historyEntry(source, "second", "assistant", "second answer")
        try stores.reconcileAgentHistory(session: source, entries: [first, second])
        var old = try #require(try stores.agentContext(session: target)); old.sources = nil
        try acknowledge(stores, session: target, context: old)
        let repeated = try #require(try stores.agentContext(session: target))
        #expect(repeated.entryCount == 2)
        try acknowledge(stores, session: target, context: repeated)
        #expect(try stores.agentContext(session: target) == nil)
        try stores.reconcileAgentHistory(session: source, entries: [second, first])
        let reordered = try #require(try stores.agentContext(session: target))
        #expect(reordered.text.contains("Canonical history correction"))
        #expect(reordered.entryCount == 2)
        let secondRange = try #require(reordered.text.range(of: "second answer"))
        let firstRange = try #require(reordered.text.range(of: "first answer"))
        #expect(secondRange.lowerBound < firstRange.lowerBound)
    }

    @Test func nativeCompletionAndUnknownDeliveryNeverConsumeUnacknowledgedHandover() throws {
        let stores = try inMemoryStores()
        var (chat, source) = try agentStoreChat(stores)
        source.sessionID = .init(provider: .claude, profile: "default", nativeID: "native")
        try stores.saveAgentSession(source)
        let target = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(target)
        try stores.reconcileAgentHistory(session: source, entries: [historyEntry(source, "done", "assistant", "completed"), historyEntry(source, "partial", "assistant", "unknown output", completed: false)])
        let context = try #require(try stores.agentContext(session: target))
        #expect(context.entryCount == 1)
        #expect(!context.text.contains("unknown output"))
        let input = AgentInput(text: context.wire(message: "current"))
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: target.id), context: context)
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        try stores.finishAgentTurn(id: input.id, state: .interrupted)
        #expect(try stores.agentContext(session: target) == context)
        try stores.recoverAgentTurns()
        #expect(try stores.agentContext(session: target) == context)
        #expect(try stores.agentTurn(id: input.id)?.delivery == .deliveryUnknown)
    }

    @Test(arguments: [AgentProvider.claude, .codex], [false, true])
    func stripOnlyExactAcknowledgedEnvelopeWithNativeIdentity(provider: AgentProvider, acknowledged: Bool) throws {
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: provider)
        session.sessionID = .init(provider: provider, profile: "default", nativeID: "native")
        try stores.saveAgentSession(session)
        let context = try #require(ChatContextProjection.make(entries: [.init(chatID: chat.id, provider: .local, kind: "assistant", text: "context")], provider: provider))
        let input = AgentInput(text: context.wire(message: "question"))
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id), context: context)
        _ = try stores.saveAgentEntry(.init(id: input.id, chatID: chat.id, provider: provider, kind: "user", text: "question",
            payloadJSON: JSONValue.object(["nativeTurnID": .string("turn")]).jsonString, sessionID: session.id, nativeMessageID: "user"))
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        if acknowledged { try stores.advanceAgentDelivery(id: input.id, to: .acknowledged) }
        try stores.finishAgentTurn(id: input.id, state: .completed)
        let exact = historyEntry(session, "user", "user", input.text, turnID: "turn")
        try stores.reconcileAgentHistory(session: session, entries: [exact])
        #expect(try stores.agentEntries(chatID: chat.id).first?.text == (acknowledged ? "question" : input.text))
        try stores.reconcileAgentHistory(session: session, entries: [exact])
        #expect(try stores.agentEntries(chatID: chat.id).first?.text == (acknowledged ? "question" : input.text))
        var edited = exact; edited.text += " edited"
        try stores.reconcileAgentHistory(session: session, entries: [edited])
        #expect(try stores.agentEntries(chatID: chat.id).first?.text == edited.text)
        let spoof = historyEntry(session, "someone-else", "user", input.text, turnID: "turn")
        try stores.reconcileAgentHistory(session: session, entries: [spoof])
        #expect(try stores.agentEntries(chatID: chat.id).first?.text == input.text)
    }

    @Test func legacyCorrectionsAndSameProviderDifferentThreadAreCaughtUp() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores, provider: .local)
        let target = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(target)
        let message = StoredMessage(conversationID: chat.localConversationID, role: "assistant", content: "legacy answer")
        try stores.db.queue.write { try message.insert($0) }
        try acknowledge(stores, session: target, context: try #require(try stores.agentContext(session: target)))
        var edited = message; edited.content = "corrected legacy"
        try stores.db.queue.write { try edited.update($0) }
        #expect(try stores.agentContext(session: target)?.text.contains("corrected legacy") == true)
        #expect(try stores.agentContext(session: session)?.text.contains("corrected legacy") == true)
    }
}

private func acknowledge(_ stores: Stores, session: AgentChatSession, context: ChatContextProjection) throws {
    let input = AgentInput(text: context.wire(message: "next"))
    try stores.prepareAgentTurn(.init(input: input, chatID: session.chatID, sessionID: session.id), context: context)
    try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
    try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
    try stores.finishAgentTurn(id: input.id, state: .completed)
}
