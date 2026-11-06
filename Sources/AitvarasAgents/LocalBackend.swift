import Foundation

/// M2 text-only adapter. The application injects today's isolated local chat
/// path; this module has no dependency on engines, connectors or shared memory.
public actor LocalBackend: AgentBackend {
    public typealias Reply = @Sendable (AgentSessionConfiguration, AgentInput) async throws -> AsyncThrowingStream<String, Error>
    private let reply: Reply
    private let availableModels: [AgentModel]

    public init(models: [AgentModel] = [.init(id: "local", name: "Local")], reply: @escaping Reply) {
        self.availableModels = models; self.reply = reply
    }
    public func status() -> AgentStatus { .init(installed: true, authentication: .local, capabilities: []) }
    public func models() -> [AgentModel] { availableModels }
    public func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) {}
    public func start(_ configuration: AgentSessionConfiguration) throws -> any AgentRun {
        if let resume = configuration.resume, resume.provider != .local { throw AgentFailure.invalidRequest }
        return LocalRun(configuration: configuration, reply: reply)
    }
    public func listSessions(folder: URL, cursor: String?) -> AgentPage<AgentSessionSummary> { .init(items: []) }
    public func readHistory(session: AgentSessionID, cursor: String?) -> AgentPage<AgentEvent> { .init(items: []) }
}

private actor LocalRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let configuration: AgentSessionConfiguration
    private let reply: LocalBackend.Reply
    private var worker: Task<Void, Never>?
    private var inputID: UUID?
    private var closed = false

    init(configuration: AgentSessionConfiguration, reply: @escaping LocalBackend.Reply) {
        self.configuration = configuration; self.reply = reply
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, inputID == nil else { throw AgentFailure.invalidTransition }
        try input.validateComposerInput(provider: .local)
        inputID = input.id
        do { try await willDeliver() }
        catch { if inputID == input.id { inputID = nil }; throw error }
        guard !closed, inputID == input.id else { throw AgentFailure.invalidTransition }
        emit(.delivery(.acknowledged), input: input.id)
        worker = Task {
            do {
                let stream = try await reply(configuration, input)
                for try await text in stream {
                    try Task.checkCancellation()
                    guard inputID == input.id, !closed else { return }
                    emit(.textDelta(text), input: input.id)
                }
                try Task.checkCancellation()
                finish(.completed, input: input.id)
            } catch is CancellationError { finish(.interrupted, input: input.id) }
            catch { finish(.failed((error as? AgentFailure) ?? .unknown), input: input.id) }
        }
    }
    private func emit(_ kind: AgentEvent.Kind, input: UUID) {
        if case .dropped = continuation.yield(.init(scope: .init(runID: id, inputID: input), kind: kind)) {
            closed = true; worker?.cancel(); continuation.finish(throwing: AgentFailure.invalidTransition)
        }
    }
    private func finish(_ outcome: AgentTurnOutcome, input: UUID) {
        guard inputID == input else { return }
        emit(.turnEnded(outcome), input: input); inputID = nil; worker = nil
    }
    func respond(to request: AgentRequest, with response: AgentResponse) throws { throw AgentFailure.invalidRequest }
    func setMode(_ mode: AgentMode) {} // No tool permissions in this adapter.
    func interrupt() {
        worker?.cancel()
        if let inputID { finish(.interrupted, input: inputID) }
    }
    func shutdown() { interrupt(); closed = true; continuation.finish() }
}
