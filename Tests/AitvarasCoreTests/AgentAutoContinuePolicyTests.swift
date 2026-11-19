import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinuePolicyTests {
    @Test func boundedConsentAuditsDispatchAndStillRequiresToolApproval() async throws {
        let stores = try inMemoryStores(), persistence = AgentAutoContinueStore(db: stores.db)
        let saved = try autoContinueIntent(stores), input = AgentInput(text: AgentAutoContinue.prompt, automaticIntentID: saved.id)
        let claim = try persistence.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
        let clock = UsageResetTestClock(autoContinueTestDate)
        let raw = AutoContinueRun(session: saved.native)
        let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: saved.chatID), audit: { _ = try stores.record($0) })
        try await coordinator.sendAutomatically(input, authorization: claim, session: saved.native, persistence: persistence, clock: clock.clock, willDeliver: {})
        let scope = AgentEventScope(runID: raw.id, session: saved.native, inputID: input.id)
        let request = AgentRequest(id: .string("approval"), scope: scope, kind: .permission(.init(name: "Bash", input: .string("PRIVATE_COMMAND_CANARY"))))
        await raw.emit(.request(request))
        try await autoWait { await coordinator.pendingRequests().count == 1 }
        #expect(await raw.responses.isEmpty)
        try await coordinator.respond(to: request, with: .deny)
        let events = try stores.recentActivity()
        let authorize = try #require(events.first { $0.detailJSON.flatMap(JSONValue.parse)?["operation"]?.stringValue == "authorize" })
        #expect(events.contains { $0.causedBy == authorize.id && $0.sourceID == saved.failedInputID.uuidString })
        let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for value in ["NATIVE_CANARY", "PRIVATE_COMMAND_CANARY", "PRIVATE_PROMPT_CANARY", "ACCOUNT_CANARY"] { #expect(!text.contains(value)) }
        try await coordinator.shutdown()
    }

    @Test func auditFailureOrRevocationPreventsProviderWrite() async throws {
        for scenario in ["audit-failure", "new-input", "archived"] {
            let stores = try inMemoryStores(), persistence = AgentAutoContinueStore(db: stores.db)
            let saved = try autoContinueIntent(stores), input = AgentInput(text: AgentAutoContinue.prompt, automaticIntentID: saved.id)
            let claim = try persistence.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
            let raw = AutoContinueRun(session: saved.native)
            let coordinator = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: saved.chatID), audit: { _ in
                if scenario == "new-input" { try persistence.noteNewInput(chatID: saved.chatID, now: autoContinueTestDate) }
                else if scenario == "archived" { try stores.archiveAgentChat(chatID: saved.chatID, archived: true) }
                else { throw AgentFailure.offline }
            })
            await #expect(throws: (any Error).self) {
                try await coordinator.sendAutomatically(input, authorization: claim, session: saved.native,
                    persistence: persistence, clock: UsageResetTestClock(autoContinueTestDate).clock, willDeliver: {})
            }
            #expect(await raw.inputs.isEmpty)
            try await coordinator.shutdown()
        }
    }

    @Test func modifiedPromptWrongSessionAndStaleClaimAreRejected() async throws {
        let stores = try inMemoryStores(), persistence = AgentAutoContinueStore(db: stores.db)
        let saved = try autoContinueIntent(stores), input = AgentInput(text: AgentAutoContinue.prompt, automaticIntentID: saved.id)
        let claim = try persistence.claim(id: saved.id, version: saved.version, inputID: input.id, now: autoContinueTestDate)
        let raw = AutoContinueRun(session: saved.native)
        let coordinator = AgentActionCoordinator(run: raw, mode: .auto, provenance: .init(chatID: saved.chatID), audit: { _ = try stores.record($0) })
        let clock = UsageResetTestClock(autoContinueTestDate).clock
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.sendAutomatically(.init(id: input.id, text: "Changed"), authorization: claim, session: saved.native, persistence: persistence, clock: clock, willDeliver: {}) }
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.sendAutomatically(input, authorization: claim, session: .init(provider: .codex, profile: "default", nativeID: "other"), persistence: persistence, clock: clock, willDeliver: {}) }
        try persistence.finish(id: claim.id, state: .cancelled, now: autoContinueTestDate)
        await #expect(throws: AgentFailure.invalidTransition) { try await coordinator.sendAutomatically(input, authorization: claim, session: saved.native, persistence: persistence, clock: clock, willDeliver: {}) }
        #expect(await raw.inputs.isEmpty)
        try await coordinator.shutdown()
    }

    @Test func pollChecksAccountConsentAuditAndRevocation() async throws {
        let stores = try inMemoryStores(), persistence = AgentAutoContinueStore(db: stores.db)
        let saved = try autoContinueIntent(stores), backend = AutoContinueBackend()
        let clock = UsageResetTestClock(autoContinueTestDate).clock
        let result = try await AgentActionCoordinator.autoContinueRateLimits(saved, backend: backend, persistence: persistence, clock: clock, audit: { _ = try stores.record($0) })
        #expect(result.scope == saved.scope && result.observedAt == autoContinueTestDate)
        await backend.setAccount("other-account")
        await #expect(throws: AgentFailure.invalidTransition) { _ = try await AgentActionCoordinator.autoContinueRateLimits(saved, backend: backend, persistence: persistence, clock: clock, audit: { _ = try stores.record($0) }) }
        await backend.setAccount(saved.scope.accountID)
        await #expect(throws: AgentFailure.offline) { _ = try await AgentActionCoordinator.autoContinueRateLimits(saved, backend: backend, persistence: persistence, clock: clock, audit: { _ in throw AgentFailure.offline }) }
        await #expect(throws: AgentFailure.invalidTransition) { _ = try await AgentActionCoordinator.autoContinueRateLimits(saved, backend: backend, persistence: persistence, clock: clock, audit: { _ in try persistence.noteNewInput(chatID: saved.chatID, now: autoContinueTestDate) }) }
        #expect(await backend.reads == 1)
    }
}
