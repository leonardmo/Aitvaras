import Foundation
import Testing
import GRDB
import AitvarasAgents
@testable import AitvarasStore

@Suite struct ChatContextProjectionTests {
    @Test func labelsOrderProviderWatermarkAndByteBudget() throws {
        let chat = UUID()
        let entries = (0..<80).map { position in
            AgentTranscriptEntry(chatID: chat, provider: .claude, kind: position.isMultiple(of: 2) ? "user" : "assistant",
                text: "\(position):" + String(repeating: "🦊ä", count: 100), position: position)
        }
        let context = try #require(ChatContextProjection.make(entries: entries.reversed(), provider: .codex))
        #expect(context.text.utf8.count <= 16_000)
        #expect(context.entryCount + context.omittedCount == 80)
        #expect(context.omittedCount > 0)
        #expect(context.throughPosition == 79)
        #expect(context.text.contains("\(context.omittedCount) earlier omitted"))
        let retained = entries.suffix(context.entryCount)
        var rest = context.text[...]
        for entry in retained {
            let range = try #require(rest.range(of: "[\(entry.kind) · claude] \(entry.text)"))
            rest = rest[range.upperBound...]
        }
        #expect(ChatContextProjection.make(entries: entries, provider: .claude) == nil)
        #expect(ChatContextProjection.make(entries: entries, provider: .codex, after: 79) == nil)
        #expect(ChatContextProjection.make(entries: entries, provider: .codex, maximumBytes: 1) == nil)
        // Local is stateless: it also receives earlier Local messages.
        let local = AgentTranscriptEntry(chatID: chat, provider: .local, kind: "assistant", text: "local reply")
        #expect(ChatContextProjection.make(entries: [local], provider: .local)?.entryCount == 1)
    }

    @Test func oversizedNewestEntryIsExplicitlyClippedAtUnicodeBoundary() throws {
        let entries = [AgentTranscriptEntry(chatID: UUID(), provider: .local, kind: "assistant",
                                             text: String(repeating: "🦊", count: 5000))]
        let context = try #require(ChatContextProjection.make(entries: entries, provider: .codex))
        #expect(context.entryCount == 1)
        #expect(context.omittedCount == 0)
        #expect(context.text.contains("[message truncated]"))
        #expect(context.text.contains("🦊"))
        #expect(context.text.utf8.count <= 16_000)
        #expect(!context.text.contains("�"))
    }

