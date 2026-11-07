import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite struct OpencodeBackendTests {
    @Test func replayAllowRejectAndStop() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/opencode/allow-deny-stop.jsonl")
        let events = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONValue.parse(String($0)))
        }
        let wire = OpencodeFakeTransport(recording: events)
        let backend = localBackend(wire)
        #expect(try await backend.status().authentication == .local)
        let run = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp/project"), model: "test-model"))
        var iterator = run.events.makeAsyncIterator()
        var all: [AgentEvent] = []
        for step in 0..<3 {
            try await run.send(.init(text: "Test local turn"), willDeliver: {})
            if step == 2 { try await run.interrupt() }
            var requested = false, ended = false
            while let event = try await iterator.next() {
                all.append(event)
                if case .request(let request) = event.kind {
                    requested = true
                    try await run.respond(to: request, with: step == 0 ? .allow(updatedInput: nil) : .deny)
                    await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
                }
                if case .turnEnded(let outcome) = event.kind {
                    #expect(outcome == (step == 0 ? .completed : .interrupted)); ended = true; break
                }
            }
            #expect(ended)
            if step < 2 { #expect(requested) }
        }
        #expect(all.contains { if case .textDelta = $0.kind { true } else { false } })
        #expect(all.contains { if case .thinkingDelta = $0.kind { true } else { false } })
        #expect(all.contains { if case .toolStarted(let tool) = $0.kind { tool.input["command"]?.stringValue != nil } else { false } })
        #expect(all.contains { if case .toolFinished(_, false) = $0.kind { true } else { false } })
        #expect(all.contains { if case .toolFinished(_, true) = $0.kind { true } else { false } })
        #expect(all.contains { if case .usage = $0.kind { true } else { false } })
        let decisions = await wire.calls.filter { $0.path.hasSuffix("/reply") }.map { $0.body?["decision"]?.stringValue }
        #expect(decisions == ["once", "reject"])
        #expect(await wire.calls.contains { $0.path.hasSuffix("/interrupt") })
        try await run.shutdown(); await backend.shutdown()
    }

    @Test func unknownEventsAreBoundedAndNeverForwardTheirPayload() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Hello"), willDeliver: {})
        await run.receive(localEvent("future.event", ["credential": .string("transient-test-password")]))
        await run.receive(localEvent("session.execution.succeeded"))
        var sawUnknown = false
        for try await event in run.events {
            if case .unknown(let name, let payload) = event.kind {
                #expect(name == "opencode.event"); #expect(payload == .null); sawUnknown = true
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(sawUnknown)
        try await run.shutdown()
    }

    @Test func durableBarrierPrecedesHTTPAndFailureSendsNothing() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        await #expect(throws: AgentFailure.offline) {
            try await run.send(.init(text: "Not delivered"), willDeliver: { throw AgentFailure.offline })
        }
        #expect(await wire.calls.isEmpty)
        #expect(await !run.isActive)
        try await run.send(.init(text: "Delivered"), willDeliver: {})
        #expect(await wire.calls.count == 1)
        await wire.setFailure(true)
        await #expect(throws: AgentFailure.offline) { try await run.interrupt() }
        await run.abort()
        #expect(await wire.closes == 1)
    }

    @Test func queuedFollowupUsesDeliveryAndActivatesCorrectInput() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let first = AgentInput(text: "First"), next = AgentInput(text: "Next")
        try await run.send(first, willDeliver: {})
        try await run.followup(next, willDeliver: {})
        #expect(await wire.calls.last?.body?["delivery"]?.stringValue == "queue")
        await run.receive(localEvent("session.execution.succeeded"))
        await run.receive(localEvent("session.inbox.delivered", ["inboxID": .string("msg_" + next.id.uuidString)]))
        await run.receive(localEvent("session.text.delta", ["delta": .string("Next reply")]))
        await run.receive(localEvent("session.execution.succeeded"))
        var activated = false, outputs: [UUID?] = [], ended: [UUID?] = []
        for try await event in run.events {
            if case .inputActivated = event.kind { activated = true; #expect(event.scope.inputID == next.id) }
            if case .textDelta = event.kind { outputs.append(event.scope.inputID) }
            if case .turnEnded = event.kind { ended.append(event.scope.inputID); if ended.count == 2 { break } }
        }
        #expect(activated); #expect(outputs == [next.id]); #expect(ended == [first.id, next.id])
        try await run.shutdown()
    }

    @Test func resumesNativeLocalSessionAndEnforcesRoots() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        let run = try await backend.start(localConfiguration)
        try await run.send(.init(text: "Keep running"), willDeliver: {})
        await #expect(throws: AgentFailure.invalidTransition) {
            _ = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp/other-project"), model: "test-model"))
        }
        await wire.emit(localEvent("session.execution.succeeded"))
        try await waitOpencode { !(await (run as? OpencodeRun)?.isActive ?? true) }
        try await run.shutdown()
        let resumed = try await backend.start(.init(directory: localConfiguration.directory, resume: localSession, model: "test-model", mode: .plan))
        #expect(await wire.opens == 1)
        #expect(await wire.calls.filter { $0.path == "api/session" && $0.method == "POST" }.count == 1)
        #expect(await wire.calls.contains { $0.path == "api/session/ses_fixture/model" })
        try await resumed.shutdown()
        let other = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp/other-project"), model: "test-model"))
        #expect(await wire.opens == 2)
        try await other.shutdown(); await backend.shutdown()
    }

    @Test func unavailableAndMissingModelsFailClosed() async throws {
        let wire = OpencodeFakeTransport()
        let backend = OpencodeBackend(transport: wire, catalog: { throw AgentFailure.offline })
        #expect(try await backend.status().authentication == .unavailable)
        await #expect(throws: AgentFailure.offline) { _ = try await backend.start(localConfiguration) }
        #expect(await wire.opens == 0)
        let filtered = OpencodeBackend(transport: wire, catalog: { [.init(id: "test-cloud", name: "Remote")] })
        #expect(try await filtered.models().isEmpty)
        await #expect(throws: AgentFailure.unsupported) { _ = try await filtered.start(localConfiguration) }
        let missing = OpencodeBackend(executable: URL(fileURLWithPath: "/nonexistent/opencode"), environment: [:],
            configuration: .init(root: URL(fileURLWithPath: "/tmp/profile/Opencode")))
        #expect(try await missing.status().installed == false)
        await #expect(throws: AgentFailure.notInstalled) { _ = try await missing.start(localConfiguration) }
    }

    @Test func rejectsBogusSessionPermissionAndWrongGeneration() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        await #expect(throws: AgentFailure.invalidRequest) {
            _ = try await backend.start(.init(directory: localConfiguration.directory,
                resume: .init(provider: .local, profile: "opencode", nativeID: "../bad"), model: "test-model"))
        }
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let input = AgentInput(text: "Permission")
        try await run.send(input, willDeliver: {})
        let request = AgentRequest(id: .string("permission_test"), scope: .init(runID: UUID(), session: localSession, inputID: input.id),
            kind: .permission(.init(name: "bash", input: .null)))
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .allow(updatedInput: nil)) }
        await run.receive(localEvent("permission.asked", ["id": .string("../bad"), "action": .string("bash")]))
        #expect(await wire.closes == 1)
        await backend.shutdown()
    }
}

