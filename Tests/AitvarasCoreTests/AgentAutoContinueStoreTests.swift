import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct AgentAutoContinueStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func intent(_ stores: Stores, chatID: UUID? = nil) throws -> AgentAutoContinue {
        var session: AgentChatSession
        if let chatID { session = try #require(try stores.agentSession(chatID: chatID, provider: .codex)) }
        else { session = try agentStoreChat(stores, provider: .codex).1 }
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "NATIVE_ID_CANARY-" + session.id.uuidString)
        try stores.saveAgentSession(session)
        let input = AgentInput(text: "PROMPT_CANARY")
        try stores.prepareAgentTurn(.init(input: input, chatID: session.chatID, sessionID: session.id))
        try stores.finishAgentTurn(id: input.id, state: .failed)
        return AgentAutoContinue(chatID: session.chatID, failedInputID: input.id, sessionID: session.id,
            native: try #require(session.sessionID), scope: .init(provider: .codex, accountID: "ACCOUNT_CANARY"),
            createdAt: now, inputRevision: try AgentAutoContinueStore(db: stores.db).inputRevision(chatID: session.chatID),
            nextCheckAt: now.addingTimeInterval(300), nextPollAt: now.addingTimeInterval(600))
    }

    @Test func upgradeAndReopenPreserveSessionJournalChoicesAndTerminalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-continue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("store.sqlite")
        let candidate: AgentAutoContinue
        let session: AgentChatSession
        let turn: AgentJournalTurn
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            candidate = try intent(stores)
            session = try #require(try stores.agentSession(chatID: candidate.chatID, provider: .codex))
            turn = try #require(try stores.agentTurn(id: candidate.failedInputID))
            try stores.db.queue.write { db in
                try db.drop(table: "agentAutoContinue")
                try db.drop(table: "agentChatInputRevision")
                try db.drop(table: "agentUsageResetObservation")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v42-agent-auto-continue"])
            }
        }
        var persisted: AgentAutoContinue
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let store = AgentAutoContinueStore(db: stores.db)
            #expect(try store.pending().isEmpty)
            #expect(try stores.agentTurn(id: turn.id) == turn)
            #expect(try stores.agentSession(chatID: candidate.chatID, provider: .codex) == session)
            try store.schedule(candidate)
            persisted = try store.setOptions(id: candidate.id, enabled: false, keepAwake: true, now: now)
            try store.observe(.init(scope: candidate.scope, windowID: "codex.primary", resetsAt: now.addingTimeInterval(3600), observedAt: now))
        }
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let store = AgentAutoContinueStore(db: stores.db)
            #expect(try store.pending() == [persisted])
            #expect(try store.observations(scope: candidate.scope).first?.resetsAt == now.addingTimeInterval(3600))
            let on = try store.setOptions(id: candidate.id, enabled: true, keepAwake: true, now: now)
            let input = UUID()
            try store.claim(id: on.id, version: on.version, inputID: input, now: now.addingTimeInterval(300))
            persisted = try store.advanceDelivery(id: on.id, inputID: input, to: .deliveryUnknown, now: now.addingTimeInterval(300))
        }
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let store = AgentAutoContinueStore(db: stores.db)
            #expect(try store.pending() == [persisted])
            #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: persisted.id, version: persisted.version,
                inputID: UUID(), now: now.addingTimeInterval(600)) }
            try store.noteNewInput(chatID: candidate.chatID, now: now)
            persisted = try #require(try store.continuation(id: candidate.id))
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        let store = AgentAutoContinueStore(db: stores.db)
        #expect(try store.pending().isEmpty)
        #expect(try store.continuation(id: candidate.id) == persisted)
        #expect(try store.inputRevision(chatID: candidate.chatID) == 1)
        #expect(try stores.db.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    }

    @Test func scheduleIsIdempotentAndOnlyOneIntentPerChatIsActive() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let candidate = try intent(stores)
        let first = try store.schedule(candidate)
        #expect(try store.schedule(candidate) == first)
        let other = try intent(stores, chatID: candidate.chatID)
        #expect(throws: (any Error).self) { try store.schedule(other) }
        #expect(try store.pending() == [first])
        #expect(try stores.recentActivity().count == 1)
        try store.finish(id: first.id, state: .cancelled, now: now)
        #expect(try store.schedule(candidate).state == .cancelled)
        #expect(try store.schedule(other).failedInputID == other.failedInputID)
    }

    @Test func badIDsAndCrossChatOrChangedNativeIdentityAreRejected() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let candidate = try intent(stores), other = try intent(stores)
        let invalid = AgentAutoContinue(chatID: other.chatID, failedInputID: candidate.failedInputID,
            sessionID: candidate.sessionID, native: candidate.native, scope: candidate.scope,
            createdAt: now, inputRevision: 0, nextCheckAt: now)
        #expect(throws: AgentStoreError.identityConflict) { try store.schedule(invalid) }
        #expect(throws: AgentFailure.invalidRequest) { try store.finish(id: UUID(), state: .expired, now: now) }
        let saved = try store.schedule(candidate)
        var session = try #require(try stores.agentSession(chatID: candidate.chatID, provider: .codex))
        session.sessionID = .init(provider: .codex, profile: "default", nativeID: "replacement")
        try stores.saveAgentSession(session)
        #expect(throws: AgentStoreError.identityConflict) {
            try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now.addingTimeInterval(300))
        }
        #expect(try store.continuation(id: saved.id) == saved)
        #expect(throws: AgentStoreError.missingChat) { try store.inputRevision(chatID: UUID()) }
    }

    @Test func deletedClaudeProfileCannotBeClaimedOrRedirectedToDefault() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let profile = AgentProviderProfile(name: "Example", configDirectory: "/tmp/example-provider")
        try stores.saveClaudeProfile(profile)
        let chat = try agentStoreChat(stores).0
        var session = AgentChatSession(chatID: chat.id, provider: .claude, cwd: "/tmp", model: "test", providerProfile: profile.nativeProfile)
        session.sessionID = .init(provider: .claude, profile: profile.nativeProfile, nativeID: "fixture-native")
        try stores.saveAgentSession(session)
        let input = AgentInput(text: "test")
        try stores.prepareAgentTurn(.init(input: input, chatID: chat.id, sessionID: session.id))
        try stores.finishAgentTurn(id: input.id, state: .failed)
        let value = AgentAutoContinue(chatID: chat.id, failedInputID: input.id, sessionID: session.id,
            native: try #require(session.sessionID), scope: .init(provider: .claude, providerProfile: profile.nativeProfile),
            createdAt: now, inputRevision: 0, nextCheckAt: now)
        let saved = try store.schedule(value)
        try stores.deleteClaudeProfile(id: profile.id)
        #expect(throws: AgentStoreError.identityConflict) { try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now) }
        #expect(try store.continuation(id: saved.id) == saved)
    }

    @Test func staleOptionsEarlyClaimAndDuplicateClaimsCannotDispatch() async throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let saved = try store.schedule(intent(stores))
        #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now) }
        let off = try store.setOptions(id: saved.id, enabled: false, keepAwake: true, now: now)
        #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: off.id, version: off.version, inputID: UUID(), now: now.addingTimeInterval(300)) }
        let on = try store.setOptions(id: saved.id, enabled: true, keepAwake: true, now: now)
        #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now.addingTimeInterval(300)) }
        let deadline = now.addingTimeInterval(300)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask { (try? store.claim(id: on.id, version: on.version, inputID: UUID(), now: deadline)) != nil } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
    }

    @Test func deliveryAndRetryRemainScopedAndTerminalTransitionsAreIdempotent() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let saved = try store.schedule(intent(stores)), input = UUID(), date = now.addingTimeInterval(300)
        try store.claim(id: saved.id, version: saved.version, inputID: input, now: date)
        #expect(throws: AgentFailure.invalidTransition) { try store.finish(id: saved.id, state: .fired, now: date) }
        #expect(throws: AgentFailure.invalidTransition) { try store.advanceDelivery(id: saved.id, inputID: UUID(), to: .deliveryUnknown, now: date) }
        try store.advanceDelivery(id: saved.id, inputID: input, to: .deliveryUnknown, now: date)
        #expect(throws: AgentFailure.invalidTransition) { try store.advanceDelivery(id: saved.id, inputID: input, to: .prepared, now: date) }
        let retry = try store.retryAfterQuota(id: saved.id, inputID: input, nextCheckAt: date.addingTimeInterval(600), now: date)
        #expect(retry.retryCount == 1 && retry.fallbackStartedAt == now)
        #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: retry.id, version: retry.version, inputID: input, now: date.addingTimeInterval(600)) }
        let next = UUID()
        try store.claim(id: retry.id, version: retry.version, inputID: next, now: date.addingTimeInterval(600))
        try store.advanceDelivery(id: retry.id, inputID: next, to: .deliveryUnknown, now: date)
        try store.advanceDelivery(id: retry.id, inputID: next, to: .acknowledged, now: date)
        let fired = try store.finish(id: retry.id, state: .fired, now: date)
        #expect(try store.finish(id: retry.id, state: .fired, now: date) == fired)
        #expect(throws: AgentFailure.invalidTransition) { try store.finish(id: retry.id, state: .expired, now: date) }
        #expect(try store.pending().isEmpty)
    }

    @Test func newInputCancelsAndAdvancesRevisionAtomically() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let candidate = try intent(stores), saved = try store.schedule(candidate)
        try store.noteNewInput(chatID: saved.chatID, now: now)
        #expect(try store.inputRevision(chatID: saved.chatID) == 1)
        #expect(try store.continuation(id: saved.id)?.state == .cancelled)
        #expect(throws: AgentFailure.invalidTransition) { try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now.addingTimeInterval(300)) }
        let later = try intent(stores, chatID: saved.chatID)
        try store.noteNewInput(chatID: saved.chatID, now: now)
        #expect(throws: AgentFailure.invalidTransition) { try store.schedule(later) }
    }

    @Test func auditFailureRollsBackScheduleCancellationAndClaim() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let candidate = try intent(stores)
        func failAudit(_ enabled: Bool) throws {
            try stores.db.queue.write { db in
                if enabled { try db.execute(sql: "CREATE TRIGGER failAutoAudit BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END") }
                else { try db.execute(sql: "DROP TRIGGER failAutoAudit") }
            }
        }
        try failAudit(true)
        #expect(throws: (any Error).self) { try store.schedule(candidate) }
        #expect(try store.continuation(id: candidate.id) == nil)
        try failAudit(false)
        let saved = try store.schedule(candidate)
        try failAudit(true)
        #expect(throws: (any Error).self) { try store.noteNewInput(chatID: saved.chatID, now: now) }
        #expect(try store.inputRevision(chatID: saved.chatID) == 0)
        #expect(throws: (any Error).self) { try store.claim(id: saved.id, version: saved.version, inputID: UUID(), now: now.addingTimeInterval(300)) }
        #expect(try store.continuation(id: saved.id) == saved)
        #expect(try stores.recentActivity().count == 1)
    }

    @Test func resetObservationsAreScopedMonotonicAndDurable() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let scopes: [AgentUsageLimitScope] = [.init(provider: .codex), .init(provider: .codex, accountID: "account-a"),
            .init(provider: .claude), .init(provider: .claude, providerProfile: "profile-b")]
        for (index, scope) in scopes.enumerated() {
            let reset = now.addingTimeInterval(Double(index + 1) * 600)
            let observation = AgentUsageResetObservation(scope: scope, windowID: "primary", resetsAt: reset, observedAt: now)
            try store.observe(observation)
            try store.observe(.init(scope: scope, windowID: "primary", resetsAt: now, observedAt: now.addingTimeInterval(-1)))
            #expect(try store.observations(scope: scope) == [observation])
            try store.observe(.init(scope: scope, windowID: "primary", resetsAt: reset.addingTimeInterval(100), observedAt: now.addingTimeInterval(1)))
            #expect(try store.observations(scope: scope).first?.id == observation.id)
        }
        #expect(throws: AgentStoreError.invalidValue) { try store.observe(.init(scope: .init(provider: .local), windowID: "primary", resetsAt: now, observedAt: now)) }
    }

    @Test func reschedulePreservesFallbackStartAndAuditContainsOnlyLocalProvenance() throws {
        let stores = try inMemoryStores(), store = AgentAutoContinueStore(db: stores.db)
        let saved = try store.schedule(intent(stores))
        let reset = now.addingTimeInterval(3600)
        let updated = try store.reschedule(id: saved.id, version: saved.version, windowID: "codex.primary", resetsAt: reset,
            source: .poll, nextCheckAt: reset, nextPollAt: now.addingTimeInterval(600), now: now)
        #expect(updated.resetsAt == reset && updated.fallbackStartedAt == saved.fallbackStartedAt)
        #expect(throws: AgentFailure.invalidTransition) { try store.reschedule(id: saved.id, version: saved.version,
            windowID: nil, resetsAt: nil, source: .fallback, nextCheckAt: reset, nextPollAt: nil, now: now) }
        try store.finish(id: saved.id, state: .expired, now: reset)
        let terminal = try #require(try store.continuation(id: saved.id))
        let provenance = try stores.provenance(of: #require(terminal.lastActivityID))
        #expect(provenance.count == 3)
        #expect(provenance.allSatisfy { $0.sourceID == saved.failedInputID.uuidString && $0.runID == saved.failedInputID })
        let encoded = String(decoding: try JSONEncoder().encode(provenance), as: UTF8.self)
        for canary in ["PROMPT_CANARY", "NATIVE_ID_CANARY", "ACCOUNT_CANARY"] { #expect(!encoded.contains(canary)) }
    }
}
