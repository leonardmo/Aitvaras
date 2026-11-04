import Foundation

public enum AgentSessionManagerError: Error, Sendable, Equatable {
    case chatBusy, runningChatLimit, shuttingDown, missingSession, staleRun, persistence
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
    }
    private let persistence: any AgentSessionPersistence
    private let backend: BackendFactory
    private let audit: AgentActionCoordinator.Audit
    private let idleTimeout: Duration
    private var live: [UUID: Live] = [:]
    private var states: [UUID: ChatState] = [:]
    private var subscribers: [UUID: [UUID: AsyncStream<ChatState>.Continuation]] = [:]
    private var closing = false

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
        subscribers.values.forEach { $0.values.forEach { $0.finish() } }
    }

    public func state(chatID: UUID) throws -> ChatState {
        if let state = states[chatID] { return state }
        var value = ChatState(chatID: chatID, entries: try persistence.agentEntries(chatID: chatID))
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
    private func detach(_ chat: UUID, key: UUID) { subscribers[chat]?.removeValue(forKey: key) }
    private func publish(_ chat: UUID) {
        guard let state = states[chat] else { return }
        subscribers[chat]?.values.forEach { $0.yield(state) }
    }

    /// Saving settings starts no process. A subsequent Send resumes with them.
    public func configure(_ session: AgentChatSession) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard live[session.chatID]?.inputID == nil else { throw AgentSessionManagerError.chatBusy }
        try persistence.saveAgentSession(session)
        if let slot = live.removeValue(forKey: session.chatID) {
            slot.reader?.cancel(); slot.idle?.cancel()
            if let run = slot.coordinator { await Self.close(run, timeout: .seconds(2)) }
        }
    }

    public func send(chatID: UUID, provider: AgentProvider, input: AgentInput) async throws {
        try await deliver(chatID: chatID, provider: provider, input: input, retry: false)
    }
    /// Caller explicitly chooses retry. Never called during startup or reconnect.
    public func resendPrepared(turnID: UUID) async throws {
        guard let turn = try persistence.agentTurn(id: turnID),
              let session = try persistence.agentSession(chatID: turn.chatID,
                  provider: try providerForTurn(turn)), session.id == turn.sessionID else {
            throw AgentSessionManagerError.missingSession
        }
        try await deliver(chatID: turn.chatID, provider: session.provider,
                          input: .init(id: turn.id, text: turn.prompt), retry: true)
    }
    private func providerForTurn(_ turn: AgentJournalTurn) throws -> AgentProvider {
        for provider in [AgentProvider.claude, .codex, .local] {
            if try persistence.agentSession(chatID: turn.chatID, provider: provider)?.id == turn.sessionID { return provider }
        }
        throw AgentSessionManagerError.missingSession
    }

    private func deliver(chatID: UUID, provider: AgentProvider, input: AgentInput, retry: Bool) async throws {
        guard !closing else { throw AgentSessionManagerError.shuttingDown }
        guard live[chatID]?.inputID == nil else { throw AgentSessionManagerError.chatBusy }
        guard let session = try persistence.agentSession(chatID: chatID, provider: provider) else {
            throw AgentSessionManagerError.missingSession
        }
        _ = try state(chatID: chatID)
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
            else { try persistence.prepareAgentTurn(.init(input: input, chatID: chatID, sessionID: session.id)) }
        } catch { live[chatID] = old; if let old { armIdle(chatID, token: old.token) }; throw error }
        states[chatID]?.begin(input, session: session, outputID: UUID())
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
            try await coordinator.send(input) { try persistence.advanceAgentDelivery(id: input.id, to: .deliveryUnknown) }
        } catch {
            await failedSend(chatID, token: token, inputID: input.id, error: error)
            throw error
        }
    }

    private func persistEntries(_ chat: UUID, previous: [AgentTranscriptEntry] = []) throws {
        guard var value = states[chat] else { return }
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        value.entries = try value.entries.map { old[$0.id] == $0 ? $0 : try persistence.saveAgentEntry($0) }
        states[chat] = value
    }
    private func receive(_ event: AgentEvent, chatID: UUID, token: UUID) async {
        guard let slot = live[chatID], slot.token == token, slot.coordinator?.id == event.scope.runID else { return }
        // Lifecycle events can precede Send. Turn events must match local input.
        if let input = event.scope.inputID, input != slot.inputID { return }
        do {
            switch event.kind {
            case .sessionStarted(let native):
                guard native.provider == slot.session.provider else { throw AgentFailure.invalidRequest }
                var session = slot.session; session.sessionID = native
                try persistence.saveAgentSession(session)
                live[chatID]?.session = session
            case .delivery(let delivery):
                guard let input = slot.inputID, event.scope.inputID == input else { return }
                try persistence.advanceAgentDelivery(id: input, to: delivery)
            default: break
            }
            let previous = states[chatID]?.entries ?? []
            states[chatID]?.reduce(event, newEntryID: UUID())
            if states[chatID]?.entries != previous { try persistEntries(chatID, previous: previous) }
            if case .textDelta = event.kind, let input = slot.inputID {
                let turn = try persistence.agentTurn(id: input)
                try persistence.saveAgentPartial(id: input, text: (turn?.partialOutput ?? "") + textDelta(event))
            }
            if case .turnEnded(let outcome) = event.kind, let input = slot.inputID, event.scope.inputID == input {
                try persistence.finishAgentTurn(id: input, state: Self.journalState(outcome))
                live[chatID]?.inputID = nil
                armIdle(chatID, token: token)
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
        if let input = slot.inputID {
            do { try persistence.finishAgentTurn(id: input, state: .interrupted) }
            catch { states[chat]?.end(.failed(.unknown)) }
            states[chat]?.end(.failed(failure))
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
        guard let slot = live[chatID], slot.inputID != nil else { return }
        if let coordinator = slot.coordinator { try await coordinator.interrupt() }
        else {
            live.removeValue(forKey: chatID)
            if let input = slot.inputID { try persistence.finishAgentTurn(id: input, state: .interrupted) }
            states[chatID]?.end(.interrupted); publish(chatID)
        }
    }
    public func respond(chatID: UUID, to request: AgentRequest, with response: AgentResponse) async throws {
        guard let slot = live[chatID], let run = slot.coordinator else { throw AgentSessionManagerError.staleRun }
        try await run.respond(to: request, with: response)
        let pending = await run.pendingRequests()
        guard live[chatID]?.token == slot.token else { return }
        states[chatID]?.pendingCards = pending; publish(chatID)
    }

    /// Detach generations first. Bounded cleanup never poisons the owner: if
    /// application quit is cancelled, the next Send creates a fresh live run.
    public func shutdown(timeout: Duration = .seconds(2)) async throws {
        guard !closing else { return }
        closing = true
        let slots = live; live.removeAll()
        var storageFailed = false
        for (chat, slot) in slots {
            slot.reader?.cancel(); slot.idle?.cancel()
            if let input = slot.inputID {
                do { try persistence.finishAgentTurn(id: input, state: .interrupted) }
                catch { storageFailed = true }
                states[chat]?.end(.interrupted)
            }
            states[chat]?.pendingCards = []; publish(chat)
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
