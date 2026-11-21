import Darwin
import Foundation
import Synchronization
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayChatLaunchTests {
    @Test func providerFixtureDeadlineSurvivesInheritedSignalMask() async throws {
        let fixture = try BackendExecutableFixture(timeoutSeconds: 1, script: "signal.pause()")
        defer { fixture.remove() }
        let launcher = """
        import os, signal, sys
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        os.execv(sys.argv[1], [sys.argv[1]])
        """
        let result = try await OneShotProcess.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-c", launcher, fixture.executable.path], environment: [:], timeout: .seconds(5))
        #expect(!result.timedOut)
        #expect(result.exitCode == 128 + SIGALRM)
    }

    @Test func claudeChatCombinesGatewayWithNativeGatesAndProbesStayNative() async throws {
        let fixture = try BackendExecutableFixture(timeoutSeconds: 10, script: #"""
config_path = sys.argv[sys.argv.index('--mcp-config')+1]
servers = json.load(open(config_path))['mcpServers']
assert ('--strict-mcp-config' in sys.argv) == os.path.exists('expect-strict')
assert '--setting-sources' not in sys.argv
assert json.loads(sys.argv[sys.argv.index('--settings')+1]) == {'disabledMcpjsonServers':['unapproved']}
if 'aitvaras' in servers:
    assert set(servers) == {'aitvaras','native'}
    assert servers['aitvaras']['command'].endswith('/aitvaras-mcp')
    assert servers['aitvaras']['env']['AITVARAS_STATE_DIR'] == root
    open('gateway-runtime','w').write(config_path)
else:
    assert set(servers) == {'native'}
    open('native-probe','w').close()
claude_init()
if 'aitvaras' in servers:
    assert read()['type'] == 'user'
    emit({'type':'result','is_error':False})
sys.stdin.readline()
"""#)
        defer { fixture.remove() }
        try Data(#"{"mcpServers":{"unapproved":{"command":"example"}}}"#.utf8)
            .write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let registry = GatewayLaunchRegistry()
        let cancelled = Mutex([UUID]())
        let gateway = GatewayChatLaunch(configuration: .init(executable: fixture.directory.appendingPathComponent("aitvaras-mcp"),
            stateDirectory: fixture.directory), registry: registry, cancelApprovals: { id in cancelled.withLock { $0.append(id) } })
        let projectID = UUID(), chatID = UUID()
        let policy = AgentMCPLaunchPolicy(stateDirectory: fixture.directory, load: { _, project in
            .init(projectID: project ?? projectID, globalServers: ["native": .init(command: "example")])
        }, audit: { _ in })
        // The sandbox can deny inspection of ancestors. Both paths must
        // apply the resolver's same fail-closed strict mode to the launch.
        if try policy.snapshot(directory: fixture.directory, projectID: projectID).status.repositoryUnreadable {
            try Data().write(to: fixture.directory.appendingPathComponent("expect-strict"))
        }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment,
            mcpPolicy: policy, probeDirectory: fixture.directory, gateway: gateway)
        _ = try await backend.models()
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("native-probe").path))
        #expect(await registry.activeLaunches().isEmpty)
        var config = AgentSessionConfiguration(directory: fixture.directory, model: "default", projectID: projectID)
        config.gatewayChatID = chatID
        let run = try await backend.start(config)
        let launches = await registry.activeLaunches()
        #expect(launches.count == 1)
        let launch = try #require(launches.first)
        #expect(launch.context == .init(client: .claude, projectID: projectID))
        #expect(launch.chatID == chatID)
        let path = try String(contentsOf: fixture.directory.appendingPathComponent("gateway-runtime"), encoding: .utf8)
        try await run.send(.init(text: "Example"), willDeliver: {})
        #expect(try await collectTurn(run).last?.kind == .turnEnded(.completed))
        #expect(cancelled.withLock { $0 } == [launch.id])
        try await run.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path))
        await registry.shutdown()
    }

    @Test func failedRegistrationReapsProviderBeforeItCanExecute() async throws {
        let fixture = try BackendExecutableFixture(script: "open('executed','w').close()")
        defer { fixture.remove() }
        let proc = StreamingProcess(executable: fixture.executable, arguments: [],
            currentDirectory: fixture.directory, environment: [:])
        let wire = AgentWire(process: proc, format: .codex)
        await #expect(throws: GatewayLaunchRegistryError.unauthorized) {
            try await wire.open(receive: { _, _ in }, disconnected: { _ in },
                register: { _ in throw GatewayLaunchRegistryError.unauthorized })
        }
        #expect(!proc.isRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("executed").path))
    }

    @Test func codexChatProcessesHoldDistinctProjectAuthorityAndCloseIndependently() async throws {
        let fixture = try BackendExecutableFixture(timeoutSeconds: 12, script: #"""
codex_init()
if sys.argv[1:] == ['app-server']:
    for _ in range(4):
        request = read()
        assert request['method'] == 'account/read'
        account(request)
    sys.exit(0)
assert len(sys.argv) == 4 and sys.argv[1] == '-c' and sys.argv[3] == 'app-server'
assert sys.argv[2].startswith('mcp_servers.aitvaras={ command = ')
assert ('AITVARAS_STATE_DIR = "' + root + '"') in sys.argv[2]
start_thread('thread-' + str(os.getpid()))
sys.stdin.readline()
"""#)
        defer { fixture.remove() }
        let registry = GatewayLaunchRegistry()
        let gateway = GatewayChatLaunch(configuration: .init(executable: fixture.directory.appendingPathComponent("aitvaras-mcp"),
            stateDirectory: fixture.directory), registry: registry)
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment, gateway: gateway)
        #expect(try await backend.status().authentication == .subscription)
        #expect(await registry.activeLaunches().isEmpty)
        let firstProject = UUID(), secondProject = UUID(), firstChat = UUID(), secondChat = UUID()
        // Shared cwd cannot be used as a proxy for the selected project.
        var first = AgentSessionConfiguration(directory: fixture.directory, model: "default", projectID: firstProject)
        first.gatewayChatID = firstChat
        var second = AgentSessionConfiguration(directory: fixture.directory, model: "default", projectID: secondProject)
        second.gatewayChatID = secondChat
        let firstRun = try await backend.start(first)
        var secondRun: (any AgentRun)?
        do {
            secondRun = try await backend.start(second)
            let launches = await registry.activeLaunches()
            let firstLaunch = try #require(launches.first { $0.chatID == firstChat })
            let secondLaunch = try #require(launches.first { $0.chatID == secondChat })
            #expect(launches.count == 2)
            #expect(firstLaunch.context == .init(client: .codex, projectID: firstProject))
            #expect(secondLaunch.context == .init(client: .codex, projectID: secondProject))
            #expect(firstLaunch.root != secondLaunch.root)
            try await firstRun.shutdown()
            for _ in 0..<100 where await registry.activeLaunches().contains(firstLaunch) {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await registry.activeLaunches() == [secondLaunch])
            #expect(try await backend.status().authentication == .subscription)
            try await secondRun?.shutdown()
            try await backend.shutdown()
        } catch {
            try? await firstRun.shutdown()
            try? await secondRun?.shutdown()
            try? await backend.shutdown()
            await registry.shutdown()
            throw error
        }
        await registry.shutdown()
    }
}
