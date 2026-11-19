import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentHookFoldingTests {
    @Test(arguments: [false, true])
    func realSuccessWinsOverHookDenialInEitherArrivalOrder(resultFirst: Bool) {
        var fixture = HookStateFixture()
        fixture.tool("one")
        fixture.hook("check", phase: .running)
        if resultFirst { fixture.finish("one") }
        fixture.hook("check", phase: .blocked, reason: "Hook denied")
        if !resultFirst { fixture.finish("one") }
        #expect(fixture.state.tools.first?.isDenied == false)
        #expect(fixture.state.tools.first?.isError == false)
        #expect(fixture.hooks("one").first?["status"] == .string("blocked"))
    }

    @Test(arguments: [false, true])
    func parallelToolsAssignEachPreBatchToItsEarliestEligibleTool(reverse: Bool) {
        var fixture = HookStateFixture()
        fixture.tool("first"); fixture.tool("second")
        fixture.hook("first-a", phase: .running)
        fixture.hook("first-b", phase: .running)
        for id in reverse ? ["first-b", "first-a"] : ["first-a", "first-b"] {
            fixture.hook(id, phase: id == "first-a" ? .blocked : .success, reason: id == "first-a" ? "Blocked first" : nil)
        }
        fixture.hook("second-a", phase: .running)
        fixture.hook("second-b", phase: .running)
        fixture.hook("second-b", phase: .success)
        fixture.hook("second-a", phase: .success)
        fixture.finish("second")
        #expect(fixture.hooks("first").map { $0["id"]?.stringValue } == ["first-a", "first-b"])
        #expect(fixture.hooks("second").map { $0["id"]?.stringValue } == ["second-a", "second-b"])
        #expect(fixture.state.tools.first { $0.id == "first" }?.isDenied == true)
        #expect(fixture.state.tools.first { $0.id == "second" }?.isDenied == false)
        #expect(fixture.state.tools.first { $0.id == "second" }?.isError == false)
    }

    @Test func presentationUsesStatusIconsAndOnlyBlockedReasonsOnCollapsedRows() throws {
        var fixture = HookStateFixture()
        fixture.tool("one")
        fixture.hook("passed", phase: .running)
        fixture.hook("passed", phase: .success)
        fixture.hook("running", phase: .running)
        fixture.hook("failed", phase: .running)
        fixture.hook("failed", phase: .error, reason: "Check failed.")
        fixture.hook("blocked", phase: .running)
        fixture.hook("blocked", phase: .blocked, reason: "Command blocked.")
        let entry = try #require(fixture.state.entries.first { $0.kind == "tool" })
        #expect(entry.toolHooks.map(\.icon) == ["checkmark.circle", "circle.dotted", "exclamationmark.triangle.fill", "stop.circle.fill"])
        #expect(entry.toolHooks.map(\.eventLabel) == ["Pre", "Pre", "Pre", "Pre"])
        #expect(entry.toolHooks.last?.accessibilityLabel == "PreToolUse:Bash · Blocked")
        #expect(entry.blockedHookReason == "Command blocked.")
        let legacy = JSONValue.object(["hookID": .string("legacy"), "name": .string("PostToolUse:Bash"),
            "event": .string("PostToolUse"), "phase": .string("success")])
        #expect(AgentToolHookPresentation(legacy)?.status == .passed)
        #expect(AgentToolHookPresentation(legacy)?.eventLabel == "Post")
        #expect(AgentToolHookPresentation(.object([:])) == nil)
        let unicode = AgentTranscriptContent.shortHookReason(String(repeating: "🐉", count: 300))
        #expect(unicode.utf8.count <= 240)
        #expect(!unicode.contains("\n"))
    }

    @Test func overlappingSameNameToolsKeepPinnedHooksAndObservationOrder() throws {
        var fixture = HookStateFixture()
        fixture.tool("first")
        fixture.hook("z", phase: .running)
        fixture.tool("second")
        fixture.hook("a", phase: .running)
        fixture.hook("z", phase: .success)
        fixture.hook("a", phase: .success)
        #expect(fixture.hooks("first").map { $0["id"]?.stringValue } == ["z"])
        #expect(fixture.hooks("second").map { $0["id"]?.stringValue } == ["a"])
        fixture.hook("b", phase: .running)
        fixture.hook("b", phase: .success)
        #expect(fixture.hooks("second").map { $0["id"]?.stringValue } == ["a", "b"])
        #expect(fixture.hooks("first").first?["status"] == .string("passed"))
        #expect(!fixture.state.entries.contains { $0.kind == "hook" })
    }

    @Test func preAndPostFoldIntoOneToolIncludingFinishedFallback() {
        var fixture = HookStateFixture()
        fixture.tool("one")
        fixture.hook("pre", phase: .running)
        fixture.hook("pre", phase: .success)
        fixture.finish("one")
        fixture.hook("post", event: "PostToolUse", phase: .running)
        fixture.hook("post", event: "PostToolUse", phase: .success)
        #expect(fixture.hooks("one").map { $0["event"]?.stringValue } == ["PreToolUse", "PostToolUse"])
        fixture.tool("two")
        fixture.hook("current-post", event: "PostToolUse", phase: .running)
        #expect(fixture.hooks("two").first?["id"] == .string("current-post"))
    }

    @Test func postFallbackUsesCompletionOrderWhenResultsArriveOutOfOrder() {
        var fixture = HookStateFixture()
        fixture.tool("first")
        fixture.tool("second")
        fixture.finish("second")
        fixture.finish("first")
        fixture.hook("post", event: "PostToolUse", phase: .running)
        #expect(fixture.hooks("first").first?["id"] == .string("post"))
        #expect(fixture.hooks("second").isEmpty)
    }

    @Test func blockedAndFailedReasonsStayShortAndSurviveToolUpdates() {
        var fixture = HookStateFixture()
        fixture.tool("one")
        fixture.hook("blocked", phase: .running)
        fixture.hook("blocked", phase: .blocked, reason: "Command is blocked.\nHidden long output")
        fixture.finish("one")
        #expect(fixture.hooks("one").first?["reason"] == .string("Command is blocked."))
        // The real successful result supersedes inferred denial, while the
        // blocked hook and its reason remain in the historical hook record.
        #expect(fixture.state.entries.first { $0.kind == "tool" }?.payloadJSON.flatMap(JSONValue.parse)?["isDenied"] == .bool(false))
        #expect(fixture.hooks("one").first?["status"] == .string("blocked"))
        fixture.tool("two")
        fixture.hook("failed", phase: .running)
        fixture.hook("failed", phase: .error, reason: String(repeating: "x", count: 1_000))
        #expect(fixture.hooks("two").first?["status"] == .string("failed"))
        #expect((fixture.hooks("two").first?["reason"]?.stringValue?.utf8.count ?? 999) <= 240)
        fixture.finish("two")
        #expect(fixture.hooks("two").count == 1)
    }

    @Test func unmatchedAndUnknownResponsesStayStandaloneAndCannotMove() {
        var fixture = HookStateFixture()
        fixture.hook("unmatched", phase: .running)
        fixture.tool("later")
        fixture.hook("unmatched", phase: .success)
        fixture.hook("unknown-response", phase: .error, reason: "Check failed")
        #expect(fixture.state.entries.filter { $0.kind == "hook" }.count == 2)
        #expect(fixture.hooks("later").isEmpty)
        fixture.state.end(.completed)
        fixture.hook("late", phase: .running)
        #expect(fixture.state.entries.filter { $0.kind == "hook" }.count == 2)
    }

    @Test func unfinishedHooksBecomeFailedAndDoNotMatchAnEarlierTurn() {
        var fixture = HookStateFixture()
        fixture.tool("one")
        fixture.hook("pending", phase: .running)
        fixture.state.end(.interrupted)
        #expect(fixture.hooks("one").first?["status"] == .string("failed"))
        fixture.begin()
        fixture.hook("new-turn", phase: .running)
        #expect(fixture.state.entries.filter { $0.kind == "hook" }.count == 1)
        #expect(fixture.hooks("one").count == 1)
    }

    @Test func foldedPayloadSurvivesDatabaseReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hooks.sqlite")
        let chatID: UUID
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, session) = try agentStoreChat(stores, provider: .claude)
            chatID = chat.id
            var fixture = HookStateFixture(session: session)
            fixture.tool("one")
            fixture.hook("check", phase: .running)
            fixture.hook("check", phase: .success)
            fixture.finish("one")
            for entry in fixture.state.entries { _ = try stores.saveAgentEntry(entry) }
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        let entries = try reopened.agentEntries(chatID: chatID)
        let tool = try #require(entries.first { $0.kind == "tool" })
        #expect(tool.payloadJSON.flatMap(JSONValue.parse)?["hooks"]?.arrayValue?.first?["status"] == .string("passed"))
        #expect(!entries.contains { $0.kind == "hook" })
    }

    @Test(arguments: ["exit-block", "decision-block", "decision-deny", "exit-failed", "error"])
    func realFramesClassifyBlocksAndFailuresWithoutCopyingOutput(scenario: String) async throws {
        let fixture = try BackendExecutableFixture(script: """
claude_init()
read()
emit({'type':'assistant','message':{'role':'assistant','content':[{'type':'tool_use','id':'tool','name':'Bash','input':{'command':'echo example'}}]}})
emit({'type':'system','subtype':'hook_started','hook_id':'check','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse'})
scenario='\(scenario)'
response={'type':'system','subtype':'hook_response','hook_id':'check','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse','exit_code':0,'outcome':'success','output':'FULL_OUTPUT_CANARY','stdout':'FULL_STDOUT_CANARY'}
if scenario=='exit-block': response.update(exit_code=2,stderr='Blocked command.\\nSECOND_LINE_CANARY')
if scenario=='decision-block': response.update(decision='block',reason='Blocked command.')
if scenario=='decision-deny': response.update(stdout=json.dumps({'hookSpecificOutput':{'permissionDecision':'deny','permissionDecisionReason':'Blocked command.'}}))
if scenario=='exit-failed': response.update(exit_code=1,stderr='Check failed.')
if scenario=='error': response.update(outcome='error',stderr='Check failed.')
emit(response)
emit({'type':'result','is_error':False})
done()
""")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        let input = AgentInput(text: "Example")
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        let hook = try #require(events.compactMap { if case .hook(let hook) = $0.kind { hook } else { nil } }.last)
        let blocked = scenario.contains("block") || scenario.contains("deny")
        #expect(hook.phase == (blocked ? .blocked : .error))
        #expect(hook.reason == (blocked ? "Blocked command." : "Check failed."))
        #expect(!String(describing: events).contains("FULL_OUTPUT_CANARY"))
        #expect(!String(describing: events).contains("FULL_STDOUT_CANARY"))
        #expect(!String(describing: events).contains("SECOND_LINE_CANARY"))
        try fixture.assertComplete(); try await run.shutdown()
    }
}

