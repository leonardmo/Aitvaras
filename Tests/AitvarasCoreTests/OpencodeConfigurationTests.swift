import Darwin
import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite struct OpencodeConfigurationTests {
    @Test func configContainsOnlyLocalInferenceAndAsksBeforeTools() throws {
        let config = OpencodeConfiguration(root: URL(fileURLWithPath: "/tmp/profile/Opencode"))
        let value = config.config(models: [.init(id: "test-model", name: "Test model")])
        #expect(value["share"] == .string("disabled"))
        #expect(value["autoupdate"] == .bool(false))
        #expect(value["enabled_providers"] == .array([.string("ollama")]))
        #expect(value["provider"]?.objectValue?.keys.sorted() == ["ollama"])
        #expect(value["provider"]?["ollama"]?["options"]?["baseURL"] == .string("http://127.0.0.1:11434/v1"))
        #expect(value["plugin"] == .array([])); #expect(value["mcp"] == .object([:]))
        for tool in ["*", "bash", "edit", "webfetch"] { #expect(value["permission"]?[tool] == .string("ask")) }
        for mode in [AgentMode.ask, .auto, .acceptEdits, .plan] {
            #expect(OpencodeConfiguration.permissions(mode: mode).arrayValue?.first?["effect"] == .string("ask"))
        }
        #expect(value["permission"]?["question"] == .string("deny"))
        for mode in [AgentMode.ask, .auto, .acceptEdits, .plan] {
            #expect(OpencodeConfiguration.permissions(mode: mode).arrayValue?.contains {
                $0["action"] == .string("question") && $0["effect"] == .string("deny")
            } == true)
        }
        let plan = try #require(OpencodeConfiguration.permissions(mode: .plan).arrayValue)
        for tool in ["bash", "edit", "webfetch", "websearch"] {
            #expect(plan.contains { $0["action"] == .string(tool) && $0["effect"] == .string("deny") })
        }
        let environment = config.environment(["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "test-credential",
            "OPENCODE_CONFIG_CONTENT": "remote-config", "HTTPS_PROXY": "https://example.invalid", "XDG_CONFIG_HOME": "/tmp/untrusted"])
        #expect(environment["OPENAI_API_KEY"] == nil); #expect(environment["HTTPS_PROXY"] == nil)
        #expect(environment["OPENCODE_CONFIG_CONTENT"] == nil)
        #expect(environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "true")
        for (key, directory) in zip(["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "HOME"], config.dataDirectories) {
            #expect(environment[key] == directory.path)
        }
    }

    @Test func sandboxGrantsOnlyLoopbackAndExplicitWriteRoots() throws {
        let config = OpencodeConfiguration(root: URL(fileURLWithPath: "/tmp/profile/Opencode"), temporaryDirectory: URL(fileURLWithPath: "/tmp/agent-temp"))
        let projects = ["/tmp/project", "/tmp/worktree", "/tmp/additional"].map { URL(fileURLWithPath: $0) }
        let sandbox = try config.sandbox(projects: projects)
        #expect(sandbox.contains("(deny network*)"))
        #expect(sandbox.contains("(allow network-outbound (remote ip \"localhost:*\"))"))
        #expect(sandbox.contains("(allow network-inbound (local ip \"localhost:*\"))"))
        #expect(!sandbox.contains("unix-socket"))
        #expect(sandbox.contains("(deny file-write*)"))
        let roots = try OpencodeConfiguration.writeRoots(projects + config.dataDirectories + [config.temporaryDirectory])
        #expect(sandbox.components(separatedBy: "(subpath ").count - 1 == roots.count)
        for root in roots { #expect(sandbox.contains("(subpath \"\(root)\")")) }
        #expect(throws: AgentFailure.invalidRequest) { try config.sandbox(projects: [URL(fileURLWithPath: "/")]) }
        #expect(throws: AgentFailure.invalidRequest) { try config.sandbox(projects: [URL(string: "https://example.invalid")!]) }
        let escaped = try config.sandbox(projects: [URL(fileURLWithPath: "/tmp/project\"name")])
        #expect(escaped.contains("project\\\"name"))
    }

    @Test func parsesSSEDataWithEmptyEventFieldsAndRejectsGarbage() throws {
        var decoder = OpencodeSSEDecoder()
        #expect(try decoder.consume(": heartbeat") == nil)
        #expect(try decoder.consume("event:") == nil)
        #expect(try decoder.consume(#"data: {"type":"session.text.delta","data":{"delta":"Hello"}}"#) == nil)
        #expect(try decoder.consume("")?["type"] == .string("session.text.delta"))
        #expect(try decoder.consume("\r") == nil)
        _ = try decoder.consume("data: not JSON")
        #expect(throws: AgentFailure.invalidRequest) { try decoder.consume("") }
        var large = OpencodeSSEDecoder()
        #expect(throws: AgentFailure.invalidRequest) { try large.consume("data: " + String(repeating: "x", count: 1_048_576)) }
    }

    @Test func catalogExcludesRemoteModelsAndRejectsRedirectResponse() async throws {
        let stub = OpencodeHTTPStub()
        let session = stub.session()
        defer { session.invalidateAndCancel() }
        stub.set(status: 200, body: #"{"models":[{"name":"test-model"},{"name":"test-model"},{"name":"test-cloud"},{"name":"proxy-model","remote_host":"https://example.invalid"},{"name":"remote-model","remote_model":"other"}]}"#)
        #expect(try await OpencodeConfiguration.installedModels(session: session).map(\.id) == ["test-model"])
        stub.set(status: 302, body: "")
        await #expect(throws: AgentFailure.offline) { _ = try await OpencodeConfiguration.installedModels(session: session) }
        stub.set(status: 200, body: "garbage")
        await #expect(throws: AgentFailure.offline) { _ = try await OpencodeConfiguration.installedModels(session: session) }
    }

    @Test func passwordStaysInHTTPAuthorizationAndErrorsAreSafe() async throws {
        let stub = OpencodeHTTPStub()
        let session = stub.session()
        defer { session.invalidateAndCancel() }
        let secret = "transient-test-password"
        let transport = OpencodeHTTPTransport(session: session, port: 12345)
        await transport.startupLine("server password " + secret)
        stub.set(status: 500, body: "server password " + secret)
        do {
            _ = try await transport.request("api/session", method: "POST", body: .object([:]))
            Issue.record("Expected HTTP failure")
        } catch {
            #expect(error as? AgentFailure == .offline)
            #expect(!String(describing: error).contains(secret))
        }
        let request = try #require(stub.request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:\(secret)".utf8).base64EncodedString())
        #expect(request.url?.user == nil); #expect(request.url?.password == nil)
        #expect(!(request.url?.absoluteString.contains(secret) ?? true))
        #expect(!(request.httpBody.map { String(decoding: $0, as: UTF8.self).contains(secret) } ?? false))
        await transport.close()
        await #expect(throws: AgentFailure.offline) { _ = try await transport.request("api/session", method: "GET", body: nil) }
    }
}

/// Each URLSession registers an independent response stub, so concurrent tests
/// cannot replace each other’s HTTP responses.
private final class OpencodeHTTPStub: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 200
    private var body = "{}"
    private var lastRequest: URLRequest?
    private let id = UUID().uuidString
    var request: URLRequest? { lock.withLock { lastRequest } }
    func set(status: Int, body: String) { lock.withLock { self.status = status; self.body = body } }
    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpencodeStubProtocol.self]
        OpencodeStubRegistry.shared.insert(self, id: id)
        configuration.httpAdditionalHeaders = ["X-Opencode-Test-ID": id]
        return URLSession(configuration: configuration, delegate: OpencodeStubDelegate(stub: self), delegateQueue: nil)
    }
    func response(_ request: URLRequest) -> (Int, String) {
        lock.withLock { lastRequest = request; return (status, body) }
    }
}
private final class OpencodeStubDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let stub: OpencodeHTTPStub
    init(stub: OpencodeHTTPStub) { self.stub = stub }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private final class OpencodeStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Opencode-Test-ID"),
              let stub = OpencodeStubRegistry.shared.lookup(id) else {
            client?.urlProtocol(self, didFailWithError: AgentFailure.offline); return
        }
        let (status, body) = stub.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OpencodeStubRegistry: @unchecked Sendable {
    static let shared = OpencodeStubRegistry()
    private struct WeakStub { weak var value: OpencodeHTTPStub? }
    private let lock = NSLock()
    private var values: [String: WeakStub] = [:]
    func insert(_ value: OpencodeHTTPStub, id: String) { lock.withLock { values[id] = WeakStub(value: value) } }
    func lookup(_ id: String) -> OpencodeHTTPStub? { lock.withLock { values[id]?.value } }
}

