import Foundation
import Testing
@testable import AitvarasAgents

struct ClaudeBackendTests {
    @Test func defaultModelUsesNativeDefaultWithoutInventingAnID() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--model' not in sys.argv
claude_init()
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: ["aborted_streaming", "error_during_execution"])
    func interruptResultOverridesAssistantError(marker: String) async throws {
        let result = marker == "aborted_streaming"
            ? "{'type':'result','is_error':True,'terminal_reason':'aborted_streaming'}"
            : "{'type':'result','is_error':True,'subtype':'error_during_execution'}"
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'working'}}})
request=read()
assert request['request']['subtype']=='interrupt'
emit({'type':'assistant','error':'execution_error','message':{'role':'assistant','content':[]}})
emit(\(result))
# The result races ahead of the interrupt acknowledgement.
open('done','w').close()
emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{}}})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        let events = try await collectTurn(run, interrupt: true)
        #expect(events.last?.kind == .turnEnded(.interrupted))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: ["accept-edits", "ask-mode", "plan-mode", "question", "interrupt", "auth-failed"])
    func recordings(name: String) async throws {
        let fixture = try BackendExecutableFixture(provider: "claude", name: name)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let mode: AgentMode = name == "accept-edits" ? .acceptEdits : name == "plan-mode" ? .plan : .ask
        let run = try await backend.start(.init(directory: fixture.directory, model: "haiku", mode: mode))
        let input = AgentInput(text: try fixture.prompt(provider: "claude", name: name))
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run, interrupt: name == "interrupt")
        let outcome: AgentTurnOutcome = name == "auth-failed" ? .failed(.authRequired) : name == "interrupt" ? .interrupted : .completed
        #expect(events.last?.kind == .turnEnded(outcome))
        #expect(events.contains { $0.kind == .delivery(.acknowledged) })
        #expect(events.allSatisfy { $0.scope.runID == run.id && ($0.scope.inputID == input.id || $0.scope.inputID == nil) })
        if name != "auth-failed" && name != "interrupt" { #expect(events.contains { if case .rateLimits(let windows) = $0.kind { windows.count == 2 } else { false } }) }
        if name == "plan-mode" { #expect(events.contains { if case .request(let r) = $0.kind, case .plan = r.kind { true } else { false } }) }
        if name == "question" { #expect(events.contains { if case .request(let r) = $0.kind, case .questions = r.kind { true } else { false } }) }
        try await Task.sleep(for: .milliseconds(30))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func twoTurnsAllBlocksNativeIDsAndJournalBarrier() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[1:]==['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--include-partial-messages','--permission-prompt-tool','stdio','--permission-mode','auto','--model','test-model','--resume','session-test','--effort','high']
claude_init()
for n in range(2):
    assert read()['message']['content']=='hello'
    emit({'type':'assistant','session_id':'session-test','message':{'id':'message-'+str(n),'role':'assistant','content':[{'type':'text','text':'first'},{'type':'thinking','thinking':'reason'},{'type':'tool_use','id':'tool-'+str(n),'name':'Read','input':{}},{'type':'text','text':'second'},{'type':'new-block','value':1}]}})
    emit({'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'tool-'+str(n),'content':'output','is_error':False}]}})
    emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory,
            resume: .init(provider: .claude, profile: "default", nativeID: "session-test"), model: "test-model", effort: "high", mode: .auto))
        await #expect(throws: AgentFailure.invalidRequest) { try await run.send(.init(text: "unsent"), willDeliver: { throw AgentFailure.invalidRequest }) }
        for n in 0..<2 {
            try await run.send(.init(text: "hello"), willDeliver: {})
            let events = try await collectTurn(run)
            #expect(events.contains { $0.kind == .message(id: "message-\(n)", role: "assistant", text: "first\nsecond") })
            #expect(events.contains { $0.scope.itemID == "tool-\(n)" && $0.kind == .toolFinished(output: .string("output"), isError: false) })
            #expect(events.contains { $0.kind == .thinkingDelta("reason") })
            #expect(events.contains { if case .unknown(name: "new-block", payload: _) = $0.kind { true } else { false } })
        }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func requestsFailClosedAndExpire() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'control_request','request_id':'unknown','request':{'subtype':'future'}})
assert read()['response']['subtype']=='error'
emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':'Write','input':{'content':'test'}}})
reply=read()
assert reply['response']['response']['behavior']=='deny'
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "hello"), willDeliver: {})
        var pending: AgentRequest?
        for try await event in run.events {
            if case .request(let request) = event.kind {
                pending = request
                let stale = AgentRequest(id: request.id, scope: .init(runID: UUID()), kind: request.kind)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: stale, with: .allow(updatedInput: nil)) }
                try await run.respond(to: request, with: .deny)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
            }
            if case .turnEnded = event.kind { break }
        }
        let request = try #require(pending)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: .deny) }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: ["crash", "garbage", "huge", "exit-before-init"])
    func brokenProcess(scenario: String) async throws {
        let script = scenario == "exit-before-init" ? "sys.exit(4)" : "claude_init()\nread()\n" +
            (scenario == "crash" ? "sys.exit(7)" : scenario == "garbage" ? "print('garbage',flush=True)" : "print('x'*1100000,flush=True)")
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        if scenario == "exit-before-init" {
            await #expect(throws: (any Error).self) { _ = try await backend.start(.init(directory: fixture.directory, model: "test")) }
        } else {
            let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
            try await run.send(.init(text: "hello"), willDeliver: {})
            let events = try await collectTurn(run)
            #expect(events.contains { if case .turnEnded(.failed) = $0.kind { true } else { false } })
            try await run.shutdown()
        }
    }

    @Test func statusModelsAndNativeHistory() async throws {
        let fixture = try BackendExecutableFixture(script: "claude_init()\ndone()")
        defer { fixture.remove() }
        let history = try NativeHistoryFixture()
        defer { history.remove() }
        try history.write(records: [history.record("user", text: "Example question")])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
                                    overrides: ["CLAUDE_CONFIG_DIR": history.root.path])
        let status = try await backend.status()
        #expect(status.authentication == .subscription)
        #expect(status.capabilities.contains(.history))
        #expect(try await backend.models() == [AgentModel(id: "test-model", name: "test-model")])
        let sessions = try await backend.listSessions(folder: history.root, cursor: nil)
        #expect(sessions.items.map(\.id) == [history.session])
        #expect(try await backend.readHistory(session: history.session, cursor: nil).items.map(\.kind)
            == [.message(id: "user", role: "user", text: "Example question")])
        await #expect(throws: AgentFailure.invalidRequest) {
            _ = try await backend.readHistory(session: .init(provider: .claude, profile: "default", nativeID: "test"), cursor: nil)
        }
        await #expect(throws: AgentFailure.unsupported) { _ = try await backend.nativeSessions(folder: nil, cursor: nil, archived: true) }
    }
    @Test(arguments: ["api-key", "endpoint", "signed-out", "no-plan"])
    func refusesNonSubscriptionBeforeSession(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: "open('launched','w').close()")
        defer { fixture.remove() }
        var status: [String: JSONValue] = ["loggedIn": .bool(true), "apiKeySource": .string("none"),
            "apiProvider": .string("firstParty"), "authMethod": .string("claude.ai"), "subscriptionType": .string("pro")]
        switch scenario {
        case "api-key": status["apiKeySource"] = .string("environment")
        case "endpoint": status["apiProvider"] = .string("other")
        case "signed-out": status["loggedIn"] = .bool(false)
        default: status["subscriptionType"] = .null
        }
        try JSONValue.object(status).jsonString.write(to: fixture.directory.appendingPathComponent("auth-status.json"), atomically: true, encoding: .utf8)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: scenario == "signed-out" ? AgentFailure.authRequired : .unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: "test"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
    }

    @Test func loginReportsStderrURLBeforeWaitingForBrowser() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[1:]==['auth','login','--claudeai']
