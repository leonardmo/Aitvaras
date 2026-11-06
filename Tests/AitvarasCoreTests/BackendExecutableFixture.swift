import Foundation
import Testing
@testable import AitvarasAgents

/// Executes a generated provider binary, exercising the production pipe path.
/// The executable compares JSON trees, never JSON spelling or key order.
struct BackendExecutableFixture {
    let directory: URL
    let executable: URL
    var environment: [String: String] { ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "must-be-removed", "OPENAI_API_KEY": "must-be-removed"] }

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-backend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("provider")
        try ("#!/usr/bin/python3\n" + Self.prelude + "\n" + script).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    init(provider: String, name: String) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/\(provider)/\(name).jsonl")
        let recording = try String(contentsOf: url, encoding: .utf8)
        let data = Data(recording.utf8).base64EncodedString()
        try self.init(script: "recording = base64.b64decode('\(data)').decode()\n" + Self.replay)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func assertComplete() throws {
        let failure = directory.appendingPathComponent("failure")
        if FileManager.default.fileExists(atPath: failure.path) {
            let message = try String(contentsOf: failure, encoding: .utf8)
            Issue.record("\(message)")
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("done").path))
    }
    func prompt(provider: String, name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/\(provider)/\(name).jsonl")
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") where line.hasPrefix("# SENT ") {
            let value = JSONValue.parse(String(line.dropFirst(7)))!
            if let text = value["message"]?["content"]?.stringValue ?? value["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue {
                return text.replacingOccurrences(of: "/tmp/project", with: directory.path)
            }
        }
        throw AgentFailure.invalidRequest
    }
    static let prelude = #"""
import sys, os, json, time, base64, uuid
root = os.path.dirname(os.path.abspath(__file__))
os.chdir(root)
def emit(value):
    print(json.dumps(value), flush=True)
    time.sleep(0.002)
def read():
    line = sys.stdin.readline()
    if not line: sys.exit(0)
    return json.loads(line)
def done():
    open('done','w').close()
    while sys.stdin.readline(): pass
def fail(expected, actual):
    open('failure','w').write('Expected: '+repr(expected)+'\nActual: '+repr(actual))
    sys.exit(9)
assert not os.environ.get('ANTHROPIC_API_KEY')
assert not os.environ.get('OPENAI_API_KEY')
if sys.argv[1:3] == ['auth','status']:
    emit(json.load(open('auth-status.json')) if os.path.exists('auth-status.json') else {'loggedIn':True,'authMethod':'claude.ai','apiKeySource':'none','apiProvider':'firstParty','subscriptionType':'pro'})
    sys.exit(0)
def codex_init():
    request = read()
    assert request['method'] == 'initialize'
    emit({'id':request['id'],'result':{}})
    assert read()['method'] == 'initialized'
def account(request):
    emit({'id':request['id'],'result':{'account':{'type':'chatgpt'},'requiresOpenaiAuth':True}})
def start_thread(thread='thread-test'):
    request=read()
    assert request['method']=='account/read'
    account(request)
    request=read()
    assert request['method'] in ['thread/start','thread/resume']
    emit({'id':request['id'],'result':{'thread':{'id':thread,'modelProvider':'openai'}}})
def claude_init():
    request=read()
    assert request['request']['subtype']=='initialize'
    emit({'type':'control_response','response':{'subtype':'success','request_id':request['request_id'],'response':{'models':[{'value':'test-model'}]}}})
"""#
    static let replay = #"""
lines = recording.replace('/tmp/project',root).splitlines()
# The recorder pipelined its first prompt. Release the recorded initialization
# response before awaiting that prompt so start() can complete without delivery.
if '--input-format' in sys.argv:
    i=next(i for i,l in enumerate(lines) if l.startswith('{') and json.loads(l).get('type')=='control_response')
    response=lines.pop(i)
    lines.insert(1,response)
ids={}
claude_ids={}
policy=None
sandbox=None
for line in lines:
    if line.startswith('# SENT '):
        expected=json.loads(line[7:])
        actual=read()
        while actual.get('method')=='account/read':
            assert actual['params']=={'refreshToken':False}
            account(actual)
            actual=read()
        if expected.get('method'):
            if 'id' in expected:
                ids[expected['id']]=actual.get('id')
                expected['id']=actual.get('id')
            if expected['method']=='initialize':
                assert set(actual['params']['clientInfo'])=={'name','title','version'}
                expected['params']['clientInfo']=actual['params']['clientInfo']
                expected['params']['capabilities']={'experimentalApi':True}
            if expected['method']=='thread/start':
                expected['params'].pop('ephemeral',None)
                assert actual['params'].get('ephemeral') is not True
                policy=expected['params']['approvalPolicy']
                sandbox=expected['params']['sandbox']
            if expected['method']=='turn/start':
                expected['params']['approvalPolicy']=policy
                expected['params']['sandboxPolicy']={'type':'readOnly' if sandbox=='read-only' else 'workspaceWrite'}
        if expected.get('type')=='control_request':
            if expected['request']['subtype']=='initialize':
                expected['request']['hooks']={'PreToolUse':[{'matcher':None,'hookCallbackIds':['pre']}],'PostToolUse':[{'matcher':None,'hookCallbackIds':['post']}]}
            claude_ids[expected['request_id']]=actual.get('request_id')
            expected['request_id']=actual.get('request_id')
        if expected.get('type')=='user':
            # Aitvaras supplies a stable UUID, retained in native JSONL.
            assert str(uuid.UUID(actual['uuid'])).upper()==actual['uuid'].upper()
            expected['uuid']=actual['uuid']
        if expected!=actual: fail(expected,actual)
    elif line.startswith('{'):
        value=json.loads(line)
        if value.get('type')=='control_response':
            rid=value['response']['request_id']
            value['response']['request_id']=claude_ids.get(rid,rid)
        if 'method' not in value and 'id' in value:
            value['id']=ids.get(value['id'],value['id'])
        emit(value)
done()
"""#
}

func collectTurn(_ run: any AgentRun, interrupt: Bool = false,
                 answer: @Sendable (AgentRequest) -> AgentResponse = { request in
                     switch request.kind {
                     case .preToolUse, .postToolUse: return .continueHook
                     case .questions(let questions): return .answers(Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [$0.options.first?.label ?? "answer"]) }))
                     default: return .allow(updatedInput: nil)
                     }
                 }) async throws -> [AgentEvent] {
    var events: [AgentEvent] = [], stopped = false
    for try await event in run.events {
        events.append(event)
        if case .request(let request) = event.kind { try await run.respond(to: request, with: answer(request)) }
        if interrupt, !stopped, case .textDelta = event.kind { stopped = true; try await run.interrupt() }
        if case .turnEnded = event.kind { return events }
    }
    throw AgentFailure.unknown
}
