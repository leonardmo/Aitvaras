import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPLaunchTests {
    @Test func claudeDisablesUnapprovedServersAndLoadsAppSecretsOnlyFromRuntime() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--setting-sources' not in sys.argv and '--strict-mcp-config' not in sys.argv
assert '--include-hook-events' in sys.argv
settings=json.loads(sys.argv[sys.argv.index('--settings')+1])
assert settings=={'disabledMcpjsonServers':['echo']}
path=sys.argv[sys.argv.index('--mcp-config')+1]
assert os.stat(path).st_mode & 0o777 == 0o600
config=json.load(open(path))
assert set(config['mcpServers'])=={'helper'}
assert config['mcpServers']['helper']['env']['ACCESS']=='synthetic-runtime-value'
open('runtime-path','w').write(path)
claude_init()
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        try Data(#"{"mcpServers":{"echo":{"command":"echo","timeout":12}}}"#.utf8)
            .write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default", projectID: project.id))
        try fixture.assertComplete()
        let path = try String(contentsOf: fixture.directory.appendingPathComponent("runtime-path"), encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: path))
        try await run.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
        let serialized = try await stores.db.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM kv").map { String(describing: $0) }
                + Row.fetchAll(db, sql: "SELECT * FROM activityEvent").map { String(describing: $0) }
        }.joined()
        #expect(!serialized.contains("synthetic-runtime-value"))
    }

    @Test(arguments: [false, true]) func unreadableRepoUsesStrictConfigAndReportsState(withAppServer: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--strict-mcp-config' in sys.argv
assert '--include-hook-events' in sys.argv
assert json.loads(sys.argv[sys.argv.index('--settings')+1])=={'disabledMcpjsonServers':[]}
assert ('--mcp-config' in sys.argv)==os.path.exists('with-app')
claude_init()
done()
"""#)
        defer { fixture.remove() }
        try Data("invalid".utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let stores = try inMemoryStores()
        if withAppServer {
            try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo")])
            try Data().write(to: fixture.directory.appendingPathComponent("with-app"))
        }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
                                    mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        #expect(run.mcpSetup?.repositoryUnreadable == true)
        #expect(run.mcpSetup?.notice?.contains("Repo servers are disabled") == true)
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test(arguments: ["commands", "models"]) func catalogProbesUseTheSameGatingAndRemoveTheirRuntimeFile(catalog: String) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--include-hook-events' in sys.argv
assert json.loads(sys.argv[sys.argv.index('--settings')+1])=={'disabledMcpjsonServers':['echo']}
path=sys.argv[sys.argv.index('--mcp-config')+1]
open('runtime-path','w').write(path)
r=read()
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'commands':[{'name':'review','argumentHint':'[file]'}],'models':[{'value':'test-model'}]}}})
open('done','w').close()
assert sys.stdin.readline()==''
"""#)
        defer { fixture.remove() }
        try Data(#"{"mcpServers":{"echo":{"command":"echo"}}}"#.utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let stores = try inMemoryStores()
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo")])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
                                    mcpPolicy: mcpTestPolicy(stores, root: fixture.directory), probeDirectory: fixture.directory)
        if catalog == "commands" {
            #expect(try await backend.commands(directory: fixture.directory).first?.argumentHint == "[file]")
        } else { #expect(try await backend.models().map(\.id) == ["opus", "test-model"]) }
        let path = try String(contentsOf: fixture.directory.appendingPathComponent("runtime-path"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: path))
        try fixture.assertComplete()
    }

    @Test(arguments: ["startup", "crash", "garbage", "abort"])
    func claudeRuntimeIsRemovedOnEveryTransportExit(scenario: String) async throws {
        let body: String
        switch scenario {
        case "startup": body = "sys.exit(9)"
        case "crash": body = "claude_init()\nread()\nsys.exit(9)"
        case "garbage": body = "claude_init()\nread()\nprint('garbage',flush=True)"
        default: body = "claude_init()\ndone()"
        }
        let fixture = try BackendExecutableFixture(script: "path=sys.argv[sys.argv.index('--mcp-config')+1]\nopen('runtime-path','w').write(path)\n" + body)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo")])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
                                    mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        if scenario == "startup" {
            await #expect(throws: (any Error).self) { try await backend.start(.init(directory: fixture.directory, model: "default")) }
        } else {
            let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
            if scenario == "abort" { await run.abort() }
            else {
                try await run.send(.init(text: "Example"), willDeliver: {})
                _ = try await collectTurn(run)
            }
            try await run.shutdown()
        }
        let path = try String(contentsOf: fixture.directory.appendingPathComponent("runtime-path"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func managerReusesOnlyMatchingSetupAndRetriesAfterSignInWithoutPersistingRuntimePaths() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
open('launches','a').write('launch\n')
claude_init()
for _ in range(4):
    r=read()
    if r.get('type')!='user': continue
    emit({'type':'result','is_error':False})
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) }, mcpPolicy: policy)
        for index in 0..<3 {
            if index == 2 {
                try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
            }
            let input = AgentInput(text: "Example")
            try await manager.send(chatID: chat.id, provider: .claude, input: input)
            try await waitMCPLaunch { try await manager.state(chatID: chat.id).outcome == .completed }
            let count = try String(contentsOf: fixture.directory.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").count
            #expect(count == (index == 2 ? 2 : 1))
        }
        let rows = try await stores.db.queue.read { try Row.fetchAll($0, sql: "SELECT * FROM agentChatSession").map { String(describing: $0) }.joined() }
        #expect(!rows.contains("Runtime/mcp")); #expect(!rows.contains("synthetic-runtime-value"))
        try await manager.shutdown()

        // Prepared input survives sign-out; the next explicit retry recomputes setup.
        try Data(#"{"loggedIn":false}"#.utf8).write(to: fixture.directory.appendingPathComponent("auth-status.json"))
        let retryManager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in }, mcpPolicy: policy)
        let input = AgentInput(text: "Retry")
        await #expect(throws: AgentFailure.authRequired) { try await retryManager.send(chatID: chat.id, provider: .claude, input: input) }
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("auth-status.json"))
        try await retryManager.resendPrepared(turnID: input.id)
        try await waitMCPLaunch { try await retryManager.state(chatID: chat.id).outcome == .completed }
        try await retryManager.shutdown()
    }

    @Test func unknownSystemEventsNeverBecomeTranscriptRows() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'system','subtype':'hook_started','hook_id':'hook-example','private':'never-forward'})
