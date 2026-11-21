import Darwin
import Foundation
import Synchronization
import Testing
import XCTest
import AitvarasCore
import AitvarasConnectors
import AitvarasStore
@testable import AitvarasAgent
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayG1CoreAcceptanceTests {
    @Test func connectedProjectsShareScopedMemoryAndOneOAuthSession() async throws {
        let fixture = try await GatewayG1Fixture()
        let claude = fixture.connect(.claude, project: fixture.first)
        let codex = fixture.connect(.codex, project: fixture.first)
        let other = fixture.connect(.codex, project: fixture.second)
        await gatewayReady(claude)
        await gatewayReady(codex)
        await gatewayReady(other)
        for client in [claude, codex] {
            #expect(await names(client).contains("issues_sign_in"))
        }
        #expect(await names(other) == ["other_sign_in"])

        try await fixture.signIn()
        for client in [claude, codex] {
            let change = try await AsyncDeadline.run(for: .seconds(10)) {
                var notifications = client.notifications.makeAsyncIterator()
                return await notifications.next()
            }
            #expect(change.flatMap { JSONValue.parse(String(decoding: $0, as: UTF8.self)) }?["method"]
                == .string("notifications/tools/list_changed"))
            let listed = await names(client)
            #expect(listed.contains("issues_update_issue") && !listed.contains("issues_sign_in"))
            let memory = await gatewayCall(client, name: "memory_search", arguments: ["query": .string("orchard")])
            #expect(gatewayText(memory)?.contains("orchard fixture fact") == true)
            let call = Task { await gatewayCall(client, name: "issues_update_issue") }
            defer { call.cancel() }
            let approval = try await fixture.pendingApproval()
            #expect(approval.toolName == "issues_update_issue")
            #expect(await fixture.approvals.decide(id: approval.id, allow: true))
            #expect(await gatewayText(call.value) == "Synthetic issue")
        }
        #expect(await names(other) == ["other_sign_in"])
        #expect(await fixture.remote.registrations == 1)
        let counts = await fixture.remote.counts()
        #expect(counts.initialize == 1 && counts.calls == 2)
        await claude.close(); await codex.close(); await other.close()
    }

    private func names(_ gateway: MCPGateway) async -> Set<String> {
        let result = await gatewayFrame(gateway, method: "tools/list", id: 3)
        return Set(result?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
    }
}