let localSession = AgentSessionID(provider: .local, profile: "opencode", nativeID: "ses_fixture")
let localConfiguration = AgentSessionConfiguration(directory: URL(fileURLWithPath: "/tmp/project"), model: "test-model")
func localEvent(_ type: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
    .object(["type": .string(type), "data": .object(extra.merging(["sessionID": .string("ses_fixture")]) { _, right in right })])
}
func localBackend(_ transport: OpencodeFakeTransport) -> OpencodeBackend {
    OpencodeBackend(transport: transport, catalog: { [.init(id: "test-model", name: "Test model")] })
}
func waitOpencode(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(5))
    }
}

actor OpencodeFakeTransport: OpencodeTransport {
    struct Call: Sendable { let path: String; let method: String; let body: JSONValue? }
    private(set) var calls: [Call] = []
    private(set) var opens = 0
    private(set) var closes = 0
    private var continuation: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var recording: [JSONValue]
    private var failure = false
    private var promptNumber = 0
    private var pausePrompt = false
    private var promptWaiter: CheckedContinuation<Void, Never>?
    var promptIsPaused: Bool { promptWaiter != nil }
    func pauseNextPrompt() { pausePrompt = true }
    func releasePrompt() { promptWaiter?.resume(); promptWaiter = nil }
    init(recording: [JSONValue] = []) { self.recording = recording }
    func setFailure(_ value: Bool) { failure = value }
    func open(projects: [URL], models: [AgentModel]) { opens += 1 }
    func subscribe() -> AsyncThrowingStream<JSONValue, Error> {
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        self.continuation = continuation; return stream
    }
    func emit(_ value: JSONValue) { continuation?.yield(value) }
    private func advance() {
        while !recording.isEmpty {
            let value = recording.removeFirst(); emit(value)
            if ["permission.asked", "session.execution.succeeded", "session.execution.interrupted"].contains(value["type"]?.stringValue ?? "") { break }
        }
    }
    func request(_ path: String, method: String, body: JSONValue?) async throws -> JSONValue {
        calls.append(.init(path: path, method: method, body: body))
        if failure { throw AgentFailure.offline }
        if path == "api/session", method == "POST" {
            return .object(["data": .object(["id": .string("ses_fixture")])])
        }
        if path == "api/session/ses_fixture", method == "GET" {
            return .object(["data": .object(["id": .string("ses_fixture"),
                "location": .object(["directory": .string(localConfiguration.directory.resolvingSymlinksInPath().path)]),
                "model": .object(["providerID": .string("ollama")])])])
        }
        if path.hasSuffix("/prompt") {
            if pausePrompt {
                pausePrompt = false
                await withCheckedContinuation { promptWaiter = $0 }
            }
            promptNumber += 1
            if promptNumber < 3 { advance() }
            return .object(["data": .object(["id": body?["id"] ?? .null, "sessionID": .string("ses_fixture")])])
        }
        if path.hasSuffix("/reply") || path.hasSuffix("/interrupt") { advance() }
        return .null
    }
    func close() { closes += 1; continuation?.finish(); continuation = nil }
}

