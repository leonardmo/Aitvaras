import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

struct AgentConformanceTests {
    @Test(arguments: [AgentProvider.claude, .codex], [true, false])
    func executableBackendsPassThroughCoordinator(provider: AgentProvider, approve: Bool) async throws {
        let claude = """
claude_init()
read()
emit({'type':'control_request','request_id':'action','request':{'subtype':'hook_callback','callback_id':'pre','input':{'hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':'echo test'}}}})
reply=read()['response']['response']
assert reply['continue']==True
emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':'Bash','input':{'command':'echo test'}}})
reply=read()['response']['response']
assert reply['behavior']=='\(approve ? "allow" : "deny")'
emit({'type':'result','is_error':False})
done()
"""
        let codex = """
codex_init()
start_thread()
request=read()
assert request['method']=='turn/start'
emit({'id':request['id'],'result':{'turn':{'id':'turn-test'}}})
emit({'id':99,'method':'item/commandExecution/requestApproval','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'item-test','command':'echo test'}})
reply=read()
assert reply['id']==99 and reply['result']['decision']=='\(approve ? "accept" : "decline")'
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[]}}})
done()
"""
        let fixture = try BackendExecutableFixture(script: provider == .claude ? claude : codex)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test", mode: .acceptEdits))
        let audit = FakeActionAudit()
        let coordinator = AgentActionCoordinator(run: run, mode: .acceptEdits, provenance: .init(chatID: UUID())) {
            try await audit.record($0)
        }
        try await coordinator.send(.init(text: "test"), willDeliver: {})
        try await waitForPending(coordinator)
        let request = try #require(await coordinator.pendingRequests().first)
        try await coordinator.respond(to: request, with: approve ? .allow(updatedInput: nil) : .deny)
        var outcome: AgentTurnOutcome?
        for try await event in coordinator.events {
            if case .turnEnded(let value) = event.kind { outcome = value; break }
        }
        #expect(outcome == .completed)
        #expect(await audit.events.count == (provider == .claude ? 3 : 2))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], [true, false])
    func approveDenyAndRejectDuplicateOrStaleAnswers(provider: AgentProvider, approve: Bool) async throws {
        let fixture = try ActionFixture(provider: provider)
        let coordinator = fixture.coordinator
        try await coordinator.send(fixture.input, willDeliver: {})
        let request = await fixture.run.request(.permission(.init(name: "commandExecution", input: .object([:]))))
        try await waitForPending(coordinator)
        let stale = AgentRequest(id: request.id, scope: .init(runID: UUID(), inputID: fixture.input.id), kind: request.kind)
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.respond(to: stale, with: .deny) }
        await #expect(throws: AgentFailure.invalidRequest) {
            try await coordinator.respond(to: request, with: .allow(updatedInput: .object(["command": .string("changed")])))
        }
        let answer: AgentResponse = approve ? .allow(updatedInput: nil) : .deny
        try await coordinator.respond(to: request, with: answer)
        await #expect(throws: AgentFailure.invalidRequest) { try await coordinator.respond(to: request, with: answer) }
        #expect(await fixture.run.responses == [answer])
        #expect(await fixture.run.executions == (approve ? 1 : 0))
        let events = await fixture.audit.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.runID == coordinator.id && $0.causedBy == fixture.parent && $0.sourceID == "source-test" })
        let detail = try #require(JSONValue.parse(events[0].detailJSON ?? ""))
        #expect(detail["chatID"]?.stringValue == fixture.chat.uuidString)
        #expect(detail["inputID"]?.stringValue == fixture.input.id.uuidString)
        #expect(detail["risk"]?.stringValue == "confirmable")
        #expect(detail["provider"]?.stringValue == provider.rawValue)
        try await coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], ["offer", "answer", "read"])
    func auditFailureDeniesBeforeExecution(provider: AgentProvider, phase: String) async throws {
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        await fixture.audit.fail(after: phase == "answer" ? 1 : 0)
        let kind: AgentRequest.Kind = phase == "read" ? .preToolUse(.init(name: "Read", input: .null))
            : .permission(.init(name: "Write", input: .null))
        let request = await fixture.run.request(kind)
        if phase == "answer" {
            try await waitForPending(fixture.coordinator)
            await #expect(throws: AgentFailure.unknown) {
                try await fixture.coordinator.respond(to: request, with: .allow(updatedInput: nil))
            }
        }
        try await waitForResponses(fixture.run)
        #expect(await fixture.run.responses == [.deny])
        #expect(await fixture.run.executions == 0)
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], ["shutdown", "exit", "turn", "interrupt"])
    func pendingIsDeniedWhenRunEndsOrStops(provider: AgentProvider, reason: String) async throws {
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        let request = await fixture.run.request(.permission(.init(name: "Write", input: .null)))
        try await waitForPending(fixture.coordinator)
        switch reason {
        case "shutdown": try await fixture.coordinator.shutdown()
        case "exit": await fixture.run.exit()
        case "interrupt": try await fixture.coordinator.interrupt()
        default: await fixture.run.emit(.turnEnded(.completed))
        }
        try await waitForResponses(fixture.run)
        await #expect(throws: AgentFailure.invalidRequest) {
            try await fixture.coordinator.respond(to: request, with: .allow(updatedInput: nil))
        }
        #expect(await fixture.run.executions == 0)
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        #expect(await fixture.run.responses == [.deny])
        let audit = await fixture.audit.events
        #expect(audit.count == 2)
        #expect(audit.contains { $0.kind == .confirmationDenied })
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], ["offer-shutdown", "answer-shutdown", "offer-interrupt", "answer-interrupt"])
    func stopDuringAuditCannotReleaseApproval(provider: AgentProvider, scenario: String) async throws {
        let phase = scenario.hasPrefix("offer") ? "offer" : "answer"
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        await fixture.audit.pause(after: phase == "offer" ? 0 : 1)
        let request = await fixture.run.request(.permission(.init(name: "Write", input: .null)))
        var answering: Task<Void, Error>?
        if phase == "answer" {
            try await waitForPending(fixture.coordinator)
            answering = Task { try await fixture.coordinator.respond(to: request, with: .allow(updatedInput: nil)) }
        }
        for _ in 0..<200 {
            if await fixture.audit.isPaused { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.audit.isPaused)
        if scenario.hasSuffix("shutdown") { try await fixture.coordinator.shutdown() }
        else { try await fixture.coordinator.interrupt() }
        await fixture.audit.resume()
        if let answering {
            await #expect(throws: AgentFailure.invalidRequest) { try await answering.value }
        }
        #expect(await fixture.run.responses == [.deny])
        #expect(await fixture.run.executions == 0)
        if scenario.hasSuffix("interrupt") {
            var outcome: AgentTurnOutcome?
            for try await event in fixture.coordinator.events {
                if case .turnEnded(let value) = event.kind { outcome = value; break }
            }
            #expect(outcome == .interrupted)
        }
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func duplicateRequestsFailClosed(provider: AgentProvider) async throws {
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        let request = await fixture.run.request(.permission(.init(name: "Write", input: .null)))
        try await waitForPending(fixture.coordinator)
        await fixture.run.emit(.request(request))
        var failure: AgentFailure?
        do { for try await _ in fixture.coordinator.events {} }
        catch { failure = error as? AgentFailure }
        #expect(failure == .invalidRequest)
        #expect(await fixture.run.responses == [.deny])
        #expect(await fixture.run.executions == 0)
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], [AgentMode.ask, .acceptEdits, .plan, .auto])
    func forbiddenServiceActionsCannotBeApproved(provider: AgentProvider, mode: AgentMode) async throws {
        let fixture = try ActionFixture(provider: provider, mode: mode)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        let tools = ["mail.send", "mail.compose", "mail.read_and_send", "mcp__gmail__send_message",
                     "calendar.update", "reminders.delete", "Bash"]
        for (index, name) in tools.enumerated() {
            let request = await fixture.run.request(.preToolUse(.init(name: name,
                input: .object(["command": .string("sendmail person@example.org")]))))
            try await waitForResponses(fixture.run, count: index + 1)
            await #expect(throws: AgentFailure.invalidRequest) {
                try await fixture.coordinator.respond(to: request, with: .allow(updatedInput: nil))
            }
        }
        #expect(await fixture.run.responses == Array(repeating: .deny, count: tools.count))
        #expect(await fixture.run.executions == 0)
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], [AgentMode.ask, .acceptEdits, .plan, .auto])
    func hooksNeverOfferCards(provider: AgentProvider, mode: AgentMode) async throws {
        let fixture = try ActionFixture(provider: provider, mode: mode)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        let tools = ["Read", "Write", "Bash", "ToolSearch", "TodoWrite", "Task", "FutureInternalTool"]
        for (index, name) in tools.enumerated() {
            _ = await fixture.run.request(.preToolUse(.init(name: name, input: .null)))
            try await waitForResponses(fixture.run, count: index + 1)
        }
        #expect(await fixture.run.responses == Array(repeating: .continueHook, count: tools.count))
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        let events = await fixture.audit.events
        #expect(!events.contains { $0.kind == .suggestionOffered })
        let risks = events.compactMap { JSONValue.parse($0.detailJSON ?? "")?["risk"]?.stringValue }
        #expect(risks.count == tools.count)
        #expect(risks[0] == "read")
        #expect(risks[1] == "reversibleWrite")
        try await fixture.coordinator.shutdown()
    }

    @Test func recordedAskModeOffersExactlyOneCard() async throws {
        let replay = try await replayClaudeRecording("ask-mode", mode: .ask)
        #expect(replay.approvals.count == 1)
        guard case .permission(let tool) = try #require(replay.approvals.first).kind else {
            Issue.record("Expected one native Write approval")
            return
        }
        #expect(tool.name == "Write")
        #expect(replay.audit.filter { $0.kind == .suggestionOffered }.count == 1)
    }

    @Test(arguments: [AgentMode.acceptEdits, .auto])
    func recordedAcceptEditsWriteAndBashNeedNoCards(mode: AgentMode) async throws {
        // Auto sees the same hook-only sequence when native rules allow tools.
        let replay = try await replayClaudeRecording("accept-edits", mode: mode)
        #expect(replay.approvals.isEmpty)
        #expect(!replay.audit.contains { $0.kind == .suggestionOffered })
        #expect(replay.events.contains { event in
            if case .request(let request) = event.kind, case .preToolUse(let tool) = request.kind { tool.name == "Bash" }
            else { false }
        })
    }

    @Test func recordedInternalToolSearchDoesNotAsk() async throws {
        let replay = try await replayClaudeRecording("plan-mode", mode: .plan)
        #expect(replay.events.contains { event in
            if case .request(let request) = event.kind, case .preToolUse(let tool) = request.kind { tool.name == "ToolSearch" }
            else { false }
        })
        #expect(replay.approvals.allSatisfy { request in
            switch request.kind {
            case .plan: true
            case .permission(let tool): tool.name == "Write" || tool.name == "Bash"
            default: false
            }
        })
    }

    @Test func recordedPlanFileWriteReachesPlanApproval() async throws {
        let replay = try await replayClaudeRecording("plan-mode", mode: .plan)
        let firstHook = try #require(replay.events.compactMap { event -> AgentTool? in
            if case .request(let request) = event.kind, case .preToolUse(let tool) = request.kind { return tool }
            return nil
        }.first)
        #expect(firstHook.name == "Write")
        #expect(firstHook.input["file_path"]?.stringValue == "/tmp/redacted")
        guard case .plan = try #require(replay.approvals.first).kind else {
            Issue.record("Expected native plan approval after the plan-file write")
            return
        }
        // After plan approval the recording switches native mode and asks
        // separately about the workspace Write and Bash actions.
        #expect(replay.approvals.count == 3)
        #expect(!replay.audit.contains { $0.kind == .confirmationDenied })
    }

    @Test(arguments: [AgentMode.ask, .acceptEdits, .plan, .auto])
    func recordedHookDeniesInjectedForbiddenTool(mode: AgentMode) async throws {
        let name = mode == .plan ? "plan-mode" : mode == .ask ? "ask-mode" : "accept-edits"
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/claude/\(name).jsonl")
        let data = try Data(contentsOf: url).base64EncodedString()
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
frames=[json.loads(line) for line in base64.b64decode('\(data)').decode().splitlines() if line.startswith('{')]
# Reuse the recorded hook envelope, injecting a forbidden service action.
hook=next(frame for frame in frames if frame.get('type')=='control_request' and frame['request'].get('callback_id')=='pre')
hook['request']['input']['tool_name']='mail.send'
hook['request']['input']['tool_input']={}
emit(hook)
reply=read()['response']
assert reply['request_id']==hook['request_id']
assert reply['response']['continue']==False
open('done','w').close()
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test", mode: mode))
        let audit = FakeActionAudit()
        let coordinator = AgentActionCoordinator(run: run, mode: mode, provenance: .init(chatID: UUID())) {
            try await audit.record($0)
        }
        try await coordinator.send(.init(text: "test"), willDeliver: {})
        for try await event in coordinator.events { if case .turnEnded = event.kind { break } }
        #expect(await coordinator.pendingRequests().isEmpty)
        #expect(await audit.events.filter { $0.kind == .confirmationDenied }.count == 1)
        try fixture.assertComplete()
        try await coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], [AgentMode.ask, .acceptEdits, .plan, .auto])
    func nativePermissionsNeedUserRegardlessOfRisk(provider: AgentProvider, mode: AgentMode) async throws {
        let fixture = try ActionFixture(provider: provider, mode: mode)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        for name in ["Read", "Write", "Bash"] {
            let request = await fixture.run.request(.permission(.init(name: name, input: .null)))
            try await waitForPending(fixture.coordinator)
            #expect(await fixture.coordinator.pendingRequests() == [request])
            try await fixture.coordinator.respond(to: request, with: .deny)
        }
        let grant = await fixture.run.request(.permissions(.object([:])))
        try await waitForPending(fixture.coordinator)
        #expect(await fixture.coordinator.pendingRequests() == [grant])
        try await fixture.coordinator.respond(to: grant, with: .deny)
        #expect(await fixture.run.responses == Array(repeating: .deny, count: 4))
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex], [AgentMode.ask, .acceptEdits, .plan, .auto])
    func explicitWhitelistAllowsPermissionsButCannotAllowForbiddenTools(provider: AgentProvider, mode: AgentMode) async throws {
        let fixture = try ActionFixture(provider: provider, mode: mode,
            policy: .init(whitelist: ["provider.Bash", "provider.mail.send"]))
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        _ = await fixture.run.request(.permission(.init(name: "Bash", input: .object(["command": .string("echo test")]))))
        try await waitForResponses(fixture.run)
        #expect(await fixture.run.responses == [.allow(updatedInput: nil)])
        _ = await fixture.run.request(.permission(.init(name: "mail.send", input: .null)))
        try await waitForResponses(fixture.run, count: 2)
        #expect(await fixture.run.responses == [.allow(updatedInput: nil), .deny])
        #expect(await fixture.coordinator.pendingRequests().isEmpty)
        #expect(await fixture.run.executions == 1)
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func unknownRequestsAndUncertainOutcomes(provider: AgentProvider) async throws {
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        _ = await fixture.run.request(.unknown(method: "future", parameters: .null))
        try await waitForResponses(fixture.run)
        #expect(await fixture.run.responses == [.unsupported])
        await fixture.run.emit(.turnEnded(.failed(.unknown)))
        var outcome: AgentTurnOutcome?
        for try await event in fixture.coordinator.events {
            if case .turnEnded(let value) = event.kind { outcome = value; break }
        }
        #expect(outcome == .failed(.unknown))
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func itemEventsAreAuditedWithoutRawContent(provider: AgentProvider) async throws {
        let fixture = try ActionFixture(provider: provider)
        try await fixture.coordinator.send(fixture.input, willDeliver: {})
        await fixture.run.emit(.toolStarted(.init(name: "commandExecution", input: .string("secret-test-content"))))
        await fixture.run.emit(.toolFinished(output: .string("secret-test-content"), isError: true))
        await fixture.run.emit(.fileChanged(path: "secret-test-content", diff: "secret-test-content"))
        await fixture.run.emit(.turnEnded(.completed))
        for try await event in fixture.coordinator.events { if case .turnEnded = event.kind { break } }
        let events = await fixture.audit.events
        #expect(events.count == 3)
        #expect(events[1].summary == "Provider action: observed failure")
        #expect(!events.contains { ($0.detailJSON ?? "").contains("secret-test-content") })
        try await fixture.coordinator.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func realStoreAuditSink(provider: AgentProvider) async throws {
        let stores = try inMemoryStores()
        let run = FakeActionRun(provider: provider)
        let coordinator = AgentActionCoordinator(run: run, mode: .ask, provenance: .init(chatID: UUID())) {
            _ = try stores.record($0)
        }
        try await coordinator.send(.init(text: "test"), willDeliver: {})
        _ = await run.request(.preToolUse(.init(name: "Read", input: .null)))
        try await waitForResponses(run)
        #expect(await run.responses == [.continueHook])
        try await coordinator.shutdown()
    }
}

private func replayClaudeRecording(_ name: String, mode: AgentMode) async throws -> (
    approvals: [AgentRequest], events: [AgentEvent], audit: [ActivityEvent]
) {
    let fixture = try BackendExecutableFixture(provider: "claude", name: name)
    defer { fixture.remove() }
    let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
    let run = try await backend.start(.init(directory: fixture.directory, model: "haiku", mode: mode))
    let audit = FakeActionAudit()
    let coordinator = AgentActionCoordinator(run: run, mode: mode, provenance: .init(chatID: UUID())) {
        try await audit.record($0)
    }
    do {
        try await coordinator.send(.init(text: try fixture.prompt(provider: "claude", name: name)), willDeliver: {})
        var events: [AgentEvent] = [], approvals: [AgentRequest] = []
        for try await event in coordinator.events {
            events.append(event)
            if case .request(let request) = event.kind {
                let pending = await coordinator.pendingRequests()
                switch request.kind {
                case .preToolUse, .postToolUse:
                    // Fail immediately on a hook card instead of leaving the
                    // replay blocked forever waiting for an automatic reply.
                    try #require(!pending.contains { $0.id == request.id })
                default:
                    try #require(pending == [request])
                    approvals.append(request)
                    try await coordinator.respond(to: request, with: .allow(updatedInput: nil))
                }
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(events.last?.kind == .turnEnded(.completed))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        let saved = await audit.events
        try await coordinator.shutdown()
        return (approvals, events, saved)
    } catch {
        try? await coordinator.shutdown()
        throw error
    }
}

private struct ActionFixture {
    let run: FakeActionRun
    let audit = FakeActionAudit()
    let coordinator: AgentActionCoordinator
    let input = AgentInput(text: "test")
    let chat = UUID()
    let parent = UUID()

    init(provider: AgentProvider, mode: AgentMode = .ask, policy: AutonomyPolicy = AutonomyPolicy()) throws {
        run = FakeActionRun(provider: provider)
        let audit = audit
        coordinator = AgentActionCoordinator(run: run, mode: mode,
            provenance: .init(chatID: chat, causedBy: parent, sourceID: "source-test"), policy: policy) {
                try await audit.record($0)
            }
    }
}

private actor FakeActionAudit {
    private(set) var events: [ActivityEvent] = []
    private var failureAfter: Int?
    private var pauseAfter: Int?
    private var waiter: CheckedContinuation<Void, Never>?
    var isPaused: Bool { waiter != nil }
    func pause(after count: Int) { pauseAfter = count }
    func resume() { waiter?.resume(); waiter = nil }
    func fail(after count: Int) { failureAfter = count }
    func record(_ event: ActivityEvent) async throws {
        if let pauseAfter, events.count == pauseAfter {
            self.pauseAfter = nil
            await withCheckedContinuation { waiter = $0 }
        }
        if let failureAfter, events.count >= failureAfter { throw AgentFailure.unknown }
        events.append(event)
    }
}

/// Both provider variants implement the same run contract. Protocol wire
/// formats are separately covered by ClaudeBackendTests/CodexBackendTests.
private actor FakeActionRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    private let provider: AgentProvider
    private var inputID: UUID?
    private var nextID: Int64 = 0
    private(set) var responses: [AgentResponse] = []
    private(set) var executions = 0
    init(provider: AgentProvider) {
        self.provider = provider
        (events, continuation) = AsyncThrowingStream.makeStream()
    }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws {
        try await willDeliver(); inputID = input.id
    }
    func respond(to request: AgentRequest, with response: AgentResponse) {
        responses.append(response)
        if case .allow = response { executions += 1 }
        if case .continueHook = response { executions += 1 }
    }
    func setMode(_ mode: AgentMode) {}
    func interrupt() { emit(.turnEnded(.interrupted)) }
    func shutdown() { continuation.finish() }
    func exit() { continuation.finish(throwing: AgentFailure.crashed(exitCode: 1)) }
    private var scope: AgentEventScope {
        .init(runID: id, session: .init(provider: provider, profile: "test", nativeID: "session-test"),
              inputID: inputID, turnID: "turn-test", itemID: "item-test")
    }
    func request(_ kind: AgentRequest.Kind) -> AgentRequest {
        nextID += 1
        let request = AgentRequest(id: provider == .claude ? .string("request-\(nextID)") : .integer(nextID), scope: scope, kind: kind)
        emit(.request(request))
        return request
    }
    func emit(_ kind: AgentEvent.Kind) { continuation.yield(.init(scope: scope, kind: kind)) }
}

private func waitForPending(_ coordinator: AgentActionCoordinator) async throws {
    for _ in 0..<200 {
        if await !coordinator.pendingRequests().isEmpty { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}

private func waitForResponses(_ run: FakeActionRun, count: Int = 1) async throws {
    for _ in 0..<200 {
        if await run.responses.count >= count { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw AgentFailure.offline
}
