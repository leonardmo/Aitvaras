import Foundation

public enum AgentSessionManagerError: Error, Sendable, Equatable {
    case chatBusy, chatUnavailable, runningChatLimit, shuttingDown, missingSession, staleRun, persistence
}

/// Application lifetime owner. Views only subscribe; detaching never stops a run.
public actor AgentSessionManager {
    public typealias BackendFactory = @Sendable (AgentProvider) throws -> any AgentBackend
    private struct Live {
        let token: UUID
        var session: AgentChatSession
        var coordinator: AgentActionCoordinator?
        var reader: Task<Void, Never>?
        var idle: Task<Void, Never>?
        var inputID: UUID?
        var followups: [AgentInput] = []
        var sendingFollowup = false
        var stopping = false
    }
    private let persistence: any AgentSessionPersistence
    private let backend: BackendFactory
    private let audit: AgentActionCoordinator.Audit
    private let idleTimeout: Duration
    private var live: [UUID: Live] = [:]
    private var states: [UUID: ChatState] = [:]
    private var subscribers: [UUID: [UUID: AsyncStream<ChatState>.Continuation]] = [:]
    private var closing = false
    private var refreshing = Set<UUID>()
    private var historyTokens: [UUID: UUID] = [:]
    private var approvalSubscribers: [UUID: AsyncStream<[AgentApprovalSuggestion]>.Continuation] = [:]

    /// Startup recovery is synchronous and must finish before any backend starts.
    public init(persistence: any AgentSessionPersistence, idleTimeout: Duration = .seconds(600),
                backend: @escaping BackendFactory, audit: @escaping AgentActionCoordinator.Audit) throws {
        self.persistence = persistence; self.idleTimeout = idleTimeout; self.backend = backend; self.audit = audit
        try persistence.recoverAgentTurns()
    }
    deinit {
        for slot in live.values {
            slot.reader?.cancel(); slot.idle?.cancel()
            if let coordinator = slot.coordinator { Task { try? await coordinator.shutdown() } }
        }
        approvalSubscribers.values.forEach { $0.finish() }
        subscribers.values.forEach { $0.values.forEach { $0.finish() } }
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
            switch turn.state {
            case .interrupted: value.end(.interrupted)
            case .completed: value.end(.completed)
            case .failed: value.end(.failed(.unknown))
            case .running: break
            }
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
        }
    }

    public func send(chatID: UUID, provider: AgentProvider, input: AgentInput) async throws {
        if live[chatID]?.inputID != nil {
            try await followup(chatID: chatID, provider: provider, input: input)
        } else {
            try await deliver(chatID: chatID, provider: provider, input: input, retry: false)
        }
    }
    private func followup(chatID: UUID, provider: AgentProvider, input: AgentInput) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.requireAgentChatAvailable(chatID: chatID)
        guard let slot = live[chatID], slot.session.provider == provider,
              let run = slot.coordinator, !slot.stopping, !slot.sendingFollowup,
              provider != .local, slot.followups.count < 32,
              try persistence.agentTurn(id: input.id) == nil else { throw AgentSessionManagerError.chatBusy }
        // Reserve before yielding, and commit this input separately from the
        // output owner. Failed/uncertain follow-ups are never silently resent.
        live[chatID]?.sendingFollowup = true
        defer { if live[chatID]?.token == slot.token { live[chatID]?.sendingFollowup = false } }
        try persistence.prepareAgentTurn(.init(input: input, chatID: chatID, sessionID: slot.session.id,
            parentInputID: slot.inputID))
        live[chatID]?.followups.append(input)
        states[chatID]?.appendFollowup(input, session: slot.session)
        do {
            try persistEntries(chatID); publish(chatID)
            let persistence = persistence
            try await run.followup(input) { try persistence.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
        } catch {
            if let current = live[chatID], current.token == slot.token {
                if try persistence.agentTurn(id: input.id)?.delivery == .prepared {
                    // A busy provider or failed barrier has not taken this
                    // input. Keep the active turn and its approval cards alive.
                    try persistence.finishAgentTurn(id: input.id, state: .failed)
                    live[chatID]?.followups.removeAll { $0.id == input.id }
                    states[chatID]?.markFollowup(input.id, status: "notSent")
                    try persistEntries(chatID); publish(chatID)
                } else {
                    try await retire(chatID, slot: current, outcome: .failed((error as? AgentFailure) ?? .unknown))
                }
            }
            throw error
        }
    }
    /// Caller explicitly chooses retry. Never called during startup or reconnect.
    public func resendPrepared(turnID: UUID) async throws {
        guard let turn = try persistence.agentTurn(id: turnID),
              let session = try persistence.agentSession(chatID: turn.chatID,
                  provider: try providerForTurn(turn)), session.id == turn.sessionID else {
            throw AgentSessionManagerError.missingSession
        }
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

    private func deliver(chatID: UUID, provider: AgentProvider, input: AgentInput, retry: Bool) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        try persistence.requireAgentChatAvailable(chatID: chatID)
        guard !refreshing.contains(chatID) else { throw AgentSessionManagerError.chatBusy }
        if !retry, live[chatID]?.inputID == nil {
            try await refreshNativeHistory(chatID: chatID)
            try persistence.requireAgentChatAvailable(chatID: chatID)
        }
        guard live[chatID]?.inputID == nil, live[chatID]?.followups.isEmpty != false,
              live[chatID]?.sendingFollowup != true, live[chatID]?.stopping != true else {
            throw AgentSessionManagerError.chatBusy
        }
        guard let session = try persistence.agentSession(chatID: chatID, provider: provider) else {
            throw AgentSessionManagerError.missingSession
        }
        _ = try state(chatID: chatID)
        let context = try retry ? persistence.agentHandover(turnID: input.id) : persistence.agentContext(session: session)
        let wireText = try retry ? persistence.agentTurn(id: input.id)?.prompt : nil
        let wireInput = AgentInput(id: input.id, text: wireText ?? context?.wire(message: input.text) ?? input.text,
                                  attachments: input.attachments, mentions: input.mentions, command: input.command)
        if live[chatID] == nil, live.count >= 3 {
            states[chatID]?.end(.failed(.invalidTransition)); publish(chatID)
            throw AgentSessionManagerError.runningChatLimit
        }
        // Reserve this chat and capacity before any await, including startup.
        let old = live[chatID]
        let token = old?.session == session ? old!.token : UUID()
        old?.idle?.cancel()
        let reusable = old?.session == session ? old?.coordinator : nil
        live[chatID] = Live(token: token, session: session, coordinator: reusable, inputID: input.id)
        do {
            if retry { _ = try persistence.claimAgentResend(id: input.id) }
            else { try persistence.prepareAgentTurn(.init(input: wireInput, chatID: chatID, sessionID: session.id), context: context) }
        } catch { live[chatID] = old; if let old { armIdle(chatID, token: old.token) }; throw error }
        states[chatID]?.begin(input, session: session, outputID: UUID(), context: context)
        do {
            try persistEntries(chatID)
            publish(chatID)
            let coordinator: AgentActionCoordinator
            if let reusable {
                coordinator = reusable
                live[chatID]?.reader = old?.reader
            } else {
                old?.reader?.cancel()
                if let run = old?.coordinator { await Self.close(run, timeout: .seconds(2)) }
                let raw = try await backend(provider).start(session.configuration)
                guard live[chatID]?.token == token, !closing else {
                    await Self.close(raw, timeout: .seconds(2)); throw AgentSessionManagerError.staleRun
                }
                coordinator = AgentActionCoordinator(run: raw, mode: session.mode,
                    provenance: .init(chatID: chatID), audit: audit)
                live[chatID]?.coordinator = coordinator
                live[chatID]?.reader = Task { [weak self] in
                    do {
                        for try await event in coordinator.events {
                            await self?.receive(event, chatID: chatID, token: token)
                        }
                        await self?.exited(chatID, token: token, failure: .crashed(exitCode: nil))
                    } catch { await self?.exited(chatID, token: token, failure: (error as? AgentFailure) ?? .unknown) }
                }
            }
            guard live[chatID]?.token == token, live[chatID]?.inputID == input.id else {
                throw AgentSessionManagerError.staleRun
            }
            let persistence = persistence
            try await coordinator.send(wireInput) { try persistence.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
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
            switch event.kind {
            case .modeChanged(let mode):
                var session = slot.session; session.mode = mode
                try persistence.saveAgentSession(session)
                live[chatID]?.session = session
            case .sessionStarted(let native):
                guard native.provider == slot.session.provider else { throw AgentFailure.invalidRequest }
                var session = slot.session; session.sessionID = native
                try persistence.saveAgentSession(session)
                live[chatID]?.session = session
            case .message(let nativeID, "user", _) where event.scope.inputID != slot.inputID:
                if let index = states[chatID]?.entries.firstIndex(where: { $0.id == event.scope.inputID }) {
                    states[chatID]?.entries[index].nativeMessageID = nativeID
                    try persistEntries(chatID)
                }
            case .inputActivated:
                guard let id = event.scope.inputID, let input = slot.followups.first(where: { $0.id == id }) else { return }
                live[chatID]?.inputID = id
                live[chatID]?.followups.removeAll { $0.id == id }
                states[chatID]?.begin(input, session: slot.session, outputID: UUID())
                states[chatID]?.markFollowup(id, status: "sent")
            case .delivery(let delivery):
                guard let input = event.scope.inputID else { return }
                try persistence.advanceAgentDelivery(id: input, to: delivery)
                if delivery == .acknowledged, slot.session.provider == .codex {
                    states[chatID]?.markFollowup(input, status: "steered")
                    if live[chatID]?.inputID == nil, let outcome = states[chatID]?.outcome {
                        try persistence.finishAgentTurn(id: input, state: Self.journalState(outcome))
                    }
                }
            default: break
            }
            let previous = states[chatID]?.entries ?? []
            switch event.kind {
            case .inputActivated, .delivery: try persistEntries(chatID)
            default: break
            }
            states[chatID]?.reduce(event, newEntryID: UUID())
            if states[chatID]?.entries != previous { try persistEntries(chatID, previous: previous) }
            if case .textDelta = event.kind, let input = slot.inputID {
                let turn = try persistence.agentTurn(id: input)
                try persistence.saveAgentPartial(id: input, text: (turn?.partialOutput ?? "") + textDelta(event))
            }
            if case .turnEnded(let outcome) = event.kind, let input = slot.inputID, event.scope.inputID == input {
                let outcome = slot.stopping ? AgentTurnOutcome.interrupted : outcome
                if slot.stopping { states[chatID]?.end(.interrupted) }
                try persistence.finishAgentTurn(id: input, state: Self.journalState(outcome))
                live[chatID]?.inputID = nil
                if slot.session.provider == .codex {
                    for followup in slot.followups {
                        // A steer response can follow a fast turn/completed.
                        // Finish only after its RPC acknowledgement is handled.
                        if try persistence.agentTurn(id: followup.id)?.delivery == .acknowledged {
                            try persistence.finishAgentTurn(id: followup.id, state: Self.journalState(outcome))
                        }
                    }
                }
                if slot.session.provider == .claude, !slot.stopping, let next = slot.followups.first {
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
        } catch { await exited(chatID, token: token, failure: .unknown) }
    }
    private func textDelta(_ event: AgentEvent) -> String {
        if case .textDelta(let text) = event.kind { return text }; return ""
    }
    private static func journalState(_ outcome: AgentTurnOutcome) -> AgentJournalState {
        switch outcome { case .completed: .completed; case .interrupted: .interrupted; case .failed: .failed }
    }
    private func failedSend(_ chat: UUID, token: UUID, inputID: UUID, error: Error) async {
        guard live[chat]?.token == token, live[chat]?.inputID == inputID else { return }
        await exited(chat, token: token, failure: (error as? AgentFailure) ?? .unknown)
    }
    private func exited(_ chat: UUID, token: UUID, failure: AgentFailure) async {
        guard let slot = live[chat], slot.token == token else { return }
        live.removeValue(forKey: chat); slot.reader?.cancel(); slot.idle?.cancel()
        for followup in slot.followups {
            if (try? persistence.agentTurn(id: followup.id)?.state) == .running {
                try? persistence.finishAgentTurn(id: followup.id, state: .interrupted)
            }
            states[chat]?.markFollowup(followup.id, status: "interrupted")
        }
        if let input = slot.inputID {
            do { try persistence.finishAgentTurn(id: input, state: .interrupted) }
            catch { states[chat]?.end(.failed(.unknown)) }
            states[chat]?.end(slot.stopping ? .interrupted : .failed(failure))
        }
        states[chat]?.pendingCards = []; publish(chat)
        if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
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
        guard let slot = live[chat], slot.token == token, slot.inputID == nil else { return }
        live.removeValue(forKey: chat); slot.reader?.cancel()
        if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
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
        if current.inputID == nil, current.followups.isEmpty, !current.sendingFollowup {
            live[chatID]?.stopping = false
            states[chatID]?.end(.interrupted); publish(chatID)
        } else {
            try await retire(chatID, slot: current, outcome: .interrupted)
        }
    }
    private func retire(_ chat: UUID, slot: Live, outcome: AgentTurnOutcome) async throws {
        guard live[chat]?.token == slot.token else { return }
        live.removeValue(forKey: chat); slot.reader?.cancel(); slot.idle?.cancel()
        var storageFailed = false
        for id in [slot.inputID].compactMap({ $0 }) + slot.followups.map(\.id) {
            do {
                if try persistence.agentTurn(id: id)?.state == .running {
                    try persistence.finishAgentTurn(id: id, state: .interrupted)
                }
            } catch { storageFailed = true }
            states[chat]?.markFollowup(id, status: "interrupted")
        }
        states[chat]?.end(outcome)
        do { try persistEntries(chat) } catch { storageFailed = true }
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
        if storageFailed { throw AgentSessionManagerError.persistence }
    }
    public func respond(chatID: UUID, to request: AgentRequest, with response: AgentResponse) async throws {
        guard let slot = live[chatID], let run = slot.coordinator else { throw AgentSessionManagerError.staleRun }
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

    /// Detach generations first. Bounded cleanup never poisons the owner: if
    /// application quit is cancelled, the next Send creates a fresh live run.
    public func shutdown(timeout: Duration = .seconds(2)) async throws {
        guard !closing else { return }
        closing = true
        historyTokens.removeAll()
        let slots = live; live.removeAll()
        var storageFailed = false
        for (chat, slot) in slots {
            slot.reader?.cancel(); slot.idle?.cancel()
            for followup in slot.followups {
                do {
                    if try persistence.agentTurn(id: followup.id)?.state == .running {
                        try persistence.finishAgentTurn(id: followup.id, state: .interrupted)
                    }
                } catch { storageFailed = true }
                states[chat]?.markFollowup(followup.id, status: "interrupted")
            }
            if let input = slot.inputID {
                do { try persistence.finishAgentTurn(id: input, state: .interrupted) }
                catch { storageFailed = true }
                states[chat]?.end(.interrupted)
            }
            states[chat]?.pendingCards = []
            do { try persistEntries(chat) } catch { storageFailed = true }
            publish(chat)
        }
        // All closes share one deadline, including a misbehaving injected run.
        let runs = slots.values.compactMap(\.coordinator)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let cleanup = Task {
            await withTaskGroup(of: Void.self) { group in
                for run in runs { group.addTask { try? await run.shutdown() } }
            }
            continuation.yield(()); continuation.finish()
        }
        let timer = Task { try? await Task.sleep(for: timeout); continuation.yield(()); continuation.finish() }
        for await _ in stream { break }
        cleanup.cancel(); timer.cancel(); closing = false
        if storageFailed { throw AgentSessionManagerError.persistence }
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
    public func discoverNativeSessions(provider: AgentProvider) async throws -> [UUID] {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard provider != .local, let store = persistence as? any AgentNativeSessionPersistence else { throw AgentFailure.unsupported }
        let reader = try backend(provider)
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
        defer { refreshing.remove(chatID); historyTokens.removeValue(forKey: chatID) }
        let previous = try persistence.agentEntries(chatID: chatID)
        var observations: [(AgentChatSession, [AgentTranscriptEntry])] = []
        for provider in [AgentProvider.claude, .codex] {
            guard let session = try persistence.agentSession(chatID: chatID, provider: provider), session.sessionID != nil else { continue }
            let reader = try backend(provider)
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
        return try await readNativeHistory(session: session, reader: backend(provider))
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
