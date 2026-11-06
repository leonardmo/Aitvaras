import Foundation
import Testing
@testable import AitvarasAgents

struct CodexBackendTests {
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
