import Foundation

/// Application-owned scheduler for verified usage-limit stops.
public actor AgentAutoContinueScheduler {
    public typealias Backend = @Sendable (AgentProviderChoice) throws -> any AgentBackend
    private let manager: AgentSessionManager
    private let turns: any AgentSessionPersistence
    private let persistence: any AgentAutoContinuePersistence
    private let backend: Backend
    private let audit: AgentActionCoordinator.Audit
    private let clock: AgentAutoContinueClock
    private var generation = UUID()
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var active = false
    private var processing = false
    private var requested = false
    private var listener: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var dispatch: Task<UUID, Error>?

    public init(manager: AgentSessionManager, turns: any AgentSessionPersistence,
                persistence: any AgentAutoContinuePersistence, backend: @escaping Backend,
                audit: @escaping AgentActionCoordinator.Audit, clock: AgentAutoContinueClock = .live) {
        self.manager = manager; self.turns = turns; self.persistence = persistence
        self.backend = backend; self.audit = audit; self.clock = clock
    }
    deinit {
        listener?.cancel(); timer?.cancel(); dispatch?.cancel()
        subscribers.values.forEach { $0.finish() }
    }
    public func updates() -> AsyncStream<Void> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[key] = continuation; continuation.yield(())
        continuation.onTermination = { [weak self] _ in Task { await self?.detach(key) } }
        return stream
    }
    private func detach(_ key: UUID) { subscribers.removeValue(forKey: key) }
    private func changed() { subscribers.values.forEach { $0.yield(()) } }
    private func current(_ generation: UUID) -> Bool { active && self.generation == generation }
    private func wakeCurrentGeneration() {
        guard active else { return }
        Task { [weak self] in try? await self?.wake() }
    }

    public func start() async throws {
        guard !Task.isCancelled else { return }
        if active { try await wake(); return }
        generation = UUID(); active = true
        let generation = generation
        if listener == nil {
            let updates = await manager.autoContinueUpdates()
            guard current(generation) else { return }
            listener = Task { [weak self] in
                for await _ in updates {
                    guard !Task.isCancelled else { break }
                    try? await self?.wake()
                }
            }
        }
        try await wake()
    }
    public func shutdown() {
        generation = UUID(); active = false; requested = false; dispatch?.cancel(); dispatch = nil
        timer?.cancel(); timer = nil; listener?.cancel(); listener = nil
    }
    public func cancel(id: UUID) async throws {
        try persistence.finish(id: id, state: .cancelled, now: clock.now())
        changed(); try await wake()
    }
    public func setOptions(id: UUID, enabled: Bool, keepAwake: Bool) async throws {
        try persistence.setOptions(id: id, enabled: enabled, keepAwake: keepAwake, now: clock.now())
        changed(); try await wake()
    }
    /// A row can be toggled while registration is awaiting the provider's status.
    /// Save the choice first; dispatch and polling still verify the current account.
    public func setRowOption(failedInputID: UUID, _ option: AgentAutoContinueRowOption) throws {
        guard active else { throw AgentFailure.invalidTransition }
        if let existing = try persistence.continuation(failedInputID: failedInputID) {
            let choices = option.applying(enabled: existing.enabled, keepAwake: existing.keepAwake)
            try persistence.setOptions(id: existing.id, enabled: choices.enabled, keepAwake: choices.keepAwake, now: clock.now())
        } else {
            guard let stop = try turns.quotaStops().first(where: { $0.id == failedInputID }),
                  scope(for: stop).hasKnownAccount,
                  try turns.latestAgentTurn(chatID: stop.chatID)?.id == stop.id,
                  try persistence.inputRevision(chatID: stop.chatID) == stop.inputRevision else { throw AgentFailure.invalidTransition }
            if let receipt = try turns.automaticInput(id: stop.id),
               try persistence.continuation(id: receipt.intentID)?.state != .fired { throw AgentFailure.invalidTransition }
            let choices = option.applying(enabled: true, keepAwake: false)
            try schedule(stop, enabled: choices.enabled, keepAwake: choices.keepAwake)
        }
        changed()
        wakeCurrentGeneration()
    }
    /// Wake, launch and timer all converge here; actor reentrancy cannot dispatch twice.
    public func wake() async throws {
        guard active, !Task.isCancelled else { return }
        if processing { requested = true; changed(); return }
        let generation = generation
        processing = true
        do {
            repeat {
                requested = false
                try await recoverClaims(generation: generation)
                guard current(generation) else { break }
                try await registerStops(generation: generation)
                for pending in try persistence.pending() where pending.state == .pending && pending.enabled {
                    guard current(generation) else { break }
                    try await process(pending, generation: generation)
                }
            } while requested && current(generation)
            processing = false; changed()
            guard current(generation) else { wakeCurrentGeneration(); return }
            try armTimer()
        } catch {
            processing = false; changed()
            guard current(generation) else { wakeCurrentGeneration(); return }
            // Failed storage/audit never causes a hot loop or an unaudited send.
            try? armTimer(notBefore: clock.now().addingTimeInterval(30))
            throw error
        }
    }
    private func registerStops(generation: UUID) async throws {
        for stop in try turns.quotaStops() {
            let scope = scope(for: stop)
            guard current(generation), scope.hasKnownAccount, try turns.latestAgentTurn(chatID: stop.chatID)?.id == stop.id,
                  try persistence.inputRevision(chatID: stop.chatID) == stop.inputRevision else { continue }
            if let receipt = try turns.automaticInput(id: stop.id),
               try persistence.continuation(id: receipt.intentID)?.state != .fired { continue }
            // Creation is idempotent, including terminal/cancelled intents.
            if try persistence.continuation(failedInputID: stop.id) != nil { continue }
            let allSessions = try turns.agentSessions(chatID: stop.chatID)
            guard allSessions.contains(where: { $0.id == stop.sessionID && $0.sessionID == stop.native }) else { continue }
            let status: AgentStatus
            do {
                try turns.requireAgentChatAvailable(chatID: stop.chatID)
                let provider = try backend(.init(provider: stop.native.provider, profile: stop.providerProfile))
                status = try await AgentActionCoordinator.quotaStopStatus(stop, backend: provider, clock: clock, audit: audit)
            } catch { continue }
            guard current(generation), scope.matches(accountID: status.accountID), try turns.latestAgentTurn(chatID: stop.chatID)?.id == stop.id,
                  try persistence.inputRevision(chatID: stop.chatID) == stop.inputRevision else { continue }
            do { try schedule(stop) }
            catch AgentSessionManagerError.chatUnavailable { continue }
        }
    }
    private func scope(for stop: AgentQuotaStop) -> AgentUsageLimitScope {
        .init(provider: stop.native.provider, providerProfile: stop.providerProfile, accountKey: stop.accountKey)
    }
    private func schedule(_ stop: AgentQuotaStop, enabled: Bool = true, keepAwake: Bool = false) throws {
        let scope = scope(for: stop)
        let resolver = AgentUsageResetResolver(clock: clock), schedule = AgentAutoContinueSchedule(clock: clock)
        let reset = resolver.resolve(scope: scope, failure: stop.evidence, cached: try persistence.observations(scope: scope))
        let pending = AgentAutoContinue(chatID: stop.chatID, failedInputID: stop.id, sessionID: stop.sessionID,
            native: stop.native, scope: scope, createdAt: stop.stoppedAt, inputRevision: stop.inputRevision,
            enabled: enabled, keepAwake: keepAwake, windowID: reset?.windowID, resetsAt: reset?.resetsAt,
            resetSource: reset?.source ?? .fallback,
            nextCheckAt: max(stop.stoppedAt, schedule.firstCheck(startedAt: stop.stoppedAt, reset: reset)),
            nextPollAt: stop.native.provider == .codex ? stop.stoppedAt.addingTimeInterval(600) : nil)
        try persistence.schedule(pending, causedBy: nil)
    }
    private func recoverClaims(generation: UUID) async throws {
        for value in try persistence.pending() where value.state == .claimed {
            guard current(generation) else { return }
            if let input = value.continuationInputID, await manager.isInputRunning(chatID: value.chatID, inputID: input) { continue }
            guard current(generation) else { return }
            let turn = try value.continuationInputID.flatMap { try turns.agentTurn(id: $0) }
            let receipt = try value.continuationInputID.flatMap { try turns.automaticInput(id: $0) }
            if receipt?.outcome == "quota", let input = value.continuationInputID {
                try retry(value, inputID: input, resetsAt: receipt?.resetsAt)
            } else if receipt?.outcome == "completed" || turn?.delivery == .acknowledged && receipt?.outcome == nil {
                if value.delivery == .prepared { try persistence.advanceDelivery(id: value.id, inputID: turn!.id, to: .deliveryUnknown, now: clock.now()) }
                if value.delivery != .acknowledged { try persistence.advanceDelivery(id: value.id, inputID: turn!.id, to: .acknowledged, now: clock.now()) }
                try persistence.finish(id: value.id, state: .fired, now: clock.now())
                if let inputID = value.continuationInputID {
                    try await manager.publishAutomaticMarker(chatID: value.chatID, inputID: inputID)
                }
            } else if receipt?.outcome != nil || value.delivery != .prepared || turn?.delivery == .deliveryUnknown {
                try persistence.finish(id: value.id, state: .cancelled, now: clock.now())
            } else {
                try persistence.releasePrepared(id: value.id, inputID: value.continuationInputID, now: clock.now())
            }
        }
    }
    private func retry(_ value: AgentAutoContinue, inputID: UUID, resetsAt: Date?) throws {
        let now = clock.now(), schedule = AgentAutoContinueSchedule(clock: clock)
        let evidence = try turns.quotaStops().first { $0.id == inputID }?.evidence
        let reset = AgentUsageResetResolver(clock: clock).resolve(scope: value.scope,
            failure: .init(status: .rejected, windowID: evidence?.windowID ?? value.windowID, resetsAt: resetsAt), cached: try persistence.observations(scope: value.scope), rejectedAt: now)
        let next = reset?.resetsAt ?? schedule.nextFallbackAttempt(startedAt: value.fallbackStartedAt,
            rejectedAttempts: value.retryCount + 1, rejectedAt: now)
        guard let next, next > now else { try persistence.finish(id: value.id, state: .expired, now: now); return }
        try persistence.retryAutomatic(id: value.id, inputID: inputID, reset: reset, nextCheckAt: next,
            nextPollAt: value.scope.provider == .codex ? value.nextPollAt ?? value.createdAt.addingTimeInterval(600) : nil, now: now)
    }
    private func process(_ pending: AgentAutoContinue, generation: UUID) async throws {
        guard pending.scope.hasKnownAccount else {
            try persistence.finish(id: pending.id, state: .cancelled, now: clock.now())
            return
        }
        let schedule = AgentAutoContinueSchedule(clock: clock), plan = schedule.plan(pending)
        switch plan.state {
        case .expired: try persistence.finish(id: pending.id, state: .expired, now: clock.now())
        case .ready:
            do {
                let manager = manager
                let sending = Task { try await manager.continueAutomatically(id: pending.id) }
                dispatch = sending
                _ = try await sending.value
                if current(generation) { dispatch = nil }
            }
            catch let error as AgentSessionManagerError where error == .chatBusy || error == .runningChatLimit {
                guard current(generation) else { return }
                try deferCheck(pending)
            } catch {
                guard current(generation), let saved = try persistence.continuation(id: pending.id) else { return }
                // A failed send can journal a definite rejection before throwing.
                // Require that receipt so a pre-claim quota error cannot loop.
                if case .quota? = error as? AgentFailure, saved.state == .claimed,
                   let inputID = saved.continuationInputID, let receipt = try turns.automaticInput(id: inputID),
                   receipt.outcome == "quota" {
                    try retry(saved, inputID: inputID, resetsAt: receipt.resetsAt)
                } else if saved.state == .claimed || saved == pending {
                    try persistence.finish(id: pending.id, state: .cancelled, now: clock.now())
                }
            }
        case .waiting:
            guard let pollAt = plan.pollAt, pollAt <= clock.now() else { return }
            var reset: AgentUsageResetResolution?
            do {
                let snapshot = try await AgentActionCoordinator.autoContinueRateLimits(pending,
                    backend: backend(.init(provider: pending.scope.provider, profile: pending.scope.providerProfile)),
                    persistence: persistence, clock: clock, audit: audit)
                guard current(generation) else { return }
                for window in snapshot.windows {
                    if let date = window.resetsAt { try persistence.observe(.init(scope: snapshot.scope, windowID: window.id, resetsAt: date, observedAt: snapshot.observedAt)) }
                }
                reset = AgentUsageResetResolver(clock: clock).resolve(scope: pending.scope,
                    failure: .init(status: .rejected, windowID: pending.windowID, resetsAt: pending.resetsAt), polled: snapshot)
            } catch let failure as AgentFailure where failure == .authRequired {
                guard current(generation), try persistence.continuation(id: pending.id) == pending else { return }
                try persistence.finish(id: pending.id, state: .cancelled, now: clock.now()); return
            } catch { /* Reads can be unavailable; the bounded fallback still applies. */ }
            guard current(generation), try persistence.continuation(id: pending.id) == pending else { return }
            let now = clock.now()
            try persistence.reschedule(id: pending.id, version: pending.version, windowID: reset?.windowID ?? pending.windowID,
                resetsAt: reset?.resetsAt ?? pending.resetsAt, source: reset?.source ?? pending.resetSource,
                nextCheckAt: max(now, reset?.resetsAt ?? pending.nextCheckAt),
                nextPollAt: now.addingTimeInterval(AgentAutoContinueSchedule.pollingInterval), now: now)
            if let reset, reset.resetsAt <= now { requested = true }
        default: break
        }
    }
    private func deferCheck(_ value: AgentAutoContinue) throws {
        guard try persistence.continuation(id: value.id) == value else { return }
        try persistence.reschedule(id: value.id, version: value.version, windowID: value.windowID, resetsAt: value.resetsAt,
            source: value.resetSource, nextCheckAt: clock.now().addingTimeInterval(30), nextPollAt: value.nextPollAt, now: clock.now())
    }
    private func armTimer(notBefore: Date? = nil) throws {
        timer?.cancel(); timer = nil
        guard active else { return }
        let schedule = AgentAutoContinueSchedule(clock: clock)
        var dates: [Date] = []
        for pending in try persistence.pending() {
            let plan = schedule.plan(pending)
            if plan.state == .expired {
                try persistence.finish(id: pending.id, state: .expired, now: clock.now()); changed()
            } else if let date = plan.nextWakeAt { dates.append(date) }
        }
        guard let date = dates.min() else { return }
        let deadline = max(date, notBefore ?? date), clock = clock
        timer = Task { [weak self] in
            do { try await clock.sleepUntil(deadline); try Task.checkCancellation(); try await self?.wake() }
            catch { /* Cancellation and transient checks are handled by the next opportunity. */ }
        }
    }
}
