import Darwin
import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPLoginTests {
    @Test func claudeLoginUsesAWideTerminalInTheProjectDirectoryAndWaitsForTheCallback() async throws {
        let fixture = try AgentExecutableFixture(#"""
        test "$1" = --settings && test "$2" = '{"enabledMcpjsonServers":["docs"]}' && test "$3" = mcp && test "$4" = login && test "$5" = -- && test "$6" = docs && test "$#" = 6 || exit 9
        test -t 0 && test -t 1 && test -t 2 || exit 1
        /usr/bin/python3 -I -c 'import os; assert os.tcgetpgrp(0) == os.getpgrp(); assert os.get_terminal_size(0).columns >= 4096' || exit 2
        pwd > login.cwd
        printf '\r\033[2KOpen \033]8;;https://hidden.example.invalid/metadata\007\033[34mhttps://auth.example.invalid/author\033[0mize?state=%01024d\033]8;;\033\\\n' 0 >&2
        printf 'Open https://duplicate.example.invalid/authorize\n'
        i=0
        while [ "$i" -lt 100 ]; do
            test ! -f login.callback || exit 0
            /bin/sleep 0.05
            i=$((i+1))
        done
        exit 3
        """#)
        defer { fixture.remove() }
        let project = fixture.directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let urls = MCPLoginURLs()
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        try await backend.signInMCP(name: "docs", directory: project, timeout: .seconds(8)) { url in
            await urls.append(url)
            do { try Data().write(to: project.appendingPathComponent("login.callback")) }
            catch { Issue.record("Could not signal the fixture") }
        }
        let cwd = try String(contentsOf: project.appendingPathComponent("login.cwd"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == project.resolvingSymlinksInPath())
        let expectedURL = "https://auth.example.invalid/authorize?state=" + String(repeating: "0", count: 1024)
        #expect(await urls.values.map(\.absoluteString) == [expectedURL])
    }

    @Test(arguments: [false, true])
    func claudeTimeoutAndCancellationReapTheProcess(cancel: Bool) async throws {
        let fixture = try AgentExecutableFixture(#"""
        test -t 0 || exit 1
        trap '' TERM
        echo $$ > child.pid
        i=0; while [ $i -lt 15 ]; do /bin/sleep 1; i=$((i+1)); done
        """#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let start = ContinuousClock.now
        let task = Task {
            try await backend.signInMCP(name: "docs", directory: fixture.directory,
                timeout: cancel ? .seconds(20) : .milliseconds(500)) { _ in Issue.record("No browser URL expected") }
        }
        if cancel {
            try await waitMCPLogin { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            await #expect(throws: ProviderSignInError.timedOut) { try await task.value }
        }
        #expect(start.duration(to: .now) < .seconds(4))
        // Under load the short timeout can end the child before it records its
        // pid; the cancel case always waits for the pid, so it checks reaping.
        guard cancel || FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) else { return }
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
