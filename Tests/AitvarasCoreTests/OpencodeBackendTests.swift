import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite struct OpencodeBackendTests {
    @Test func replayRecordedSessionDoesNotCancelInformationalEvents() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/opencode/allow-deny-stop.jsonl")
        let hostRecording = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/agent-recordings/opencode/session-allow-deny-stop.jsonl")
        // Replay the host evidence when available; public CI uses its sanitized
        // projection, including informational events the old fixture omitted.
        let source = FileManager.default.fileExists(atPath: hostRecording.path) ? hostRecording : fixture
        let events = try opencodeRecordingEvents(source)
        #expect(events.contains { $0["type"] == .string("session.instructions.updated") })
        #expect(events.contains { $0["type"] == .string("project.updated") })
        let wire = OpencodeFakeTransport(recording: events)
        let backend = localBackend(wire)
        #expect(try await backend.status().authentication == .local)
        let run = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp/project"), model: "test-model"))
        var iterator = run.events.makeAsyncIterator()
        var all: [AgentEvent] = []
        for step in 0..<3 {
            try await run.send(.init(text: "Test local turn"), willDeliver: {})
            if step == 2 { try await run.interrupt() }
            var requested = false, ended = false, text = ""
            while let event = try await iterator.next() {
                all.append(event)
                if case .textDelta(let delta) = event.kind { text += delta }
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
            #expect(!text.contains("Not supported"))
            if step == 0 { #expect(!text.isEmpty) }
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
        #expect(events.filter { $0["type"] == .string("permission.replied") }
            .compactMap { $0["data"]?["reply"]?.stringValue } == decisions)
        #expect(await wire.calls.contains { $0.path.hasSuffix("/interrupt") })
        try await run.shutdown(); await backend.shutdown()
    }

    @Test func informationalAndUnknownEventsNeverInterrupt() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        let run = try await backend.start(localConfiguration)
        try await run.send(.init(text: "Hello"), willDeliver: {})
        for type in ["session.instructions.updated", "session.inbox.enqueued", "session.inbox.delivered",
                     "session.usage.updated", "project.updated", "plugin.updated", "session.status",
                     "future.event", "future.request.asked"] {
            for sessionScoped in [false, true] {
                var data: [String: JSONValue] = ["credential": .string("never-forward")]
                if sessionScoped { data["sessionID"] = .string("ses_fixture") }
                await wire.emit(.object(["type": .string(type), "data": .object(data)]))
            }
        }
        await wire.emit(localEvent("session.text.delta", ["delta": .string("Hello back")]))
        await wire.emit(localEvent("session.execution.succeeded"))
        var kinds: [AgentEvent.Kind] = []
        for try await event in run.events {
            kinds.append(event.kind)
            if case .turnEnded = event.kind { break }
        }
        #expect(kinds == [.sessionStarted(localSession), .delivery(.acknowledged),
                          .textDelta("Hello back"), .turnEnded(.completed)])
        #expect(await !wire.calls.contains { $0.path.hasSuffix("/interrupt") })
        try await run.shutdown(); await backend.shutdown()
    }

    @Test func nestedFormRoutesThroughBackendAndAuditedQuestionCard() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        #expect(try await !backend.status().capabilities.contains(.questions))
        let raw = try await backend.start(localConfiguration)
        let run = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), audit: { _ in })
        try await run.send(.init(text: "Ask a question"), willDeliver: {})
        await wire.emit(localEvent("permission.asked", ["id": .string("permission_question"), "action": .string("question")]))
        try await waitOpencode { await wire.calls.contains { $0.body?["decision"]?.stringValue == "once" } }
        #expect(await run.pendingRequests().isEmpty)
        // Unlike permission events, the session ID is nested inside data.form.
        await wire.emit(formCreated(questionForm))
        try await waitOpencode { await run.pendingRequests().count == 1 }
        let request = try #require(await run.pendingRequests().first)
        guard case .questions(let questions) = request.kind else { Issue.record("Missing questions"); return }
        #expect(questions[0].prompt == "Approval\nWhich color?")
        #expect(questions[0].options.map(\.label) == ["Blue", "Green"])
        #expect(questions[0].options[0].description == "Cool")
        var draft = AgentQuestionState(questions: questions)
        try draft.select("Blue", for: "color")
        try await run.respond(to: request, with: .answers(try #require(draft.answers)))
        let reply = try #require(await wire.calls.last)
        #expect(reply.path == "api/session/ses_fixture/form/frm_question/reply")
        #expect(reply.method == "POST")
        #expect(reply.body == .object(["answer": .object(["color": .string("blue_value")])]))
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
        await wire.emit(localEvent("session.execution.succeeded"))
        try await waitOpencode { await (raw as? OpencodeRun)?.isActive == false }
        try await run.shutdown(); await backend.shutdown()
    }

    @Test func formMapsMultipleAndTextAnswersAndValidatesBeforeHTTP() async throws {
        let form = try OpencodeForm(.object(["title": .string("Choose"), "fields": .array([
            .object(["key": .string("many"), "type": .string("multiselect"), "title": .string("Features?"),
                "custom": .bool(true), "minItems": .number(1), "options": .array([
                    .object(["label": .string("Fast"), "value": .string("fast_value")])])]),
            .object(["key": .string("text"), "type": .string("string"), "title": .string("Details?")])])]))
        var draft = AgentQuestionState(questions: form.questions)
        try draft.select("Fast", for: "many")
        try draft.setText("Quiet", for: "many")
        try draft.setText(" Example ", for: "text")
        #expect(try form.reply(try #require(draft.answers)) == .object(["answer": .object([
            "many": .array([.string("fast_value"), .string("Quiet")]), "text": .string("Example")])]))

        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Question"), willDeliver: {})
        await run.receive(formCreated(questionForm))
        var iterator = run.events.makeAsyncIterator()
        let request = try await nextOpencodeRequest(&iterator)
        for answers in [["unknown": ["Blue"]], ["color": []], ["color": ["Other"]], ["color": ["Blue", "Green"]]] {
            await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .answers(answers)) }
        }
        #expect(await wire.calls.count == 1)
        await run.receive(localEvent("form.cancelled", ["id": .string("frm_question")]))
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .answers(["color": ["Blue"]])) }
        try await run.shutdown()
    }

    @Test func unsupportedFormRulesAndMalformedChoicesAreRejected() throws {
        let fields: [JSONValue] = [
            .object(["key": .string("q"), "type": .string("string"), "pattern": .string(".*")]),
            .object(["key": .string("q"), "type": .string("string"), "hidden": .bool(true)]),
            .object(["key": .string("q"), "type": .string("string"), "future-control": .bool(true)]),
            .object(["key": .string("q"), "type": .string("multiselect"), "minItems": .number(2), "options": .array([])]),
            .object(["key": .string("q"), "type": .string("string"), "options": .array([
                .object(["label": .string("Same"), "value": .string("one")]),
                .object(["label": .string("Same"), "value": .string("two")])])])
        ]
        for field in fields {
            #expect(throws: (any Error).self) {
                _ = try OpencodeForm(.object(["title": .string("Question"), "fields": .array([field])]))
            }
        }
    }

    @Test(arguments: [AgentResponse.deny, .unsupported, .answers(["color": ["Blue"]])])
    func formCancellationRepliesAndHTTPFailureCannotHang(response: AgentResponse) async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Question"), willDeliver: {})
        await run.receive(formCreated(questionForm))
        var iterator = run.events.makeAsyncIterator()
        let request = try await nextOpencodeRequest(&iterator)
        if case .answers = response {
            await wire.setFailure(true)
            await #expect(throws: AgentFailure.offline) { try await run.respond(to: request, with: response) }
            #expect(await !run.isActive); #expect(await wire.closes == 1)
        } else {
            try await run.respond(to: request, with: response)
            #expect(await wire.calls.last?.method == "DELETE")
            #expect(await wire.calls.last?.path == "api/session/ses_fixture/form/frm_question")
            await run.receive(localEvent("session.execution.succeeded"))
            #expect(await !run.isActive)
            try await run.shutdown()
        }
    }

    @Test(arguments: ["external", "future-control", "number"])
    func unsupportedFormsAreCancelledAndVisible(type: String) async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Unsupported form"), willDeliver: {})
        await run.receive(formCreated(.object(["id": .string("frm_unknown"), "sessionID": .string("ses_fixture"),
            "title": .string("Unknown"), "fields": .array([.object(["key": .string("q"), "type": .string(type)])]) ])))
        #expect(await wire.calls.last?.method == "DELETE")
        #expect(await wire.calls.last?.path == "api/session/ses_fixture/form/frm_unknown")
        // Cancellation allows the native tool to fail and the turn to continue.
        await run.receive(localEvent("session.execution.succeeded"))
        try await run.shutdown()
        var texts: [String] = [], cards = 0
        for try await event in run.events {
            if case .textDelta(let text) = event.kind { texts.append(text) }
            if case .request = event.kind { cards += 1 }
        }
        #expect(texts == ["\nNot supported here\n"]); #expect(cards == 0)
    }

    @Test(arguments: [false, true], ["question.asked"])
    func unsupportedBlockingQuestionReleasesQueuedInputsWithoutTerminalEvent(failure: Bool, type: String) async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        let first = AgentInput(text: "First"), next = AgentInput(text: "Follow-up")
        try await run.send(first, willDeliver: {})
        try await run.followup(next, willDeliver: {})
        await wire.setFailure(failure)
        await run.receive(localEvent(type, ["id": .string("request_unknown"), "credential": .string("never-forward"),
            "status": .object(["type": .string("future-wait")])]))
        #expect(await !run.isActive)
        #expect(await wire.calls.last?.path == "api/session/ses_fixture/interrupt")
        if !failure { try await run.shutdown() }
        var text = "", ended: [UUID?] = []
        do {
            for try await event in run.events {
                if case .textDelta(let delta) = event.kind { text += delta }
                if case .turnEnded(let outcome) = event.kind { #expect(outcome == .interrupted); ended.append(event.scope.inputID) }
                if case .unknown(_, let payload) = event.kind { #expect(payload == .null) }
            }
            #expect(!failure)
        } catch { #expect(failure); #expect(error as? AgentFailure == .offline) }
        #expect(text == "\nNot supported here\n")
        if !failure { #expect(ended == [first.id, next.id]) }
    }

    @Test func unscopedBlockingRequestDoesNotWaitSilently() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        let run = try await backend.start(localConfiguration)
        try await run.send(.init(text: "Hello"), willDeliver: {})
        await wire.emit(.object(["type": .string("server.connected"), "data": .object([:])]))
        await wire.emit(.object(["type": .string("permission.asked"), "data": .object(["id": .string("unknown")])]))
        try await waitOpencode { await (run as? OpencodeRun)?.isActive == false }
        #expect(await wire.calls.contains { $0.path.hasSuffix("/interrupt") })
        try await run.shutdown(); await backend.shutdown()
    }

    @Test func unsupportedBlockingQuestionClearsChatCardsAndFollowupDelivery() async throws {
        let stores = try inMemoryStores()
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let chat = try agentStoreChat(stores, provider: .local, cwd: "/tmp/project").0
        let first = AgentInput(text: "Ask me"), followup = AgentInput(text: "Follow-up")
        try await manager.send(chatID: chat.id, provider: .local, input: first)
        await wire.emit(formCreated(questionForm))
        try await waitOpencode { try await manager.state(chatID: chat.id).pendingCards.count == 1 }
        try await manager.send(chatID: chat.id, provider: .local, input: followup)
        await wire.emit(localEvent("question.asked", ["id": .string("unknown")]))
        try await waitOpencode { try stores.agentTurn(id: followup.id)?.state == .interrupted }
        let state = try await manager.state(chatID: chat.id)
        #expect(!state.isRunning); #expect(state.pendingCards.isEmpty)
        #expect(state.entries.contains { $0.text.contains("Not supported here") })
        let queued = try #require(state.entries.first { $0.id == followup.id })
        #expect(queued.payloadJSON.flatMap(JSONValue.parse)?["followup"]?.stringValue != "steering")
        #expect(try stores.agentTurn(id: first.id)?.state == .interrupted)
        // The provider switch uses the same manager busy state. Changing mode
        // proves that no hidden input/queue continues to reserve this chat.
        var session = try #require(try stores.agentSession(chatID: chat.id, provider: .local))
        session.mode = .plan
        try await manager.configure(session)
        try await manager.shutdown(); await backend.shutdown()
    }

    @Test func duplicateFormDoesNotResetCardAndResolutionRejectsLateAnswer() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Question"), willDeliver: {})
        await run.receive(formCreated(questionForm))
        await run.receive(formCreated(questionForm))
        await run.receive(localEvent("form.replied", ["id": .string("frm_question")]))
        await run.receive(formCreated(questionForm))
        await run.receive(localEvent("session.execution.succeeded"))
        try await run.shutdown()
        var requests: [AgentRequest] = [], resolutions = 0
        for try await event in run.events {
            if case .request(let request) = event.kind { requests.append(request) }
            if case .requestResolved = event.kind { resolutions += 1 }
        }
        #expect(requests.count == 1); #expect(resolutions == 1)
        let request = try #require(requests.first)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .answers(["color": ["Blue"]])) }
    }

    @Test(arguments: ["frm_../bad", "frm_missing"])
    func malformedOrUncancellableFormInterruptsInsteadOfWaiting(formID: String) async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Question"), willDeliver: {})
        if formID == "frm_missing" { await wire.failNextFormCancellation() }
        await run.receive(formCreated(.object(["id": .string(formID), "sessionID": .string("ses_fixture"),
            "title": .string("Unsupported"), "fields": .array([])])))
        #expect(await !run.isActive)
        #expect(await wire.calls.last?.path.hasSuffix("/interrupt") == true)
        #expect(await !wire.calls.contains { $0.path.contains("..") })
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
        #expect(await wire.opens == 2)
        #expect(await wire.calls.filter { $0.path == "api/session" && $0.method == "POST" }.count == 1)
        #expect(await wire.calls.contains { $0.path == "api/session/ses_fixture/model" })
        try await resumed.shutdown()
        let other = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp/other-project"), model: "test-model"))
        #expect(await wire.opens == 3)
        try await other.shutdown(); await backend.shutdown()
    }

    @Test func finalRunShutdownClosesServerAndNextRunReopensIt() async throws {
        let wire = OpencodeFakeTransport()
        let backend = localBackend(wire)
        let run = try await backend.start(localConfiguration)
        #expect(await wire.closes == 0)
        try await run.shutdown()
        #expect(await wire.closes == 1)
        await backend.shutdown()
        #expect(await wire.closes == 1)
        let resumed = try await backend.start(.init(directory: localConfiguration.directory, resume: localSession, model: "test-model"))
        #expect(await wire.opens == 2)
        await backend.shutdown()
        #expect(await wire.closes == 2)
        #expect(await (resumed as? OpencodeRun)?.isActive == false)
    }

    @Test func shutdownDuringStartupCannotLeaveANewServerBehind() async throws {
        let wire = OpencodeFakeTransport()
        await wire.pauseNextOpen()
        let backend = localBackend(wire)
        let starting = Task { try await backend.start(localConfiguration) }
        try await waitOpencode { await wire.openIsPaused }
        await backend.shutdown()
        await wire.releaseOpen()
        await #expect(throws: AgentFailure.invalidTransition) { _ = try await starting.value }
        #expect(await wire.closes >= 1)
        #expect(await wire.calls.isEmpty)
    }

    @Test func shutdownClosesTransportEvenWhenInterruptFails() async throws {
        let wire = OpencodeFakeTransport()
        let run = OpencodeRun(transport: wire, session: localSession, configuration: localConfiguration, release: { _ in })
        try await run.send(.init(text: "Running"), willDeliver: {})
        await wire.setFailure(true)
        await #expect(throws: AgentFailure.offline) { try await run.shutdown() }
        #expect(await wire.closes == 1)
        #expect(await !run.isActive)
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

/// Keep protocol shape/order while replacing all host text and identifiers
/// before they can enter test assertions, events or diagnostics.
private func opencodeRecordingEvents(_ source: URL) throws -> [JSONValue] {
    var ids: [String: String] = [:]
    func scrub(_ value: JSONValue, key: String = "") -> JSONValue {
        switch value {
        case .object(let fields): return .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, scrub($0.value, key: $0.key)) }))
        case .array(let values): return .array(values.map { scrub($0, key: key) })
        case .string(let text):
            if key == "sessionID" { return .string("ses_fixture") }
            if ["id", "assistantMessageID", "requestID", "inboxID"].contains(key) {
                if ids[text] == nil { ids[text] = "fixture_\(ids.count + 1)" }
                return .string(ids[text]!)
            }
            if ["action", "name"].contains(key) { return .string("bash") }
            if key == "type" { return .string(text == "aborted" ? "aborted" : "fixture") }
            if key == "command" { return .string("printf example > local-made.txt") }
            if key == "reply", ["once", "reject"].contains(text) { return .string(text) }
            return .string("Local reply.")
        case .number: return .number(1)
        default: return value
        }
    }
    var result: [JSONValue] = []
    for line in try String(contentsOf: source, encoding: .utf8).split(separator: "\n") {
        guard let row = JSONValue.parse(String(line)) else { throw AgentFailure.invalidRequest }
        let event = row["type"] == nil ? row["data"] : row
        guard let event, let type = event["type"]?.stringValue, let data = event["data"] else { continue }
        var clean = scrub(data).objectValue ?? [:]
        if type == "session.tool.input.ended" {
            clean["text"] = .string(#"{"command":"printf example > local-made.txt"}"#)
        }
        let sanitized: JSONValue = .object(["type": .string(type), "data": .object(clean)])
        if result.last != sanitized { result.append(sanitized) }
    }
    return result
}

