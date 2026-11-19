import Foundation
import Testing
import GRDB
import AitvarasCore
@testable import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueDeliveryTests {
    @Test(arguments: [AgentProvider.claude, .codex])
    func exactSessionPromptAndHiddenInputSurviveReconciliation(provider: AgentProvider) async throws {
        let stores = try inMemoryStores(), pending = try autoContinueIntent(stores, provider: provider)
        let storage = AgentAutoContinueStore(db: stores.db), backend = AutoContinueBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: UsageResetTestClock(autoContinueTestDate).clock)
        let input = try await manager.continueAutomatically(id: pending.id)
        let run = try #require(await backend.runs.last)
        #expect(await backend.configurations.last?.resume == pending.native)
        #expect(await run.inputs == [.init(id: input, text: AgentAutoContinue.prompt, automaticIntentID: pending.id)])
        try await autoWait { try stores.agentTurn(id: input)?.delivery == .acknowledged }
        if provider == .codex { await run.emit(.message(id: "native-input", role: "user", text: AgentAutoContinue.prompt), turn: "turn-test") }
        await run.emit(.textDelta("Continued answer"), turn: provider == .codex ? "turn-test" : nil)
        await run.emit(.turnEnded(.completed), turn: provider == .codex ? "turn-test" : nil)
        try await autoWait { try stores.automaticInput(id: input)?.outcome == "completed" }
        #expect(try stores.agentEntries(chatID: pending.chatID).allSatisfy { $0.kind != "user" })
        let receipt = try #require(try stores.automaticInput(id: input))
        let session = try #require(try stores.agentSessions(chatID: pending.chatID).first { $0.id == pending.sessionID })
        let userID = try #require(receipt.nativeMessageID)
        let metadata = JSONValue.object(["nativeHistory": .object(["turnID": receipt.nativeTurnID.map(JSONValue.string) ?? .null, "completed": .bool(true)])]).jsonString
        let user = AgentTranscriptEntry(chatID: pending.chatID, provider: provider, kind: "user", text: AgentAutoContinue.prompt,
            payloadJSON: metadata, sessionID: session.id, nativeMessageID: userID)
        let answer = AgentTranscriptEntry(chatID: pending.chatID, provider: provider, kind: "assistant", text: "Continued answer",
            payloadJSON: metadata, sessionID: session.id, nativeMessageID: "native-answer")
        try stores.reconcileAgentHistory(session: session, entries: [user, answer])
        try stores.reconcileAgentHistory(session: session, entries: [user, answer])
        #expect(try stores.agentEntries(chatID: pending.chatID).allSatisfy { $0.kind != "user" })
        var typed = user; typed.id = UUID(); typed.nativeMessageID = "typed-native-input"
        try stores.reconcileAgentHistory(session: session, entries: [user, answer, typed])
        #expect(try stores.agentEntries(chatID: pending.chatID).filter { $0.kind == "user" }.map(\.text) == [AgentAutoContinue.prompt])
        try await manager.shutdown()
    }

    @Test func codexHistoryUsesTheSubmittedIdentityWithoutAUserEcho() async throws {
        let stores = try inMemoryStores(), pending = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db), backend = AutoContinueBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: UsageResetTestClock(autoContinueTestDate).clock)
        let input = try await manager.continueAutomatically(id: pending.id)
        let run = try #require(await backend.runs.first)
        await run.emit(.textDelta("Answer"), turn: "native-turn")
        await run.emit(.turnEnded(.completed), turn: "native-turn")
        try await autoWait { try stores.automaticInput(id: input)?.outcome == "completed" }
        let session = try #require(try stores.agentSessions(chatID: pending.chatID).first { $0.id == pending.sessionID })
        let metadata = JSONValue.object(["nativeHistory": .object(["turnID": .string("native-turn"), "completed": .bool(true)])]).jsonString
        let nativeID = pending.native.canonicalMessageID(input.uuidString, turnID: "native-turn")
        let user = AgentTranscriptEntry(chatID: pending.chatID, provider: .codex, kind: "user", text: AgentAutoContinue.prompt,
            payloadJSON: metadata, sessionID: session.id, nativeMessageID: nativeID)
        try stores.reconcileAgentHistory(session: session, entries: [user])
        #expect(try stores.agentEntries(chatID: pending.chatID).allSatisfy { $0.kind != "user" })
        var unproven = user; unproven.nativeMessageID = "unbound-server-item"
        #expect(throws: AgentNativeHistoryError.identityConflict) { try stores.reconcileAgentHistory(session: session, entries: [unproven]) }
        #expect(try stores.agentEntries(chatID: pending.chatID).allSatisfy { $0.kind != "user" })
        try await manager.shutdown()
    }

    @Test func receiptMigrationUpgradesWithoutChangingPendingIntentOrJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.sqlite"), saved: AgentAutoContinue
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            saved = try autoContinueIntent(stores)
            try stores.db.queue.write { db in
                try db.drop(table: "agentAutomaticInput"); try db.drop(table: "agentQuotaStop")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v37-agent-automatic-input-receipts"])
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url)), storage = AgentAutoContinueStore(db: stores.db)
        #expect(try storage.continuation(id: saved.id) == saved)
        #expect(try stores.agentTurn(id: saved.failedInputID)?.state == .failed)
        let input = AgentInput(text: AgentAutoContinue.prompt)
        let claim = try storage.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
        try stores.prepareAutomaticTurn(.init(input: input, chatID: saved.chatID, sessionID: saved.sessionID), authorization: claim)
        #expect(try stores.automaticInput(id: input.id)?.intentID == saved.id)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func personSendCancelsEvenWhenStartupFailsAndUnknownIDsDoNotSend() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db)
        let backend = AutoContinueBackend(); await backend.setFailure(.authRequired)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) }, autoContinuePersistence: storage)
        await #expect(throws: AgentFailure.authRequired) { try await manager.send(chatID: saved.chatID, provider: .codex, input: .init(text: "A new question")) }
        #expect(try storage.continuation(id: saved.id)?.state == .cancelled)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.continueAutomatically(id: UUID()) }
        #expect(await backend.runs.isEmpty)
        try await manager.shutdown()
    }

    @Test func newMessageDuringAutomaticStartupRevokesBeforeWrite() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db)
        let backend = AutoContinueBackend(), gate = AutoContinueGate()
        await backend.setStartGate(gate)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: UsageResetTestClock(autoContinueTestDate).clock)
        let sending = Task { try await manager.continueAutomatically(id: saved.id) }
        await gate.waitUntilEntered()
        // This exercises the public send cancellation before follow-up validation.
        _ = try? await manager.send(chatID: saved.chatID, provider: .codex, input: .init(text: "Replace the request"))
        await gate.release()
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(try storage.continuation(id: saved.id)?.state == .cancelled)
        #expect(await backend.runs.first?.inputs.isEmpty == true)
        try await manager.shutdown()
    }

    @Test func externalNativeMessageCancelsBeforeAutomaticClaim() async throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db)
        let backend = AutoContinueBackend()
        await backend.setHistory([.init(scope: .init(runID: UUID(), session: saved.native, turnID: "external-turn"), kind: .message(id: "external", role: "user", text: "A newer native question"))])
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) },
            autoContinuePersistence: storage, continuationClock: UsageResetTestClock(autoContinueTestDate).clock)
        await #expect(throws: AgentFailure.invalidTransition) { try await manager.continueAutomatically(id: saved.id) }
        #expect(try storage.continuation(id: saved.id)?.state == .cancelled)
        #expect(await backend.runs.isEmpty)
        try await manager.shutdown()
    }

    @Test func cancellationBetweenAuthorizationAndDeliveryBarrierCannotWrite() throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db)
        let input = AgentInput(text: AgentAutoContinue.prompt)
        let claim = try storage.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
        try stores.prepareAutomaticTurn(.init(input: input, chatID: saved.chatID, sessionID: saved.sessionID), authorization: claim)
        try storage.noteNewInput(chatID: saved.chatID, now: autoContinueTestDate)
        #expect(throws: AgentFailure.invalidTransition) { try stores.beginAutomaticDelivery(id: input.id, authorization: claim, now: autoContinueTestDate) }
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
    }

    @Test func automaticReceiptAndJournalRollbackTogether() throws {
        let stores = try inMemoryStores(), saved = try autoContinueIntent(stores), storage = AgentAutoContinueStore(db: stores.db)
        let input = AgentInput(text: AgentAutoContinue.prompt)
        let claim = try storage.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
        try stores.db.queue.write { try $0.execute(sql: "CREATE TRIGGER failAutomaticReceipt BEFORE INSERT ON agentAutomaticInput BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
        #expect(throws: (any Error).self) { try stores.prepareAutomaticTurn(.init(input: input, chatID: saved.chatID, sessionID: saved.sessionID), authorization: claim) }
        #expect(try stores.agentTurn(id: input.id) == nil)
        #expect(try stores.automaticInput(id: input.id) == nil)
    }
}
