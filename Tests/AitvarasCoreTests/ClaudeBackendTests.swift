import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2)))
struct ClaudeBackendTests {
    @Test func composerAutoKeepsSandboxAndExplicitEscalations() throws {
        let settings = ClaudeRunPermissions.settings(#"{"disabledMcpjsonServers":["disabled"]}"#, permissions: .auto)
        let json = try #require(JSONValue.parse(settings))
        #expect(json["disabledMcpjsonServers"] == .array([.string("disabled")]))
        #expect(json["sandbox"]?["enabled"] == .bool(true))
        #expect(json["sandbox"]?["failIfUnavailable"] == .bool(true))
        #expect(json["sandbox"]?["autoAllowBashIfSandboxed"] == .bool(true))
        #expect(json["sandbox"]?["network"]?["allowedDomains"] == .array([.string("github.com:443"), .string("api.github.com:443")]))
        #expect(json["sandbox"]?["network"]?["allowMachLookup"] == .array([.string("com.apple.trustd.agent")]))
        #expect(json["permissions"]?["ask"] == .array([.string("Bash(dangerouslyDisableSandbox:true)")]))
        #expect(ClaudeRunPermissions.nativeMode(.auto, permissions: .auto) == "acceptEdits")
        #expect(ClaudeRunPermissions.nativeMode(.auto, permissions: .fullAccess) == "bypassPermissions")
        #expect(JSONValue.parse(ClaudeRunPermissions.settings("{}", permissions: .fullAccess))?["sandbox"]?["enabled"] == .bool(false))
    }

    @Test func foreignSessionFramesDoNotEndANormalTurn() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'parent-session'})
emit({'type':'assistant','session_id':'subagent-session','message':{'role':'assistant','content':[{'type':'text','text':'Subagent reply'}]}})
emit({'type':'system','subtype':'compact_boundary','session_id':'compaction-session'})
emit({'type':'result','session_id':'parent-session','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(events.last?.kind == .turnEnded(.completed))
        #expect(events.contains { $0.kind == .sessionStarted(.init(provider: .claude, profile: "default", nativeID: "parent-session")) })
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test(arguments: [2, 3])
    func toolResultUUIDsDoNotConflictWithPersistedUserIdentity(tools: Int) async throws {
        let fixture = try BackendExecutableFixture(script: AgentMultiToolTurnTests.script(tools: tools, hooks: false))
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, session) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(session.configuration)
        let input = AgentInput(text: "run some commands")
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        try await run.shutdown()
        var state = ChatState(chatID: chat.id)
        state.begin(input, session: session, outputID: UUID())
        // Exercise the same identity checks as manager persistence without its
        // catch-all hiding the concrete store error behind AgentFailure.unknown.
        for event in events {
            state.reduce(event, newEntryID: UUID())
            for entry in state.entries { _ = try stores.saveAgentEntry(entry) }
        }
        let users = try stores.agentEntries(chatID: chat.id).filter { $0.kind == "user" }
        #expect(users.map(\.id) == [input.id])
        #expect(users.first?.nativeMessageID == nil)
        #expect(state.outcome == .completed)
        try fixture.assertComplete()
    }

    @Test(arguments: ["tool-results", "mixed", "text", "attachment", "empty-text", "empty-content"])
    func userFramesOnlySuppressMessagesForPureToolResults(content: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
original=read()
kind='\(content)'
results=[{'type':'tool_result','tool_use_id':'tool-one','content':'first output','is_error':False},
         {'type':'tool_result','tool_use_id':'tool-two','content':[{'type':'text','text':'second output'}],'is_error':True}]
if kind=='tool-results': blocks=results
elif kind=='mixed': blocks=[results[0],{'type':'text','text':'first line'},results[1],{'type':'text','text':'second line'}]
elif kind=='text': blocks=[{'type':'text','text':'echo'}]
elif kind=='attachment': blocks=[{'type':'image','source':{'type':'base64','media_type':'image/png','data':'Zml4dHVyZQ=='}}]
elif kind=='empty-text': blocks=[{'type':'text','text':''}]
else: blocks=[]
emit({'type':'user','uuid':original['uuid'],'message':{'role':'user','content':blocks}})
emit({'type':'assistant','uuid':'reply','message':{'role':'assistant','content':[{'type':'text','text':'done'}]}})
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: "echo")
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        let messages: [(String, String)] = events.compactMap {
            if case .message(let id, "user", let text) = $0.kind { return (id, text) }
            return nil
        }
        if content == "tool-results" {
            #expect(messages.isEmpty)
        } else {
            #expect(messages.count == 1)
            #expect(messages.first?.0 == input.id.uuidString)
            let expected = content == "mixed" ? "first line\nsecond line" : content == "text" ? "echo" : ""
            #expect(messages.first?.1 == expected)
        }
        let results: [AgentEvent] = events.filter { if case .toolFinished = $0.kind { true } else { false } }
        if ["tool-results", "mixed"].contains(content) {
            #expect(results.map(\.scope.itemID) == ["tool-one", "tool-two"])
            #expect(results.first?.kind == .toolFinished(output: .string("first output"), isError: false))
            #expect(results.last?.kind == .toolFinished(output: .array([.object(["type": .string("text"), "text": .string("second output")])]), isError: true))
        } else { #expect(results.isEmpty) }
        #expect(events.last?.kind == .turnEnded(.completed))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: ["five_hour", "seven_day"])
    func quotaUsesTheRejectedWindowAndClearsBetweenInputs(window: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
info={'status':'rejected','rateLimitType':'\(window)','resetsAt':2100000000,'unifiedWindows':{'five_hour':{'resetsAt':2000000000},'seven_day':{'resetsAt':1900000000}}}
for _ in range(2): emit({'type':'rate_limit_event','rate_limit_info':info})
emit({'type':'assistant','error':'rate_limit','message':{'role':'assistant','content':[]}})
emit({'type':'result','uuid':'quota-result','is_error':True})
read()
emit({'type':'result','uuid':'next-result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: "test")
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        let reset = Date(timeIntervalSince1970: window == "five_hour" ? 2_000_000_000 : 1_900_000_000)
        #expect(events.last?.kind == .turnEnded(.failed(.quota(resetsAt: reset))))
        #expect(events.contains { $0.scope.inputID == input.id && $0.kind == .usageLimit(.init(status: .rejected, windowID: window, resetsAt: reset)) })
        try await run.send(.init(text: "next"), willDeliver: {})
        #expect(try await collectTurn(run).last?.kind == .turnEnded(.completed))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func contextUsesTheLatestMainResponseAndItsReportedWindow() async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
def answer(id, model, usage, parent=None):
    emit({'type':'assistant','uuid':id,'parent_tool_use_id':parent,
          'message':{'model':model,'usage':usage,'content':[{'type':'text','text':'Example reply'}]}})
answer('first','main',{'input_tokens':100})
answer('latest','main',{'input_tokens':1000,'cache_creation_input_tokens':3000,
                       'cache_read_input_tokens':38000,'output_tokens':900})
answer('subagent','other',{'input_tokens':90000},parent='tool')
emit({'type':'result','is_error':False,'usage':{'input_tokens':150000},
      'modelUsage':{'main':{'contextWindow':200000},'other':{'contextWindow':1000000}}})
read()
emit({'type':'result','is_error':False,'modelUsage':{'main':{'contextWindow':200000}}})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(events.contains { event in
            guard case .usage(let usage) = event.kind else { return false }
            return usage.contextTokens == 42_000 && usage.contextLimit == 200_000 && usage.inputTokens == 150_000
        })
        try await run.send(.init(text: "Another example"), willDeliver: {})
        let secondTurn = try await collectTurn(run)
        #expect(!secondTurn.contains { event in
            guard case .usage(let usage) = event.kind else { return false }
            return usage.contextTokens != nil || usage.contextLimit != nil
        })
        try await run.shutdown()
    }

    @Test func partialRateLimitEventPublishesTheReportedWindow() async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'rate_limit_event','rate_limit_info':{
    'status':'allowed','rateLimitType':'five_hour','utilization':0.42,'resetsAt':2000000000}})
