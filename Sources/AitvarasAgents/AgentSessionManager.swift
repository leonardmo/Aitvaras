import Foundation

public enum AgentSessionManagerError: Error, Sendable, Equatable {
    case chatBusy, chatUnavailable, runningChatLimit, shuttingDown, missingSession, staleRun, persistence
}

/// Application lifetime owner. Views only subscribe; detaching never stops a run.
public actor AgentSessionManager {
    public static let maximumRunningChats = 8
    public typealias BackendFactory = @Sendable (AgentProvider) throws -> any AgentBackend
    private struct Live {
        let token: UUID
        var session: AgentChatSession
        var coordinator: AgentActionCoordinator?
        var startup: Task<any AgentRun, Error>?
        var reader: Task<Void, Never>?
        var idle: Task<Void, Never>?
        var inputID: UUID?
        var followups: [AgentInput] = []
        var sendingFollowup = false
        var stopping = false
        var automatic: UUID?
        var accountID: String?
        var usageLimit: AgentUsageLimit?
        var expectedNative: AgentSessionID?
        var wakeTools: [String: AgentTool] = [:]
        var lastUsed = ContinuousClock.now

        var isRunning: Bool { inputID != nil || !followups.isEmpty || sendingFollowup || stopping }
    }
    private let persistence: any AgentSessionPersistence
    public typealias ProfileBackendFactory = @Sendable (AgentProviderChoice) throws -> any AgentBackend
    private let profileBackend: ProfileBackendFactory?
    private let backend: BackendFactory
    private let audit: AgentActionCoordinator.Audit
    private let continuationPersistence: (any AgentAutoContinuePersistence)?
    private let continuationClock: AgentAutoContinueClock
    private let idleTimeout: Duration
    private let mcpPolicy: AgentMCPLaunchPolicy
    private var live: [UUID: Live] = [:]
    private var states: [UUID: ChatState] = [:]
    private var subscribers: [UUID: [UUID: AsyncStream<ChatState>.Continuation]] = [:]
    private var continuationSubscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var wakeTickRunning = false
    private var closing = false
    private var recovering = Set<UUID>()
    private struct RecoveryDelivery {
        let stoppedEntryID: UUID
        let action: AgentRecoveryAction
        let session: AgentChatSession
        let wireText: String
        let context: ChatContextProjection?
        let continued: Bool
    }
    private var refreshing = Set<UUID>()
    private var historyWaiters: [UUID: [CheckedContinuation<Void, any Error>]] = [:]
    private var historyTokens: [UUID: UUID] = [:]
    private var approvalSubscribers: [UUID: AsyncStream<[AgentApprovalSuggestion]>.Continuation] = [:]

    /// Startup recovery is synchronous and must finish before any backend starts.
    public init(persistence: any AgentSessionPersistence, idleTimeout: Duration = .seconds(600),
                backend: @escaping BackendFactory, profileBackend: ProfileBackendFactory? = nil, audit: @escaping AgentActionCoordinator.Audit,
                mcpPolicy: AgentMCPLaunchPolicy = .default, autoContinuePersistence: (any AgentAutoContinuePersistence)? = nil,
                continuationClock: AgentAutoContinueClock = .live) throws {
        self.continuationPersistence = autoContinuePersistence; self.continuationClock = continuationClock
        self.profileBackend = profileBackend
        self.persistence = persistence; self.idleTimeout = idleTimeout; self.backend = backend; self.audit = audit
        self.mcpPolicy = mcpPolicy
        try persistence.recoverAgentTurns()
        try (persistence as? any AgentWakePersistence)?.releaseAgentWakeTransport(nil)
    }
    deinit {
        for slot in live.values {
            slot.reader?.cancel(); slot.idle?.cancel()
            slot.startup?.cancel()
            if let coordinator = slot.coordinator { Task { try? await coordinator.shutdown() } }
        }
        approvalSubscribers.values.forEach { $0.finish() }
        subscribers.values.forEach { $0.values.forEach { $0.finish() } }
    }

    private func scopedBackend(_ choice: AgentProviderChoice) throws -> any AgentBackend {
        if let profileBackend { return try profileBackend(choice) }
        guard choice.profile == "default" else { throw AgentFailure.invalidRequest }
        return try backend(choice.provider)
    }
    private func scopedBackend(_ session: AgentChatSession) throws -> any AgentBackend { try scopedBackend(session.choice) }

    public func autoContinueUpdates() -> AsyncStream<Void> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuationSubscribers[key] = continuation; continuation.yield(())
        continuation.onTermination = { [weak self] _ in Task { await self?.detachContinuation(key) } }
        return stream
    }
    private func detachContinuation(_ key: UUID) { continuationSubscribers.removeValue(forKey: key) }
    private func continuationChanged() { continuationSubscribers.values.forEach { $0.yield(()) } }
    public func isInputRunning(chatID: UUID, inputID: UUID) -> Bool { live[chatID]?.inputID == inputID }
    private func quotaContext(for stop: AgentStopReason?, chatID: UUID, slot: Live) throws -> AgentStoppedTurn.QuotaContext? {
        guard let continuationPersistence, stop?.kind == .quota, slot.session.sessionID != nil else { return nil }
        return .init(windowID: slot.usageLimit?.windowID, accountID: slot.accountID,
            inputRevision: try continuationPersistence.inputRevision(chatID: chatID), stoppedAt: continuationClock.now())
    }

    public func state(chatID: UUID) throws -> ChatState {
        if let state = states[chatID] { return state }
        var value = ChatState(chatID: chatID, entries: try persistence.agentEntries(chatID: chatID))
        for entry in value.entries where entry.kind == "user" && entry.payloadJSON != nil {
            if try persistence.agentTurn(id: entry.id)?.state == .interrupted {
                value.markFollowup(entry.id, status: "interrupted")
            }
        }
        if let turn = try persistence.latestAgentTurn(chatID: chatID) {
            value.restore(turn: turn)
        }
        states[chatID] = value; return value
    }
    public func updates(chatID: UUID) throws -> AsyncStream<ChatState> {
        let value = try state(chatID: chatID)
        let key = UUID()
        let (stream, continuation) = AsyncStream<ChatState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[chatID, default: [:]][key] = continuation
        continuation.yield(value)
        continuation.onTermination = { [weak self] _ in Task { await self?.detach(chatID, key: key) } }
        return stream
    }
    /// Suggestions and inline cards are projections of the same live pending set.
    public func approvalUpdates() -> AsyncStream<[AgentApprovalSuggestion]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[AgentApprovalSuggestion]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        approvalSubscribers[key] = continuation
        continuation.yield(approvalSuggestions())
        continuation.onTermination = { [weak self] _ in Task { await self?.detachApprovals(key) } }
        return stream
    }
    public func approvalSuggestions() -> [AgentApprovalSuggestion] {
        states.keys.sorted { $0.uuidString < $1.uuidString }.flatMap { chat in
            (states[chat]?.pendingCards ?? []).map { AgentApprovalSuggestion(chatID: chat, request: $0) }
        }
    }
    private func detachApprovals(_ key: UUID) { approvalSubscribers.removeValue(forKey: key) }
    private func detach(_ chat: UUID, key: UUID) { subscribers[chat]?.removeValue(forKey: key) }
    private func publish(_ chat: UUID) {
        guard let state = states[chat] else { return }
        subscribers[chat]?.values.forEach { $0.yield(state) }
        let approvals = approvalSuggestions()
        approvalSubscribers.values.forEach { $0.yield(approvals) }
    }

    /// Surface pre-delivery failures too; they have no journaled turn yet.
    /// A rejected follow-up must not overwrite the active turn's state.
    public func reportSendFailure(chatID: UUID, failure: AgentFailure) throws {
        guard live[chatID]?.inputID == nil else { return }
        var value = try state(chatID: chatID)
        value.end(.failed(failure)); states[chatID] = value; publish(chatID)
    }

    /// Also covers errors caught by the App before a provider can start.
    @discardableResult
    public func reportSendFailure(chatID: UUID, inputID: UUID, error: any Error) async throws -> AgentFailure {
        let report = AgentFailureDiagnostics.capture(error)
        _ = await report.recording(chatID: chatID, inputID: inputID, audit: audit)
        try reportSendFailure(chatID: chatID, failure: report.failure)
        return report.failure
    }

    public static func historyUnavailable(_ error: any Error) -> Bool {
        if let report = error as? AgentFailureReport { return historyUnavailable(report.failure) }
        if let failure = error as? AgentFailure {
            switch failure {
            case .unsupported, .notInstalled, .offline, .authRequired, .crashed: return true
            default: return false
            }
        }
        return (error as? AgentNativeHistoryError) == .notFound
    }

    /// Shared-chat metadata only. Neither operation sends to a provider or
    /// disposes a run; an archived active chat can still finish or be stopped.
    public func rename(chatID: UUID, title: String) throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.renameAgentChat(chatID: chatID, title: title)
    }
    public func setArchived(chatID: UUID, archived: Bool) throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.archiveAgentChat(chatID: chatID, archived: archived)
    }

    /// Saving settings starts no process. A subsequent Send resumes with them.
    public func configure(_ session: AgentChatSession) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.requireAgentChatAvailable(chatID: session.chatID)
        guard !refreshing.contains(session.chatID), live[session.chatID]?.inputID == nil, live[session.chatID]?.followups.isEmpty != false,
              live[session.chatID]?.sendingFollowup != true, live[session.chatID]?.stopping != true else {
            throw AgentSessionManagerError.chatBusy
        }
        try persistence.saveAgentSession(session)
        if live[session.chatID]?.session == session { return }
        if let slot = live.removeValue(forKey: session.chatID) {
            slot.reader?.cancel(); slot.idle?.cancel()
            if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
            try wakeStore?.releaseAgentWakeTransport(slot.token)
        }
    }

    public func send(chatID: UUID, provider: AgentProvider, input: AgentInput,
                     onAccepted: @escaping @Sendable () async -> Void = {}) async throws {
        if !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.attachments.isEmpty || input.command != nil {
            try continuationPersistence?.noteNewInput(chatID: chatID, now: continuationClock.now())
            continuationChanged()
        }
        if live[chatID]?.inputID != nil {
            try await followup(chatID: chatID, provider: provider, input: input, onAccepted: onAccepted)
        } else {
            try await deliver(chatID: chatID, provider: provider, input: input, retry: false, onAccepted: onAccepted)
        }
    }
    /// Only the original stored session/profile is eligible; composer selection is irrelevant.
    @discardableResult public func continueAutomatically(id: UUID) async throws -> UUID {
        guard let continuationPersistence, let pending = try continuationPersistence.continuation(id: id),
              pending.state == .pending, pending.enabled else { throw AgentFailure.invalidTransition }
        guard AgentAutoContinueSchedule(clock: continuationClock).plan(pending).state == .ready else { throw AgentFailure.invalidTransition }
        let input = AgentInput(text: AgentAutoContinue.prompt, automaticIntentID: pending.id)
        try await deliver(chatID: pending.chatID, provider: pending.scope.provider, input: input, retry: false, automatic: pending)
        return input.id
    }

    private func followup(chatID: UUID, provider: AgentProvider, input: AgentInput,
                          onAccepted: @Sendable () async -> Void) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.requireAgentChatAvailable(chatID: chatID)
        guard let slot = live[chatID], slot.session.provider == provider,
              try persistence.agentSession(chatID: chatID, provider: provider)?.id == slot.session.id,
              let run = slot.coordinator, !slot.stopping, !slot.sendingFollowup,
              slot.session.usesThreadContext, slot.followups.count < 32,
              try persistence.agentTurn(id: input.id) == nil else { throw AgentSessionManagerError.chatBusy }
        // Reserve before yielding, and commit this input separately from the
        // output owner. Failed/uncertain follow-ups are never silently resent.
        live[chatID]?.sendingFollowup = true
        defer { if live[chatID]?.token == slot.token { live[chatID]?.sendingFollowup = false } }
        try persistence.prepareAgentTurn(.init(input: input, chatID: chatID, sessionID: slot.session.id,
            parentInputID: slot.inputID))
        live[chatID]?.lastUsed = .now
        live[chatID]?.followups.append(input)
        states[chatID]?.appendFollowup(input, session: slot.session)
        do {
            try persistEntries(chatID); publish(chatID)
            await onAccepted()
            guard live[chatID]?.token == slot.token, live[chatID]?.stopping == false,
                  live[chatID]?.followups.contains(where: { $0.id == input.id }) == true, !closing else {
                throw AgentSessionManagerError.staleRun
            }
            let persistence = persistence
            try await run.followup(input) { try persistence.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
        } catch {
            if let current = live[chatID], current.token == slot.token {
                if try persistence.agentTurn(id: input.id)?.delivery == .prepared {
                    // A busy provider or failed barrier has not taken this
                    // input. Keep the active turn and its approval cards alive.
                    try finishTurn(chatID: chatID, id: input.id, state: .failed,
                        stop: .failure(AgentFailureDiagnostics.failure(for: error), category: AgentFailureDiagnostics.capture(error).category))
                    live[chatID]?.followups.removeAll { $0.id == input.id }
                    states[chatID]?.markFollowup(input.id, status: "notSent")
                    try persistEntries(chatID); publish(chatID)
                    if live[chatID]?.inputID == nil, live[chatID]?.followups.isEmpty == true { armIdle(chatID, token: slot.token) }
                } else {
                    let report = AgentFailureDiagnostics.capture(error)
                    // Retire owns transport/state cleanup before the audit can yield.
                    do { try await retire(chatID, slot: current, outcome: .failed(report.failure), stop: .failure(report.failure, category: report.category)) }
                    catch {
                        _ = await AgentFailureDiagnostics.capture(error).recording(chatID: chatID, inputID: input.id, audit: audit)
                        _ = await report.recording(chatID: chatID, inputID: input.id, audit: audit)
                        throw error
                    }
                    _ = await report.recording(chatID: chatID, inputID: input.id, audit: audit)
                }
            }
            throw error
        }
    }
    /// Caller explicitly chooses retry. Never called during startup or reconnect.
    public func resendPrepared(turnID: UUID) async throws {
        guard try persistence.automaticInput(id: turnID) == nil else { throw AgentFailure.invalidTransition }
        guard let turn = try persistence.agentTurn(id: turnID),
              let session = try persistence.agentSession(chatID: turn.chatID,
                  provider: try providerForTurn(turn)), session.id == turn.sessionID else {
            throw AgentSessionManagerError.missingSession
        }
        try continuationPersistence?.noteNewInput(chatID: turn.chatID, now: continuationClock.now())
        // Without the durable user entry we cannot prove that selected bytes
        // and skills survived a failed save. Never retry a text-only substitute.
        guard let entry = try persistence.agentEntries(chatID: turn.chatID).first(where: { $0.id == turn.id }) else {
            throw AgentFailure.invalidTransition
        }
        try await deliver(chatID: turn.chatID, provider: session.provider,
                          input: .restoring(id: turn.id, text: entry.text, payload: entry.payloadJSON), retry: true)
    }
    private func providerForTurn(_ turn: AgentJournalTurn) throws -> AgentProvider {
        for provider in [AgentProvider.claude, .codex, .local] {
            if try persistence.agentSession(chatID: turn.chatID, provider: provider)?.id == turn.sessionID { return provider }
        }
        throw AgentSessionManagerError.missingSession
    }

    /// Explicit recovery seam. It never schedules a timer or sends on startup.
    /// The caller supplies the persisted row, not a draft or the selected model.
    public func recover(chatID: UUID, stoppedEntryID: UUID, action: AgentRecoveryAction) async throws {
        guard !closing, recovering.insert(chatID).inserted else { throw AgentSessionManagerError.chatBusy }
        defer { recovering.remove(chatID) }
        try persistence.requireAgentChatAvailable(chatID: chatID)
        guard live[chatID]?.isRunning != true, !refreshing.contains(chatID),
              let row = try persistence.agentEntries(chatID: chatID).first(where: { $0.id == stoppedEntryID }),
              let stop = row.stoppedTurn, stop.actions.contains(action), [.continueTurn, .retry].contains(action),
              let turn = try persistence.agentTurn(id: stop.inputID), turn.state != .running,
              turn.resendCount == stop.attempt, try persistence.latestAgentTurn(chatID: chatID)?.id == turn.id,
              let session = try persistence.agentSessions(chatID: chatID).first(where: { $0.id == row.sessionID }),
              session.id == turn.sessionID, session.choice == stop.choice,
              session.sessionID == stop.nativeSession else { throw AgentFailure.invalidTransition }
        let original = try persistence.agentEntries(chatID: chatID).first { $0.id == turn.id }
        let input: AgentInput
        let wire: String
        let context: ChatContextProjection?
        if action == .continueTurn {
            guard session.usesThreadContext, stop.canContinue else { throw AgentFailure.invalidTransition }
            input = AgentInput(text: AgentStoppedTurn.continuationText)
            wire = input.text; context = nil
        } else {
            // Autonomous turns have no user prompt to resend.
            guard let original, let prompt = turn.prompt else { throw AgentFailure.invalidTransition }
            input = try .restoring(id: UUID(), text: original.text, payload: original.payloadJSON)
            wire = prompt; context = try persistence.agentHandover(turnID: turn.id)
        }
        let recovery = RecoveryDelivery(stoppedEntryID: stoppedEntryID, action: action, session: session,
            wireText: wire, context: context, continued: action == .continueTurn || original?.kind == "continued")
        try continuationPersistence?.noteNewInput(chatID: chatID, now: continuationClock.now())
        continuationChanged()
        try await deliver(chatID: chatID, provider: session.provider, input: input, retry: false, recovery: recovery)
    }

    private func deliver(chatID: UUID, provider: AgentProvider, input: AgentInput, retry: Bool,
                         recovery: RecoveryDelivery? = nil,
                         autonomousReason: AgentAutonomousReason? = nil,
                         autonomousSession: AgentChatSession? = nil,
                         claimDelivery: (@Sendable (UUID) async throws -> Void)? = nil,
                         onAccepted: @Sendable () async -> Void = {}, automatic: AgentAutoContinue? = nil) async throws {
        var authorization = automatic
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.requireAgentChatAvailable(chatID: chatID)
        guard !refreshing.contains(chatID) else { throw AgentSessionManagerError.chatBusy }
        if !retry, recovery == nil, live[chatID]?.inputID == nil {
            if let automatic, let continuationPersistence {
                try await AgentActionCoordinator.authorizeAutomaticHistoryRead(automatic, persistence: continuationPersistence, clock: continuationClock, audit: audit)
            }
            do { try await refreshNativeHistory(chatID: chatID) }
            catch where Self.historyUnavailable(error) {
                // The durable transcript remains the context source when the
                // CLI has no readable native history yet (or no full reader).
            }
            try persistence.requireAgentChatAvailable(chatID: chatID)
        }
        guard live[chatID]?.inputID == nil, live[chatID]?.followups.isEmpty != false,
              live[chatID]?.sendingFollowup != true, live[chatID]?.stopping != true else {
            throw AgentSessionManagerError.chatBusy
        }
        let selectedSession = try automatic.flatMap { pending in try persistence.agentSessions(chatID: chatID).first { $0.id == pending.sessionID } }
        guard var session = try selectedSession ?? recovery?.session ?? autonomousSession ?? persistence.agentSession(chatID: chatID, provider: provider) else {
            throw AgentSessionManagerError.missingSession
        }
        if let automatic {
            guard session.id == automatic.sessionID, session.sessionID == automatic.native,
                  try continuationPersistence?.continuation(id: automatic.id) == automatic else { throw AgentFailure.invalidTransition }
        }
        if provider == .local, (try? backend(provider)) is LocalBackend, session.usesThreadContext {
            guard recovery == nil else { throw AgentFailure.invalidTransition }
            // A missing opencode installation must not make text-only inference
            // skip its own prior replies or pretend it resumed a native thread.
            session.sessionID = nil
            try persistence.saveAgentSession(session)
        }
        _ = try state(chatID: chatID)
        let context = try automatic != nil ? nil : recovery.map(\.context) ?? (retry ? persistence.agentHandover(turnID: input.id) : persistence.agentContext(session: session))
        let wireText = try recovery?.wireText ?? (retry ? persistence.agentTurn(id: input.id)?.prompt : nil)
        let wireInput = AgentInput(id: input.id, text: wireText ?? context?.wire(message: input.text) ?? input.text,
                                  attachments: input.attachments, mentions: input.mentions, command: input.command, automaticIntentID: input.automaticIntentID)
        if live.values.filter(\.isRunning).count >= Self.maximumRunningChats {
            throw AgentSessionManagerError.runningChatLimit
        }
        // Retain at most eight transports. Idle sessions are durable and can
        // resume natively; a running turn (including approvals) is never evicted.
        let eviction = live[chatID] == nil && live.count >= Self.maximumRunningChats
            ? live.filter { !$0.value.isRunning }.max { a, b in
                let left = nextOwnedFire(chatID: a.key, token: a.value.token)
                let right = nextOwnedFire(chatID: b.key, token: b.value.token)
                return left == right ? a.value.lastUsed > b.value.lastUsed : left < right
            } : nil
        // Reserve this chat and capacity before any await, including startup.
        let old = live[chatID]
        var configuration = session.configuration
        configuration.knownMessageIDs = Set((states[chatID]?.entries ?? []).filter { $0.sessionID == session.id }.compactMap(\.nativeMessageID))
        configuration.verifiesResumeIdentity = recovery?.action == .continueTurn
        configuration.projectID = try persistence.agentProjectID(chatID: chatID)
        let revision = try (provider == .claude || provider == .local)
            ? mcpPolicy.snapshot(directory: configuration.directory, projectID: configuration.projectID).status.revision : nil
        let setupMatches = old?.coordinator?.mcpSetup.map { $0.revision == revision } ?? true
        let canReuse = session.usesThreadContext && old?.session == session && setupMatches
        let token = canReuse ? old!.token : UUID()
        old?.idle?.cancel()
        // Native Local sessions reuse their transport and acknowledged handover
        // receipts, just like the subscription providers. AgentLoop stays fresh.
        let reusable = canReuse ? old?.coordinator : nil
        live[chatID] = Live(token: token, session: session, coordinator: reusable, inputID: input.id, automatic: automatic?.id, accountID: reusable?.accountID)
        live[chatID]?.expectedNative = automatic?.native ?? recovery?.session.sessionID
        do {
            if let automatic, let continuationPersistence {
                authorization = try continuationPersistence.claim(id: automatic.id, version: automatic.version, inputID: input.id, now: continuationClock.now())
                var turn = AgentJournalTurn(input: wireInput, chatID: chatID, sessionID: session.id)
                turn.startedAt = continuationClock.now()
                try persistence.prepareAutomaticTurn(turn, authorization: authorization!)
            } else if let recovery {
                let entry = AgentTranscriptEntry(id: input.id, chatID: chatID, provider: provider,
                    kind: recovery.continued ? "continued" : "user", text: input.text,
                    payloadJSON: input.composerPayload(), sessionID: session.id)
                try persistence.prepareAgentRecovery(.init(input: wireInput, chatID: chatID, sessionID: session.id),
                    context: context, entry: entry, stoppedEntryID: recovery.stoppedEntryID, action: recovery.action, session: session)
                states[chatID]?.entries = try persistence.agentEntries(chatID: chatID)
            } else if retry {
                _ = try persistence.claimAgentResend(id: input.id)
                states[chatID]?.entries = try persistence.agentEntries(chatID: chatID)
            } else if let reason = autonomousReason {
                var turn = AgentJournalTurn(autonomousID: input.id, reason: reason, chatID: chatID, sessionID: session.id)
                // PR prompts can contain third-party logs and comments. Their
                // contents are needed only for this delivery.
                if reason != .pullRequest { turn.autonomousPrompt = wireInput.text }
                try persistence.prepareAgentTurn(turn, context: context)
            } else {
                var turn = AgentJournalTurn(input: wireInput, chatID: chatID, sessionID: session.id)
                turn.startedAt = continuationClock.now()
                try persistence.prepareAgentTurn(turn, context: context)
            }
        } catch { live[chatID] = old; if let old { armIdle(chatID, token: old.token) }; throw error }
        var evictionCleanup: Task<Void, Never>?
        if let (chat, slot) = eviction {
            live.removeValue(forKey: chat)
            slot.reader?.cancel(); slot.idle?.cancel()
            // Reserve the replacement before yielding to bounded shutdown.
            let wakeStore = persistence as? any AgentWakePersistence
            evictionCleanup = Task {
                if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
                try? wakeStore?.releaseAgentWakeTransport(slot.token)
            }
        }
        if let reason = autonomousReason {
            states[chatID]?.beginAutonomous(id: input.id, reason: reason, provider: provider, sessionID: session.id)
        } else { states[chatID]?.begin(input, session: session, outputID: UUID(), context: context, automatic: automatic != nil) }
        do {
            try persistEntries(chatID)
            publish(chatID)
            await onAccepted()
            await evictionCleanup?.value
            guard live[chatID]?.token == token, live[chatID]?.inputID == input.id,
                  live[chatID]?.stopping == false, !closing else { throw AgentSessionManagerError.staleRun }
            if let authorization, let continuationPersistence {
                try await AgentActionCoordinator.autoContinueStatus(authorization, backend: scopedBackend(session),
                    persistence: continuationPersistence, clock: continuationClock, audit: audit)
            }
            let coordinator: AgentActionCoordinator
            if let reusable {
                // Acceptance can yield to UI/storage. A revoked setup must not
                // authorize another turn on an already initialized transport.
                if let setup = reusable.mcpSetup,
                   try mcpPolicy.snapshot(directory: configuration.directory, projectID: configuration.projectID).status.revision != setup.revision {
                    throw AgentFailure.invalidTransition
                }
                coordinator = reusable
                live[chatID]?.reader = old?.reader
            } else {
                old?.reader?.cancel()
                if let run = old?.coordinator { await Self.close(run, timeout: .seconds(2)) }
                if let old { try wakeStore?.releaseAgentWakeTransport(old.token) }
                let launchConfiguration = configuration
                let selectedBackend = try scopedBackend(session)
                let startup = Task { try await selectedBackend.start(launchConfiguration) }
                live[chatID]?.startup = startup
                let raw = try await withTaskCancellationHandler { try await startup.value } onCancel: { startup.cancel() }
                if live[chatID]?.token == token { live[chatID]?.startup = nil }
                guard live[chatID]?.token == token, !closing else {
                    await Self.close(raw, timeout: .seconds(2)); throw AgentSessionManagerError.staleRun
                }
                coordinator = AgentActionCoordinator(run: raw, mode: session.mode,
                    provenance: .init(chatID: chatID), projectGrants: { [persistence, mcpPolicy] in
                        let current = try mcpPolicy.snapshot(directory: launchConfiguration.directory, projectID: launchConfiguration.projectID)
                        return AgentToolPolicy.currentGrants(try persistence.agentAlwaysAllowedTools(chatID: chatID),
                            servers: current.status.serverFingerprints)
                    }, audit: { [audit] event in
                        var value = event
                        // Coordinator IDs identify a transport that can serve many
                        // turns. Activity is owned by the durable input instead.
                        value.runID = event.detailJSON.flatMap(JSONValue.parse)?["inputID"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? input.id
                        try await audit(value)
                    })
                live[chatID]?.coordinator = coordinator
                live[chatID]?.accountID = raw.accountID
                states[chatID]?.mcpSetup = raw.mcpSetup
                live[chatID]?.reader = Task { [weak self] in
                    do {
                        for try await event in coordinator.events {
                            await self?.receive(event, chatID: chatID, token: token)
                        }
                        await self?.exited(chatID, token: token, failure: .crashed(exitCode: nil))
                    } catch { await self?.exited(chatID, token: token, report: AgentFailureDiagnostics.capture(error)) }
                }
            }
            guard live[chatID]?.token == token, live[chatID]?.inputID == input.id else {
                throw AgentSessionManagerError.staleRun
            }
            let persistence = persistence
            if let authorization, let continuationPersistence {
                try await coordinator.sendAutomatically(wireInput, authorization: authorization, session: authorization.native,
                    persistence: continuationPersistence, clock: continuationClock) {
                    guard try persistence.agentSessions(chatID: chatID).contains(where: { $0.id == authorization.sessionID && $0.sessionID == authorization.native }) else { throw AgentFailure.invalidTransition }
                    try persistence.beginAutomaticDelivery(id: input.id, authorization: authorization, now: self.continuationClock.now())
                }
            } else {
                try await coordinator.send(wireInput) {
                    if let claimDelivery { try await claimDelivery(input.id) }
                    else { try persistence.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
                }
            }
        } catch {
            await failedSend(chatID, token: token, inputID: input.id, error: error)
            throw error
        }
    }

    private func persistEntries(_ chat: UUID, previous: [AgentTranscriptEntry] = []) throws {
        guard var value = states[chat] else { return }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        value.entries = try value.entries.map { $0.isLegacyProjection || old[$0.id] == $0 ? $0 : try persistence.saveAgentEntry($0) }
        states[chat] = value
    }
    private func receive(_ incoming: AgentEvent, chatID: UUID, token: UUID) async {
        var event = incoming
        if case .message(let id, let role, let text) = incoming.kind, let session = incoming.scope.session {
            event = .init(scope: incoming.scope, kind: .message(id: session.canonicalMessageID(id, turnID: incoming.scope.turnID), role: role, text: text))
        }
        guard let slot = live[chatID], slot.token == token, slot.coordinator?.id == event.scope.runID else { return }
        // Lifecycle events can precede Send. Turn events must match local input.
        if case .autonomousTurnStarted(let id, let reason) = event.kind {
            guard slot.inputID == nil, !slot.stopping, event.scope.inputID == id else { return }
            do {
                if reason == .wakeup || reason == .scheduled {
                    let wakes = try wakeStore?.pendingAgentWakes(chatID: chatID) ?? []
                    // The CLI starts its timer before Aitvaras sees the tool result, so a
                    // live fire can land just before the stored fireAt. Clear the oldest
                    // record this transport owns; never let it linger into the grace path.
                    if let wake = wakes.filter({ $0.transportID == token && $0.fireAt != nil
                        && (reason == .wakeup ? $0.kind == .wakeup : $0.kind == .cron) }).min(by: { $0.fireAt! < $1.fireAt! }) {
                        try wakeStore?.finishAgentWake(id: wake.id, now: .now)
                    }
                }
                try persistence.prepareAgentTurn(.init(autonomousID: id, reason: reason, chatID: chatID, sessionID: slot.session.id))
                live[chatID]?.idle?.cancel(); live[chatID]?.inputID = id; live[chatID]?.lastUsed = .now
                live[chatID]?.automatic = nil; live[chatID]?.usageLimit = nil
                states[chatID]?.beginAutonomous(id: id, reason: reason, provider: slot.session.provider, sessionID: slot.session.id)
                try persistEntries(chatID)
                publish(chatID)
            } catch { await exited(chatID, token: token, failure: .unknown) }
            return
        }
        if let input = event.scope.inputID, input != slot.inputID {
            guard slot.followups.contains(where: { $0.id == input }) else { return }
            switch event.kind {
            case .delivery, .inputActivated, .message(_, "user", _): break
            default: return
            }
        }
        if slot.stopping {
            // Keep identity and delivery evidence even if Stop races init.
            // Queued activation/output cannot re-open stale approval cards.
            switch event.kind {
            case .turnEnded, .sessionStarted, .delivery: break
            default: return
            }
        }
        do {
            try observeWake(event, chatID: chatID, slot: slot)
            if slot.automatic != nil, let input = slot.inputID, event.scope.inputID == input {
                var messageID: String?
                if slot.session.provider == .codex, case .message(let id, "user", let text) = event.kind,
                   text == AgentAutoContinue.prompt { messageID = id }
                if messageID != nil || event.scope.turnID != nil {
                    try persistence.bindAutomaticInput(id: input, messageID: messageID, turnID: event.scope.turnID)
                }
            }
            switch event.kind {
            case .usageLimit(let evidence):
                if evidence.status == .rejected { live[chatID]?.usageLimit = evidence }
            case .rateLimits(let windows):
                if let continuationPersistence, slot.session.provider != .local {
                    let scope = AgentUsageLimitScope(provider: slot.session.provider, providerProfile: slot.session.providerProfile, accountID: slot.accountID)
                    for window in windows {
                        if let reset = window.resetsAt {
                            try continuationPersistence.observe(.init(scope: scope, windowID: window.id, resetsAt: reset, observedAt: continuationClock.now()))
                        }
                    }
                }
            case .modeChanged(let mode):
                var session = slot.session; session.mode = mode
                try persistence.saveAgentSession(session)
                live[chatID]?.session = session
            case .sessionStarted(let native):
                guard native.provider == slot.session.provider else { throw AgentFailure.invalidRequest }
                if let expected = slot.expectedNative, native != expected { throw AgentFailure.invalidTransition }
                var session = slot.session
                if let origin = session.forkOrigin, origin.pending {
                    guard native.provider == .claude, let identity = UUID(uuidString: native.nativeID),
                          identity != UUID(uuidString: origin.native.nativeID) else { throw AgentFailure.invalidRequest }
                    session.forkOrigin?.pending = false
                }
                session.sessionID = native
                try persistence.saveAgentSession(session)
                live[chatID]?.session = session
            case .message(let nativeID, "user", _) where event.scope.inputID != slot.inputID:
                if let index = states[chatID]?.entries.firstIndex(where: { $0.id == event.scope.inputID }),
                   states[chatID]?.entries[index].nativeMessageID == nil || states[chatID]?.entries[index].nativeMessageID == nativeID {
                    states[chatID]?.entries[index].nativeMessageID = nativeID
                    try persistEntries(chatID)
                }
            case .inputActivated:
                guard let id = event.scope.inputID, let input = slot.followups.first(where: { $0.id == id }) else { return }
                live[chatID]?.inputID = id
                live[chatID]?.automatic = nil; live[chatID]?.usageLimit = nil
                live[chatID]?.followups.removeAll { $0.id == id }
                states[chatID]?.begin(input, session: slot.session, outputID: UUID())
                states[chatID]?.markFollowup(id, status: "sent")
            case .delivery(let delivery):
                guard let input = event.scope.inputID else { return }
                try persistence.advanceAgentDelivery(id: input, to: delivery)
                if delivery == .acknowledged, slot.session.provider == .codex {
                    states[chatID]?.markFollowup(input, status: "steered")
                    if live[chatID]?.inputID == nil, let outcome = states[chatID]?.outcome {
                        try finishTurn(chatID: chatID, id: input, state: Self.journalState(outcome), stop: Self.stopReason(outcome))
                    }
                }
            default: break
            }
            if case .turnEnded(let reportedOutcome) = event.kind, slot.session.provider == .claude,
               event.scope.completedInputIDs.count > 1 {
                let ids = event.scope.completedInputIDs
                guard ids.first == slot.inputID, Set(ids).count == ids.count,
                      Set(ids.dropFirst()).isSubset(of: Set(slot.followups.map(\.id))),
                      let latest = slot.followups.first(where: { $0.id == ids.last }) else { throw AgentFailure.invalidRequest }
                let outcome = slot.stopping ? AgentTurnOutcome.interrupted : reportedOutcome
                let answer = states[chatID]?.completeCoalescedTurn(latest: latest, outcome: outcome) ?? ""
                for id in ids {
                    if outcome == .completed { try persistence.advanceAgentDelivery(id: id, to: .acknowledged) }
                    try persistence.saveAgentPartial(id: id, text: id == latest.id ? answer : "")
                    try finishTurn(chatID: chatID, id: id, state: Self.journalState(outcome),
                        stop: Self.stopReason(outcome, report: event.failureReport), quotaSlot: slot)
                    states[chatID]?.markFollowup(id, status: outcome == .interrupted ? "interrupted" : "sent")
                }
                live[chatID]?.followups.removeAll { ids.contains($0.id) }
                live[chatID]?.inputID = nil
                try persistEntries(chatID)
                try persistence.orderAgentEntries(chatID: chatID, ids: (states[chatID]?.entries ?? []).filter { !$0.isLegacyProjection }.map(\.id))
                states[chatID]?.entries = try persistence.agentEntries(chatID: chatID)
                states[chatID]?.pendingCards = []
                continuationChanged()
                armIdle(chatID, token: token); publish(chatID)
                return
            }
            if let intentID = slot.automatic, let continuationPersistence,
               let pending = try continuationPersistence.continuation(id: intentID), pending.state == .claimed, pending.delivery == .acknowledged {
                let worked: Bool
                switch event.kind {
                case .textDelta(let text), .thinkingDelta(let text): worked = !text.isEmpty
                case .toolStarted: worked = true
                case .message(_, "assistant", let text): worked = !text.isEmpty
                default: worked = false
                }
                if worked { try continuationPersistence.finish(id: intentID, state: .fired, now: continuationClock.now()); continuationChanged() }
            }
            let previous = states[chatID]?.entries ?? []
            switch event.kind {
            case .inputActivated, .delivery: try persistEntries(chatID)
            default: break
            }
            states[chatID]?.reduce(event, newEntryID: UUID())
            if states[chatID]?.entries != previous { try persistEntries(chatID, previous: previous) }
            switch event.kind {
            case .textDelta, .message(_, "assistant", _):
                if let input = slot.inputID {
                    try persistence.saveAgentPartial(id: input, text: states[chatID]?.partialOutput ?? "")
                }
            default: break
            }
            if case .turnEnded(let outcome) = event.kind, let input = slot.inputID, event.scope.inputID == input {
                let outcome = slot.stopping ? AgentTurnOutcome.interrupted : outcome
                if slot.stopping { states[chatID]?.end(.interrupted) }
                try finishTurn(chatID: chatID, id: input, state: Self.journalState(outcome),
                    stop: Self.stopReason(outcome, report: event.failureReport), quotaSlot: slot)
                live[chatID]?.inputID = nil
                if slot.session.provider == .codex {
                    for followup in slot.followups {
                        // A steer response can follow a fast turn/completed.
                        // Finish only after its RPC acknowledgement is handled.
                        if try persistence.agentTurn(id: followup.id)?.delivery == .acknowledged {
                            try finishTurn(chatID: chatID, id: followup.id, state: Self.journalState(outcome), stop: Self.stopReason(outcome, report: event.failureReport), quotaSlot: slot)
                        }
                    }
                }
                continuationChanged()
                if slot.session.provider == .local, !slot.stopping, let next = slot.followups.first {
                    live[chatID]?.inputID = next.id
                    states[chatID]?.awaitingQueuedInput()
                }
                if slot.followups.isEmpty { armIdle(chatID, token: token) }
            }
            if live[chatID]?.inputID == nil, slot.session.provider == .codex {
                live[chatID]?.followups.removeAll { followup in
                    (try? persistence.agentTurn(id: followup.id)?.state) != .running
                }
                if live[chatID]?.followups.isEmpty == true { armIdle(chatID, token: token) }
            }
            // Hooks are forwarded, but only the coordinator's pending set makes cards.
            if let coordinator = slot.coordinator {
                let pending = await coordinator.pendingRequests()
                guard live[chatID]?.token == token else { return }
                states[chatID]?.pendingCards = pending
            }
            publish(chatID)
            if case .turnEnded(.failed(let failure)) = event.kind {
                let report = event.failureReport ?? AgentFailureDiagnostics.capture(failure)
                _ = await report.recording(chatID: chatID, inputID: event.scope.inputID, audit: audit)
            }
        } catch { await exited(chatID, token: token, report: AgentFailureDiagnostics.capture(error, mappedTo: .unknown), failedInput: event.scope.inputID) }
    }
    private static func stopReason(_ outcome: AgentTurnOutcome, report: AgentFailureReport? = nil) -> AgentStopReason? {
        switch outcome {
        case .completed: nil
        case .interrupted: .interrupted
        case .failed(let failure): .failure(failure, category: report?.category)
        }
    }
    private func finishTurn(chatID: UUID, id: UUID, state: AgentJournalState, stop: AgentStopReason? = nil,
                            quotaSlot: Live? = nil) throws {
        if states[chatID]?.inputID == id, let turn = try? persistence.agentTurn(id: id) {
            states[chatID]?.noteDelivery(turn.delivery)
        }
        do {
            let context = try quotaSlot.flatMap { try quotaContext(for: stop, chatID: chatID, slot: $0) }
            if let entry = try persistence.finishAgentTurn(id: id, state: state, stop: stop, quotaContext: context) {
                putStopped(entry, chatID: chatID)
            }
        } catch {
            // Keep a visible internal failure even when the diagnostic itself
            // cannot be saved. No recovery can be claimed from this fallback.
            let report = AgentFailureDiagnostics.capture(error)
            if let turn = try? persistence.agentTurn(id: id),
               let session = try? persistence.agentSessions(chatID: chatID).first(where: { $0.id == turn.sessionID }) {
                let value = AgentStoppedTurn(turn: turn, session: session, reason: .failure(.unknown, category: report.category))
                let entry = AgentTranscriptEntry(chatID: chatID, provider: session.provider, kind: "stopped",
                    payloadJSON: try? value.payload(), sessionID: session.id)
                putStopped(entry, chatID: chatID)
            }
            throw error
        }
    }
    private func putStopped(_ entry: AgentTranscriptEntry, chatID: UUID) {
        let value = entry.stoppedTurn
        if let index = states[chatID]?.entries.firstIndex(where: {
            $0.id == entry.id || (value != nil && $0.stoppedTurn?.inputID == value?.inputID && $0.stoppedTurn?.attempt == value?.attempt)
        }) { states[chatID]?.entries[index] = entry }
        else { states[chatID]?.entries.append(entry) }
    }
    private static func journalState(_ outcome: AgentTurnOutcome) -> AgentJournalState {
        switch outcome { case .completed: .completed; case .interrupted: .interrupted; case .failed: .failed }
    }
    private func failedSend(_ chat: UUID, token: UUID, inputID: UUID, error: Error) async {
        guard live[chat]?.token == token, live[chat]?.inputID == inputID else { return }
        await exited(chat, token: token, report: AgentFailureDiagnostics.capture(error), preservePrepared: error is CancellationError)
    }
    private func exited(_ chat: UUID, token: UUID, failure: AgentFailure) async {
        await exited(chat, token: token, report: AgentFailureDiagnostics.capture(failure))
    }
    private func exited(_ chat: UUID, token: UUID, report: AgentFailureReport, failedInput: UUID? = nil, preservePrepared: Bool = false) async {
        guard let slot = live[chat], slot.token == token else { return }
        var reports = [report]
        live.removeValue(forKey: chat); slot.reader?.cancel(); slot.idle?.cancel()
        for followup in slot.followups {
            do {
                if try persistence.agentTurn(id: followup.id)?.state == .running {
                    try finishTurn(chatID: chat, id: followup.id, state: .interrupted,
                        stop: slot.stopping ? .interrupted : .failure(report.failure, category: report.category))
                }
            } catch { reports.append(AgentFailureDiagnostics.capture(error)) }
            states[chat]?.markFollowup(followup.id, status: "interrupted")
        }
        if let input = slot.inputID ?? failedInput {
            do {
                let journal = try persistence.agentTurn(id: input)
                let isAutomatic = try persistence.automaticInput(id: input) != nil
                let preserve = preservePrepared && journal?.delivery == .prepared
                let stop: AgentStopReason = preserve ? .connectionClosed : slot.stopping ? .interrupted
                    : .failure(report.failure, category: report.category)
                let failed = !preserve && !slot.stopping && (isAutomatic || stop.kind == .quota)
                try finishTurn(chatID: chat, id: input, state: failed ? .failed : .interrupted, stop: stop, quotaSlot: slot)
            }
            catch { reports.append(AgentFailureDiagnostics.capture(error)) }
            states[chat]?.end(slot.stopping ? .interrupted : .failed(report.failure))
        }
        do { try persistEntries(chat) }
        catch { reports.append(AgentFailureDiagnostics.capture(error)) }
        states[chat]?.pendingCards = []; publish(chat); continuationChanged()
        if slot.inputID != nil || failedInput != nil || !slot.followups.isEmpty {
            for report in reports {
                _ = await report.recording(chatID: chat, inputID: slot.inputID ?? failedInput ?? slot.followups.first?.id, audit: audit)
            }
        }
        if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
        try? wakeStore?.releaseAgentWakeTransport(slot.token)
    }
    private func armIdle(_ chat: UUID, token: UUID) {
        live[chat]?.idle?.cancel()
        let timeout = idleTimeout
        live[chat]?.idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.idleExpired(chat, token: token)
        }
    }
    private func idleExpired(_ chat: UUID, token: UUID) async {
        guard let slot = live[chat], slot.token == token, !slot.isRunning else { return }
        guard (try? wakeStore?.pendingAgentWakes(chatID: chat).contains { $0.transportID == token }) != true else { return }
        live.removeValue(forKey: chat); slot.reader?.cancel()
        if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
        try? wakeStore?.releaseAgentWakeTransport(slot.token)
    }
    /// Reject stale Activity clicks before entering the chat-scoped Stop path.
    /// A queued input stops its owning run, including the other queued inputs.
    @discardableResult
    public func stop(activityRunID: UUID) async throws -> Bool {
        guard let turn = try persistence.agentTurn(id: activityRunID), turn.state == .running,
              let slot = live[turn.chatID], slot.session.id == turn.sessionID,
              slot.inputID == turn.id || slot.followups.contains(where: { $0.id == turn.id }) else { return false }
        try await stop(chatID: turn.chatID)
        return true
    }

    public func stop(chatID: UUID) async throws {
        if refreshing.contains(chatID) {
            historyTokens.removeValue(forKey: chatID)
        }
        guard let slot = live[chatID], !slot.stopping,
              slot.inputID != nil || !slot.followups.isEmpty || slot.sendingFollowup else { return }
        live[chatID]?.stopping = true
        let clock = ContinuousClock(), deadline = clock.now + .milliseconds(1400)
        let interrupt = Task { try? await slot.coordinator?.interrupt() }
        // Do not use a task group: an uncooperative RPC/audit would keep its
        // group alive beyond the deadline even after cancellation.
        while clock.now < deadline, live[chatID]?.token == slot.token,
              live[chatID]?.inputID != nil, slot.coordinator != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        interrupt.cancel()
        guard let current = live[chatID], current.token == slot.token else { return }
        if slot.session.provider == .claude, !slot.followups.isEmpty {
            // A result after interrupt does not prove the native stdin queue
            // was consumed. Dispose it; the next explicit Send resumes safely.
            try await retire(chatID, slot: current, outcome: .interrupted)
        } else if current.inputID == nil, current.followups.isEmpty, !current.sendingFollowup {
            live[chatID]?.stopping = false
            states[chatID]?.end(.interrupted); publish(chatID)
        } else {
            try await retire(chatID, slot: current, outcome: .interrupted)
        }
    }
    private func retire(_ chat: UUID, slot: Live, outcome: AgentTurnOutcome, stop: AgentStopReason? = nil) async throws {
        guard live[chat]?.token == slot.token else { return }
        slot.startup?.cancel()
        live.removeValue(forKey: chat); slot.reader?.cancel(); slot.idle?.cancel()
        var failures: [(UUID?, AgentFailureReport)] = []
        for id in [slot.inputID].compactMap({ $0 }) + slot.followups.map(\.id) {
            do {
                if try persistence.agentTurn(id: id)?.state == .running {
                    try finishTurn(chatID: chat, id: id, state: .interrupted, stop: stop ?? Self.stopReason(outcome))
                }
            } catch { failures.append((id, AgentFailureDiagnostics.capture(error))) }
            states[chat]?.markFollowup(id, status: "interrupted")
        }
        states[chat]?.end(outcome)
        do { try persistEntries(chat) }
        catch { failures.append((slot.inputID, AgentFailureDiagnostics.capture(error))) }
        publish(chat)
        if let run = slot.coordinator {
            let abort = Task { await run.abort() }
            // Transport disposal has a small bounded grace; no detached run can
            // regain ownership or deliver into the replacement generation.
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            let cleanup = Task { await abort.value; continuation.yield(()); continuation.finish() }
            let timer = Task { try? await Task.sleep(for: .milliseconds(300)); continuation.yield(()); continuation.finish() }
            for await _ in stream { break }
            cleanup.cancel(); timer.cancel()
        }
        for (inputID, report) in failures { _ = await report.recording(chatID: chat, inputID: inputID, audit: audit) }
        try wakeStore?.releaseAgentWakeTransport(slot.token)
        if !failures.isEmpty { throw AgentSessionManagerError.persistence }
    }
    public func respond(chatID: UUID, to request: AgentRequest, with response: AgentResponse) async throws {
        guard let slot = live[chatID], let run = slot.coordinator else { throw AgentSessionManagerError.staleRun }
        live[chatID]?.lastUsed = .now
        do { try await run.respond(to: request, with: response) }
        catch {
            let pending = await run.pendingRequests()
            if live[chatID]?.token == slot.token { states[chatID]?.pendingCards = pending; publish(chatID) }
            throw error
        }
        let pending = await run.pendingRequests()
        guard live[chatID]?.token == slot.token else { return }
        states[chatID]?.pendingCards = pending; publish(chatID)
    }
    public func alwaysAllow(chatID: UUID, request: AgentRequest) async throws {
        guard let slot = live[chatID], let run = slot.coordinator,
              let projectID = try persistence.agentProjectID(chatID: chatID) else { throw AgentFailure.invalidRequest }
        let session = slot.session
        do {
            try await run.alwaysAllow(to: request) { [persistence, mcpPolicy] in
                if case .permission(let tool) = request.kind, tool.name.hasPrefix("mcp__") {
                    let current = try mcpPolicy.snapshot(directory: URL(fileURLWithPath: session.cwd), projectID: projectID)
                    guard let fingerprint = AgentToolPolicy.fingerprint(tool: tool.name, servers: current.status.serverFingerprints),
                          fingerprint == AgentToolPolicy.fingerprint(tool: tool.name, servers: run.mcpSetup?.serverFingerprints ?? [:]) else { throw AgentFailure.invalidRequest }
                }
                try persistence.allowAgentTool(chatID: chatID, request: request)
            }
        } catch {
            if live[chatID]?.token == slot.token { states[chatID]?.pendingCards = await run.pendingRequests(); publish(chatID) }
            throw error
        }
        if live[chatID]?.token == slot.token { states[chatID]?.pendingCards = await run.pendingRequests(); publish(chatID) }
    }

    /// Detach generations first. Bounded cleanup never poisons the owner: if
    /// application quit is cancelled, the next Send creates a fresh live run.
    public func resumeAfterCancelledTermination() { closing = false }

    public func shutdown(timeout: Duration = .seconds(2)) async throws {
        guard !closing else { return }
        closing = true
        historyTokens.removeAll()
        let slots = live; live.removeAll()
        var failures: [(UUID, UUID?, AgentFailureReport)] = []
        for (chat, slot) in slots {
            slot.reader?.cancel(); slot.idle?.cancel()
            slot.startup?.cancel()
            for followup in slot.followups {
                do {
                    if try persistence.agentTurn(id: followup.id)?.state == .running {
                        try finishTurn(chatID: chat, id: followup.id, state: .interrupted)
                    }
                } catch { failures.append((chat, followup.id, AgentFailureDiagnostics.capture(error))) }
                states[chat]?.markFollowup(followup.id, status: "interrupted")
            }
            if let input = slot.inputID {
                do {
                    // App shutdown is recoverable for an automatic input that has not crossed the write barrier.
                    try finishTurn(chatID: chat, id: input, state: .interrupted,
                        stop: slot.automatic == nil ? nil : .connectionClosed)
                } catch { failures.append((chat, input, AgentFailureDiagnostics.capture(error))) }
                states[chat]?.end(.interrupted)
            }
            states[chat]?.pendingCards = []
            do { try persistEntries(chat) }
            catch { failures.append((chat, slot.inputID, AgentFailureDiagnostics.capture(error))) }
            publish(chat)
        }
        // All closes share one deadline, including a misbehaving injected run.
        let runs = slots.values.compactMap(\.coordinator)
        let startups = slots.values.compactMap(\.startup)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let cleanup = Task {
            await withTaskGroup(of: Void.self) { group in
                for run in runs { group.addTask { try? await run.shutdown() } }
                for startup in startups {
                    group.addTask { if let run = try? await startup.value { try? await run.shutdown() } }
                }
            }
            continuation.yield(()); continuation.finish()
        }
        let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(()); continuation.finish() }
        for await _ in stream { break }
        cleanup.cancel(); timer.cancel(); closing = false
        for (chat, inputID, report) in failures { _ = await report.recording(chatID: chat, inputID: inputID, audit: audit) }
        var wakeReleaseFailed = false
        for slot in slots.values {
            do { try wakeStore?.releaseAgentWakeTransport(slot.token) } catch { wakeReleaseFailed = true }
        }
        if !failures.isEmpty || wakeReleaseFailed { throw AgentSessionManagerError.persistence }
    }
    private static func close(_ run: any AgentRun, timeout: Duration) async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let cleanup = Task { try? await run.shutdown(); continuation.yield(()); continuation.finish() }
        let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(()); continuation.finish() }
        for await _ in stream { break }
        cleanup.cancel(); timer.cancel()
    }
}

