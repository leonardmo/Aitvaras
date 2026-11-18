import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentHookTests {
    @Test func metadataReadsAllSourcesAndRuleScopesWithoutCommandsOrEnvironmentValues() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let user = fixture.directory.appendingPathComponent("user")
        let claude = fixture.directory.appendingPathComponent(".claude")
        let rules = claude.appendingPathComponent("rules")
        for dir in [user, rules] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Data(#"{"env":{"ACCESS_TOKEN":"synthetic-hidden"},"hooks":{"PreToolUse":[{"matcher":"Bash|Write","hooks":[{"type":"command","command":"echo synthetic-command","statusMessage":"Check synthetic-hidden"}]}]}}"#.utf8).write(to: user.appendingPathComponent("settings.json"))
        try Data(#"{"hooks":{"PreToolUse":[{"matcher":"mcp__.*","hooks":[{"type":"command","command":"echo example","statusMessage":"Check server"}]}],"PostToolUse":[{"matcher":"^(Read|Edit)$","hooks":[{"type":"command","command":"echo example","statusMessage":"Check files"}]}],"Stop":[{"hooks":[{"type":"prompt","prompt":"synthetic-hook-body","statusMessage":"Check completion"}]}]}}"#.utf8).write(to: claude.appendingPathComponent("settings.local.json"))
        try Data("---\npaths:\n  - 'Sources/**'\n  - Tests/**\n---\nPrivate rule body stays excluded.".utf8).write(to: rules.appendingPathComponent("source.md"))
        try Data("---\npaths: [App/**, \"Tests/**\"]\n---\nExample".utf8).write(to: rules.appendingPathComponent("app.md"))
        let reader = AgentProjectMetadataReader(projectDirectory: fixture.directory, userDirectory: user)
        let metadata = await reader.read()
        #expect(metadata.hooks.count == 4)
        #expect(metadata.statusMessage(event: "PreToolUse", tool: "Bash") == "Check [redacted]")
        #expect(metadata.statusMessage(event: "PreToolUse", tool: "mcp__echo__echo") == "Check server")
        #expect(metadata.statusMessage(event: "PostToolUse", tool: "Edit") == "Check files")
        #expect(metadata.statusMessage(event: "PostToolUse", tool: "Editor") == nil)
        #expect(metadata.rules.map(\.paths) == [["App/**", "Tests/**"], ["Sources/**", "Tests/**"]])
        let display = String(describing: metadata)
        #expect(!display.contains("synthetic-hidden")); #expect(!display.contains("synthetic-command"))
        #expect(!display.contains("Private rule body"))
        #expect(!display.contains("synthetic-hook-body"))
    }

    @Test func malformedFilesAndSymlinkedProjectMetadataDoNotEscapeTheInventory() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let claude = fixture.directory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: claude.appendingPathComponent("settings.json"))
        let reader = AgentProjectMetadataReader(projectDirectory: fixture.directory)
        #expect(await !reader.read().warnings.isEmpty)
        try FileManager.default.removeItem(at: claude)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: fixture.directory)
        #expect(await reader.read().hooks.isEmpty)
    }

    @Test func reducerKeepsSameNameHooksSeparateAndAttachesOnlyExplicitToolIDs() {
        let chat = UUID(), input = AgentInput(text: "Example"), run = UUID()
        let session = AgentChatSession(chatID: chat, provider: .claude, cwd: "/tmp/project", model: "default")
        var state = ChatState(chatID: chat)
        state.begin(input, session: session, outputID: UUID())
        let scope = AgentEventScope(runID: run, inputID: input.id)
        for id in ["one", "two"] {
            state.reduce(.init(scope: scope, kind: .hook(.init(id: id, name: "PreToolUse:Bash", event: "PreToolUse", phase: .running))), newEntryID: UUID())
        }
        state.reduce(.init(scope: scope, kind: .hook(.init(id: "one", name: "PreToolUse:Bash", event: "PreToolUse", phase: .blocked, reason: "Blocked"))), newEntryID: UUID())
        state.reduce(.init(scope: scope, kind: .hook(.init(id: "one", name: "PreToolUse:Bash", event: "PreToolUse", phase: .running))), newEntryID: UUID())
        state.reduce(.init(scope: scope, kind: .hook(.init(id: "linked", name: "PreToolUse:Bash", event: "PreToolUse", phase: .blocked, reason: "Blocked", toolUseID: "tool-one"))), newEntryID: UUID())
        #expect(state.entries.filter { $0.kind == "hook" }.count == 2)
        #expect(state.entries.filter { $0.kind == "tool" }.count == 1)
        let linked = state.entries.first { $0.kind == "tool" }?.payloadJSON.flatMap(JSONValue.parse)
        #expect(linked?["hooks"]?.arrayValue?.first?["reason"] == .string("Blocked"))
        #expect(linked?["isDenied"] == .bool(true))
        state.end(.interrupted)
        let pending = state.entries.filter { $0.kind == "hook" }.last?.payloadJSON.flatMap(JSONValue.parse)
        #expect(pending?["phase"] == .string("interrupted"))
        let before = state.entries
        state.reduce(.init(scope: scope, kind: .hook(.init(id: "late", name: "Hook", event: "Stop", phase: .running))), newEntryID: UUID())
        #expect(state.entries == before)
    }

    @Test func hookReasonsAndRepeatedToolErrorTextRedactResolvedRuntimeSecrets() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