extension OpencodeConfigurationTests {
    @Test func passwordNeverReachesPersistedTranscriptJournalOrActivity() async throws {
        let stub = OpencodeHTTPStub()
        let session = stub.session()
        defer { session.invalidateAndCancel() }
        let secret = "transient-test-password"
        let transport = OpencodeHTTPTransport(session: session, port: 12345)
        await transport.startupLine("server password " + secret)
        let backend = OpencodeHTTPTestBackend(transport: transport)
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .local, cwd: "/tmp/project")
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = AgentInput(text: "Create an example file")
        stub.set(status: 200, body: JSONValue.object(["data": .object([
            "id": .string("msg_" + input.id.uuidString), "sessionID": .string("ses_fixture")])]).jsonString)
        try await manager.send(chatID: chat.id, provider: .local, input: input)
        let run = try #require(await backend.run)
        await run.receive(localEvent("session.tool.input.started", ["id": .string("tool_test"), "name": .string("bash")]))
        await run.receive(localEvent("session.tool.called", ["id": .string("tool_test"), "input": .object(["command": .string("printf example > example.txt")])]))
        await run.receive(localEvent("permission.asked", ["id": .string("permission_test"), "action": .string("bash"),
            "source": .object(["id": .string("tool_test")])]))
        try await waitOpencode { try await manager.state(chatID: chat.id).pendingCards.count == 1 }
        let request = try #require(try await manager.state(chatID: chat.id).pendingCards.first)
        stub.set(status: 204, body: "")
        try await manager.respond(chatID: chat.id, to: request, with: .allow(updatedInput: nil))
        #expect(stub.request?.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("opencode:\(secret)".utf8).base64EncodedString())
        await run.receive(localEvent("session.tool.success", ["id": .string("tool_test"), "content": .string("Created")]))
        // A future notification might contain a credential. Ignore its payload
        // and let the native turn complete normally.
        await run.receive(localEvent("future.credentials", ["password": .string(secret)]))
        await run.receive(localEvent("session.text.delta", ["delta": .string("Created")]))
        await run.receive(localEvent("session.execution.succeeded"))
        try await waitOpencode { try await manager.state(chatID: chat.id).outcome == .completed }
        #expect(try await !manager.state(chatID: chat.id).entries.contains { $0.text.contains("Not supported here") })
        let encoder = JSONEncoder()
        let entries = try encoder.encode(stores.agentEntries(chatID: chat.id))
        let journal = try encoder.encode(stores.agentTurn(id: input.id))
        let activity = try encoder.encode(stores.activityEvents(runID: input.id))
        #expect(!String(decoding: entries, as: UTF8.self).contains(secret))
        #expect(!String(decoding: journal, as: UTF8.self).contains(secret))
        #expect(!String(decoding: activity, as: UTF8.self).contains(secret))
        #expect(try stores.activityEvents(runID: input.id).isEmpty == false)
        try await manager.shutdown(); await transport.close()
    }
}