extension AgentSessionManager {
    /// Discovery starts no run and sends no prompt. Read every page before
    /// committing mappings, so a failed CLI never leaves half a discovery.
    public func discoverNativeSessions(provider: AgentProvider, profile: String = "default") async throws -> [UUID] {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard provider != .local, let store = persistence as? any AgentNativeSessionPersistence else { throw AgentFailure.unsupported }
        let reader = try scopedBackend(.init(provider: provider, profile: profile))
        var sessions: [AgentSessionSummary] = [], cursor: String?, cursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await reader.nativeSessions(folder: nil, cursor: cursor, archived: false)
            guard page.items.allSatisfy({ $0.id.provider == provider }) else { throw AgentNativeHistoryError.identityConflict }
            sessions += page.items
            guard sessions.count <= 100_000 else { throw AgentNativeHistoryError.tooLarge }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw AgentNativeHistoryError.invalidCursor }
            guard cursors.count <= 2_000 else { throw AgentNativeHistoryError.tooLarge }
        } while cursor != nil
        try Task.checkCancellation()
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        return try store.discoverAgentNativeSessions(sessions)
    }
}

extension AgentSessionManager {
    /// A composer can accept input while a passive refresh owns the chat.
    /// Resume only after its atomic publication (or propagate its failure).
    public func waitForNativeHistory(chatID: UUID) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        if refreshing.contains(chatID) {
            try await withCheckedThrowingContinuation { historyWaiters[chatID, default: []].append($0) }
        }
        try Task.checkCancellation()
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
    }

    /// Refresh all bound providers, even when a different provider is selected.
    /// No process run or prompt is started. Per-chat reservation prevents a Send
    /// or settings change from racing a multi-page observation.
    public func refreshNativeHistory(chatID: UUID) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard let store = persistence as? any AgentHistoryPersistence else { return }
        guard !refreshing.contains(chatID), live[chatID]?.inputID == nil,
              live[chatID]?.followups.isEmpty != false, live[chatID]?.sendingFollowup != true,
              live[chatID]?.stopping != true else { throw AgentSessionManagerError.chatBusy }
        refreshing.insert(chatID)
        let token = UUID()
        historyTokens[chatID] = token
        var failure: (any Error)?
        defer {
            refreshing.remove(chatID); historyTokens.removeValue(forKey: chatID)
            for waiter in historyWaiters.removeValue(forKey: chatID) ?? [] {
                if let failure { waiter.resume(throwing: failure) }
                else { waiter.resume() }
            }
        }
        do { try await refreshNativeHistory(chatID: chatID, store: store, token: token) }
        catch { failure = error; throw error }
    }

    private func refreshNativeHistory(chatID: UUID, store: any AgentHistoryPersistence, token: UUID) async throws {
        let previous = try persistence.agentEntries(chatID: chatID)
        var observations: [(AgentChatSession, [AgentTranscriptEntry])] = []
        for session in try persistence.agentSessions(chatID: chatID) where session.provider != .local && session.sessionID != nil {
            let reader = try scopedBackend(session)
            // A complete second observation detects changes after the final
            // page, including single-page reads. This is no native-client lock.
            let entries = try await readNativeHistory(session: session, reader: reader)
            guard !closing, historyTokens[chatID] == token else { throw AgentSessionManagerError.staleRun }
            let confirmation = try await readNativeHistory(session: session, reader: reader)
            guard entries.map(Self.historyEvidence) == confirmation.map(Self.historyEvidence) else { throw AgentNativeHistoryError.staleCursor }
            try Task.checkCancellation()
            guard !closing, historyTokens[chatID] == token else { throw AgentSessionManagerError.staleRun }
            observations.append((session, entries))
        }
        // Read all providers before publishing any of them. A failed read must
        // not leave half of a cross-provider catch-up in the visible transcript.
        try store.reconcileAgentHistories(observations)
        let entries = try persistence.agentEntries(chatID: chatID)
        // An idle CLI still holds its old in-memory context. When native
        // history changed externally, the next Send must resume afresh.
        func contents(_ values: [AgentTranscriptEntry]) -> [String] {
            values.map { JSONValue.array([.string($0.id.uuidString), .string($0.kind), .string($0.text)]).jsonString }
        }
        if contents(previous) != contents(entries), let slot = live.removeValue(forKey: chatID) {
            slot.reader?.cancel(); slot.idle?.cancel()
            if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
        }
        guard !closing, historyTokens[chatID] == token else { throw AgentSessionManagerError.staleRun }
        states[chatID]?.entries = entries
        publish(chatID)
    }

    /// Kept for callers that need a read-only preview rather than publication.
    public func nativeHistoryPreview(chatID: UUID, provider: AgentProvider) async throws -> [AgentTranscriptEntry] {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard provider != .local else { throw AgentFailure.unsupported }
        guard let session = try persistence.agentSession(chatID: chatID, provider: provider), session.sessionID != nil else { return [] }
        return try await readNativeHistory(session: session, reader: scopedBackend(session))
    }
    private static func historyEvidence(_ entry: AgentTranscriptEntry) -> String {
        JSONValue.array([.string(entry.nativeMessageID ?? ""), .string(entry.kind), .string(entry.text), .string(entry.payloadJSON ?? "")]).jsonString
    }
    private func readNativeHistory(session: AgentChatSession, reader: any AgentBackend) async throws -> [AgentTranscriptEntry] {
        guard let nativeID = session.sessionID else { return [] }
        var entries: [AgentTranscriptEntry] = [], cursor: String?, cursors = Set<String>(), seen = Set<String>(), bytes = 0
        repeat {
            try Task.checkCancellation()
            let page = try await reader.readHistory(session: nativeID, cursor: cursor)
            for event in page.items {
                guard event.scope.session == nativeID else { throw AgentNativeHistoryError.identityConflict }
                if case .message(let id, let role, let text) = event.kind {
                    let canonicalID = nativeID.canonicalMessageID(id, turnID: event.scope.turnID)
                    guard !id.isEmpty, seen.insert(canonicalID).inserted, ["user", "assistant"].contains(role) else { throw AgentNativeHistoryError.identityConflict }
                    bytes += text.utf8.count
                    let payload = JSONValue.object(["nativeHistory": .object([
                        "turnID": event.scope.turnID.map(JSONValue.string) ?? .null,
                        "itemID": .string(id),
                        "completed": .bool(page.completedItemIDs.contains(canonicalID))
                    ])]).jsonString
                    entries.append(.init(chatID: session.chatID, provider: session.provider, kind: role, text: text,
                                         payloadJSON: payload, sessionID: session.id, nativeMessageID: canonicalID, position: entries.count))
                }
            }
            guard entries.count <= 100_000, bytes <= 32 * 1024 * 1024 else { throw AgentNativeHistoryError.tooLarge }
            cursor = page.nextCursor
            if let cursor, !cursors.insert(cursor).inserted { throw AgentNativeHistoryError.invalidCursor }
            guard cursors.count <= 2_000 else { throw AgentNativeHistoryError.tooLarge }
        } while cursor != nil
        try Task.checkCancellation()
        return entries
    }
}

