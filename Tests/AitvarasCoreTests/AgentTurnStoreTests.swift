import Foundation
import Testing
import AitvarasAgents
@testable import AitvarasStore

@Suite struct AgentTurnStoreTests {
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
