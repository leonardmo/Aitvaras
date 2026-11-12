import Foundation
import Testing
@testable import AitvarasAgents

struct AgentContractTests {
    @Test func nativeIdentityIncludesProviderHostAndProfile() {
        let session = AgentSessionID(provider: .claude, profile: "synthetic", nativeID: "session")
        #expect(session != AgentSessionID(provider: .codex, profile: "synthetic", nativeID: "session"))
        #expect(session != AgentSessionID(provider: .claude, host: "other", profile: "synthetic", nativeID: "session"))
        #expect(session != AgentSessionID(provider: .claude, profile: "other", nativeID: "session"))
    }

    @Test func requestIDsPreserveNumericAndStringIdentityWithoutRounding() throws {
        for id in [AgentRequestID.integer(0), .integer(9_007_199_254_740_993), .string("0")] {
            #expect(try JSONDecoder().decode(AgentRequestID.self, from: JSONEncoder().encode(id)) == id)
        }
        #expect(AgentRequestID.integer(0) != .string("0"))
        for raw in ["null", "true", "1.5", "{}"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentRequestID.self, from: Data(raw.utf8)) }
        }
    }

    @Test func deliveryNeverRegressesAndCostCannotAuthorizeResend() throws {
        let prepared = AgentDeliveryState.prepared
        #expect(prepared.canAutomaticallyResend)
        let uncertain = try prepared.advancing(to: .deliveryUnknown)
        let acknowledged = try uncertain.advancing(to: .acknowledged)
        #expect(!uncertain.canAutomaticallyResend)
        #expect(!acknowledged.canAutomaticallyResend)
        #expect(try acknowledged.advancing(to: .acknowledged) == acknowledged)
        #expect(throws: AgentFailure.invalidTransition) { try uncertain.advancing(to: .prepared) }
        #expect(throws: AgentFailure.invalidTransition) { try acknowledged.advancing(to: .deliveryUnknown) }
        #expect(throws: AgentFailure.invalidTransition) { try prepared.advancing(to: .acknowledged) }
        let zeroCost = AgentUsage(scope: .process, costUSD: 0)
        #expect(zeroCost.costUSD == 0)
        #expect(AgentTurnOutcome.failed(.authRequired) != .completed)
        #expect(!uncertain.canAutomaticallyResend)
    }

    @Test func unsupportedCapabilitiesAreExplicit() throws {
        let status = AgentStatus(installed: true, authentication: .local, capabilities: [.history])
        try status.require(.history)
        #expect(throws: AgentFailure.unsupported) { try status.require(.tools) }
        #expect(AgentStatus(installed: true, authentication: .unsupported, capabilities: []).authentication == .unsupported)
    }

    @Test func hookCallbacksAndPermissionRequestsHaveDistinctScopedReplies() throws {
        let frames = try recording("claude/ask-mode")
        let requests = frames.filter { $0["type"]?.stringValue == "control_request" }
        let pre = try #require(requests.first { $0["request"]?["input"]?["hook_event_name"]?.stringValue == "PreToolUse" })
        let permission = try #require(requests.first { $0["request"]?["subtype"]?.stringValue == "can_use_tool" })
        let post = try #require(requests.first { $0["request"]?["input"]?["hook_event_name"]?.stringValue == "PostToolUse" })
        let session = AgentSessionID(provider: .claude, profile: "synthetic",
            nativeID: try #require(pre["request"]?["input"]?["session_id"]?.stringValue))
        let scope = AgentEventScope(runID: UUID(), session: session,
            itemID: try #require(pre["request"]?["tool_use_id"]?.stringValue))
        let tool = AgentTool(name: try #require(permission["request"]?["tool_name"]?.stringValue),
            input: try #require(permission["request"]?["input"]))
        let normalized = [
            AgentRequest(id: .string(try #require(pre["request_id"]?.stringValue)), scope: scope, kind: .preToolUse(tool)),
            AgentRequest(id: .string(try #require(permission["request_id"]?.stringValue)), scope: scope, kind: .permission(tool)),
            AgentRequest(id: .string(try #require(post["request_id"]?.stringValue)), scope: scope,
                kind: .postToolUse(tool, output: try #require(post["request"]?["input"]?["tool_response"])))
        ]
        #expect(Set(normalized.map(\.id)).count == 3)
        #expect(normalized.allSatisfy { $0.scope.itemID == permission["request"]?["tool_use_id"]?.stringValue })
        let edits = try recording("claude/accept-edits")
        #expect(edits.contains { $0["request"]?["input"]?["hook_event_name"]?.stringValue == "PreToolUse" })
        #expect(!edits.contains { $0["request"]?["subtype"]?.stringValue == "can_use_tool" })
    }

    @Test func recordedCodexServerRequestRetainsNumericIDAndTurnScope() throws {
        let frames = try recording("codex/write-ask")
        let request = try #require(frames.first { $0["method"]?.stringValue == "item/commandExecution/requestApproval" })
        let params = try #require(request["params"])
        let id = try JSONDecoder().decode(AgentRequestID.self, from: Data(try #require(request["id"]).jsonString.utf8))
        let scope = AgentEventScope(runID: UUID(), session: AgentSessionID(provider: .codex, profile: "synthetic",
            nativeID: try #require(params["threadId"]?.stringValue)),
            turnID: try #require(params["turnId"]?.stringValue), itemID: try #require(params["itemId"]?.stringValue))
        let normalized = AgentRequest(id: id, scope: scope,
            kind: .permission(AgentTool(name: "commandExecution", input: params)))
        #expect(normalized.id == .integer(0))
        #expect(normalized.scope.turnID != nil)
        #expect(params["availableDecisions"]?.arrayValue?.isEmpty == false)
    }

    @Test func planApprovalIsDistinctFromInformationalPlanUpdates() throws {
        let frames = try recording("claude/plan-mode")
        let request = try #require(frames.first {
            $0["request"]?["subtype"]?.stringValue == "can_use_tool" && $0["request"]?["tool_name"]?.stringValue == "ExitPlanMode"
        })
        let text = try #require(request["request"]?["input"]?["plan"]?.stringValue)
        let scope = AgentEventScope(runID: UUID())
        let approval = AgentRequest(id: .string(try #require(request["request_id"]?.stringValue)), scope: scope, kind: .plan(text))
        #expect(!text.isEmpty)
        #expect(AgentEvent(scope: scope, kind: .request(approval)) != AgentEvent(scope: scope, kind: .planUpdated(.array([]))))
    }

    @Test func recordedQuestionAnswerKeysAndMultipleAnswersAreRepresentable() throws {
        let frame = try #require(recording("claude/question").first {
            $0["request"]?["subtype"]?.stringValue == "can_use_tool" && $0["request"]?["tool_name"]?.stringValue == "AskUserQuestion"
        })
        let question = try #require(frame["request"]?["input"]?["questions"]?.arrayValue?.first)
        let text = try #require(question["question"]?.stringValue)
        let options = try #require(question["options"]?.arrayValue).map {
            AgentQuestion.Option(label: $0["label"]?.stringValue ?? "", description: $0["description"]?.stringValue ?? "")
        }
        let normalized = AgentQuestion(id: text, prompt: text, options: options,
            allowsMultiple: question["multiSelect"]?.boolValue ?? false)
        #expect(normalized.options.count == 2)
        #expect(!normalized.allowsMultiple)
        let response = AgentResponse.answers([normalized.id: [normalized.options[0].label]])
        #expect(response == .answers([text: ["Red"]]))
        let secret = AgentQuestion(id: "synthetic-question", prompt: "Synthetic question", isSecret: true)
        #expect(secret.isSecret)
        let nonblocking = AgentRequest(id: .integer(1), scope: AgentEventScope(runID: UUID()),
            kind: .questions([secret]), isBlocking: false)
        #expect(!nonblocking.isBlocking)
    }

    @Test func usagePreservesCacheCountersContextAndDifferentAccountingScopes() throws {
        let claude = try #require(recording("claude/ask-mode").first { $0["type"]?.stringValue == "result" })
        let usage = try #require(claude["usage"])
        let total = AgentUsage(scope: .turn, inputTokens: usage["input_tokens"]?.doubleValue.map(Int.init),
            outputTokens: usage["output_tokens"]?.doubleValue.map(Int.init),
            cachedInputTokens: usage["cache_read_input_tokens"]?.doubleValue.map(Int.init),
            cacheWriteInputTokens: usage["cache_creation_input_tokens"]?.doubleValue.map(Int.init),
            thinkingTokens: usage["output_tokens_details"]?["thinking_tokens"]?.doubleValue.map(Int.init))
        #expect(total.cachedInputTokens == 34274)
        #expect(total.cacheWriteInputTokens == 13524)
        let codex = try #require(recording("codex/write-ask").last { $0["method"]?.stringValue == "thread/tokenUsage/updated" })
        let counters = try #require(codex["params"]?["tokenUsage"])
        let last = AgentUsage(scope: .lastCall, inputTokens: counters["last"]?["inputTokens"]?.doubleValue.map(Int.init),
            contextTokens: counters["last"]?["totalTokens"]?.doubleValue.map(Int.init),
            contextLimit: counters["modelContextWindow"]?.doubleValue.map(Int.init))
        #expect(last.contextTokens == 17534)
        #expect(last.contextLimit == 258400)
        #expect(last.inputTokens != counters["total"]?["inputTokens"]?.doubleValue.map(Int.init))
        let rate = try #require(recording("claude/ask-mode").first { $0["type"]?.stringValue == "rate_limit_event" })
        let windows = try #require(rate["rate_limit_info"]?["unifiedWindows"])
        let fiveHour = AgentRateLimitWindow(id: "five_hour", utilization: windows["five_hour"]?["utilization"]?.doubleValue,
            duration: 5 * 3600, resetsAt: windows["five_hour"]?["resetsAt"]?.doubleValue.map(Date.init(timeIntervalSince1970:)))
        #expect(fiveHour.utilization == 0.75)
        #expect(fiveHour.resetsAt != nil)
        #expect(AgentRateLimitWindow(id: "primary", utilization: nil).utilization == nil)
    }

    @Test func recordedErrorsAndInterruptionCannotBeMistakenForSuccess() throws {
        let auth = try #require(recording("claude/auth-failed").first { $0["type"]?.stringValue == "result" })
        #expect(auth["subtype"]?.stringValue == "success")
        #expect(auth["is_error"]?.boolValue == true)
        #expect(AgentTurnOutcome.failed(.authRequired) != .completed)
        let interrupted = try #require(recording("claude/interrupt").first { $0["type"]?.stringValue == "result" })
        #expect(interrupted["terminal_reason"]?.stringValue == "aborted_streaming")
        let codex = try #require(recording("codex/interrupt").first { $0["method"]?.stringValue == "turn/completed" })
        #expect(codex["params"]?["turn"]?["status"]?.stringValue == "interrupted")
    }

    @Test func protocolBarrierCanRefuseDeliveryAndRequestsExpireWithRun() async throws {
        let run = ContractRun()
        let input = AgentInput(text: "synthetic message")
        await #expect(throws: AgentFailure.invalidTransition) {
            try await run.send(input) { throw AgentFailure.invalidTransition }
        }
        #expect(await run.delivered.isEmpty)
        try await run.send(input, willDeliver: {})
        #expect(await run.delivered == [input.id])
        let request = AgentRequest(id: .integer(0), scope: AgentEventScope(runID: run.id), kind: .permissions(.object([:])))
        await run.offer(request)
        let stale = AgentRequest(id: request.id, scope: AgentEventScope(runID: UUID()), kind: request.kind)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: stale, with: .deny) }
        try await run.respond(to: request, with: .deny)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .allow(updatedInput: nil)) }
        await run.offer(request)
        try await run.shutdown()
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
    }

    private func recording(_ name: String) throws -> [JSONValue] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/" + name + ".jsonl")
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map {
            try #require(JSONValue.parse(String($0)))
        }
    }
}

/// An executable contract example, not a provider or protocol parser.
private actor ContractRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private var requests: [AgentRequestID: AgentRequest] = [:]
    private(set) var delivered: [UUID] = []
    init() { (events, continuation) = AsyncThrowingStream.makeStream() }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver()
        delivered.append(input.id)
    }
    func offer(_ request: AgentRequest) { requests[request.id] = request }
    func respond(to request: AgentRequest, with response: AgentResponse) throws {
        guard request.scope.runID == id, requests[request.id] == request else { throw AgentFailure.invalidRequest }
        requests.removeValue(forKey: request.id)
    }
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() throws { requests.removeAll(); continuation.finish() }
}
