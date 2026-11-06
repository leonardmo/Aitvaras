import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

struct CodexOSSConfigurationTests {
    private func configuration() -> CodexOSSConfiguration {
        .init(catalog: { [.init(id: "example:small", name: "Example")] })
    }

    @Test func factoryRequiresExplicitSelectionAndNeverFallsBack() async throws {
        let reply: LocalBackend.Reply = { _, _ in throw AgentFailure.unknown }
        #expect(try LocalChatBackendFactory.make(reply: reply) is LocalBackend)
        #expect(try LocalChatBackendFactory.make(selection: "agent-loop", reply: reply) is LocalBackend)
        let candidate = try LocalChatBackendFactory.make(selection: "codex-oss", reply: reply)
        #expect(candidate is CodexBackend)
        #expect(throws: AgentFailure.invalidRequest) {
            _ = try LocalChatBackendFactory.make(selection: "automatic", reply: reply)
        }
        // Construction and shutdown do not connect to Ollama or launch Codex.
        try await (candidate as? CodexBackend)?.shutdown()
    }

    @Test func exactLaunchArgumentsEnvironmentAndLocalIdentity() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[1:]==['app-server','-c','model_provider="ollama"','-c','local_provider="ollama"','-c','model_providers.ollama.base_url="http://127.0.0.1:11434/v1"','-c','model_providers.ollama.requires_openai_auth=false']
assert not os.environ.get('OLLAMA_HOST')
assert not os.environ.get('OLLAMA_BASE_URL')
assert not os.environ.get('HTTPS_PROXY')
assert os.environ['NO_PROXY']=='127.0.0.1,localhost,::1'
codex_init()
r=read()
assert r['method']=='thread/start'
assert r['params']=={'cwd':root,'model':'example:small','modelProvider':'ollama','approvalPolicy':'untrusted','sandbox':'workspace-write','ephemeral':True}
emit({'id':r['id'],'result':{'thread':{'id':'local-thread','modelProvider':'ollama'},'modelProvider':'ollama','model':'example:small'}})
done()
"""#)
        defer { fixture.remove() }
        var environment = fixture.environment
        environment["OLLAMA_HOST"] = "https://example.invalid"
        environment["OLLAMA_BASE_URL"] = "https://example.invalid"
        environment["HTTPS_PROXY"] = "https://example.invalid"
        let backend = CodexBackend(executable: fixture.executable, environment: environment, oss: configuration())
        let status = try await backend.status()
        #expect(status.authentication == .local)
        #expect(status.accountID == nil)
        try status.require(.tools)
        #expect(throws: AgentFailure.unsupported) { try status.require(.history) }
        #expect(throws: AgentFailure.unsupported) { try status.require(.followups) }
        let run = try await backend.start(.init(directory: fixture.directory, model: "example:small"))
        var events = run.events.makeAsyncIterator()
        #expect(try await events.next()?.kind == .sessionStarted(.init(provider: .local,
            profile: CodexOSSConfiguration.profile, nativeID: "local-thread")))
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["offline", "empty", "cloud"])
    func missingServiceHasUnavailableStatusAndCannotStart(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: "open('launched','w').close(); sys.exit(9)")
        defer { fixture.remove() }
        let config = CodexOSSConfiguration(catalog: {
            if scenario == "offline" { throw AgentFailure.offline }
            return scenario == "empty" ? [] : [.init(id: "example:cloud", name: "Cloud")]
        })
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: config)
        let status = try await backend.status()
        #expect(status.installed)
        #expect(status.authentication == .unavailable)
        #expect(status.capabilities.isEmpty)
        await #expect(throws: scenario == "offline" ? AgentFailure.offline : .unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: "example:small"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
        try await backend.shutdown()
    }

    @Test func missingExecutableIsNotInstalled() async throws {
        let backend = CodexBackend(executable: URL(fileURLWithPath: "/tmp/missing-oss-\(UUID())"),
                                   environment: ["PATH": ""], oss: configuration())
        #expect(try await backend.status().installed == false)
        await #expect(throws: AgentFailure.notInstalled) {
            _ = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp"), model: "example:small"))
        }
    }

    @Test(arguments: ["default", "local", "gpt-example", "example:cloud", "example:small-cloud", "example:small\nmodel_provider=\"openai\""])
    func refusesImplicitMissingOrCloudModelsWithoutLaunching(model: String) async throws {
        let fixture = try BackendExecutableFixture(script: "open('launched','w').close(); sys.exit(9)")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        await #expect(throws: AgentFailure.unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: model))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
        try await backend.shutdown()
    }

    @Test(arguments: ["provider", "threadProvider", "model", "missing"])
    func refusesMismatchedOrMissingProviderEvidenceBeforePrompt(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
assert r['method']=='thread/start'
result={'thread':{'id':'wrong-thread','modelProvider':'ollama'},'modelProvider':'ollama','model':'example:small'}
"""# + "\nscenario='\(scenario)'\n" + #"""
if scenario=='provider': result['modelProvider']='openai'
if scenario=='threadProvider': result['thread']['modelProvider']='openai'
if scenario=='model': result['model']='gpt-example'
if scenario=='missing': del result['modelProvider']
emit({'id':r['id'],'result':result})
open('done','w').close()
r=read()
fail('no prompt after rejected configuration',r)
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        await #expect(throws: AgentFailure.unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: "example:small"))
        }
        try await backend.shutdown()
        try fixture.assertComplete()
    }

    @Test func unsupportedOperationsDoNotLaunchOrLoadModels() async throws {
        let fixture = try BackendExecutableFixture(script: "open('launched','w').close(); sys.exit(9)")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        await #expect(throws: AgentFailure.unsupported) { try await backend.signIn { _ in Issue.record("Unexpected browser") } }
        await #expect(throws: AgentFailure.unsupported) { _ = try await backend.rateLimits() }
        await #expect(throws: AgentFailure.unsupported) { _ = try await backend.commands(directory: fixture.directory) }
        await #expect(throws: AgentFailure.unsupported) { _ = try await backend.files(query: "file", directory: fixture.directory) }
        await #expect(throws: AgentFailure.unsupported) { _ = try await backend.listSessions(folder: fixture.directory, cursor: nil) }
        await #expect(throws: AgentFailure.unsupported) {
            _ = try await backend.start(.init(directory: fixture.directory, model: "example:small", effort: "high"))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("launched").path))
        try await backend.shutdown()
    }

    @Test func turnFailureDoesNotRetryOrSelectACloudModel() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read()
