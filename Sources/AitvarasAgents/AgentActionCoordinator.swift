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
    public nonisolated let accountID: String?
    public nonisolated let mcpSetup: AgentMCPLaunchStatus?
    public nonisolated let permissionSource: AgentPermissionSource
    public nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let run: any AgentRun
    private let provenance: Provenance
    private let audit: Audit
    private let policy: AutonomyPolicy
    private let projectGrants: @Sendable () throws -> Set<String>
    private var mode: AgentMode
    private var inputID: UUID?
    private var automaticProvenance: [UUID: Provenance] = [:]
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
                policy: AutonomyPolicy = AutonomyPolicy(), permissionSource: AgentPermissionSource? = nil,
                projectGrants: @escaping @Sendable () throws -> Set<String> = { [] }, audit: @escaping Audit) {
        self.run = run; id = run.id; accountID = run.accountID; self.mode = mode
        mcpSetup = run.mcpSetup
        self.permissionSource = permissionSource ?? run.permissionSource; self.projectGrants = projectGrants
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

    /// Saved row consent authorizes only this exact prompt/claim, never tools.
    public func sendAutomatically(_ input: AgentInput, authorization: AgentAutoContinue, session: AgentSessionID,
                                  persistence: any AgentAutoContinuePersistence, clock: AgentAutoContinueClock = .live,
                                  willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        guard authorization.chatID == provenance.chatID, session == authorization.native,
              input.id == authorization.continuationInputID, input.automaticIntentID == authorization.id, input.text == AgentAutoContinue.prompt,
              input.attachments.isEmpty, input.mentions.isEmpty, input.command == nil else { throw AgentFailure.invalidRequest }
        try Self.validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
        let tool = ToolDefinition(name: "continueAfterReset", description: "Continue stopped chat", parametersJSON: "{}", risk: .confirmable)
        if policy.verdict(for: tool, connectorID: "agent.autoContinue") == .requireConfirmation {
            // Only this claim's saved row choice supplies confirmation.
            guard authorization.enabled, authorization.continuationInputID == input.id else { throw AgentFailure.invalidTransition }
        }
        let event = Self.continuationAudit(authorization, operation: "authorize", inputID: input.id, clock: clock)
        try await audit(event)
        try Self.validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
        automaticProvenance[input.id] = .init(chatID: authorization.chatID, causedBy: event.id,
                                              sourceID: authorization.failedInputID.uuidString)
        do {
            try await send(input) {
                try Self.validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
                try await willDeliver()
            }
        } catch { automaticProvenance.removeValue(forKey: input.id); throw error }
    }

    /// A provider/account read is audited and revalidated across every await.
    public static func autoContinueRateLimits(_ authorization: AgentAutoContinue, backend: any AgentBackend,
                                             persistence: any AgentAutoContinuePersistence,
                                             clock: AgentAutoContinueClock = .live, policy: AutonomyPolicy = .init(),
                                             audit: @escaping Audit) async throws -> AgentUsageLimitSnapshot {
        guard authorization.scope.provider == .codex else { throw AgentFailure.unsupported }
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
        let tool = ToolDefinition(name: "rateLimits", description: "Read CLI rate limits", parametersJSON: "{}", risk: .read)
        guard policy.verdict(for: tool, connectorID: "agent.autoContinue") == .allow else { throw AgentFailure.invalidTransition }
        try await audit(continuationAudit(authorization, operation: "rateLimits", inputID: nil, clock: clock))
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
        let status = try await backend.status()
        guard status.authentication == .subscription else { throw AgentFailure.authRequired }
        guard status.accountID == authorization.scope.accountID else { throw AgentFailure.invalidTransition }
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
        let windows = try await backend.rateLimits()
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
        return .init(scope: authorization.scope, windows: windows, observedAt: clock.now())
    }

    public static func authorizeAutomaticHistoryRead(_ authorization: AgentAutoContinue, persistence: any AgentAutoContinuePersistence,
                                                     clock: AgentAutoContinueClock, audit: @escaping Audit) async throws {
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
        let tool = ToolDefinition(name: "history", description: "Read native chat history", parametersJSON: "{}", risk: .read)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.autoContinue") == .allow else { throw AgentFailure.invalidTransition }
        try await audit(continuationAudit(authorization, operation: "history", inputID: nil, clock: clock))
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: false)
    }

    public static func quotaStopStatus(_ stop: AgentQuotaStop, backend: any AgentBackend,
                                       clock: AgentAutoContinueClock = .live, audit: @escaping Audit) async throws -> AgentStatus {
        let tool = ToolDefinition(name: "accountStatus", description: "Read CLI account", parametersJSON: "{}", risk: .read)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.autoContinue") == .allow else { throw AgentFailure.invalidTransition }
        try await audit(ActivityEvent(kind: .automationRun, timestamp: clock.now(), connectorID: "agent.autoContinue",
            summary: "Usage-reset continuation: account status",
            detailJSON: JSONValue.object(["operation": .string("accountStatus"), "chatID": .string(stop.chatID.uuidString),
                "inputID": .string(stop.id.uuidString), "risk": .string("read")]).jsonString,
            sourceID: stop.id.uuidString, runID: stop.id))
        let status = try await backend.status()
        guard status.authentication == .subscription else { throw AgentFailure.authRequired }
        return status
    }

    public static func autoContinueStatus(_ authorization: AgentAutoContinue, backend: any AgentBackend,
                                          persistence: any AgentAutoContinuePersistence, clock: AgentAutoContinueClock = .live,
                                          audit: @escaping Audit) async throws {
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
        let tool = ToolDefinition(name: "accountStatus", description: "Read CLI account", parametersJSON: "{}", risk: .read)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.autoContinue") == .allow else { throw AgentFailure.invalidTransition }
        try await audit(continuationAudit(authorization, operation: "status", inputID: authorization.continuationInputID, clock: clock))
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
        let status = try await backend.status()
        guard status.authentication == .subscription else { throw AgentFailure.authRequired }
        guard status.accountID == authorization.scope.accountID else { throw AgentFailure.invalidTransition }
        try validateContinuation(authorization, persistence: persistence, clock: clock, claimed: true)
    }

    private static func validateContinuation(_ authorization: AgentAutoContinue, persistence: any AgentAutoContinuePersistence,
                                             clock: AgentAutoContinueClock, claimed: Bool) throws {
        try Task.checkCancellation()
        try persistence.validate(authorization)
        guard let current = try persistence.continuation(id: authorization.id), current == authorization,
              current.enabled, current.state == (claimed ? .claimed : .pending),
              !claimed || current.delivery == .prepared,
              current.inputRevision == (try persistence.inputRevision(chatID: current.chatID)) else { throw AgentFailure.invalidTransition }
        var eligible = current; eligible.state = .pending
        guard AgentAutoContinueSchedule(clock: clock).plan(eligible).state != .expired else { throw AgentFailure.invalidTransition }
    }

    private static func continuationAudit(_ value: AgentAutoContinue, operation: String, inputID: UUID?,
                                          clock: AgentAutoContinueClock) -> ActivityEvent {
        ActivityEvent(kind: .automationRun, timestamp: clock.now(), connectorID: "agent.autoContinue",
            summary: "Usage-reset continuation: " + operation,
            detailJSON: JSONValue.object(["operation": .string(operation), "intentID": .string(value.id.uuidString),
                "chatID": .string(value.chatID.uuidString), "inputID": .string((inputID ?? value.failedInputID).uuidString),
                "provider": .string(value.scope.provider.rawValue), "risk": .string(operation == "authorize" ? "confirmable" : "read")]).jsonString,
            causedBy: value.lastActivityID, sourceID: value.failedInputID.uuidString, runID: inputID ?? value.failedInputID)
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
            // Stop can deny this request while its approval audit is yielding.
            // The denial already went out, so only this late answer is invalid;
            // the session stays open for the native interrupted result.
            if interrupting, error as? AgentFailure == .invalidRequest { throw error }
            await exited((error as? AgentFailure) ?? .unknown)
            throw error
        }
    }

    /// Reserve the live request before persisting the explicit user grant. The
    /// persistence closure must save the rule and its audit in one transaction.
    public func alwaysAllow(to request: AgentRequest, persist: @Sendable () throws -> Void) async throws {
        guard !interrupting, isCurrent(request), pending[request.id] == request,
              AgentToolPolicy.canAlwaysAllow(request), case .permission(let tool) = request.kind,
              let provider = request.scope.session?.provider,
              (try? AgentToolPolicy.grantKey(provider: provider, tool: tool.name,
                  fingerprint: AgentToolPolicy.fingerprint(tool: tool.name, servers: mcpSetup?.serverFingerprints ?? [:]))) != nil else { throw AgentFailure.invalidRequest }
        removePending(request.id)
        do {
            try persist()
            try await finish(request, response: .allow(updatedInput: nil), decision: "approved and allowed in project")
        } catch {
            if interrupting, error as? AgentFailure == .invalidRequest { throw error }
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
                await denyPending()
                if let inputID { automaticProvenance.removeValue(forKey: inputID) }
                inputID = nil
                followups.subtract(event.scope.completedInputIDs)
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
            if forbidden(tool) {
                try await finish(request, response: .deny, decision: "forbidden")
            } else if AgentToolPolicy.requiresExplicitMCPApproval(tool) {
                try await finish(request, response: .askHook, decision: "requires explicit MCP approval")
            } else if permissionSource == .aitvaras, requiresAitvarasApproval(tool) {
                try await finish(request, response: .askHook, decision: "requires Aitvaras approval")
            } else {
                try await finish(request, response: .continueHook, decision: "allowed")
            }
        case .permission(let tool):
            if forbidden(tool) {
                try await finish(request, response: .deny, decision: "forbidden")
            } else if request.scope.session?.profile == OpencodeConfiguration.profile,
                      request.scope.session?.provider == .local,
                      risk(tool) == .read || ((mode == .acceptEdits || mode == .auto) && risk(tool) == .reversibleWrite) {
                // Native Local permissions always ask, so policy and durable
                // provenance are applied even when the app mode permits edits.
                try await finish(request, response: .allow(updatedInput: nil), decision: "allowed by local mode")
            } else if let provider = request.scope.session?.provider,
                      AgentToolPolicy.grantEligible(tool),
                      let key = try? AgentToolPolicy.grantKey(provider: provider, tool: tool.name,
                          fingerprint: AgentToolPolicy.fingerprint(tool: tool.name, servers: mcpSetup?.serverFingerprints ?? [:])),
                      try projectGrants().contains(key) {
                try await finish(request, response: .allow(updatedInput: nil), decision: "allowed by project grant")
            } else if AgentToolPolicy.grantEligible(tool), !tool.name.hasPrefix("mcp__"), policy.whitelist.contains("provider.\(tool.name)") {
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
        let origin = scope.inputID.flatMap { automaticProvenance[$0] } ?? provenance
        var detail: [String: JSONValue] = ["chatID": .string(origin.chatID.uuidString),
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
            detailJSON: JSONValue.object(detail).jsonString, causedBy: origin.causedBy,
            sourceID: origin.sourceID, runID: id))
    }

    private func observation(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .toolStarted: "observed start"
        case .toolFinished(_, let error): error ? "observed failure" : "observed completion"
        default: "observed file change"
        }
    }

    /// Repo allow rules must not bypass approvals required by the current mode.
    private func requiresAitvarasApproval(_ tool: AgentTool) -> Bool {
        switch risk(tool) {
        case .read: false
        case .reversibleWrite: mode != .acceptEdits && mode != .auto
        // Auto retains the repo-source hook behavior. Native auto mode still
        // decides whether to issue a permission request, which we gate normally.
        case .confirmable: mode != .auto
        }
    }

    /// Audit metadata only. Native permissions decide which operations ask;
    /// even a read permission request needs the user unless whitelisted.
    private func risk(_ tool: AgentTool) -> ActionRisk {
        AgentToolPolicy.risk(tool)
    }

    private func forbidden(_ tool: AgentTool) -> Bool {
        AgentToolPolicy.forbidden(tool)
    }
}
