import Darwin
import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPLoginTests {
    @Test func claudeLoginUsesTheProjectDirectoryAndNoRuntimeFlags() async throws {
        let fixture = try AgentExecutableFixture(#"""
        test "$1" = mcp && test "$2" = login && test "$3" = -- && test "$4" = docs && test "$#" = 4 || exit 9
        pwd > login.cwd
        printf 'Open https://auth.example.invalid/authorize?state=synthetic-browser-value\n' >&2
        printf 'Open https://auth.example.invalid/authorize?state=synthetic-browser-value\n'
        exit 0
        """#)
        defer { fixture.remove() }
        let project = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let urls = MCPLoginURLs()
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        try await backend.signInMCP(name: "docs", directory: project) { await urls.append($0) }
        let cwd = try String(contentsOf: project.appendingPathComponent("login.cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == project.resolvingSymlinksInPath())
        #expect(await urls.values.count == 1)
        #expect(await urls.values.first?.host == "auth.example.invalid")
    }

    @Test(arguments: [false, true])
    func claudeTimeoutAndCancellationReapTheProcess(cancel: Bool) async throws {
        let fixture = try AgentExecutableFixture(#"""
        echo $$ > child.pid
        trap '' TERM
        i=0; while [ $i -lt 15 ]; do /bin/sleep 1; i=$((i+1)); done
        """#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let start = ContinuousClock.now
        let task = Task {
            try await backend.signInMCP(name: "docs", directory: fixture.directory,
                timeout: cancel ? .seconds(20) : .milliseconds(150)) { _ in Issue.record("No browser URL expected") }
        }
        if cancel {
            try await waitMCPLogin { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: ProviderSignInError.timedOut) { try await task.value }
        }
        #expect(start.duration(to: .now) < .seconds(4))
        let pid = try fixture.childPID()
        #expect(kill(pid, 0) != 0 && errno == ESRCH)
    }

    @Test func claudeFailureDoesNotExposeOutputAndUnsafeBrowserURLsAreIgnored() async throws {
        let fixture = try AgentExecutableFixture("printf 'file:///tmp/example javascript:example synthetic-credential\\n'; exit 7")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        do {
            try await backend.signInMCP(name: "docs", directory: fixture.directory) { _ in Issue.record("Unsafe URL") }
            Issue.record("Expected login failure")
        } catch { #expect(!String(describing: error).contains("synthetic-credential")) }
    }

    @Test func codexCompletionIsMatchedByServerBeforeThreadRouting() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read(); assert r['method']=='mcpServer/oauth/login' and r['params']['name']=='docs'
emit({'method':'mcpServer/oauthLogin/completed','params':{'name':'other','success':False}})
emit({'method':'mcpServer/oauthLogin/completed','params':{'name':'docs','success':True}})
emit({'id':r['id'],'result':{'authorizationUrl':'https://auth.example.invalid/authorize?state=synthetic-browser-value'}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment), urls = MCPLoginURLs()
        try await backend.signInMCP(name: "docs", directory: fixture.directory) { await urls.append($0) }
        #expect(await urls.values.count == 1)
        try fixture.assertComplete(); try await backend.shutdown()
    }

    @Test(arguments: ["failed", "unsafe-url", "timeout", "cancel"])
    func codexLoginFailureTimeoutAndCancellationAreBounded(scenario: String) async throws {
        let body: String
        switch scenario {
        case "failed": body = "emit({'method':'mcpServer/oauthLogin/completed','params':{'name':'docs','success':False,'error':'synthetic-private-error'}})"
        case "unsafe-url": body = ""
        default: body = ""
        }
        let url = scenario == "unsafe-url" ? "file:///tmp/example" : "https://auth.example.invalid/authorize"
        let fixture = try BackendExecutableFixture(script: "codex_init()\nr=read()\n" + body
            + "\nemit({'id':r['id'],'result':{'authorizationUrl':'" + url + "'}})\nopen('waiting','w').close()\nfor _ in range(15): time.sleep(1)")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let task = Task {
            try await backend.signInMCP(name: "docs", directory: fixture.directory,
                timeout: scenario == "timeout" ? .milliseconds(200) : .seconds(5)) { _ in }
        }
        if scenario == "cancel" {
            try await waitMCPLogin { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("waiting").path) }
            task.cancel()
        }
        do { try await task.value; Issue.record("Expected failure") }
        catch { #expect(!String(describing: error).contains("synthetic-private-error")) }
        try await backend.shutdown()
    }

    @Test func codexLoginCancellationLeavesExistingChatConnectionUsable() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
if os.path.exists('chat-started'):
    codex_init()
    r=read(); assert r['method']=='mcpServer/oauth/login'
    emit({'id':r['id'],'result':{'authorizationUrl':'https://auth.example.invalid/authorize'}})
    open('login-waiting','w').close()
    for _ in range(15): time.sleep(1)
else:
    codex_init()
    start_thread()
    open('chat-started','w').close()
    r=read(); assert r['method']=='turn/start'
    emit({'id':r['id'],'result':{'turn':{'id':'turn-example'}}})
    emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'turn-example','status':'completed'}}})
    done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await waitMCPLogin { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("chat-started").path) }
        let login = Task { try await backend.signInMCP(name: "docs", directory: fixture.directory) { _ in } }
        try await waitMCPLogin { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("login-waiting").path) }
        login.cancel()
        await #expect(throws: CancellationError.self) { try await login.value }
        try await run.send(.init(text: "Example"), willDeliver: {})
        #expect(try await collectTurn(run).contains { if case .turnEnded(.completed) = $0.kind { true } else { false } })
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func codexLoginTimeoutIncludesConnectionInitialization() async throws {
        let fixture = try BackendExecutableFixture(script: "for _ in range(15): time.sleep(1)")
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await backend.signInMCP(name: "docs", directory: fixture.directory, timeout: .milliseconds(150)) { _ in }
        }
        #expect(start.duration(to: .now) < .seconds(4))
        try await backend.shutdown()
    }
}

private actor MCPLoginURLs {
    var values: [URL] = []
    func append(_ url: URL) { values.append(url) }
}
private func waitMCPLogin(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw AgentFailure.offline }
        try await Task.sleep(for: .milliseconds(10))
    }
}