let localSession = AgentSessionID(provider: .local, profile: "opencode", nativeID: "ses_fixture")
let localConfiguration = AgentSessionConfiguration(directory: URL(fileURLWithPath: "/tmp/project"), model: "test-model")
private let questionForm: JSONValue = .object([
    "id": .string("frm_question"), "sessionID": .string("ses_fixture"), "title": .string("Question"),
    "fields": .array([.object([
        "key": .string("color"), "type": .string("string"), "title": .string("Approval"),
        "description": .string("Which color?"), "custom": .bool(false), "options": .array([
            .object(["value": .string("blue_value"), "label": .string("Blue"), "description": .string("Cool")]),
            .object(["value": .string("green_value"), "label": .string("Green")])])])])])
private func formCreated(_ form: JSONValue) -> JSONValue {
    .object(["type": .string("form.created"), "data": .object(["form": form])])
}
private func nextOpencodeRequest(_ iterator: inout AsyncThrowingStream<AgentEvent, Error>.Iterator) async throws -> AgentRequest {
    while let event = try await iterator.next() {
        if case .request(let request) = event.kind { return request }
    }
    throw AgentFailure.invalidRequest
}
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
    private var failFormCancellation = false
    private var promptNumber = 0
    private var pausePrompt = false
    private var promptWaiter: CheckedContinuation<Void, Never>?
    private var pauseOpen = false
    private var openWaiter: CheckedContinuation<Void, Never>?
    var openIsPaused: Bool { openWaiter != nil }
    func pauseNextOpen() { pauseOpen = true }
    func releaseOpen() { openWaiter?.resume(); openWaiter = nil }
    var promptIsPaused: Bool { promptWaiter != nil }
    func pauseNextPrompt() { pausePrompt = true }
    func releasePrompt() { promptWaiter?.resume(); promptWaiter = nil }
    init(recording: [JSONValue] = []) { self.recording = recording }
    func setFailure(_ value: Bool) { failure = value }
    func failNextFormCancellation() { failFormCancellation = true }
    func open(projects: [URL], models: [AgentModel]) async {
        opens += 1
        if pauseOpen {
            pauseOpen = false
            await withCheckedContinuation { openWaiter = $0 }
        }
    }
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
        if method == "DELETE", path.contains("/form/"), failFormCancellation {
            failFormCancellation = false; throw AgentFailure.offline
        }
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
