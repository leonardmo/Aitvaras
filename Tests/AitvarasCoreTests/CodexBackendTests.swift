import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2)))
struct CodexBackendTests {
    @Test func composerPreflightWaitsForApprovalBeforeReturningVerdict() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
assert r['method']=='account/read'
account(r)
r=read()
assert r['method']=='config/read'
emit({'id':r['id'],'result':{'config':{}}})
r=read()
assert r['method']=='thread/start'
emit({'id':r['id'],'result':{'thread':{'id':'thread-test','modelProvider':'openai'}}})
r=read()
assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
r=read()
assert r['method']=='turn/interrupt'
emit({'id':r['id'],'result':{}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'interrupted','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try #require(try await backend.start(.init(directory: fixture.directory, model: "test", permissions: .auto)) as? CodexRun)
        try await run.send(.init(text: "Fixture"), willDeliver: {})
        var events = run.events.makeAsyncIterator()
        func hook(_ call: String, _ name: String, _ input: JSONValue) -> JSONValue {
            .object(["hook_event_name": .string("PreToolUse"), "session_id": .string("thread-test"),
                "turn_id": .string("turn-test"), "tool_use_id": .string(call), "tool_name": .string(name), "tool_input": input])
        }
        let pipeline = hook("routine", "Bash", .object(["command": .string("printf 'a\\n' | head -1")]))
        #expect(await run.receiveHook(pipeline) == CodexCommandHook.allowed)
        let recursiveDelete = hook("critical", "Bash", .object(["command": .string("rm -r example")]))
        let pending = Task { await run.receiveHook(recursiveDelete) }
        var approval: AgentRequest?
        while let event = try await events.next() {
            if case .request(let request) = event.kind { approval = request; break }
        }
        let request = try #require(approval)
        let expectedTool = AgentTool(name: "Bash", input: .object(["command": .string("rm -r example")]))
        #expect(request.kind == .permission(expectedTool))
        try await run.respond(to: request, with: .deny)
        #expect(await pending.value == CodexCommandHook.rejected)
        try await run.interrupt()
        while let event = try await events.next() {
            if case .turnEnded = event.kind { break }
        }
        try fixture.assertComplete()
        try await backend.shutdown()
    }

    @Test func composerPolicyKeepsAutoSandboxAndRoutesFullAccessMCPInternally() throws {
        let workspace = URL(fileURLWithPath: "/tmp/example workspace")
        let auto = CodexRunPermissions(mode: .auto, permissions: .auto)
        #expect(auto.sandboxMode == "workspace-write")
        #expect(auto.approvalPolicy["granular"]?["sandbox_approval"] == .bool(true))
        #expect(auto.approvalPolicy["granular"]?["rules"] == .bool(true))
        #expect(auto.sandboxPolicy(additionalDirectories: [workspace])["writableRoots"] == .array([.string(workspace.path)]))
        let ask = CodexRunPermissions(mode: .ask, permissions: .ask)
        #expect(ask.approvalPolicy == auto.approvalPolicy)
        let pipeline = AgentTool(name: "Bash", input: .object(["command": .string("printf a | head -1")]))
        #expect(CodexRun.requiresHookApproval(pipeline, permissions: .ask))
        #expect(!CodexRun.requiresHookApproval(pipeline, permissions: .auto))

        let full = CodexRunPermissions(mode: .auto, permissions: .fullAccess)
        #expect(full.sandboxMode == "danger-full-access")
        #expect(full.sandboxPolicy(additionalDirectories: [workspace]) == .object(["type": .string("dangerFullAccess")]))
        #expect(full.approvalPolicy["granular"]?["sandbox_approval"] == .bool(true))
        #expect(full.approvalPolicy["granular"]?["rules"] == .bool(true))
        #expect(full.approvalPolicy["granular"]?["request_permissions"] == .bool(false))
        #expect(full.approvalPolicy["granular"]?["mcp_elicitations"] == .bool(true))
        #expect(!full.matchesReportedPolicy(.object(["sandbox": .object(["type": .string("workspaceWrite")])])))
        #expect(CodexRunPermissions.ignoringProjectConfiguration(at: workspace)
            == "projects={ \"/tmp/example workspace\" = { trust_level = \"untrusted\" } }")

        let config = try #require(JSONValue.parse(#"{"mcp_servers":{"aitvaras":{},"one":{"tools":{"lookup":{"approval_mode":"approve"}}},"disabled":{"enabled":false}}}"#))
        let overrides = CodexRunPermissions.mcpApprovalOverrides(config, hasGateway: true)
        #expect(overrides["mcp_servers"]?.objectValue?.keys.sorted() == ["one"])
        #expect(overrides["mcp_servers"]?["one"]?["tools"]?["lookup"]?["approval_mode"] == .string("prompt"))
    }

