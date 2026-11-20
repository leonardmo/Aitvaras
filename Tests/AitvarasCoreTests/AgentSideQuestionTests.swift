import Darwin
import Foundation
import Testing
import GRDB
import AitvarasCore
@testable import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2))) struct AgentSideQuestionTests {
    @Test func exactArgumentsAndOnePromptLeaveChatAndNativeFilesUnchanged() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert sys.argv[1:]==json.load(open('expected-argv.json'))
assert sys.stdin.read()=='Answer this side question using the resumed conversation. The question is JSON-quoted text: "Synthetic side question"\n'
emit({'type':'system','subtype':'init','apiKeySource':'none','session_id':'00000000-0000-4000-8000-000000000003'})
emit({'type':'assistant','message':{'content':[{'type':'text','text':'Synthetic side answer'}]}})
emit({'type':'result','is_error':False})
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores(), source = try conversationFixture(stores, directory: fixture.directory)
        let session = source.session
        let expected = ["-p", "--output-format", "stream-json", "--verbose", "--resume", session.nativeID!,
            "--fork-session", "--no-session-persistence", "--tools", "", "--settings", "{\"disableAllHooks\":true}",
            "--strict-mcp-config", "--model", "test-model", "--effort", "medium"]
        try JSONEncoder().encode(expected).write(to: fixture.directory.appendingPathComponent("expected-argv.json"))
        let native = fixture.directory.appendingPathComponent("native-sessions")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let originalFile = native.appendingPathComponent("original.jsonl")
        try Data("Synthetic session evidence\n".utf8).write(to: originalFile)
        let beforeBytes = try Data(contentsOf: originalFile)
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "example", env: ["ACCESS_TOKEN": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let policy = AgentMCPLaunchPolicy(stateDirectory: fixture.directory.appendingPathComponent("state"), load: { directory, projectID in
            try stores.agentMCPLaunchContext(directory: directory, projectID: projectID)
        }, audit: { _ = try stores.record($0) }, resolveSecret: { _ in Issue.record("Side questions must not resolve MCP secrets"); return nil })
        let registry = GatewayLaunchRegistry()
        let gateway = GatewayChatLaunch(configuration: .init(executable: fixture.directory.appendingPathComponent("aitvaras-mcp"),
            stateDirectory: fixture.directory), registry: registry)
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: policy, gateway: gateway)
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let before = try await manager.state(chatID: source.chatID)
        let actions = conversationActions(stores, storage: fixture.directory.appendingPathComponent("worktrees"), backend: backend)
        #expect(try await actions.sideQuestion(chatID: source.chatID, question: "Synthetic side question") == "Synthetic side answer")
        #expect(await registry.activeLaunches().isEmpty)
        #expect(try await manager.state(chatID: source.chatID) == before)
        #expect(try stores.agentEntries(chatID: source.chatID) == source.entries)
        #expect(try stores.agentSession(chatID: source.chatID, provider: .claude) == session)
        #expect(try Data(contentsOf: originalFile) == beforeBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: native.path) == ["original.jsonl"])
        #expect(try stores.latestAgentTurn(chatID: source.chatID) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("state/Runtime").path))
        let audit = try stores.activity(since: .distantPast)
        #expect(audit.contains { $0.summary == "Side question requested" && $0.detailJSON == nil && $0.sourceID == "chat:" + source.chatID.uuidString })
        #expect(audit.allSatisfy { !(($0.detailJSON ?? "") + $0.summary).contains("Synthetic side") })
        try await manager.shutdown(); await actions.shutdown()
    }

    @Test(arguments: ["garbage", "tool", "permission", "failed", "hook"])
    func malformedOutputOrUnexpectedActionsFailClosed(scenario: String) async throws {
        let output: String = switch scenario {
        case "garbage": "print('garbage', flush=True)"
        case "tool": "emit({'type':'assistant','message':{'content':[{'type':'tool_use','name':'Bash'}]}})"
        case "permission": "emit({'type':'control_request','request_id':'permission','request':{'subtype':'can_use_tool','tool_name':'Bash'}})"
        case "hook": "emit({'type':'system','subtype':'hook_started','hook_name':'PreToolUse:Bash'})"
        default: "emit({'type':'result','is_error':True,'result':'synthetic-private-error'})"
        }
        let fixture = try BackendExecutableFixture(script: "sys.stdin.read()\n" + output)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        do {
            _ = try await backend.sideQuestion(configuration: questionConfiguration(fixture.directory), question: "Example")
            Issue.record("Expected failure")
        } catch { #expect(!String(describing: error).contains("synthetic-private-error")) }
    }

    @Test(arguments: [false, true])
    func timeoutAndDismissCancellationReapTheProcess(cancel: Bool) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
sys.stdin.read()
open('child.pid','w').write(str(os.getpid()))
for _ in range(15): time.sleep(1)
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let start = ContinuousClock.now
        let task = Task { try await backend.sideQuestion(configuration: questionConfiguration(fixture.directory), question: "Example",
            timeout: cancel ? .seconds(10) : .milliseconds(150)) }
        if cancel {
            try await conversationWait { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else { await #expect(throws: AgentConversationError.timedOut) { try await task.value } }
        #expect(start.duration(to: .now) < .seconds(4))
        let marker = fixture.directory.appendingPathComponent("child.pid")
        if FileManager.default.fileExists(atPath: marker.path) {
            let pid = try #require(Int32(try String(contentsOf: marker, encoding: .utf8)))
            #expect(kill(pid, 0) != 0 && errno == ESRCH)
        } else {
            // The overall deadline can expire during auth/status, before the
            // question subprocess is created. Cancellation waits for its PID.
            #expect(!cancel)
        }
    }

    @Test func missingNativeContextAndOtherProvidersAreUnavailable() async throws {
        let stores = try inMemoryStores(), chat = try agentStoreChat(stores).0
        let actions = conversationActions(stores, storage: URL(fileURLWithPath: "/tmp/unused-worktrees"))
        await #expect(throws: AgentConversationError.unavailable) { try await actions.sideQuestion(chatID: chat.id, question: "Example") }
        let backend = CodexBackend(environment: ["PATH": ""])
        await #expect(throws: AgentFailure.unsupported) {
            try await backend.sideQuestion(configuration: questionConfiguration(URL(fileURLWithPath: "/tmp")), question: "Example", timeout: .seconds(1))
        }
    }

    @Test func timeoutAlsoBoundsSubscriptionStatusChecks() async throws {
        let fixture = try AgentExecutableFixture("i=0; while [ $i -lt 15 ]; do /bin/sleep 1; i=$((i+1)); done")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let start = ContinuousClock.now
        await #expect(throws: AgentConversationError.timedOut) {
            try await backend.sideQuestion(configuration: questionConfiguration(fixture.directory), question: "Example", timeout: .milliseconds(150))
        }
        #expect(start.duration(to: .now) < .seconds(4))
    }

    @Test(arguments: ["/shout words", "!echo example", "First line\nSecond line"])
    func questionTextCannotBecomeAHeadlessSlashCommand(question: String) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
prompt=sys.stdin.read()
prefix='Answer this side question using the resumed conversation. The question is JSON-quoted text: '
assert prompt.startswith(prefix) and len(prompt.splitlines())==1
assert json.loads(prompt[len(prefix):])==json.load(open('expected-question.json'))
emit({'type':'result','is_error':False,'result':'The command is quoted context.'})
"""#)
        defer { fixture.remove() }
        try JSONEncoder().encode(question).write(to: fixture.directory.appendingPathComponent("expected-question.json"))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        #expect(try await backend.sideQuestion(configuration: questionConfiguration(fixture.directory), question: question) == "The command is quoted context.")
    }
}

private func questionConfiguration(_ directory: URL) -> AgentSessionConfiguration {
    .init(directory: directory, resume: .init(provider: .claude, profile: "default", nativeID: "00000000-0000-4000-8000-000000000001"), model: "default")
}
