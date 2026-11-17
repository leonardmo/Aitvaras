import Foundation
import Testing
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentSetupTests {
    @Test func syntheticFixtureMergesCatalogAndReportsHookLifecycleOutsideContext() async throws {
        let fixture = try BackendExecutableFixture(provider: "claude", name: "setup-hooks")
        defer { fixture.remove() }
        let folder = fixture.directory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"env":{"ACCESS_TOKEN":"synthetic-hidden"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo example","statusMessage":"Checking project rules"}]}],"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"echo example","statusMessage":"Checking style"}]}]}}"#.utf8)
            .write(to: folder.appendingPathComponent("settings.json"))
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        let input = AgentInput(text: "Use shout")
        try await run.send(input, willDeliver: {})
        let events = try await collectTurn(run)
        let snapshot = try #require(events.compactMap { if case .setupReported(let value) = $0.kind { value } else { nil } }.last)
        #expect(snapshot.servers.map(\.name) == ["docs", "echo"])
        #expect(snapshot.servers.map(\.status) == [.needsAuth, .connected])
        #expect(snapshot.commands.map(\.name) == ["review", "shout"])
        #expect(snapshot.commands.last?.argumentHint == "[words]")
        #expect(snapshot.skills == ["shout"]); #expect(snapshot.agents == ["reviewer"])
        let hooks = events.compactMap { if case .hook(let value) = $0.kind { value } else { nil } }
        #expect(hooks.map(\.phase) == [.running, .success, .running, .blocked, .error])
        #expect(hooks.last?.statusMessage == "Checking style")
        #expect(hooks.first?.statusMessage == "Checking project rules")
        #expect(hooks.allSatisfy { !($0.reason ?? "").contains("synthetic-hidden") })
        var state = ChatState(chatID: UUID())
        let session = AgentChatSession(chatID: state.chatID, provider: .claude, cwd: fixture.directory.path, model: "default")
        state.begin(input, session: session, outputID: UUID())
        for event in events { state.reduce(event, newEntryID: UUID()) }
        #expect(state.agentSetup == snapshot)
        #expect(state.entries.filter { $0.kind == "hook" }.count == 3)
        #expect(!state.entries.contains { $0.kind == "setup" })
        #expect(!String(describing: state.entries).contains("synthetic-hidden"))
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test func initBeforeInitializeKeepsRichHintsAndMissingFieldsRetainTheLastReport() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
r=read()
emit({'type':'system','subtype':'init','apiKeySource':'none','mcp_servers':[{'name':'echo','status':'pending','source':'project'}],'slash_commands':['shout'],'skills':['shout'],'agents':['reviewer']})
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'commands':[{'name':'shout','description':'Repeat','argumentHint':'[words]'}]}}})
read()
emit({'type':'system','subtype':'init','apiKeySource':'none'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        let snapshots = events.compactMap { if case .setupReported(let value) = $0.kind { value } else { nil } }
        #expect(snapshots.last?.commands.first?.argumentHint == "[words]")
        #expect(snapshots.last?.servers.first?.status == .pending)
        #expect(snapshots.last?.skills == ["shout"])
        try await run.shutdown()
    }

    @Test func malformedCatalogEntriesAndUnknownStatusesDoNotInventCapabilities() {
        var snapshot = AgentSetupSnapshot(provider: .claude)
        snapshot.claudeInit(JSONValue.parse(#"{"mcp_servers":[{"name":"echo","status":"future","source":"future"},{"name":"echo","status":"connected"},{}],"slash_commands":["bad name",5,"review"],"skills":[{},"shout"],"agents":["reviewer"]}"#)!)
        #expect(snapshot.servers.count == 1)
        #expect(snapshot.servers.first?.status == .unknown)
        #expect(snapshot.servers.first?.source == nil)
        #expect(snapshot.commands.map(\.name) == ["review"])
        #expect(snapshot.skills == ["shout"])
        #expect(AgentSetupSnapshot(provider: .claude).commandsAvailable == false)
    }
}