private actor OpencodeHTTPTestBackend: AgentBackend {
    private let transport: OpencodeHTTPTransport
    private(set) var run: OpencodeRun?
    init(transport: OpencodeHTTPTransport) { self.transport = transport }
    func start(_ configuration: AgentSessionConfiguration) async -> any AgentRun {
        let run = OpencodeRun(transport: transport, session: localSession, configuration: configuration, release: { _ in })
        self.run = run; await run.started(); return run
    }
    func status() -> AgentStatus { .init(installed: true, authentication: .local, capabilities: OpencodeBackend.capabilities) }
    func models() -> [AgentModel] { [.init(id: "test-model", name: "Test model")] }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) throws { throw AgentFailure.unsupported }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}

@Suite struct OpencodeServerPIDTests {
    @Test func nativeArgumentsRecognizeOnlyTheServeSubcommand() throws {
        #expect(OpencodeServerPID.isServer(["/tmp/bin/opencode", "serve", "--port", "12345"]))
        for argv in [[], ["opencode"], ["opencode", "run", "serve"], ["/bin/echo", "opencode", "serve"],
                     ["opencode-other", "serve"], ["/bin/sh", "-c", "opencode serve"]] {
            #expect(!OpencodeServerPID.isServer(argv))
        }
        let own = try #require(OpencodeServerPID.arguments(for: getpid()))
        let identifiedAsServer = OpencodeServerPID.isServer(own)
        #expect(!identifiedAsServer)
    }