emit({'type':'rate_limit_event','rate_limit_info':{'status':'allowed'}})
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        let events = try await collectTurn(run)
        let reported = events.compactMap { event -> [AgentRateLimitWindow]? in
            guard case .rateLimits(let windows) = event.kind else { return nil }
            return windows
        }
        #expect(reported == [[.init(id: "five_hour", utilization: 0.42, duration: 5 * 3600,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000))], []])
        try await run.shutdown()
    }

    @Test(arguments: ["allowed", "warning", "future"])
    func nonRejectionDoesNotFailTurn(status: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'rate_limit_event','rate_limit_info':{'status':'\(status)','rateLimitType':'five_hour','resetsAt':2000000000}})
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        #expect(try await collectTurn(run).last?.kind == .turnEnded(.completed))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test(arguments: [false, true])
    func rejectedQuotaWithoutResetRespectsStop(interrupt: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'rate_limit_event','rate_limit_info':{'status':'rejected'}})
if \(interrupt ? "True" : "False"):
    emit({'type':'stream_event','event':{'type':'content_block_delta','delta':{'text':'working'}}})
    r=read()
    emit({'type':'result','is_error':True,'terminal_reason':'aborted_streaming'})
    emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{}}})
else:
    emit({'type':'assistant','error':'rate_limit','message':{'role':'assistant','content':[]}})
    emit({'type':'result','is_error':True})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        let events = try await collectTurn(run, interrupt: interrupt)
        #expect(events.last?.kind == .turnEnded(interrupt ? .interrupted : .failed(.quota(resetsAt: nil))))
        try fixture.assertComplete()
        try await run.shutdown()
    }

    @Test func quotaEvidenceValidatesWindowAndReset() {
        for info in ["{}", "{\"status\":\"rejected\",\"rateLimitType\":\"future\",\"resetsAt\":2000000000}",
                     "{\"status\":\"rejected\",\"rateLimitType\":\"five_hour\",\"resetsAt\":-1}"] {
            #expect(AgentUsageLimit.claude(JSONValue.parse(info)!).resetsAt == nil)
        }
        let info = JSONValue.parse(#"{"status":"rejected","rateLimitType":"seven_day","resetsAt":2000000000,"unifiedWindows":{"seven_day":{"resetsAt":"garbage"}}}"#)!
        #expect(AgentUsageLimit.claude(info).resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(AgentUsageLimit.claude(info).status == .rejected)
    }

    @Test func defaultModelUsesTheOpusAliasAndMediumEffort() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[sys.argv.index('--model')+1]=='opus'
assert sys.argv[sys.argv.index('--effort')+1]=='medium'
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
assert sys.argv[1:]==['-p','--input-format','stream-json','--output-format','stream-json','--verbose','--include-partial-messages','--permission-prompt-tool','stdio','--permission-mode','auto','--model','test-model','--resume','session-test','--effort','high','--settings','{"disabledMcpjsonServers":[]}','--include-hook-events']
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
            #expect(events.contains {
                $0.scope.isCommentary && $0.kind == .message(id: "message-\(n)", role: "assistant", text: "first\nsecond")
            })
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
        #expect(try await backend.models() == ChatSettings.claudeModels([AgentModel(id: "test-model", name: "test-model")]))
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