extension AgentSessionManager {
    private var wakeStore: (any AgentWakePersistence)? { persistence as? any AgentWakePersistence }

    private func autonomousSession(chatID: UUID) throws -> AgentChatSession {
        let sessions = try persistence.agentSessions(chatID: chatID)
        let latest = try persistence.latestAgentTurn(chatID: chatID)
        guard let session = live[chatID]?.session ?? sessions.first(where: { $0.id == latest?.sessionID }) ?? sessions.first else {
            throw AgentSessionManagerError.missingSession
        }
        return session
    }
    func autonomousTurnDirectory(chatID: UUID) throws -> URL {
        URL(fileURLWithPath: try autonomousSession(chatID: chatID).cwd, isDirectory: true)
    }
    func canStartAutonomousTurn(chatID: UUID) -> Bool {
        !closing && !refreshing.contains(chatID) && live[chatID]?.isRunning != true
            && states[chatID]?.pendingCards.isEmpty != false
            && live.values.filter(\.isRunning).count < Self.maximumRunningChats
    }

    /// App-authored turns use the ordinary approval path without a composer row.
    public func startAutonomousTurn(chatID: UUID, reason: AgentAutonomousReason, prompt: String) async throws {
        try await startAutonomousTurn(session: autonomousSession(chatID: chatID), reason: reason, input: .init(text: prompt))
    }
    func startAutonomousTurn(chatID: UUID, reason: AgentAutonomousReason, prompt: String, directory: URL,
                             claimDelivery: @escaping @Sendable (UUID) async throws -> Void) async throws {
        let session = try autonomousSession(chatID: chatID)
        guard URL(fileURLWithPath: session.cwd, isDirectory: true).standardizedFileURL == directory.standardizedFileURL else {
            throw AgentSessionManagerError.staleRun
        }
        try await startAutonomousTurn(session: session, reason: reason, input: .init(text: prompt), claimDelivery: claimDelivery)
    }
    private func startAutonomousTurn(session: AgentChatSession, reason: AgentAutonomousReason, input: AgentInput,
                                     claimDelivery: (@Sendable (UUID) async throws -> Void)? = nil) async throws {
        guard live[session.chatID]?.isRunning != true, states[session.chatID]?.pendingCards.isEmpty != false else {
            throw AgentSessionManagerError.chatBusy
        }
        guard try persistence.agentSessions(chatID: session.chatID).contains(session) else {
            throw AgentSessionManagerError.missingSession
        }
        try await deliver(chatID: session.chatID, provider: session.provider, input: input, retry: false,
                          autonomousReason: reason, autonomousSession: session, claimDelivery: claimDelivery)
    }
    public func pendingWakes(chatID: UUID) throws -> [AgentPendingWake] {
        try wakeStore?.pendingAgentWakes(chatID: chatID) ?? []
    }
    public func cancelWake(id: UUID) throws {
        guard let wakeStore else { throw AgentFailure.invalidTransition }
        try wakeStore.cancelAppOwnedAgentWake(id: id)
    }
    /// Serializes ticks across launch, wake and polling; the store claim also
    /// protects against independent scheduler callers. Busy chats retain due work.
    public func runDueWakeups(now: Date = .now, permitted: Bool) async throws {
        guard permitted, !closing, !wakeTickRunning, let wakeStore else { return }
        wakeTickRunning = true
        defer { wakeTickRunning = false }
        var firstFailure: (any Error)?
        for pending in try wakeStore.pendingAgentWakes(chatID: nil) {
            guard !closing, !Task.isCancelled else { return }
            guard pending.survivesTransport, pending.isAppOwned(at: now),
                  pending.fireAt.map({ $0 <= now }) == true, live[pending.chatID]?.isRunning != true else { continue }
            do { try persistence.requireAgentChatAvailable(chatID: pending.chatID) }
            catch AgentSessionManagerError.chatUnavailable { continue }
            guard let session = try persistence.agentSessions(chatID: pending.chatID).first(where: { $0.id == pending.sessionID }) else { continue }
            // Retire an overdue native owner before injecting a replacement:
            // its still-live timer must never race the catch-up input.
            if let slot = live[pending.chatID], slot.token == pending.transportID {
                live.removeValue(forKey: pending.chatID); slot.idle?.cancel(); slot.reader?.cancel()
                if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
                try wakeStore.releaseAgentWakeTransport(slot.token)
            }
            guard !Task.isCancelled else { return }
            guard let wake = try wakeStore.claimAgentWake(id: pending.id, now: now) else { continue }
            let input = AgentInput(id: wake.claimedTurnID ?? UUID(), text: wake.scheduledPrompt(at: now))
            do {
                try await startAutonomousTurn(session: session, reason: wake.kind == .cron ? .scheduled : .wakeup, input: input)
                try wakeStore.finishAgentWake(id: wake.id, now: max(now, .now))
            } catch {
                // Retry only when delivery provably never crossed the barrier.
                // Unknown delivery remains claimed until startup consumes it.
                if try persistence.agentTurn(id: input.id)?.delivery == .prepared || persistence.agentTurn(id: input.id) == nil {
                    try wakeStore.releaseAgentWakeClaim(id: wake.id)
                }
                // One unavailable chat must not starve the rest of this batch.
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
    }
    private func nextOwnedFire(chatID: UUID, token: UUID) -> Date {
        let owned = (try? wakeStore?.pendingAgentWakes(chatID: chatID)) ?? []
        // Slots without timers are cheapest; undated background work is last.
        let items = owned.filter { $0.transportID == token }
        if items.isEmpty { return .distantFuture }
        // Background tasks and monitors die with the process: evict those slots last.
        if items.contains(where: { !$0.survivesTransport }) { return .distantPast }
        return items.compactMap(\.fireAt).min() ?? .distantFuture
    }
    private func observeWake(_ event: AgentEvent, chatID: UUID, slot: Live) throws {
        guard slot.session.provider == .claude, let wakeStore else { return }
        if case .unknown("backgroundTaskFinished", let payload) = event.kind,
           let taskID = payload.stringValue {
            for wake in try wakeStore.pendingAgentWakes(chatID: chatID)
            where wake.transportID == slot.token && wake.nativeToolID == taskID && !wake.survivesTransport {
                try wakeStore.deleteAgentWake(id: wake.id)
            }
            // A task notification need not start an assistant turn. Restart the
            // idle deadline that was held by the now-finished background work.
            if !slot.isRunning { armIdle(chatID, token: slot.token) }
        }
        guard let item = event.scope.itemID else { return }
        switch event.kind {
        case .toolStarted(let tool):
            // Full canonical arguments replace partial streaming arguments.
            guard ["ScheduleWakeup", "CronCreate", "CronDelete", "Bash", "Monitor", "TaskStop"].contains(tool.name) else { return }
            live[chatID]?.wakeTools[item] = tool
        case .toolFinished(let output, let isError):
            guard let tool = live[chatID]?.wakeTools.removeValue(forKey: item), !isError else { return }
            let input = tool.input
            let now = Date.now
            let items = try wakeStore.pendingAgentWakes(chatID: chatID)
            if tool.name == "CronDelete" || tool.name == "TaskStop" {
                guard let id = input["id"]?.stringValue ?? input["task_id"]?.stringValue ?? input["taskId"]?.stringValue ?? input["job_id"]?.stringValue ?? input["shell_id"]?.stringValue else { return }
                for wake in items where wake.nativeToolID == id && wake.sessionID == slot.session.id {
                    try wakeStore.deleteAgentWake(id: wake.id)
                }
                return
            }
            let kind: AgentWakeKind
            var fireAt: Date?, cron: String?
            switch tool.name {
            case "ScheduleWakeup":
                guard let delay = input["delaySeconds"]?.doubleValue, delay.isFinite, delay >= 0, delay <= 315_576_000 else { return }
                kind = .wakeup; fireAt = now.addingTimeInterval(delay)
            case "CronCreate":
                kind = .cron; cron = input["cron"]?.stringValue ?? input["schedule"]?.stringValue
                guard let cronSpec = cron, let next = AgentWakeCron.next(cronSpec, after: now) else { return }
                fireAt = next
            case "Bash" where input["run_in_background"]?.boolValue == true: kind = .backgroundTask
            case "Monitor": kind = .monitor
            default: return
            }
            let nativeID = Self.wakeNativeID(output) ?? item
            guard !items.contains(where: { $0.sessionID == slot.session.id && $0.nativeToolID == nativeID }) else { return }
            var wake = AgentPendingWake(chatID: chatID, sessionID: slot.session.id, kind: kind, fireAt: fireAt,
                cronSpec: cron, prompt: input["prompt"]?.stringValue, nativeToolID: nativeID, transportID: slot.token, now: now)
            wake.recurring = input["recurring"]?.boolValue ?? true
            try wakeStore.saveAgentWake(wake)
        default: break
        }
    }
    private static func wakeNativeID(_ output: JSONValue) -> String? {
        for key in ["id", "task_id", "taskId", "job_id", "jobId"] {
            if let value = output[key]?.stringValue { return String(value.prefix(512)) }
        }
        if let text = output.stringValue {
            if let json = JSONValue.parse(text), json != output, let id = wakeNativeID(json) { return id }
            // Native tool results also use small text envelopes and XML tags.
            for pattern in [#"<(?:task-id|task_id|id)>([^<\s]+)</"#,
                            #"(?i)(?:task[_ ]?id|job[_ ]?id|\bid)\s*[:=]\s*[\"']?([A-Za-z0-9_-]+)"#] {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    let match = String(text[range])
                    let regex = try? NSRegularExpression(pattern: pattern)
                    if let result = regex?.firstMatch(in: match, range: NSRange(match.startIndex..., in: match)),
                       let capture = Range(result.range(at: 1), in: match) { return String(match[capture].prefix(512)) }
                }
            }
        }
        for child in output.arrayValue ?? [] {
            if let id = wakeNativeID(child["text"] ?? child) { return id }
        }
        return nil
    }
}