final class GatewayG1HostAcceptanceTests: XCTestCase {
    @MainActor
    func testFakeCLIsThroughLauncherAndUnixGateway() async throws {
        var template = Array("/tmp/ait-g1.XXXXXX".utf8CString)
        let path = try XCTUnwrap(template.withUnsafeMutableBufferPointer {
            mkdtemp($0.baseAddress!).map { String(cString: $0) }
        })
        let root = URL(fileURLWithPath: path, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = GatewayEndpoint(stateDirectory: root)
        let fixture = try await GatewayG1Fixture(root: root)
        let fakeCLI = root.appendingPathComponent("fake-provider")
        let relay = root.appendingPathComponent("aitvaras-mcp")
        try Self.installFixture(Self.cli, at: fakeCLI)
        try Self.installFixture(Self.relay, at: relay)

        for (client, project, mode) in [
            (GatewayLaunchContext.Client.claude, fixture.first, "first"),
            (.codex, fixture.first, "shared"), (.codex, fixture.second, "other")
        ] {
            let registry = GatewayLaunchRegistry()
            let startingDirectory = root.appendingPathComponent(project.id == fixture.first.id ? "first" : "second")
            let service = GatewaySocketService(endpoint: endpoint, registry: registry,
                verifyLauncher: { $0.identity.pid == getpid() },
                resolveContext: { _, client in
                    try fixture.stores.gatewayLaunchContext(client: client, startingDirectory: startingDirectory)
                },
                makeSession: { fixture.service.connect(invocation: $0, authorize: $1) })
            do { try await service.start() }
            catch GatewayTransportError.system(let name, let code) where code == EPERM || code == EACCES {
                throw XCTSkip("Gateway acceptance requires Unix sockets. \(name) denied, errno \(code).")
            }

            let startup = GatewayStartup(endpoint: endpoint, appBundle: root, budget: .seconds(5),
                dial: { try GatewayUnixSocket.connect($0, until: $1) },
                openApp: { _, _, _ in throw GatewayTransportError.appNotReady })
            let marker = root.appendingPathComponent("ready-" + mode)
            let done = root.appendingPathComponent("done-" + mode)
            let env = ["PATH": "/usr/bin:/bin", "G1_MODE": mode, "G1_CLIENT": client.rawValue,
                "G1_SOCKET": endpoint.socketURL.path, "G1_PROFILE": endpoint.profile, "G1_RELAY": relay.path,
                "G1_READY": marker.path, "G1_DONE": done.path, "AITVARAS_STATE_DIR": endpoint.stateDirectory.path]

            var running: Task<Int32, Error>?
            do {
                if mode == "first" {
                    var plainEnvironment = env
                    plainEnvironment["G1_MODE"] = "plain"
                    let plain = try await OneShotProcess.run(executable: fakeCLI, arguments: [], environment: plainEnvironment,
                                                            timeout: .seconds(20))
                    XCTAssertEqual(plain.exitCode, 0, plain.stderr)
                    XCTAssertFalse(plain.timedOut)
                }

                let launcher = GatewayLauncher(gateway: .init(executable: relay, stateDirectory: endpoint.stateDirectory),
                    register: { client in (try await startup.connect(role: .register(client))).stop() },
                    locate: { _, _ in fakeCLI },
                    supervise: { try GatewayPTY.run(executable: $0, arguments: $1, environment: $2,
                                                    interactive: false, testTimeoutMS: 50_000) })
                let run = Task.detached { try await launcher.run(arguments: [client.rawValue], environment: env) }
                running = run
                if mode == "first" {
                    try await Self.waitForFile(marker)
                    try await fixture.signIn()
                }
                if mode != "other" {
                    let approval = try await fixture.pendingApproval()
                    XCTAssertEqual(approval.invocation.context, .init(client: client, projectID: project.id))
                    XCTAssertEqual(approval.toolName, "issues_update_issue")
                    XCTAssertEqual(approval.risk, .confirmable)
                    let allowed = await fixture.approvals.decide(id: approval.id, allow: true)
                    XCTAssertTrue(allowed)
                    try await Self.waitForFile(done)
                    let launches = await registry.activeLaunches()
                    let launch = try XCTUnwrap(launches.first)
                    let revoked = await registry.revoke(id: launch.id)
                    XCTAssertTrue(revoked)
                }
                let status = try await run.value
                XCTAssertEqual(status, 0, "Fake \(client.rawValue) failed its \(mode) protocol assertions")
                await service.stop()
            } catch {
                await service.stop()
                _ = try? await running?.value
                throw error
            }
        }
        let registrations = await fixture.remote.registrations
        let counts = await fixture.remote.counts()
        XCTAssertEqual(registrations, 1)
        XCTAssertEqual(counts.initialize, 1)
        XCTAssertEqual(counts.calls, 2)
    }

    @MainActor
    func testBuiltApplicationHelpersPassPinAndSignatureChecks() async throws {
        guard let path = ProcessInfo.processInfo.environment["AITVARAS_GATEWAY_TEST_APP"], !path.isEmpty else {
            throw XCTSkip("Set AITVARAS_GATEWAY_TEST_APP to the host-built Aitvaras.app.")
        }
        let app = URL(fileURLWithPath: path, isDirectory: true)
        let main = try XCTUnwrap(Bundle(url: app)?.executableURL)
        _ = try GatewayCodeIdentity(executable: main, signingLocation: app)
        for helper in ["Contents/Helpers/aitvaras", "Contents/MacOS/aitvaras-mcp"] {
            let executable = app.appendingPathComponent(helper)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), helper)
            _ = try GatewayCodeIdentity(executable: executable)
        }
        let seal = try await OneShotProcess.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", app.path], timeout: .seconds(25))
        XCTAssertFalse(seal.timedOut)
        XCTAssertEqual(seal.exitCode, 0, "The installed bundle seal and nested signatures must verify")
    }

    private static func installFixture(_ source: String, at url: URL) throws {
        let deadline = """
        #!/usr/bin/python3 -I
        import signal
        signal.signal(signal.SIGALRM, signal.SIG_DFL)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        signal.alarm(40)
        """
        try (deadline + "\n" + source).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { throw GatewayTransportError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let cli = #"""
import json, os, subprocess, sys
mode = os.environ['G1_MODE']
relay = os.environ['G1_RELAY']
env = os.environ.copy()
if mode != 'plain':
    profile = os.environ['AITVARAS_STATE_DIR']
    if os.environ['G1_CLIENT'] == 'claude':
        assert len(sys.argv) == 3 and sys.argv[1] == '--mcp-config', sys.argv
        config = json.load(open(sys.argv[2]))['mcpServers']
        assert set(config) == {'aitvaras'}
        entry = config['aitvaras']
        assert entry['command'] == relay and entry['type'] == 'stdio'
        assert entry['env']['AITVARAS_STATE_DIR'] == profile
        env.update(entry['env'])
    else:
        assert len(sys.argv) == 3 and sys.argv[1] == '-c', sys.argv
        expected = ('mcp_servers.aitvaras={ command = ' + json.dumps(relay) +
                    ', args = [], enabled = true, env = { AITVARAS_STATE_DIR = ' + json.dumps(profile) + ' } }')
        assert sys.argv[2] == expected, sys.argv

with subprocess.Popen([relay], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as child:
    def send(method, request_id=None, params=None):
        message = {'jsonrpc': '2.0', 'method': method}
        if request_id is not None: message['id'] = request_id
        if params is not None: message['params'] = params
        child.stdin.write(json.dumps(message) + '\n')
        child.stdin.flush()

    def receive():
        line = child.stdout.readline()
        assert line, 'unexpected relay EOF'
        return json.loads(line)

    def tools(request_id):
        send('tools/list', request_id)
        reply = receive()
        assert reply['id'] == request_id
        return {tool['name'] for tool in reply['result']['tools']}

    if mode == 'plain':
        assert child.stdout.readline() == ''
        assert child.wait(timeout=2) == 17
    else:
        send('initialize', 1, {'protocolVersion': '2025-06-18'})
        assert receive()['result']['serverInfo']['name'] == 'aitvaras'
        send('notifications/initialized')
        listed = tools(2)
        if mode == 'other':
            assert listed == {'other_sign_in'}, listed
            child.stdin.close()
            assert child.wait(timeout=3) == 0
        else:
            if mode == 'first':
                assert 'issues_sign_in' in listed and 'memory_search' in listed, listed
                open(os.environ['G1_READY'], 'w').close()
                assert receive()['method'] == 'notifications/tools/list_changed'
                listed = tools(3)
            assert 'issues_update_issue' in listed and 'issues_sign_in' not in listed and 'memory_search' in listed, listed
            send('tools/call', 4, {'name': 'memory_search', 'arguments': {'query': 'orchard'}})
            assert 'orchard fixture fact' in str(receive()['result']['content'])
            send('tools/call', 5, {'name': 'issues_update_issue', 'arguments': {}})
            assert receive()['result']['content'][0]['text'] == 'Synthetic issue'
            open(os.environ['G1_DONE'], 'w').close()
            assert child.stdout.readline() == '', 'revoked relay stayed live'
            assert child.wait(timeout=3) == 0
"""#

    private static let relay = #"""
import json, os, select, socket, sys
with socket.socket(socket.AF_UNIX) as server:
    server.settimeout(35)
    server.connect(os.environ['G1_SOCKET'])
    with server.makefile('rb', buffering=0) as handshake:
        server.sendall((json.dumps({'version': 1, 'profile': os.environ['G1_PROFILE'], 'role': 'relay'}) + '\n').encode())
        if json.loads(handshake.readline())['status'] != 'ready':
            sys.exit(17)
    while True:
        readable, _, _ = select.select([server, 0], [], [], 30)
        if not readable:
            sys.exit(18)
        if server in readable:
            data = server.recv(8192)
            if not data: break
            with os.fdopen(os.dup(1), 'wb') as output:
                output.write(data)
        if 0 in readable:
            data = os.read(0, 8192)
            if not data: break
            server.sendall(data)
"""#
}

private struct GatewayG1Fixture: Sendable {
    let stores: Stores
    let first: WorkspaceProject
    let second: WorkspaceProject
    let service: GatewayToolService
    let oauth: GatewayUpstreamSessions
    let approvals: GatewayApprovalBroker
    let remote: OAuthUpstreamFixture
    let primary: UUID

    init(root: URL? = nil) async throws {
        let stores = try inMemoryStores()
        self.stores = stores
        func folders(_ name: String) throws -> [WorkspaceFolderDraft] {
            guard let root else { return [] }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            return [.init(path: folder.path)]
        }
        first = try stores.createWorkspaceProject(title: "First project", folders: folders("first"))
        second = try stores.createWorkspaceProject(title: "Other project", folders: folders("second"))
        let endpoint = "https://mcp.example.invalid/mcp"
        try stores.addGatewayUpstream(serverName: "issues", label: "Shared example account", endpoint: endpoint, projectID: nil)
        try stores.addGatewayUpstream(serverName: "other", label: "Other account", endpoint: endpoint, projectID: second.id)
        try stores.editAgentSetup(projectID: second.id, edit: .globalEnabled(name: "issues", enabled: false))
        guard let account = try stores.gatewayUpstreams(for: .init(client: .claude, projectID: first.id)).first else {
            throw GatewayUpstreamError.invalidAccount
        }
        primary = account.account.id
        try stores.saveGatewayToolScopes(projectID: first.id, scopes: [.memory], expectedRevision: 0)
        try stores.saveFact(.init(text: "orchard fixture fact", source: .userStated), entityNames: "Example")
        let hub = ConnectorHub(stores: stores)
        await hub.register(MemoryConnector(stores: stores, embedder: GatewayMemoryEmbedder()))
        let remote = OAuthUpstreamFixture(includesWriteTool: true)
        self.remote = remote
        let vault = Secrets()
        oauth = .init(secrets: .init(load: { key in vault.entries.withLock { $0[key] } },
            save: { key, value in vault.entries.withLock { $0[key] = value } },
            delete: { key in vault.entries.withLock { _ = $0.removeValue(forKey: key) } }),
            send: { try await remote.send($0, id: $1) })
        approvals = GatewayApprovalBroker()
        service = GatewayToolService(stores: stores, hub: hub, approvals: approvals, upstreams: oauth)
    }

    func connect(_ client: GatewayLaunchContext.Client, project: WorkspaceProject) -> MCPGateway {
        service.connect(invocation: .init(launchID: UUID(), context: .init(client: client, projectID: project.id),
                                          presentation: .outside), authorize: {})
    }

    func signIn() async throws {
        let redirect = URL(string: "http://127.0.0.1:49153/oauth/callback")!
        try await oauth.signIn(primary, currentRoute: { try stores.gatewayUpstream(id: primary) }, redirect: redirect) {
            try await remote.authorize($0, redirect: redirect, wrongState: false)
        }
    }

    func pendingApproval() async throws -> GatewayApprovalRequest {
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if let request = await approvals.requests().first { return request }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GatewayTransportError.timeout
    }

    private final class Secrets: Sendable {
        let entries = Mutex<[String: String]>([:])
    }
}