emit({'type':'system','subtype':'future','private':'never-forward'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(!events.contains { if case .unknown = $0.kind { true } else { false } })
        try await run.shutdown()
    }

    @Test(arguments: ["stop", "shutdown"])
    func cancellingManagerDuringInitializationRemovesRuntimeAndPreventsDelivery(action: String) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
path=sys.argv[sys.argv.index('--mcp-config')+1]
open('runtime-path','w').write(path)
read()
open('starting','w').close()
for _ in range(10): time.sleep(1)
sys.exit(0)
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo")])
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in }, mcpPolicy: policy)
        let input = AgentInput(text: "Example")
        let owner = chat.id
        let task = Task { try await manager.send(chatID: owner, provider: .claude, input: input) }
        let marker = fixture.directory.appendingPathComponent("starting").path
        try await waitMCPLaunch { FileManager.default.fileExists(atPath: marker) }
        if action == "stop" { try await manager.stop(chatID: owner) }
        else { try await manager.shutdown() }
        await #expect(throws: (any Error).self) { try await task.value }
        let path = try String(contentsOf: fixture.directory.appendingPathComponent("runtime-path"), encoding: .utf8)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        #expect(try await manager.state(chatID: owner).outcome == .interrupted)
        try await manager.shutdown()
    }

    @Test func repoChangeWhileSecretsResolvePreventsLaunchAndErasesRuntime() async throws {
        let fixture = try BackendExecutableFixture(script: "open('unexpected-launch','w').close()\nclaude_init()\ndone()")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let file = fixture.directory.appendingPathComponent(".mcp.json")
        try Data(#"{"mcpServers":{"echo":{"command":"echo"}}}"#.utf8).write(to: file)
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let policy = AgentMCPLaunchPolicy(stateDirectory: fixture.directory, load: { directory, projectID in
            try stores.agentMCPLaunchContext(directory: directory, projectID: projectID)
        }, audit: { _ = try stores.record($0) }, resolveSecret: { _ in
            try Data(#"{"mcpServers":{"echo":{"command":"changed"}}}"#.utf8).write(to: file)
            return "synthetic-runtime-value"
        })
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy)
        await #expect(throws: AgentFailure.invalidTransition) { try await backend.start(.init(directory: fixture.directory, model: "default")) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-launch").path))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.directory.appendingPathComponent("Runtime").path)
            .filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func setupChangedDuringAcceptanceCannotReuseOldAuthority() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, cwd: fixture.directory.path)
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ in }, mcpPolicy: policy)
        try await manager.send(chatID: chat.id, provider: .claude, input: .init(text: "First"))
        try await waitMCPLaunch { try await manager.state(chatID: chat.id).outcome == .completed }
        let input = AgentInput(text: "Second")
        await #expect(throws: AgentFailure.invalidTransition) {
            try await manager.send(chatID: chat.id, provider: .claude, input: input, onAccepted: {
                try? stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo")])
            })
        }
        #expect(try stores.agentTurn(id: input.id)?.delivery == .prepared)
        try await manager.shutdown()
    }
}

func mcpTestPolicy(_ stores: Stores, root: URL) -> AgentMCPLaunchPolicy {
    AgentMCPLaunchPolicy(stateDirectory: root, load: { directory, projectID in
        try stores.agentMCPLaunchContext(directory: directory, projectID: projectID)
    }, audit: { _ = try stores.record($0) }, resolveSecret: { _ in "synthetic-runtime-value" })
}

private func waitMCPLaunch(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(10))
    }
}
