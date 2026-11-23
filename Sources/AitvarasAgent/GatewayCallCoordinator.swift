import Foundation
import AitvarasCore
import AitvarasAgents
import AitvarasStore

enum GatewayAuditContext {
    @TaskLocal static var active = false
}

public struct GatewayExactGrant: Hashable, Sendable {
    public let projectID: UUID
    public let toolRevision: String

    public init?(projectID: UUID?, tool: MCPGatewayTool) {
        guard let projectID, GatewayPolicyDecision.criticalReason(tool) == nil else { return nil }
        self.projectID = projectID
        toolRevision = tool.revision
    }
}

public struct GatewayPolicyRules: Sendable {
    public let overrides: [String: ActionRisk]
    public let grants: Set<GatewayExactGrant>

    /// Override keys are exact tool revisions, including the upstream account and definition.
    public init(overrides: [String: ActionRisk] = [:], grants: Set<GatewayExactGrant> = []) {
        self.overrides = overrides
        self.grants = grants
    }
}

struct GatewayPolicyDecision: Equatable, Sendable {
    let risk: ActionRisk
    let forbidden: Bool
    let verdict: AutonomyPolicy.Verdict
    let exactGrant: Bool
    let approvalReason: String?
    let canAlwaysAllow: Bool
    let usesUnpromptedMode: Bool

    init(tool: MCPGatewayTool, invocation: MCPGatewayInvocation, rules: GatewayPolicyRules, policy: AutonomyPolicy) {
        let protectedService = ["mail", "smtp", "outlook", "calendar", "reminder"].contains {
            tool.name.lowercased().contains($0)
        }
        let hardDenial: Bool
        switch tool.origin {
        case .aitvaras(.mail):
            hardDenial = !["recent_messages", "search_messages", "get_message"].contains(tool.definition.name) || tool.definition.risk != .read
        case .aitvaras: hardDenial = false
        case .upstream:
            // Generic upstreams cannot prove mail safety or EventKit ownership.
            hardDenial = protectedService || AgentToolPolicy.isCommandExecution(.init(name: tool.definition.name, input: .null))
        }
        let permissions: AgentChatPermissions?
        if case .inline = invocation.presentation { permissions = invocation.context.permissions }
        else { permissions = nil }
        let criticalReason = Self.criticalReason(tool)
        // External launches retain the existing gateway approval policy.
        let explicit = permissions == nil ? Self.requiresExplicitApproval(tool) : criticalReason != nil
        let proposed: ActionRisk
        if case .aitvaras = tool.origin { proposed = tool.definition.risk }
        else if let override = rules.overrides[tool.revision] { proposed = override }
        else if tool.trusted, tool.annotations.readOnly == true, tool.annotations.destructive != true { proposed = .read }
        else if tool.trusted, tool.annotations.destructive == false, tool.annotations.idempotent == true {
            proposed = .reversibleWrite
        } else { proposed = .confirmable }

        let risk = hardDenial || explicit ? .confirmable : proposed
        let forbidden = hardDenial || (permissions?.isPlan == true && risk != .read)
        let mode = permissions?.isPlan == true ? nil : permissions?.mcp
        let unprompted = !forbidden && mode == .unprompted
        let grant = GatewayExactGrant(projectID: invocation.context.projectID, tool: tool)
        let canUseGrant = !forbidden && !explicit && mode != .ask && !unprompted && risk == .confirmable
        let exactGrant = canUseGrant && (grant.map(rules.grants.contains) ?? false)
        let verdict = policy.verdict(for: risk, hasExactGrant: exactGrant || unprompted,
            requiresExplicitConfirmation: forbidden || mode == .ask || (explicit && !unprompted))

        self.risk = risk
        self.forbidden = forbidden
        self.exactGrant = exactGrant
        self.verdict = verdict
        usesUnpromptedMode = unprompted
        canAlwaysAllow = !forbidden && mode == .auto && verdict == .requireConfirmation && grant != nil
        if verdict != .requireConfirmation || forbidden {
            approvalReason = nil
        } else if mode == .ask {
            approvalReason = "This chat asks before running MCP tools."
        } else if mode == .auto {
            approvalReason = criticalReason ?? "This tool has no current project approval or recognized risk classification."
        } else {
            approvalReason = nil
        }
    }