assert r['method']=='thread/start'
emit({'id':r['id'],'result':{'thread':{'id':'local-thread','modelProvider':'ollama'},'modelProvider':'ollama','model':'example:small'}})
r=read()
assert r['method']=='turn/start'
emit({'id':r['id'],'error':{'code':-32000,'message':'local model unavailable'}})
open('done','w').close()
r=read()
fail('no retry, account request or fallback',r)
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        let run = try await backend.start(.init(directory: fixture.directory, model: "example:small"))
        let unsupported = AgentInput(text: "file", attachments: [try .init(name: "example.txt", data: Data("example".utf8))])
        await #expect(throws: AgentFailure.unsupported) {
            try await run.send(unsupported, willDeliver: { Issue.record("Unsupported attachment reached delivery") })
        }
        await #expect(throws: (any Error).self) { try await run.send(.init(text: "example"), willDeliver: {}) }
        let events = try await collectTurn(run)
        #expect(events.contains { if case .turnEnded(.failed) = $0.kind { true } else { false } })
        try await run.shutdown(); try await backend.shutdown()
        try fixture.assertComplete()
    }

    @Test(arguments: ["tags", "offline", "garbage", "malformed", "redirect"])
    func metadataOnlyDiscoveryRejectsRemoteModelsAndInvalidService(scenario: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaMetadataProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Scenario": scenario]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        if scenario == "tags" {
            #expect(try await CodexOSSConfiguration.installedModels(session: session)
                == [.init(id: "example:small", name: "example:small")])
        } else {
            await #expect(throws: (any Error).self) { _ = try await CodexOSSConfiguration.installedModels(session: session) }
        }
    }

    @Test func localManagerStartsFreshThreadsAndIncludesCompletedContextOnce() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for n in range(2):
    r=read()
    assert r['method']=='thread/start' and 'threadId' not in r['params'] and r['params']['ephemeral']==True
    thread='local-'+str(n)
    emit({'id':r['id'],'result':{'thread':{'id':thread,'modelProvider':'ollama'},'modelProvider':'ollama','model':'example:small'}})
    r=read()
    assert r['method']=='turn/start' and r['params']['threadId']==thread
    text=r['params']['input'][0]['text']
    assert text=='first' if n==0 else text.count('[user · local] first')==1 and '[assistant · local] reply' in text and text.endswith('\nsecond')
    turn='turn-'+str(n)
    emit({'id':r['id'],'result':{'turn':{'id':turn}}})
    emit({'method':'item/completed','params':{'threadId':thread,'turnId':turn,'item':{'type':'agentMessage','id':'reply-'+str(n),'text':'reply'}}})
    emit({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        let stores = try inMemoryStores()
        var (chat, session) = try agentStoreChat(stores, provider: .local, cwd: fixture.directory.path)
        session.model = "example:small"
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        try await manager.configure(session)
        for text in ["first", "second"] {
            let input = AgentInput(text: text)
            try await manager.send(chatID: chat.id, provider: .local, input: input)
            try await waitAgentCondition { try stores.agentTurn(id: input.id)?.state == .completed }
            #expect(try stores.agentTurn(id: input.id)?.delivery == .acknowledged)
        }
        #expect(try stores.agentEntries(chatID: chat.id).filter { $0.kind == "assistant" }.count == 2)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await manager.shutdown(); try await backend.shutdown()
    }

    @Test(arguments: ["write-ask", "readonly", "interrupt"])
    func recordedCodexProtocolAlsoRunsUnderLocalConfiguration(name: String) async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/codex/\(name).jsonl")
        let recording = try Data(contentsOf: source).base64EncodedString()
        // These are subscription recordings, not evidence of an Ollama run.
        // Change only the selected model/provider and retain all native events,
        // tool requests, approval responses and interruption frames.
        let script = "recording=base64.b64decode('\(recording)').decode().replace('gpt-6-luna','example:small')\n" + #"""
codex_init()
ids={}
policy=None
sandbox=None
for line in recording.replace('/tmp/project',root).splitlines()[3:]:
    if line.startswith('# SENT '):
        expected=json.loads(line[7:])
        actual=read()
        if 'id' in expected:
            ids[expected['id']]=actual.get('id')
            expected['id']=actual.get('id')
        if expected.get('method')=='thread/start':
            expected['params']['modelProvider']='ollama'
            policy=expected['params']['approvalPolicy']
            sandbox=expected['params']['sandbox']
        if expected.get('method')=='turn/start':
            expected['params']['approvalPolicy']=policy
            expected['params']['sandboxPolicy']={'type':'readOnly' if sandbox=='read-only' else 'workspaceWrite'}
        if expected!=actual: fail(expected,actual)
    elif line.startswith('{'):
        value=json.loads(line)
        if 'method' not in value and 'id' in value:
            value['id']=ids.get(value['id'],value['id'])
            if 'thread' in value.get('result',{}):
                value['result']['modelProvider']='ollama'
                value['result']['thread']['modelProvider']='ollama'
        emit(value)
done()
"""#
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, oss: configuration())
        let run = try await backend.start(.init(directory: fixture.directory, model: "example:small", mode: name == "write-ask" ? .ask : .plan))
        await #expect(throws: AgentFailure.unsupported) { try await run.followup(.init(text: "unsupported"), willDeliver: {}) }
        let prompt = try fixture.prompt(provider: "codex", name: name)
        try await run.send(.init(text: prompt), willDeliver: {})
        let events = try await collectTurn(run, interrupt: name == "interrupt")
        #expect(events.last?.kind == .turnEnded(name == "interrupt" ? .interrupted : .completed))
        #expect(events.contains { $0.kind == .delivery(.acknowledged) })
        #expect(events.allSatisfy { $0.scope.session?.provider == .local })
        if name == "write-ask" { #expect(events.contains { if case .request = $0.kind { true } else { false } }) }
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }
}

private final class OllamaMetadataProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url == CodexOSSConfiguration.baseURL.appendingPathComponent("api/tags"), request.httpMethod == "GET" else {
            Issue.record("Discovery attempted a non-metadata request")
            client?.urlProtocol(self, didFailWithError: AgentFailure.invalidRequest); return
        }
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario")
        if scenario == "offline" { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let body = scenario == "garbage" ? "garbage" : scenario == "malformed" ? #"{"models":[{}]}"# : #"{"models":[{"name":"example:small"},{"name":"example:small"},{"name":"example:cloud"},{"name":"example:small-cloud"},{"name":"remote:small","remote_host":"https://example.invalid"},{"name":"remote:other","remote_model":"other"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: scenario == "redirect" ? 302 : 200,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