print('Open https://example.invalid/login',file=sys.stderr,flush=True)
for _ in range(100):
    if os.path.exists('browser-opened'): sys.exit(0)
    time.sleep(0.01)
sys.exit(3)
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let marker = fixture.directory.appendingPathComponent("browser-opened")
        try await backend.signIn { url in
            #expect(url.absoluteString == "https://example.invalid/login")
            try? Data().write(to: marker)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func lateDuplicateAndUnrelatedControlResponsesAreIgnored() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
requests=[read(),read()]
for r in reversed(requests):
    assert r['request']['subtype']=='set_permission_mode'
    emit({'type':'control_response','response':{'subtype':'success','request_id':'stale','response':{}}})
    emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
    emit({'type':'control_response','response':{'subtype':'error','request_id':r['request_id'],'error':'late'}})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        async let one: Void = run.setMode(.plan)
        async let two: Void = run.setMode(.acceptEdits)
        _ = try await (one, two)
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func nativeCancellationExpiresRequestBeforeTurnEnds() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'control_request','request_id':'cancelled','request':{'subtype':'can_use_tool','tool_name':'Write','input':{}}})
emit({'type':'control_cancel_request','request_id':'cancelled'})
emit({'type':'test-barrier'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "hello"), willDeliver: {})
        var pending: AgentRequest?
        for try await event in run.events {
            if case .request(let request) = event.kind { pending = request }
            if case .unknown(name: "test-barrier", payload: _) = event.kind {
                let expired = try #require(pending)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: expired, with: .allow(updatedInput: nil)) }
            }
            if case .turnEnded = event.kind { break }
        }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown()
    }

}