    private static func requiresExplicitApproval(_ tool: MCPGatewayTool) -> Bool {
        let name = tool.definition.name.lowercased()
        return AgentToolPolicy.requiresExplicitMCPApproval(.init(name: "mcp__" + tool.name, input: .null))
            || name.contains("delete") || name.contains("remove")
    }

    static func criticalReason(_ tool: MCPGatewayTool) -> String? {
        if tool.annotations.destructive == true { return "This tool is declared destructive." }
        return AgentToolPolicy.criticalMCPApprovalReason(toolName: tool.definition.name)
    }
}

struct GatewayCallCoordinator: Sendable {
    let stores: Stores
    let approvals: GatewayApprovalBroker

    func execute(_ invocation: MCPGatewayInvocation, tool: MCPGatewayTool, arguments: JSONValue,
                 decision: @Sendable () async throws -> GatewayPolicyDecision, revalidate: MCPGateway.Authorize,
                 operation: @Sendable () async throws -> MCPGatewayToolResult) async throws -> MCPGatewayToolResult {
        let start = ContinuousClock.now
        let audit = GatewayCallAudit(invocation: invocation, tool: tool, arguments: arguments)
        var current: GatewayPolicyDecision?
        var approval = "notRequired"
        var dispatched = false
        var completed = false
        do {
            guard case .object = arguments, arguments.jsonString.utf8.count <= ConnectorHub.maximumToolArgumentsBytes else {
                throw MCPGatewayCallError.invalidArguments
            }
            try Task.checkCancellation()
            let initial = try await decision()
            current = initial
            guard !initial.forbidden else { throw MCPGatewayCallError.denied }
            try await revalidate()
            if initial.exactGrant { approval = "exactGrant" }
            if initial.usesUnpromptedMode { approval = "chatUnprompted" }
            var approvedByUser = false
            var grant: (chatID: UUID, toolRevision: String)?
            if initial.verdict == .requireConfirmation {
                approval = "pending"
                try write(audit, decision: current, approval: approval, outcome: "awaitingApproval", since: start, kind: .suggestionOffered)
                let request = GatewayApprovalRequest(id: audit.callID, invocation: invocation,
                    toolName: tool.name, risk: initial.risk, reason: initial.approvalReason,
                    canAlwaysAllow: initial.canAlwaysAllow, arguments: arguments)
                let outcome = await approvals.wait(for: request)
                approval = outcome.rawValue
                switch outcome {
                case .approved: approvedByUser = true
                case .approvedForProject:
                    guard initial.canAlwaysAllow, case .inline(let chatID) = invocation.presentation else {
                        throw MCPGatewayCallError.denied
                    }
                    approvedByUser = true
                    grant = (chatID, tool.revision)
                case .denied: throw MCPGatewayCallError.denied
                case .timedOut: throw MCPGatewayCallError.timedOut
                case .cancelled: throw CancellationError()
                }
            }
            try Task.checkCancellation()
            try await revalidate()
            let refreshed = try await decision()
            let grantedByAnotherCall = approvedByUser && initial.canAlwaysAllow
                && refreshed.exactGrant && !refreshed.forbidden && refreshed.risk == initial.risk
            guard refreshed == initial || grantedByAnotherCall else { throw MCPGatewayCallError.stale }
            try Task.checkCancellation()
            // A durable pre-dispatch record is required before any operation.
            try write(audit, decision: current, approval: approval, outcome: "dispatching", since: start, grant: grant)
            try Task.checkCancellation()
            dispatched = true
            let result = try await operation()
            completed = true
            _ = try result.validated()
            if result.isError && initial.risk != .read { throw MCPGatewayCallError.outcomeUnknown }
            try write(audit, decision: current, approval: approval, outcome: result.isError ? "toolError" : "succeeded", since: start)
            return result
        } catch {
            if completed, error as? MCPGatewayCallError == .auditUnavailable {
                throw MCPGatewayCallError.completedWithoutAudit
            }
            let safe = publicError(error, dispatched: dispatched, risk: current?.risk)
            let status = error is CancellationError && safe != .outcomeUnknown ? "cancelled" : String(describing: safe)
            try? write(audit, decision: current, approval: approval, outcome: status, since: start,
                       kind: safe == .denied || safe == .timedOut ? .confirmationDenied : .toolExecuted)
            throw safe
        }
    }