private struct HookStateFixture {
    var state: ChatState
    let session: AgentChatSession
    init(session: AgentChatSession = .init(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "test")) {
        self.session = session; state = ChatState(chatID: session.chatID); begin()
    }
    mutating func begin() { state.begin(.init(text: "Example"), session: session, outputID: UUID()) }
    mutating func tool(_ id: String) { emit(.toolStarted(.init(name: "Bash", input: .null)), item: id) }
    mutating func finish(_ id: String) { emit(.toolFinished(output: .string("Done"), isError: false), item: id) }
    mutating func hook(_ id: String, event: String = "PreToolUse", phase: AgentHookEvent.Phase, reason: String? = nil) {
        emit(.hook(.init(id: id, name: event + ":Bash", event: event, phase: phase, reason: reason)))
    }
    mutating func emit(_ kind: AgentEvent.Kind, item: String? = nil) {
        state.reduce(.init(scope: .init(runID: UUID(), inputID: state.inputID, itemID: item), kind: kind), newEntryID: UUID())
    }
    func hooks(_ tool: String) -> [JSONValue] {
        state.entries.compactMap { $0.payloadJSON.flatMap(JSONValue.parse) }
            .first { $0["itemID"] == .string(tool) }?["hooks"]?.arrayValue ?? []
    }
}