emit({'type':'system','subtype':'hook_started','hook_id':'example','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse'})
emit({'type':'system','subtype':'hook_response','hook_id':'example','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse','exit_code':2,'outcome':'error','stderr':'synthetic-runtime-value blocked the command '+('x'*4000)})
emit({'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'tool-example','is_error':True,'content':'PreToolUse:Bash hook error: synthetic-runtime-value'}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(!String(describing: events).contains("synthetic-runtime-value"))
        let reason = events.compactMap { if case .hook(let hook) = $0.kind { hook.reason } else { nil } }.last
        #expect(reason?.contains("[redacted]") == true)
        #expect((reason?.utf8.count ?? 0) <= 2048)
        try await run.shutdown()
    }

    @Test func genericCredentialPatternsAreRedactedBeforeTruncation() {
        let text = "Authorization: Bearer synthetic-access PASSWORD='synthetic-password' https://service.example.invalid/path?access=synthetic-url"
        let safe = AgentHookText.safe(text)
        #expect(!safe.contains("synthetic-access")); #expect(!safe.contains("synthetic-password")); #expect(!safe.contains("synthetic-url"))
    }

    @Test func longSettingsCredentialIsRedactedBeforeBoundingEvenInStructuredToolResults() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
read()
secret=('synthetic-credential-'*200)+'"\\suffix'
reason='PreToolUse:Bash hook error: '+secret
emit({'type':'system','subtype':'hook_response','hook_id':'example','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse','exit_code':2,'outcome':'error','stderr':reason})
emit({'type':'user','message':{'role':'user','content':[{'type':'tool_result','tool_use_id':'tool-example','is_error':True,'content':[{'type':'text','text':reason}]}]}})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let folder = fixture.directory.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = String(repeating: "synthetic-credential-", count: 200) + "\"\\suffix"
        try Data(JSONValue.object(["env": .object(["ACCESS_TOKEN": .string(secret)])]).jsonString.utf8)
            .write(to: folder.appendingPathComponent("settings.json"))
        let stores = try inMemoryStores()
        // Include an app server to exercise both sequential redactors.
        try stores.saveGlobalAgentMCPServers(["helper": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: "Example"), willDeliver: {})
        let events = try await collectTurn(run)
        #expect(!String(describing: events).contains("synthetic-credential-"))
        #expect(events.contains { if case .toolFinished(let output, _) = $0.kind { output.stringValue?.contains("[redacted]") == true } else { false } })
        try await run.shutdown()
    }
}