    @Test func completedOnlyAndAcknowledgementIsTheDurableWatermark() throws {
        let stores = try inMemoryStores()
        let (chat, claude) = try agentStoreChat(stores)
        let codex = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(codex)
        try completedTurn(stores, session: claude, prompt: "first", reply: "first answer")
        // Running, interrupted and tool output are never context.
        let failed = AgentInput(text: "failed input")
        try stores.prepareAgentTurn(.init(input: failed, chatID: chat.id, sessionID: claude.id))
        _ = try stores.saveAgentEntry(.init(id: failed.id, chatID: chat.id, provider: .claude,
                                           kind: "user", text: failed.text, sessionID: claude.id))
        _ = try stores.saveAgentEntry(.init(chatID: chat.id, provider: .claude, kind: "assistant",
                                           text: "partial secret", sessionID: claude.id))
        #expect(try stores.agentContext(session: codex)?.entryCount == 2)
        try stores.finishAgentTurn(id: failed.id, state: .interrupted)
        let context = try #require(try stores.agentContext(session: codex))
        #expect(!context.text.contains("partial secret"))
        let input = AgentInput(text: context.wire(message: "next"))
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: codex.id))
        try stores.prepareAgentHandover(context, turnID: input.id)
        #expect(try stores.agentContext(session: codex) == context)
        try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
        #expect(try stores.agentContext(session: codex) == context)
        try stores.advanceAgentDelivery(id: input.id, to: .acknowledged)
        #expect(try stores.agentContext(session: codex) == nil)
        #expect(try stores.agentHandover(turnID: input.id) == context)
        try stores.finishAgentTurn(id: input.id, state: .completed)
        try completedTurn(stores, session: claude, prompt: "later", reply: "later answer")
        let later = try #require(try stores.agentContext(session: codex))
        #expect(later.entryCount == 2)
        #expect(!later.text.contains("first answer"))
        #expect(later.text.contains("later answer"))
        let other = try agentStoreChat(stores, provider: .local).1
        #expect(try stores.agentContext(session: other) == nil)
        // A fresh owner after recovery reads the same durable watermark.
        try stores.recoverAgentTurns()
        #expect(try stores.agentContext(session: codex) == later)
    }

    @Test func managerSendsEnvelopeOnceAndKeepsOriginalTranscript() async throws {
        let stores = try inMemoryStores()
        let (chat, claude) = try agentStoreChat(stores)
        try completedTurn(stores, session: claude, prompt: "previous", reply: "answer")
        let codex = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(codex)
        let wire = ContextWireRecorder()
        // The backend is injected; its local implementation lets this test
        // inspect the actual manager send without launching a process.
        let backend = LocalBackend { _, input in
            await wire.record(input)
            return AsyncThrowingStream { $0.yield("reply"); $0.finish() }
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        #expect(await wire.inputs.isEmpty)
        try await manager.configure(codex)
        #expect(await wire.inputs.isEmpty) // Switching/settings send nothing.
        let input = AgentInput(text: "current")
        try await manager.send(chatID: chat.id, provider: .codex, input: input)
        try await waitContext { try await manager.state(chatID: chat.id).outcome == .completed }
        let sent = try #require(await wire.inputs.first)
        #expect(sent.text.contains("[user · claude] previous"))
        #expect(sent.text.hasSuffix("\ncurrent"))
        #expect(try stores.agentTurn(id: input.id)?.prompt == sent.text)
        #expect(try stores.agentEntries(chatID: chat.id).first { $0.id == input.id }?.text == "current")
        #expect(try stores.agentContext(session: codex) == nil)
        try await manager.send(chatID: chat.id, provider: .codex, input: .init(text: "again"))
        try await waitContext { await wire.inputs.count == 2 }
        #expect(await wire.inputs.last?.text == "again")
        try await manager.shutdown()
    }

    @Test func failedHandoverPersistenceRollsBackJournalAndStartsNothing() async throws {
        let stores = try inMemoryStores()
        let (chat, claude) = try agentStoreChat(stores)
        try completedTurn(stores, session: claude, prompt: "previous", reply: "answer")
        let codex = AgentChatSession(chatID: chat.id, provider: .codex, cwd: "/tmp", model: "fixture")
        try stores.saveAgentSession(codex)
        try await stores.db.queue.write {
            try $0.execute(sql: "CREATE TRIGGER fixtureHandoverFailure BEFORE INSERT ON agentHandover BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        let wire = ContextWireRecorder()
        let backend = LocalBackend { _, input in
            await wire.record(input)
            return AsyncThrowingStream { $0.finish() }
        }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in })
        let input = AgentInput(text: "not sent")
        await #expect(throws: (any Error).self) {
            try await manager.send(chatID: chat.id, provider: .codex, input: input)
        }
        #expect(try stores.agentTurn(id: input.id) == nil)
        #expect(await wire.inputs.isEmpty)
        #expect(try await manager.state(chatID: chat.id).entries.allSatisfy { $0.id != input.id })
        #expect(try stores.agentContext(session: codex)?.entryCount == 2)
        try await manager.shutdown()
    }
}

private actor ContextWireRecorder {
    var inputs: [AgentInput] = []
    func record(_ input: AgentInput) { inputs.append(input) }
}

func completedTurn(_ stores: Stores, session: AgentChatSession, prompt: String, reply: String) throws {
    let input = AgentInput(text: prompt)
    try stores.prepareAgentTurn(.init(input: input, chatID: session.chatID, sessionID: session.id))
    _ = try stores.saveAgentEntry(.init(id: input.id, chatID: session.chatID, provider: session.provider,
                                       kind: "user", text: prompt, sessionID: session.id))
    _ = try stores.saveAgentEntry(.init(chatID: session.chatID, provider: session.provider,
                                       kind: "thinking", text: "not context", sessionID: session.id))
    _ = try stores.saveAgentEntry(.init(chatID: session.chatID, provider: session.provider,
                                       kind: "assistant", text: reply, sessionID: session.id))
    try stores.finishAgentTurn(id: input.id, state: .completed)
}

private func waitContext(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<300 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