extension OpencodeBackendTests {
    @Test func reasoningUpdatesOneThinkingRowBeforePromptAcknowledgement() async throws {
        let wire = OpencodeFakeTransport()
        await wire.pauseNextPrompt()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let input = AgentInput(text: "Think about an example")
        let progress = LocalReasoningProgress(input: input)
        let reader = Task {
            for try await event in run.events { await progress.receive(event) }
        }
        let send = Task { try await run.send(input, willDeliver: {}) }
        try await waitOpencode { await wire.promptIsPaused }
        await run.receive(localEvent("session.execution.started"))
        await run.receive(localEvent("session.inbox.delivered", ["inboxID": .string("msg_" + input.id.uuidString)]))
        await run.receive(localEvent("session.reasoning.started", ["assistantMessageID": .string("thought")]))
        try await waitOpencode { await progress.state.entries.contains { $0.kind == "thinking" } }
        let row = try #require(await progress.state.entries.last?.id)
        for delta in ["Consider ", "the example."] {
            await run.receive(localEvent("session.reasoning.delta", ["assistantMessageID": .string("thought"), "delta": .string(delta)]))
        }
        try await waitOpencode { await progress.state.thinking == "Consider the example." }
        #expect(await progress.state.entries.last?.id == row)
        #expect(await progress.state.isRunning)
        #expect(await !progress.kinds.contains(.delivery(.acknowledged)))
        #expect(await !progress.state.entries.contains { $0.kind == "assistant" })
        await run.receive(localEvent("session.reasoning.ended", ["assistantMessageID": .string("thought"), "text": .string("Consider the example.")]))
        await run.receive(localEvent("session.execution.succeeded"))
        #expect(await progress.state.isRunning)
        await wire.releasePrompt()
        try await send.value
        try await waitOpencode { await progress.state.outcome == .completed }
        #expect(await progress.state.entries.filter { $0.kind == "thinking" }.count == 1)
        #expect(await progress.state.entries.last?.id == row)
        #expect(await progress.state.thinking == "Consider the example.")
        try await run.shutdown(); try await reader.value
    }

    @Test func queuedReasoningCannotLeakAcrossBufferedInputActivation() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let first = AgentInput(text: "First"), next = AgentInput(text: "Next")
        try await run.send(first, willDeliver: {})
        await wire.pauseNextPrompt()
        let send = Task { try await run.followup(next, willDeliver: {}) }
        try await waitOpencode { await wire.promptIsPaused }
        await run.receive(localEvent("session.execution.succeeded"))
        await run.receive(localEvent("session.inbox.delivered", ["inboxID": .string("msg_" + next.id.uuidString)]))
        await run.receive(localEvent("session.reasoning.delta", ["delta": .string("Next thought")]))
        await wire.releasePrompt()
        try await send.value
        await run.receive(localEvent("session.execution.succeeded"))
        var thoughts: [UUID?] = [], ended = 0
        for try await event in run.events {
            if case .thinkingDelta = event.kind { thoughts.append(event.scope.inputID) }
            if case .turnEnded = event.kind { ended += 1; if ended == 2 { break } }
        }
        #expect(thoughts == [next.id])
        try await run.shutdown()
    }

    @Test func fastSSECompletionWaitsForHTTPDeliveryAcknowledgement() async throws {
        let wire = OpencodeFakeTransport()
        await wire.pauseNextPrompt()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let input = AgentInput(text: "Fast turn")
        let send = Task { try await run.send(input, willDeliver: {}) }
        try await waitOpencode { await wire.promptIsPaused }
        await run.receive(localEvent("session.text.delta", ["delta": .string("Fast reply")]))
        await run.receive(localEvent("session.execution.succeeded"))
        #expect(await run.isActive)
        await wire.releasePrompt()
        try await send.value
        var kinds: [AgentEvent.Kind] = []
        for try await event in run.events {
            kinds.append(event.kind)
            if case .turnEnded = event.kind { break }
        }
        #expect(kinds == [.delivery(.acknowledged), .textDelta("Fast reply"), .turnEnded(.completed)])
        try await run.shutdown()
    }
}

