import Foundation
import AitvarasCore

/// The policy boundary around a provider run. Give callers this run instead of
/// the raw backend run, so even Claude hooks allowed by native rules are gated.
/// Codex enforces its sandbox itself; approvals are gated here and item events
/// are audited observations, never proof that an action has not yet run.
public actor AgentActionCoordinator: AgentRun {
    public typealias Audit = @Sendable (ActivityEvent) async throws -> Void

    public struct Provenance: Sendable {
        public let chatID: UUID
        public let causedBy: UUID?
        public let sourceID: String?
        public init(chatID: UUID, causedBy: UUID? = nil, sourceID: String? = nil) {
            self.chatID = chatID; self.causedBy = causedBy; self.sourceID = sourceID
        }
    }

    public nonisolated let id: UUID
    public nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let run: any AgentRun
    private let provenance: Provenance
    private let audit: Audit
    private let policy: AutonomyPolicy
    private var mode: AgentMode
    private var inputID: UUID?
    private var followups: Set<UUID> = []
    private var closed = false
    private var interrupting = false
    private var changingMode = false
    private var reader: Task<Void, Never>?
    private var seen: Set<AgentRequestID> = []
    /// Includes audit writes in progress, so shutdown can deny those too.
    private var unresolved: [AgentRequestID: AgentRequest] = [:]
    private var pending: [AgentRequestID: AgentRequest] = [:]
    private var pendingOrder: [AgentRequestID] = []

    /// The sink must durably save before returning. For Stores, pass
    /// `{ event in _ = try stores.record(event) }`; no schema changes required.
    /// Explicit user whitelist entries use `provider.<native tool name>`.
    public init(run: any AgentRun, mode: AgentMode, provenance: Provenance,
                policy: AutonomyPolicy = AutonomyPolicy(), audit: @escaping Audit) {
        self.run = run; id = run.id; self.mode = mode
        self.provenance = provenance; self.policy = policy; self.audit = audit
        (events, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(4096))
    }

    deinit { reader?.cancel(); continuation.finish() }

    public func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !changingMode, inputID == nil else { throw AgentFailure.invalidTransition }
        if reader == nil {
            reader = Task { [weak self, run] in
                do {
                    for try await event in run.events { await self?.receive(event) }
                    await self?.exited(nil)
                } catch { await self?.exited((error as? AgentFailure) ?? .unknown) }
            }
        }
        inputID = input.id; followups.removeAll(); interrupting = false
        do { try await run.send(input, willDeliver: willDeliver) }
        catch { if inputID == input.id { inputID = nil }; throw error }
    }

    public func followup(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard !closed, !interrupting, !changingMode, inputID != nil,
              inputID != input.id, followups.insert(input.id).inserted else { throw AgentFailure.invalidTransition }
        do { try await run.followup(input, willDeliver: willDeliver) }
        catch { followups.remove(input.id); throw error }
    }
    public func abort() async {
        closed = true; inputID = nil; followups.removeAll()
        reader?.cancel(); reader = nil
        // Dispose the transport before audit/reply cleanup, which may be stalled.
        await run.abort()
        await denyPending()
        continuation.finish()
    }

    /// A UI holds the full scoped request, not just a reusable native ID.
    public func pendingRequests() -> [AgentRequest] { pendingOrder.compactMap { pending[$0] } }

    public func respond(to request: AgentRequest, with response: AgentResponse) async throws {
        guard !interrupting, isCurrent(request), pending[request.id] == request else { throw AgentFailure.invalidRequest }
        let answer: AgentResponse
        switch (request.kind, response) {
        case (.permission, .allow(updatedInput: nil)), (.permissions, .allow(updatedInput: nil)),
             (.plan, .allow(updatedInput: nil)): answer = response
        case (.questions(let questions), .answers(let answers)):
            try AgentQuestionState.validate(answers, questions: questions)
            answer = response
        case (_, .deny):
            // Neither CLI has a question-denial payload. Unsupported closes it.
            if case .questions = request.kind { answer = .unsupported } else { answer = .deny }
        default: throw AgentFailure.invalidRequest
        }
        // Reserve before awaiting the audit sink: concurrent UI clicks cannot
        // both accept, and modified arguments cannot bypass classification.
        removePending(request.id)
        do {
            try await finish(request, response: answer, decision: response == .deny ? "denied" : "approved")
        } catch {
            await exited((error as? AgentFailure) ?? .unknown)
            throw error
        }
    }

    public func setMode(_ mode: AgentMode) async throws {
        guard !closed, !changingMode, inputID == nil else { throw AgentFailure.invalidTransition }
        changingMode = true
        defer { changingMode = false }
        try await run.setMode(mode)
        guard !closed else { throw AgentFailure.invalidTransition }
        self.mode = mode
    }

    public func interrupt() async throws {
        guard !closed, inputID != nil else { throw AgentFailure.invalidTransition }
        interrupting = true
        if pending.values.contains(where: { if case .plan = $0.kind { true } else { false } }) {
            // A Codex plan review is between native turns. Denying it first
            // would finish the local turn before Stop could interrupt it.
            try await run.interrupt()
            await denyPending()
            return
        }
        await denyPending()
        try await run.interrupt()
    }

    public func shutdown() async throws {
        guard !closed else { return }
        closed = true; inputID = nil
        await denyPending()
        reader?.cancel(); reader = nil
        continuation.finish()
        try await run.shutdown()
    }

    private func isCurrent(_ request: AgentRequest) -> Bool {
        !closed && request.scope.runID == id && inputID != nil && request.scope.inputID == inputID
    }

    private func receive(_ event: AgentEvent) async {
        guard !closed, event.scope.runID == id else { return }
        // Late callbacks from an earlier input on this same connection must not
        // clear or authorize the current turn.
        if case .inputActivated = event.kind {
            guard let input = event.scope.inputID, followups.remove(input) != nil, !interrupting else { return }
            inputID = input
        }
        if let input = event.scope.inputID, input != inputID {
            guard followups.contains(input) else { return }
            switch event.kind {
            case .delivery, .message(_, "user", _): break
            default: return
            }
        }
        do {
            switch event.kind {
            case .modeChanged(let mode): self.mode = mode
            case .request(let request):
                guard request.scope == event.scope else { throw AgentFailure.invalidRequest }
                try await handle(request)
            case .requestResolved(let id):
                if let request = unresolved.removeValue(forKey: id) {
                    removePending(id)
                    try await record(scope: request.scope, decision: "expired by provider", kind: .confirmationDenied, request: request)
                }
            case .toolStarted, .toolFinished, .fileChanged:
                guard event.scope.inputID == inputID, inputID != nil else { throw AgentFailure.invalidRequest }
                // Never persist raw arguments, command output, paths or diffs:
                // they may contain secrets. Scope metadata retains provenance.
                try await record(scope: event.scope, decision: observation(event.kind))
            case .turnEnded:
                await denyPending(); inputID = nil
            default: break
            }
            guard !closed else { return }
            switch continuation.yield(event) {
            case .enqueued: break
            case .dropped, .terminated: throw AgentFailure.invalidTransition
            @unknown default: throw AgentFailure.invalidTransition
            }
        } catch {
            // Interrupt may deny a request while its audit write is yielding.
            // The denial already went out; let the native interrupted result
            // arrive instead of replacing it with an invalid-request failure.
            if interrupting, error as? AgentFailure == .invalidRequest { return }
            await exited((error as? AgentFailure) ?? .unknown)
        }
    }

    private func handle(_ request: AgentRequest) async throws {
        guard isCurrent(request), !seen.contains(request.id), seen.count < 100_000, unresolved.count < 64 else {
            throw AgentFailure.invalidRequest
        }
        seen.insert(request.id); unresolved[request.id] = request
        if interrupting {
            try await finish(request, response: denial(for: request), decision: "denied after interrupt")
            return
        }
        switch request.kind {
        case .unknown:
            try await finish(request, response: .unsupported, decision: "unsupported")
        case .postToolUse:
            try await finish(request, response: .continueHook, decision: "observed completion")
        case .preToolUse(let tool):
            // Hooks cover every tool, including tools already allowed by
            // native rules. Enforce hard denials and audit here; only a native
            // permission request may create a user-facing approval.
            let denied = forbidden(tool)
            try await finish(request, response: denied ? .deny : .continueHook,
                             decision: denied ? "forbidden" : "allowed")
        case .permission(let tool):
            if forbidden(tool) {
                try await finish(request, response: .deny, decision: "forbidden")
            } else if policy.whitelist.contains("provider.\(tool.name)") {
                try await finish(request, response: .allow(updatedInput: nil), decision: "allowed by whitelist")
            } else {
                try await offer(request, risk: risk(tool))
            }
        case .permissions, .plan, .questions: try await offer(request, risk: .confirmable)
        }
    }

    private func offer(_ request: AgentRequest, risk: ActionRisk) async throws {
        try await record(scope: request.scope, decision: "awaiting confirmation", risk: risk,
                         kind: .suggestionOffered, request: request)
        guard isCurrent(request), unresolved[request.id] == request else { return }
        pending[request.id] = request
        pendingOrder.append(request.id)
    }

    private func removePending(_ id: AgentRequestID) {
        pending.removeValue(forKey: id); pendingOrder.removeAll { $0 == id }
    }

    private func finish(_ request: AgentRequest, response: AgentResponse, decision: String) async throws {
        do { try await record(scope: request.scope, decision: decision,
                             kind: response == .deny ? .confirmationDenied : .toolExecuted, request: request) }
        catch {
            // No affirmative reply may escape without a durable audit write.
            if unresolved.removeValue(forKey: request.id) != nil {
                try? await run.respond(to: request, with: denial(for: request))
            }
            throw error
        }
        guard isCurrent(request), unresolved.removeValue(forKey: request.id) != nil else { throw AgentFailure.invalidRequest }
        try await run.respond(to: request, with: response)
    }

    private func denial(for request: AgentRequest) -> AgentResponse {
        switch request.kind {
        case .questions, .unknown: .unsupported
        default: .deny
        }
    }

    private func denyPending() async {
        let requests = Array(unresolved.values)
        unresolved.removeAll(); pending.removeAll(); pendingOrder.removeAll()
        for request in requests {
            try? await record(scope: request.scope, decision: "expired", kind: .confirmationDenied, request: request)
            try? await run.respond(to: request, with: denial(for: request))
        }
    }

    private func exited(_ failure: AgentFailure?) async {
        guard !closed else { return }
        closed = true; inputID = nil
        await denyPending()
        continuation.finish(throwing: failure)
        try? await run.shutdown()
    }

    private func record(scope: AgentEventScope, decision: String, risk: ActionRisk? = nil,
                        kind: ActivityEvent.Kind = .toolExecuted, request: AgentRequest? = nil) async throws {
        var detail: [String: JSONValue] = ["chatID": .string(provenance.chatID.uuidString),
            "decision": .string(decision), "mode": .string(mode.rawValue)]
        if let input = scope.inputID { detail["inputID"] = .string(input.uuidString) }
        if let session = scope.session {
            detail["provider"] = .string(session.provider.rawValue)
            // Native identity may contain user paths; do not store it verbatim.
            detail["session"] = .string(StableIdentifier.short([session.provider.rawValue, session.host, session.profile, session.nativeID]))
        }
        if let item = scope.itemID { detail["item"] = .string(StableIdentifier.short([item])) }
        if let turn = scope.turnID { detail["turn"] = .string(StableIdentifier.short([turn])) }
        var actionRisk = risk
        if let request {
            detail["request"] = .string(StableIdentifier.short([request.id.encoded]))
            switch request.kind {
            case .preToolUse(let tool), .postToolUse(let tool, _), .permission(let tool):
                let builtins: Set<String> = ["Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "Write", "Edit",
                    "MultiEdit", "NotebookEdit", "Bash", "commandExecution", "fileChange"]
                detail["tool"] = .string(builtins.contains(tool.name) ? tool.name : StableIdentifier.short([tool.name]))
                actionRisk = actionRisk ?? self.risk(tool)
            default: actionRisk = actionRisk ?? .confirmable
            }
        }
        if let actionRisk { detail["risk"] = .string(actionRisk.rawValue) }
        try await audit(ActivityEvent(kind: kind, connectorID: "agent", summary: "Provider action: \(decision)",
            detailJSON: JSONValue.object(detail).jsonString, causedBy: provenance.causedBy,
            sourceID: provenance.sourceID, runID: id))
    }

    private func observation(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .toolStarted: "observed start"
        case .toolFinished(_, let error): error ? "observed failure" : "observed completion"
        default: "observed file change"
        }
    }

    /// Audit metadata only. Native permissions decide which operations ask;
    /// even a read permission request needs the user unless whitelisted.
    private func risk(_ tool: AgentTool) -> ActionRisk {
        if isServiceRead(tool) { return .read }
        return switch tool.name.lowercased() {
        case "read", "glob", "grep", "ls", "websearch", "webfetch", "enterplanmode", "exitplanmode", "askuserquestion": .read
        case "write", "edit", "multiedit", "notebookedit": .reversibleWrite
        default: .confirmable
        }
    }

    private func forbidden(_ tool: AgentTool) -> Bool {
        let name = tool.name.lowercased()
        // Service tools are denied conservatively unless explicitly read-only.
        if name.contains("mail") || name.contains("calendar") || name.contains("reminder") {
            // Ownership cannot be proved by a provider-supplied ID or boolean.
            // Only typed owned-item connectors may later enable mutations.
            return !isServiceRead(tool)
        }
        if name == "bash" || name == "commandexecution" {
            let command = (tool.input["command"]?.stringValue ?? tool.input["command"]?.jsonString ?? "").lowercased()
            return ["sendmail", "smtp", "mail ", "mailx", "mailto:", "osascript"].contains { command.contains($0) }
        }
        return false
    }

    private func isServiceRead(_ tool: AgentTool) -> Bool {
        // Exact connector operations only. A name like mail.read_and_send is
        // never considered read-only, nor is an arbitrary MCP service method.
        let names: Set<String> = ["mail.read", "mail.search", "mail.list", "mail.get",
            "mail.recent_messages", "mail.get_message", "mail.search_messages",
            "calendar.list", "calendar.read", "calendar.search", "calendar.list_events",
            "reminders.list", "reminders.read", "reminders.search", "reminders.list_reminders"]
        return names.contains(tool.name.lowercased())
    }
}