    @Test func mcpApprovalRequiresMatchingInProgressToolAndEmptyForm() throws {
        let request = try #require(JSONValue.parse(#"{"mode":"form","serverName":"example","requestedSchema":{"type":"object","properties":{}},"_meta":{"codex_approval_kind":"mcp_tool_call","tool_name":"lookup","tool_params":{"id":1}}}"#))
        let item = try #require(JSONValue.parse(#"{"type":"mcpToolCall","status":"inProgress","server":"example","tool":"lookup","arguments":{"id":1}}"#))
        #expect(CodexRun.mcpToolApproval(request, items: [item])?.name == "mcp__example__lookup")
        #expect(CodexRun.mcpToolApproval(request, items: [item])?.input == item["arguments"])
        #expect(CodexRun.mcpToolApproval(request, items: []) == nil)
        var generic = request.objectValue ?? [:]
        generic["requestedSchema"] = .object(["type": .string("object"), "properties": .object(["password": .object([:])])])
        #expect(CodexRun.mcpToolApproval(.object(generic), items: [item]) == nil)
        var readItem = item.objectValue ?? [:]
        readItem["readOnlyHint"] = .bool(true)
        #expect(CodexRun.mcpToolApproval(request, items: [JSONValue.object(readItem)])?.providerReportsReadOnly == false)
        #expect(CodexRun.mcpToolApproval(request, items: [JSONValue.object(readItem)], enabledServers: ["example"])?.providerReportsReadOnly == true)
    }