extension OpencodeBackendTests {
    @Test func missingOpencodeUsesTextOnlyFallbackWithoutAnEnvironmentSwitch() async throws {
        let backend = LocalChatBackendFactory.make(executable: URL(fileURLWithPath: "/nonexistent/opencode"),
            environment: [:], reply: { _, _ in AsyncThrowingStream { $0.yield("Local fallback"); $0.finish() } })
        #expect(backend is LocalBackend)
        #expect(try await backend.status().authentication == .local)
        #expect(try await backend.status().capabilities.isEmpty)
        let run = try await backend.start(localConfiguration)
        try await run.send(.init(text: "Hello"), willDeliver: {})
        var text = ""
        for try await event in run.events {
            if case .textDelta(let delta) = event.kind { text += delta }
            if case .turnEnded = event.kind { break }
        }
        #expect(text == "Local fallback")
        try await run.shutdown()
    }

    @Test(arguments: [AgentMode.ask, .acceptEdits, .auto])
    func localEditsFollowModeAndShellAlwaysNeedsApproval(mode: AgentMode) async throws {
        for tool in ["edit", "bash", "read"] {
            let wire = OpencodeFakeTransport()
            let config = AgentSessionConfiguration(directory: localConfiguration.directory, model: "test-model", mode: mode)
            let raw = OpencodeRun(transport: wire, session: localSession, configuration: config, release: { _ in })
            let audit = LocalAuditCounter()
            let coordinator = AgentActionCoordinator(run: raw, mode: mode, provenance: .init(chatID: UUID()), audit: { await audit.record($0) })
            try await coordinator.send(.init(text: "Test action"), willDeliver: {})
            await raw.receive(localEvent("session.tool.input.started", ["id": .string("tool_test"), "name": .string(tool)]))
            await raw.receive(localEvent("session.tool.called", ["id": .string("tool_test"), "input": .object(["command": .string("printf example > example.txt")])]))
            await raw.receive(localEvent("permission.asked", ["id": .string("permission_test"), "action": .string(tool),
                "source": .object(["id": .string("tool_test")])]))
            let autoAllowed = tool == "read" || (tool == "edit" && mode != .ask)
            if autoAllowed {
                try await waitOpencode { await wire.calls.contains { $0.path.hasSuffix("/reply") } }
                #expect(await wire.calls.last?.body?["decision"] == .string("once"))
                #expect(await coordinator.pendingRequests().isEmpty)
            } else {
                try await waitOpencode { await coordinator.pendingRequests().count == 1 }
                #expect(await !wire.calls.contains { $0.path.hasSuffix("/reply") })
                let request = try #require(await coordinator.pendingRequests().first)
                try await coordinator.respond(to: request, with: .deny)
            }
            #expect(await audit.count > 0)
            await raw.receive(localEvent("session.execution.interrupted"))
            try await coordinator.shutdown()
        }
    }
}
private actor LocalAuditCounter {
    private(set) var count = 0
    func record(_ event: ActivityEvent) { count += 1 }
}

private actor LocalReasoningProgress {
    private(set) var state: ChatState
    private(set) var kinds: [AgentEvent.Kind] = []
    init(input: AgentInput) {
        let chat = UUID()
        state = ChatState(chatID: chat)
        state.begin(input, session: .init(chatID: chat, provider: .local, cwd: "/tmp", model: "test-model"), outputID: UUID())
    }
    func receive(_ event: AgentEvent) {
        kinds.append(event.kind)
        state.reduce(event, newEntryID: UUID())
    }
}
