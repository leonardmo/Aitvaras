import Foundation
import Testing
import AitvarasAgents
import AitvarasCore
@testable import AitvarasStore

@Suite struct AgentTurnStoreTests {
    @Test func activityIdentityCollisionCannotOverwriteAnotherOperation() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "must not leave")
        let existing = ActivityRun(id: input.id, category: .capture, title: "Existing capture",
            startedAt: Date(timeIntervalSince1970: 1_000))
        ActivityReporter(stores: stores).begin(existing)
        #expect(throws: AgentStoreError.identityConflict) {
            try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        }
        #expect(try stores.agentTurn(id: input.id) == nil)
        #expect(try stores.activityRun(id: input.id) == existing)
    }

    @Test func activityWriteFailureRollsBackPreparedInputAndCompletion() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "PROMPT_CANARY")
        try stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER testActivityInsert BEFORE INSERT ON activityRun BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        #expect(throws: (any Error).self) {
            try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        }
        #expect(try stores.agentTurn(id: input.id) == nil)
        try stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testActivityInsert") }
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        try stores.saveAgentPartial(id: input.id, text: "OUTPUT_CANARY")
        try stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER testActivityUpdate BEFORE UPDATE ON activityRun BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        #expect(throws: (any Error).self) { try stores.finishAgentTurn(id: input.id, state: .completed) }
        #expect(try stores.agentTurn(id: input.id)?.state == .running)
        #expect(try stores.activityRun(id: input.id)?.state == .running)
        try stores.db.queue.write { try $0.execute(sql: "DROP TRIGGER testActivityUpdate") }
        try stores.finishAgentTurn(id: input.id, state: .completed)
        let run = try #require(try stores.activityRun(id: input.id))
        #expect(run.state == .succeeded)
        let metadata = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        #expect(!metadata.contains("PROMPT_CANARY") && !metadata.contains("OUTPUT_CANARY"))
        #expect(try stores.activityRunSteps(runID: input.id).map(\.state) == [.running, .succeeded])
    }

    @Test func activityRecoveryAndExplicitResendKeepOneIdentity() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let input = AgentInput(text: "undelivered")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        try stores.recoverAgentTurns()
        #expect(try stores.activityRun(id: input.id)?.state == .interrupted)
        _ = try stores.claimAgentResend(id: input.id)
        #expect(try stores.activityRun(id: input.id)?.state == .running)
        #expect(try stores.activityRun(id: input.id)?.finishedAt == nil)
        try stores.finishAgentTurn(id: input.id, state: .failed)
        #expect(try stores.activityRuns().map(\.id) == [input.id])
        #expect(try stores.activityRunSteps(runID: input.id).map(\.state) == [.running, .interrupted, .running, .failed])
    }

    @Test func followupsRetainRootExclusivityAndRequireMatchingActiveParent() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let (other, otherSession) = try agentStoreChat(stores)
        let journal = AgentTurnStore(db: stores.db)
        let root = AgentJournalTurn(input: .init(text: "root"), chatID: chat.id, sessionID: session.id)
        try journal.prepare(root)
        #expect(throws: (any Error).self) {
            try journal.prepare(.init(input: .init(text: "second root"), chatID: chat.id, sessionID: session.id))
        }
        for parent in [UUID(), root.id] {
            #expect(throws: (any Error).self) {
                try journal.prepare(.init(input: .init(text: "wrong scope"), chatID: other.id,
                    sessionID: otherSession.id, parentInputID: parent))
            }
        }
        let followup = AgentJournalTurn(input: .init(text: "follow-up"), chatID: chat.id,
            sessionID: session.id, parentInputID: root.id)
        try journal.prepare(followup)
        try journal.advanceDelivery(id: followup.id, to: .deliveryUnknown)
        try journal.finish(id: root.id, state: .completed)
        // An active queued input still excludes a second independent turn.
        #expect(throws: (any Error).self) {
            try journal.prepare(.init(input: .init(text: "another root"), chatID: chat.id, sessionID: session.id))
        }
        #expect(throws: (any Error).self) {
            try journal.prepare(.init(input: .init(text: "stale parent"), chatID: chat.id,
                sessionID: session.id, parentInputID: root.id))
        }
        try journal.recover()
        #expect(try journal.turn(id: root.id)?.state == .completed)
        #expect(try journal.turn(id: followup.id)?.state == .interrupted)
        #expect(try journal.turn(id: followup.id)?.parentInputID == root.id)
        #expect(try journal.turn(id: followup.id)?.delivery == .deliveryUnknown)
        #expect(throws: AgentFailure.invalidTransition) { try journal.claimResend(id: followup.id) }
    }

    @Test func followupMigrationPreservesExistingJournalRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let input = AgentInput(text: "existing input")
        let chatID: UUID
        let sessionID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, session) = try agentStoreChat(stores)
            chatID = chat.id; sessionID = session.id
            try stores.prepareAgentTurn(.init(input: input, chatID: chatID, sessionID: sessionID))
            try stores.advanceAgentDelivery(id: input.id, to: .deliveryUnknown)
            try stores.saveAgentPartial(id: input.id, text: "retained partial")
            // Restore the preceding released schema, retaining actual journal
            // data, then let the normal database initializer perform the upgrade.
            try stores.db.queue.write { db in
                try db.execute(sql: """
                    DROP TRIGGER agentFollowupScope;
                    DROP TRIGGER agentRootTurnExclusive;
                    DROP INDEX agentRunningTurn;
                    ALTER TABLE agentTurn DROP COLUMN parentInputID;
                    CREATE UNIQUE INDEX agentRunningTurn ON agentTurn(chatID) WHERE state = 'running';
                    DELETE FROM grdb_migrations WHERE identifier = 'v30-agent-followup-inputs';
                    """)
            }
        }
        let upgraded = Stores(db: try AitvarasDatabase(url: url))
        let root = try #require(try upgraded.agentTurn(id: input.id))
        #expect(root.parentInputID == nil)
        #expect(root.prompt == input.text)
        #expect(root.partialOutput == "retained partial")
        #expect(root.delivery == .deliveryUnknown)
        try upgraded.prepareAgentTurn(.init(input: .init(text: "new follow-up"), chatID: chatID,
            sessionID: sessionID, parentInputID: input.id))
        #expect(throws: (any Error).self) {
            try upgraded.prepareAgentTurn(.init(input: .init(text: "duplicate root"), chatID: chatID, sessionID: sessionID))
        }
    }

    @Test func barrierAndRecoveryRetainDeliveryAndPartialOutput() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let journal = AgentTurnStore(db: stores.db)
        let input = AgentInput(text: "fixture prompt")
        try journal.prepare(.init(input: input, chatID: chat.id, sessionID: session.id))
        #expect(try journal.turn(id: input.id)?.delivery == .prepared)
        try journal.advanceDelivery(id: input.id, to: .deliveryUnknown)
        try journal.savePartial(id: input.id, text: "partial output")
        try journal.recover()
        let recovered = try #require(try journal.turn(id: input.id))
        #expect(recovered.state == .interrupted)
        #expect(recovered.delivery == .deliveryUnknown)
        #expect(recovered.partialOutput == "partial output")
        #expect(throws: AgentFailure.invalidTransition) { try journal.claimResend(id: input.id) }
    }
    @Test func onlyPreparedCanRetryAndOnlyOnce() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let journal = AgentTurnStore(db: stores.db)
        let turn = AgentJournalTurn(input: .init(text: "fixture"), chatID: chat.id, sessionID: session.id)
        try journal.prepare(turn)
        #expect(throws: (any Error).self) { try journal.prepare(turn) }
        #expect(throws: AgentFailure.invalidTransition) { try journal.claimResend(id: turn.id) }
        try journal.recover()
        #expect(try journal.claimResend(id: turn.id).resendCount == 1)
        try journal.recover()
        #expect(throws: AgentFailure.invalidTransition) { try journal.claimResend(id: turn.id) }
    }
    @Test func acknowledgementCannotBeDowngradedAndBogusIDsFail() throws {
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores)
        let journal = AgentTurnStore(db: stores.db)
        let turn = AgentJournalTurn(input: .init(text: "fixture"), chatID: chat.id, sessionID: session.id)
        #expect(throws: AgentStoreError.missingTurn) { try journal.advanceDelivery(id: UUID(), to: .deliveryUnknown) }
        try journal.prepare(turn)
        #expect(throws: AgentFailure.invalidTransition) { try journal.advanceDelivery(id: turn.id, to: .acknowledged) }
        try journal.advanceDelivery(id: turn.id, to: .deliveryUnknown)
        try journal.advanceDelivery(id: turn.id, to: .acknowledged)
        #expect(throws: AgentFailure.invalidTransition) { try journal.advanceDelivery(id: turn.id, to: .prepared) }
        try journal.finish(id: turn.id, state: .completed)
        try journal.recover()
        #expect(try journal.turn(id: turn.id)?.state == .completed)
        #expect(throws: AgentFailure.invalidTransition) { try journal.claimResend(id: turn.id) }
        let (other, _) = try agentStoreChat(stores)
        #expect(throws: (any Error).self) {
            try journal.prepare(.init(input: .init(text: "wrong chat"), chatID: other.id, sessionID: session.id))
        }
    }
}