    @Test(arguments: ["server", "unrelated", "other-group", "reused", "leader-exited"])
    func stalePIDRequiresVerifiedServerAndOwnedGroup(kind: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-pid-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("server.pid")
        try Data("4242".utf8).write(to: file)
        let probe = OpencodePIDProbe(kind: kind)
        try await OpencodeServerPID.recover(file: file, inspect: { probe.arguments($0) },
            group: { probe.group($0) }, signal: { probe.signal($0, $1) })
        let signals = probe.signals
        if kind == "unrelated" || kind == "other-group" {
            #expect(signals.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
        } else {
            #expect(signals.map(\.0) == Array(repeating: -4242, count: kind == "reused" ? 1 : 2))
            #expect(signals.map(\.1) == (kind == "reused" ? [SIGTERM] : [SIGTERM, SIGKILL]))
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func stalePIDCannotKillAnUnrelatedLiveProcess() async throws {
        let fixture = try AgentExecutableFixture("printf 'ready\\n'; exec /bin/sleep 30")
        defer { fixture.remove() }
        let process = fixture.process()
        defer { process.terminate() }
        try process.start()
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")
        let file = fixture.directory.appendingPathComponent("server.pid")
        try Data(String(process.processIdentifier).utf8).write(to: file)
        try await OpencodeServerPID.recover(file: file)
        #expect(process.isRunning)
        OpencodeServerPID.remove(file: file, matching: process.processIdentifier + 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try await process.shutdown(grace: .zero)
    }
}

private final class OpencodePIDProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let kind: String
    private var sent: [(Int32, Int32)] = []
    init(kind: String) { self.kind = kind }
    var signals: [(Int32, Int32)] { lock.lock(); defer { lock.unlock() }; return sent }
    func arguments(_ pid: Int32) -> [String]? {
        lock.lock(); defer { lock.unlock() }
        if kind == "unrelated" || (kind == "reused" && !sent.isEmpty) { return ["/bin/sleep", "30"] }
        return ["/tmp/bin/opencode", "serve"]
    }
    func group(_ pid: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if kind == "leader-exited", !sent.isEmpty { errno = ESRCH; return -1 }
        return kind == "other-group" ? pid + 1 : pid
    }
    func signal(_ pid: Int32, _ value: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }; sent.append((pid, value)); return 0
    }
}