    private func publicError(_ error: Error, dispatched: Bool, risk: ActionRisk?) -> MCPGatewayCallError {
        if error is GatewayToolScopeError { return (error as? GatewayToolScopeError) == .invalidArguments ? .invalidArguments : .denied }
        if let error = error as? MCPGatewayCallError {
            if dispatched, risk != .read, error == .failed || error == .invalidResult { return .outcomeUnknown }
            return error
        }
        if dispatched, risk != .read { return .outcomeUnknown }
        if error is CancellationError { return .denied }
        return .failed
    }

    private func write(_ audit: GatewayCallAudit, decision: GatewayPolicyDecision?, approval: String, outcome: String,
                       since start: ContinuousClock.Instant, kind: ActivityEvent.Kind = .toolExecuted,
                       grant: (chatID: UUID, toolRevision: String)? = nil) throws {
        do {
            let duration = start.duration(to: .now).components
            let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            try stores.recordGatewayActivity(audit.event(decision: decision, approval: approval, outcome: outcome,
                elapsed: elapsed, kind: kind), projectID: audit.invocation.context.projectID, grant: grant)
        } catch {
            throw MCPGatewayCallError.auditUnavailable
        }
    }
}

private struct GatewayCallAudit {
    let callID = UUID()
    let invocation: MCPGatewayInvocation
    let toolName: String
    let origin: MCPGatewayTool.Origin
    let argumentPreview: JSONValue

    init(invocation: MCPGatewayInvocation, tool: MCPGatewayTool, arguments: JSONValue) {
        self.invocation = invocation
        toolName = tool.name
        origin = tool.origin
        let fields: [String: JSONValue] = if case .object(let object) = arguments { object } else { [:] }
        // Never persist arbitrary keys, free text, nested values, IDs or headers.
        var preview: [String: JSONValue] = [:]
        for key in ["limit", "count"] {
            if let n = fields[key]?.doubleValue, n >= 1, n <= 200, n.rounded() == n { preview[key] = .number(n) }
        }
        if let flag = fields["includeCompleted"]?.boolValue { preview["includeCompleted"] = .bool(flag) }
        preview["redactedFields"] = .number(Double(fields.count - preview.count))
        argumentPreview = .object(preview)
    }

    func event(decision: GatewayPolicyDecision?, approval: String, outcome: String, elapsed: Double,
               kind: ActivityEvent.Kind) -> ActivityEvent {
        var details: [String: JSONValue] = [
            "callID": .string(callID.uuidString), "launchID": .string(invocation.launchID.uuidString),
            "client": .string(invocation.context.client.rawValue),
            "projectID": invocation.context.projectID.map { .string($0.uuidString) } ?? .null,
            "tool": .string(toolName), "approval": .string(approval), "outcome": .string(outcome),
            "durationMs": .number(elapsed), "arguments": argumentPreview,
            "risk": decision.map { .string($0.risk.rawValue) } ?? .null,
            "policyDecision": decision.map { .string($0.forbidden ? "forbidden" : $0.verdict == .allow ? "allow" : "confirm") } ?? .null
        ]
        if case .upstream(let server, let account, _) = origin {
            details["upstream"] = .string(server)
            details["accountID"] = .string(account.uuidString)
        }
        return ActivityEvent(kind: kind, connectorID: "agent.gateway", summary: "Gateway tool: " + outcome,
                             detailJSON: JSONValue.object(details).jsonString, runID: callID)
    }
}
