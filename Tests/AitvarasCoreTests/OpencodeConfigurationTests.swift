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
        for mode in [AgentMode.ask, .auto, .acceptEdits] {
            #expect(OpencodeConfiguration.permissions(mode: mode).arrayValue?.first?["effect"] == .string("ask"))
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
        // A future server event might contain a credential. It must never be
        // projected, even though ordinary tool output remains inspectable.
        await run.receive(localEvent("future.credentials", ["password": .string(secret)]))
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
        await run.receive(localEvent("session.execution.succeeded"))
        try await waitOpencode { try await manager.state(chatID: chat.id).outcome == .completed }
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