extension ClaudeBackendTests {
    @Test(arguments: ["same account", "different member", "different organization"])
    func timedQuotaContinuationUsesTheClaudeMemberAndOrganization(account: String) async throws {
        let clock = AutoContinueTimerClock()
        let reset = clock.now.addingTimeInterval(60)
        let fixture = try BackendExecutableFixture(script: """
claude_init()
first = True
while True:
    request = read()
    assert request['type'] == 'user'
    if first:
        emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'00000000-0000-4000-8000-000000000001'})
        first = False
    evidence = json.dumps(request['message']['content'])
    if 'Continue where you stopped.' in evidence:
        emit({'type':'assistant','session_id':'00000000-0000-4000-8000-000000000001','uuid':'recovered-reply',
              'message':{'role':'assistant','content':[{'type':'text','text':'Resumed after the example reset'}]}})
        emit({'type':'result','session_id':'00000000-0000-4000-8000-000000000001','is_error':False})
        done()
        break
    assert 'Example quota turn' in evidence
    emit({'type':'rate_limit_event','session_id':'00000000-0000-4000-8000-000000000001','rate_limit_info':{
          'status':'rejected','rateLimitType':'five_hour','resetsAt':\(Int(reset.timeIntervalSince1970))}})
    emit({'type':'result','session_id':'00000000-0000-4000-8000-000000000001','is_error':True})
""")
        defer { fixture.remove() }
        let auth = fixture.directory.appendingPathComponent("auth-status.json")
        func writeStatus(email: String, orgID: String) throws {
            try JSONValue.object([
                "loggedIn": .bool(true), "authMethod": .string("claude.ai"), "apiProvider": .string("firstParty"),
                "subscriptionType": .string("max"), "email": .string(email), "orgId": .string(orgID)
            ]).jsonString.write(to: auth, atomically: true, encoding: .utf8)
        }
        try writeStatus(email: "person@example.invalid", orgID: "example-org")
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .claude, cwd: fixture.directory.path)
        let persistence = AgentAutoContinueStore(db: stores.db)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
                                    overrides: ["CLAUDE_CONFIG_DIR": fixture.directory.path])
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend },
            audit: { _ = try stores.record($0) }, autoContinuePersistence: persistence, continuationClock: clock.clock)
        let scheduler = AgentAutoContinueScheduler(manager: manager, turns: stores, persistence: persistence,
            backend: { _ in backend }, audit: { _ = try stores.record($0) }, clock: clock.clock)
        try await scheduler.start()
        let input = AgentInput(text: "Example quota turn")
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        try await autoWait { try persistence.continuation(failedInputID: input.id)?.state == .pending }
        let pending = try #require(try persistence.continuation(failedInputID: input.id))
        #expect(pending.resetsAt == reset)
        #expect(pending.scope.hasKnownAccount)
        if account == "different member" { try writeStatus(email: "other@example.invalid", orgID: "example-org") }
        if account == "different organization" { try writeStatus(email: "person@example.invalid", orgID: "other-org") }

        clock.advance(60.0004)
        let expected: AgentAutoContinue.State = account == "same account" ? .fired : .cancelled
        try await autoWait { try persistence.continuation(id: pending.id)?.state == expected }
        if account == "same account" {
            try await autoWait {
                try stores.agentEntries(chatID: chat.id).contains {
                    $0.kind == "assistant" && $0.text == "Resumed after the example reset"
                }
            }
        }
        let entries = try stores.agentEntries(chatID: chat.id)
        #expect(entries.filter { $0.kind == "automaticContinuation" }.count == (account == "same account" ? 1 : 0))
        #expect(entries.filter { $0.kind == "user" }.map(\.text) == [input.text])
        if account == "same account" { try fixture.assertComplete() }
        await scheduler.shutdown()
        try await manager.shutdown()
    }
}