    @Test func automaticContinuationSuppliesItsDurableClientMessageIdentity() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read()
assert r['method']=='turn/start'
message=r['params']['clientUserMessageId']
assert str(uuid.UUID(message)).upper()==message.upper()
assert r['params']['input']==[{'type':'text','text':'Continue where you stopped.'}]
emit({'id':r['id'],'result':{'turn':{'id':'auto-turn'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'auto-turn','status':'completed','items':[{'type':'userMessage','id':message,'content':[{'type':'text','text':'Continue where you stopped.'}]}]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: AgentAutoContinue.prompt, automaticIntentID: UUID())
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        #expect(events.contains { $0.scope.inputID == input.id && $0.kind == .message(id: input.id.uuidString, role: "user", text: input.text) })
        try fixture.assertComplete(); try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["rpc", "rpc-secondary", "terminal", "notification"])
    func usageLimitRetainsResetForTheFailingInput(path: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
codex_init()
start_thread()
r=read()
assert r['method']=='turn/start'
emit({'method':'account/rateLimits/updated','params':{'rateLimits':{'limitId':'codex','primary':{'usedPercent':100,'resetsAt':2000000000},'secondary':{'usedPercent':20,'resetsAt':1900000000}}}})
error={'message':'PRIVATE_ERROR_CANARY','codexErrorInfo':'usageLimitExceeded'}
if '\(path)'=='rpc-secondary':
    error['rateLimitType']='secondary'
if '\(path)' in ['rpc','rpc-secondary']:
    emit({'id':r['id'],'error':{'code':-32000,'data':error}})
else:
    emit({'id':r['id'],'result':{'turn':{'id':'quota-turn'}}})
    if '\(path)'=='notification':
        emit({'method':'error','params':{'threadId':'thread-test','turnId':'quota-turn','willRetry':False,'error':error}})
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'quota-turn','status':'failed','error':error if '\(path)'=='terminal' else None}}})
done()
""")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: "test")
        let reset = Date(timeIntervalSince1970: path == "rpc-secondary" ? 1_900_000_000 : 2_000_000_000)
        let windowID = path == "rpc-secondary" ? "codex.secondary" : "codex.primary"
        if path == "rpc" || path == "rpc-secondary" {
            await #expect(throws: AgentFailure.quota(resetsAt: reset)) { try await run.send(input, willDeliver: {}) }
        } else { try await run.send(input, willDeliver: {}) }
        let events = try await collectTurn(run)
        #expect(events.last?.kind == .turnEnded(.failed(.quota(resetsAt: reset))))
        #expect(events.contains { $0.scope.inputID == input.id && $0.kind == .usageLimit(.init(status: .rejected, windowID: windowID, resetsAt: reset)) })
        #expect(!String(describing: events).contains("PRIVATE_ERROR_CANARY"))
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func quotaMappingRejectsUntypedErrorsAndAmbiguousWindows() {
        let windows: [AgentRateLimitWindow] = [
            .init(id: "codex.primary", utilization: 1, resetsAt: Date(timeIntervalSince1970: 2_000_000_000)),
            .init(id: "codex.secondary", utilization: 1, resetsAt: Date(timeIntervalSince1970: 2_100_000_000))]
        let typed = JSONValue.parse(#"{"codexErrorInfo":"usageLimitExceeded"}"#)!
        #expect(AgentUsageLimit.codex(typed, windows: windows)?.resetsAt == nil)
        #expect(AgentUsageLimit.codex(typed, windows: windows)?.windowID == nil)
        let specific = JSONValue.parse(#"{"data":{"type":"usage_limit_reached","rateLimitType":"secondary","resetsAt":-1}}"#)!
        #expect(AgentUsageLimit.codex(specific, windows: windows)?.resetsAt == windows[1].resetsAt)
        for value in [#"{"message":"usage limit exceeded"}"#, #"{"codexErrorInfo":{"httpConnectionFailed":{"httpStatusCode":429}}}"#, "null"] {
            #expect(AgentUsageLimit.codex(JSONValue.parse(value)!, windows: windows) == nil)
        }
    }

    @Test func accountUpdatesRemainAvailableWithoutRuns() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
assert r['method']=='account/read'
account(r)
emit({'method':'account/rateLimits/updated','params':{'rateLimits':{'primary':{'usedPercent':100,'resetsAt':2000000000}}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let updates = await backend.rateLimitUpdates()
        _ = try await backend.status()
        for await windows in updates where !windows.isEmpty {
            #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 2_000_000_000))
            break
        }
        var latest = await backend.rateLimitUpdates().makeAsyncIterator()
        #expect(await latest.next()?.first?.utilization == 1)
        try fixture.assertComplete(); try await backend.shutdown()
    }

    @Test func pollingTimeoutAndLateReplyDoNotDisconnectRunningChat() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read()
assert r['method']=='turn/start'
emit({'id':r['id'],'result':{'turn':{'id':'live-turn'}}})
poll=read()
assert poll['method']=='account/rateLimits/read'
r=read()
assert r['method']=='account/read'
emit({'id':poll['id'],'result':{'rateLimits':{'primary':{'usedPercent':50}}}})
account(r)
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'live-turn','status':'completed'}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        await #expect(throws: AgentFailure.offline) { _ = try await backend.rateLimits(timeout: .milliseconds(20)) }
        #expect(try await backend.status().authentication == .subscription)
        #expect(try await collectTurn(run).last?.kind == .turnEnded(.completed))
        try fixture.assertComplete(); try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: [true, false])
    func ordinaryErrorsAndRecoveredQuotaDoNotBecomeQuotaFailures(recovered: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: """
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'test-turn'}}})
emit({'method':'error','params':{'threadId':'thread-test','turnId':'test-turn','willRetry':\(recovered ? "True" : "False"),'error':{'codexErrorInfo':'\(recovered ? "usageLimitExceeded" : "other")','message':'PRIVATE_ERROR_CANARY'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'test-turn','status':'\(recovered ? "completed" : "failed")','error':None}}})
done()
""")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "test"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(events.last?.kind == .turnEnded(recovered ? .completed : .failed(.providerError)))
        #expect(!String(describing: events).contains("PRIVATE_ERROR_CANARY"))
        try fixture.assertComplete(); try await run.shutdown(); try await backend.shutdown()
    }

    @Test func loginCancellationReachesNativeProvider() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
assert r['method']=='account/login/start'
emit({'id':r['id'],'result':{'loginId':'test-login','authUrl':'https://example.invalid/login'}})
r=read()
assert r['method']=='account/login/cancel'
assert r['params']=={'loginId':'test-login'}
open('done','w').close()
emit({'id':r['id'],'result':{'status':'canceled'}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let (urls, opened) = AsyncStream<URL>.makeStream()
        let login = Task { try await backend.signIn { opened.yield($0) } }
        for await _ in urls { break }
        login.cancel()
        await #expect(throws: CancellationError.self) { try await login.value }
        try fixture.assertComplete()
        try await backend.shutdown()
    }

    @Test func defaultModelUsesNativeDefaultWithoutInventingAnID() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
account(r)
r=read()
assert r['method']=='thread/start'
assert 'model' not in r['params']
emit({'id':r['id'],'result':{'thread':{'id':'test-thread'}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await Task.sleep(for: .milliseconds(20))
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["write-ask", "write-onreq", "readonly", "interrupt"])
    func recordings(name: String) async throws {
        let fixture = try BackendExecutableFixture(provider: "codex", name: name)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let mode: AgentMode = name == "write-ask" ? .ask : name == "write-onreq" ? .acceptEdits : .plan
        let run = try await backend.start(.init(directory: fixture.directory, model: "gpt-6-luna", mode: mode))
        let input = AgentInput(text: try fixture.prompt(provider: "codex", name: name))
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run, interrupt: name == "interrupt")
        #expect(events.last?.kind == .turnEnded(name == "interrupt" ? .interrupted : .completed))
        #expect(events.contains { $0.kind == .delivery(.acknowledged) })
        #expect(events.contains { if case .usage = $0.kind { true } else { false } } || name == "interrupt")
        if name == "write-ask" { #expect(events.contains { if case .request = $0.kind { true } else { false } }) }
        #expect(events.allSatisfy { $0.scope.runID == run.id })
        try await Task.sleep(for: .milliseconds(30)); try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func multiplexesThreadsAndCorrelatesOutOfOrderResponses() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
threads=0
turns=[]
while len(turns)<2:
    r=read()
    if r['method']=='account/read': account(r)
    elif r['method']=='thread/start':
        threads+=1
        emit({'id':r['id'],'result':{'thread':{'id':'thread-'+str(threads)}}})
    elif r['method']=='turn/start': turns.append(r)
for n,r in enumerate(reversed(turns)):
    thread=r['params']['threadId']
    turn='turn-'+thread
    emit({'id':str(r['id']),'result':{'turn':{'id':'wrong-string-id'}}})
    emit({'id':999,'result':{}})
    emit({'id':r['id'],'result':{'turn':{'id':turn}}})
    emit({'id':r['id'],'result':{'turn':{'id':'duplicate'}}})
    emit({'method':'item/completed','params':{'threadId':thread,'turnId':turn,'item':{'type':'agentMessage','id':'message-'+thread,'text':thread}}})
    emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        async let first = backend.start(.init(directory: fixture.directory, model: "test"))
        async let second = backend.start(.init(directory: fixture.directory, model: "test"))
        let (one, two) = try await (first, second)
        async let sendOne: Void = one.send(.init(text: "one"), willDeliver: {})
        async let sendTwo: Void = two.send(.init(text: "two"), willDeliver: {})
        _ = try await (sendOne, sendTwo)
        let eventsOne = try await collectTurn(one), eventsTwo = try await collectTurn(two)
        #expect(one.id != two.id)
        #expect(eventsOne.allSatisfy { $0.scope.runID == one.id })
        #expect(eventsTwo.allSatisfy { $0.scope.runID == two.id })
        let messages = (eventsOne + eventsTwo).compactMap { event -> String? in
            if case .message(_, _, let text) = event.kind { return text }; return nil
        }
        #expect(Set(messages) == ["thread-1", "thread-2"])
        #expect(!(eventsOne + eventsTwo).contains { $0.scope.turnID == "wrong-string-id" || $0.scope.turnID == "duplicate" })
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await one.shutdown(); try await two.shutdown(); try await backend.shutdown()
    }

    @Test func allRequestsExactIDsDenialsAndStaleResponses() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
p={'threadId':'thread-test','turnId':'turn-test','itemId':'item-test'}
emit({'id':'unknown','method':'future/request','params':p})
assert read()['error']['code']==-32601
emit({'id':'no-scope','method':'item/commandExecution/requestApproval','params':{}})
assert read()['error']['code']==-32601
for rid,method in [(9007199254740993,'item/commandExecution/requestApproval'),('9007199254740993','item/fileChange/requestApproval'),(3,'item/permissions/requestApproval'),('questions','item/tool/requestUserInput')]:
    params=dict(p)
    params['permissions']={'network':{'enabled':True}}
    params['questions']=[{'id':'choice','question':'Choose a color','options':[{'label':'Red','description':'Red color'}]}]
    emit({'id':rid,'method':method,'params':params})
    reply=read()
    assert reply['id']==rid and type(reply['id']) is type(rid)
    if rid==9007199254740993: assert reply['result']=={'decision':'decline'}
    elif rid=='9007199254740993': assert reply['result']=={'decision':'accept'}
    elif rid==3: assert reply['result']=={'permissions':{'network':{'enabled':True}},'scope':'turn'}
    else: assert reply['result']=={'answers':{'choice':{'answers':['Red']}}}
# A native client resolves an outstanding request; this client must expire it.
emit({'id':9223372036854775807,'method':'item/commandExecution/requestApproval','params':p})
emit({'method':'serverRequest/resolved','params':{'threadId':'thread-test','requestId':9223372036854775807}})
emit({'method':'test-barrier','params':{'threadId':'thread-test'}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await run.send(.init(text: "hello"), willDeliver: {})
        var pending: AgentRequest?
        for try await event in run.events {
            if case .request(let request) = event.kind {
                if request.id == .integer(Int64.max) { pending = request; continue }
                let stale = AgentRequest(id: request.id, scope: .init(runID: UUID()), kind: request.kind)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: stale, with: .deny) }
                let response: AgentResponse
                switch request.kind {
                case .questions: response = .answers(["choice": ["Red"]])
                default: response = request.id == .integer(9_007_199_254_740_993) ? .deny : .allow(updatedInput: nil)
                }
                try await run.respond(to: request, with: response)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: request, with: response) }
            }
            if case .unknown(name: "test-barrier", payload: _) = event.kind {
                let expired = try #require(pending)
                await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: expired, with: .allow(updatedInput: nil)) }
            }
            if case .turnEnded = event.kind { break }
        }
        let expired = try #require(pending)
        await #expect(throws: AgentFailure.invalidRequest) { try await run.respond(to: expired, with: .allow(updatedInput: nil)) }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["crash", "garbage", "huge", "exit-before-init"])
    func brokenProcess(scenario: String) async throws {
        let script = scenario == "exit-before-init" ? "sys.exit(4)" : #"""
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
"""# + "\n" + (scenario == "crash" ? "sys.exit(7)" : scenario == "garbage" ? "print('garbage',flush=True)" : "print('x'*1100000,flush=True)")
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        if scenario == "exit-before-init" {
            await #expect(throws: (any Error).self) { _ = try await backend.start(.init(directory: fixture.directory, model: "test")) }
        } else {
            let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
            try await run.send(.init(text: "hello"), willDeliver: {})
            let events = try await collectTurn(run)
            #expect(events.contains { if case .turnEnded(.failed) = $0.kind { true } else { false } })
            try await run.shutdown()
        }
        try await backend.shutdown()
    }

    @Test func accountLoginModelsRateLimitsAndNativeHistory() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for _ in range(7):
    r=read()
    if r['method']=='account/read': account(r)
    elif r['method']=='account/login/start':
        assert r['params']=={'type':'chatgpt'}
        emit({'id':r['id'],'result':{'type':'chatgpt','loginId':'login-test','authUrl':'https://example.invalid/login'}})
        emit({'method':'account/login/completed','params':{'loginId':'unrelated','success':False}})
        emit({'method':'account/login/completed','params':{'loginId':'login-test','success':True}})
    elif r['method']=='model/list':
        if r['params'].get('cursor')=='next': emit({'id':r['id'],'result':{'data':[],'nextCursor':None}})
        else: emit({'id':r['id'],'result':{'data':[{'model':'test-model','displayName':'Test','supportedReasoningEfforts':[{'reasoningEffort':'high'}]}],'nextCursor':'next'}})
    elif r['method']=='thread/list':
        assert r['params']['archived']==False
        emit({'id':r['id'],'result':{'data':[{'id':'native','cwd':root,'modelProvider':'openai','preview':'Example'}],'nextCursor':None}})
    elif r['method']=='thread/read':
        assert r['params']=={'threadId':'native','includeTurns':True}
        emit({'id':r['id'],'result':{'thread':{'id':'native','turns':[{'id':'turn','items':[{'id':'reply','type':'agentMessage','text':'Example reply'}]}]}}})
    elif r['method']=='account/rateLimits/read':
        emit({'id':r['id'],'result':{'rateLimits':{'limitId':'codex','primary':{'usedPercent':25,'windowDurationMins':300,'resetsAt':2000000000},'secondary':None}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let status = try await backend.status()
        #expect(status.authentication == .subscription)
        #expect(status.capabilities.contains(.history))
        try await backend.signIn { url in #expect(url.absoluteString == "https://example.invalid/login") }
        #expect(try await backend.models() == [AgentModel(id: "test-model", name: "Test", efforts: ["high"])])
        let windows = try await backend.rateLimits()
        #expect(windows == [.init(id: "codex.primary", utilization: 0.25, duration: 18000, resetsAt: Date(timeIntervalSince1970: 2_000_000_000))])
        let sessions = try await backend.listSessions(folder: fixture.directory, cursor: nil)
        let native = AgentSessionID(provider: .codex, profile: "default", nativeID: "native")
        #expect(sessions.items.map(\.id) == [native])
        #expect(try await backend.readHistory(session: native, cursor: nil).items.map(\.kind)
            == [.message(id: "reply", role: "assistant", text: "Example reply")])
        await #expect(throws: AgentFailure.invalidRequest) {
            _ = try await backend.readHistory(session: .init(provider: .codex, profile: "other", nativeID: "native"), cursor: nil)
        }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await backend.shutdown()
    }
    @Test(arguments: ["apiKey", "amazonBedrock", "signedOut"])
    func refusesNonSubscriptionBeforeThread(scenario: String) async throws {
        let account = scenario == "signedOut" ? "None" : "{'type':'\(scenario)'}"
        let fixture = try BackendExecutableFixture(script: """
        codex_init()
        r=read()
        assert r['method']=='account/read'
        emit({'id':r['id'],'result':{'account':\(account)}})
        r=read()
        fail('no thread request',r)
        """)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: scenario == "signedOut" ? AgentFailure.authRequired : .unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: "test"))
        }
        try await backend.shutdown()
    }

    @Test func modeChangesApplyToNextTurnAndOldTurnEventsAreIgnored() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
start_thread()
for n,policy,sandbox in [(0,'untrusted','workspaceWrite'),(1,'on-request','workspaceWrite'),(2,'on-request','workspaceWrite'),(3,'on-request','readOnly')]:
    r=read()
    assert r['method']=='turn/start'
    assert r['params']['approvalPolicy']==policy
    assert r['params']['sandboxPolicy']=={'type':sandbox}
    if n:
        emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-'+str(n-1),'status':'failed','items':[]}}})
    emit({'id':r['id'],'result':{'turn':{'id':'turn-'+str(n)}}})
    emit({'method':'account/rateLimits/updated','params':{'rateLimits':{'limitId':'codex','primary':{'usedPercent':40,'windowDurationMins':300},'secondary':None}}})
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-'+str(n),'status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        for mode in [AgentMode.ask, .acceptEdits, .auto, .plan] {
            try await run.setMode(mode)
            try await run.send(.init(text: "hello"), willDeliver: {})
            let events = try await collectTurn(run)
            #expect(events.last?.kind == .turnEnded(.completed))
            #expect(events.contains { if case .rateLimits(let windows) = $0.kind { windows.first?.utilization == 0.4 } else { false } })
        }
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func reconnectAllocatesNewGenerationAndRejectsOldApproval() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
count=int(open('generation').read()) if os.path.exists('generation') else 0
open('generation','w').write(str(count+1))
codex_init()
start_thread()
r=read()
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
emit({'method':'item/commandExecution/requestApproval','id':'repeat','params':{'threadId':'thread-test','turnId':'turn-test','itemId':'item-test'}})
if count==0: sys.exit(7)
assert read()['result']=={'decision':'accept'}
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-test','status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let first = try await backend.start(.init(directory: fixture.directory, model: "test"))
        try await first.send(.init(text: "hello"), willDeliver: {})
        var stale: AgentRequest?
        for try await event in first.events {
            if case .request(let request) = event.kind { stale = request }
            if case .turnEnded = event.kind { break }
        }
        let request = try #require(stale)
        let second = try await backend.start(.init(directory: fixture.directory, model: "test"))
        #expect(second.id != first.id)
        try await second.send(.init(text: "hello"), willDeliver: {})
        await #expect(throws: AgentFailure.invalidRequest) { try await second.respond(to: request, with: .allow(updatedInput: nil)) }
        #expect(try await collectTurn(second).last?.kind == .turnEnded(.completed))
        try await Task.sleep(for: .milliseconds(20)); try fixture.assertComplete()
        try await second.shutdown(); try await backend.shutdown()
    }

}

extension CodexBackendTests {
    @Test func bankedResetRequiresConfirmationAndSubmitsOnlyTheSelectedCredit() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
credit = {'id':'fixture-credit','resetType':'codexRateLimits','status':'available','title':'Full reset','expiresAt':None}
def usage(count):
    r=read()
    assert r['method']=='account/rateLimits/read'
    emit({'id':r['id'],'result':{'rateLimits':{'primary':{'usedPercent':100 if count else 0}},
                                'rateLimitResetCredits':{'availableCount':count,'credits':[credit] if count else []}}})
usage(1)
r=read()
assert r['method']=='account/read'
account(r)
usage(1)
r=read()
assert r['method']=='account/rateLimitResetCredit/consume'
assert r['params']['creditId']=='fixture-credit'
import uuid
uuid.UUID(r['params']['idempotencyKey'])
emit({'id':r['id'],'result':{'outcome':'reset'}})
usage(0)
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let first = try await backend.usageSnapshot()
        let credit = try #require(first.resets?.credits.first)
        #expect(first.resets?.availableCount == 1)
        await #expect(throws: AgentFailure.invalidTransition) {
            try await backend.redeemUsageReset(credit, confirmed: false, audit: { _ in })
        }
        let outcome = try await backend.redeemUsageReset(credit, confirmed: true, audit: { _ in })
        #expect(outcome == .reset)
        let remaining = try await backend.usageSnapshot()
        #expect(remaining.resets?.availableCount == 0)
        #expect(remaining.windows.first?.utilization == 0)
        try fixture.assertComplete()
        try await backend.shutdown()
    }

    @Test func resetBalanceDistinguishesNoCreditsFromUnavailableDetails() throws {
        #expect(CodexUsageResetBalance(nil) == nil)
        let countOnly = try #require(JSONValue.parse(#"{"availableCount":2,"credits":null}"#))
        let balance = try #require(CodexUsageResetBalance(countOnly))
        #expect(balance.availableCount == 2)
        #expect(balance.credits.isEmpty)
        let restricted = try #require(JSONValue.parse(#"""
        {"availableCount":4,"credits":[
          {"id":"expired","resetType":"codexRateLimits","status":"available","expiresAt":10},
          {"id":"in-progress","resetType":"codexRateLimits","status":"redeeming"},
          {"id":"unknown","resetType":"unknown","status":"available"},
          {"id":"ready","resetType":"codexRateLimits","status":"available","expiresAt":60}
        ]}
        """#))
        #expect(CodexUsageResetBalance(restricted, now: Date(timeIntervalSince1970: 30))?.credits.map(\.id) == ["ready"])
    }
}
