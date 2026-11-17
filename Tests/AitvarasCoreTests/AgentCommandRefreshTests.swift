import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentCommandRefreshTests {
    @Test func catalogIdentityIncludesProjectDirectoryProviderOwnerAndSetupRevision() {
        let owner = UUID(), project = UUID(), revision = UUID(), directory = URL(fileURLWithPath: "/tmp/project")
        let context = AgentCommandCatalogContext(ownerID: owner, projectID: project, directory: directory, provider: .claude, revision: revision)
        #expect(context == .init(ownerID: owner, projectID: project, directory: directory, provider: .claude, revision: revision))
        #expect(context != .init(ownerID: owner, projectID: UUID(), directory: directory, provider: .claude, revision: revision))
        #expect(context != .init(ownerID: owner, projectID: project, directory: directory.appendingPathComponent("worktree"), provider: .claude, revision: revision))
        #expect(context != .init(ownerID: owner, projectID: project, directory: directory, provider: .codex, revision: revision))
        #expect(context != .init(ownerID: UUID(), projectID: project, directory: directory, provider: .claude, revision: revision))
        #expect(context != .init(ownerID: owner, projectID: project, directory: directory, provider: .claude, revision: UUID()))
    }

    @Test func selectedCommandHintsDisappearOnceArgumentsAreEnteredWithoutAlteringText() {
        let command = AgentCommand(name: "shout", description: "Repeat", argumentHint: "[words]")
        #expect(command.argumentPlaceholder(in: "/shout ") == "[words]")
        #expect(command.argumentPlaceholder(in: "/shout quiet words") == nil)
        #expect(command.argumentPlaceholder(in: "/other ") == nil)
        #expect(command.argumentPlaceholder(in: "") == nil)
        #expect(command.insertion == "/shout")
        let long = AgentCommand(name: "shout", description: "", argumentHint: String(repeating: "ä", count: 1024))
        #expect((long.argumentPlaceholder(in: "/shout ")?.utf8.count ?? 0) <= 512)
    }

    @Test func freshCatalogProbesUseEachProjectDirectoryAndRetainArgumentHints() async throws {
        let fixture = try AgentExecutableFixture(#"""
        exec /usr/bin/python3 -u -c '
        import os, sys, json, time
        def emit(value): print(json.dumps(value), flush=True)
        if sys.argv[1:3] == ["auth", "status"]:
            emit({"loggedIn":True,"authMethod":"claude.ai","apiKeySource":"none","apiProvider":"firstParty","subscriptionType":"pro"})
        else:
            request=json.loads(sys.stdin.readline())
            assert request["request"]["subtype"]=="initialize"
            emit({"type":"control_response","response":{"subtype":"success","request_id":request["request_id"],"response":{"commands":[{"name":os.path.basename(os.getcwd()),"description":"Example","argumentHint":"[words]"}]}}})
            for _ in range(15): time.sleep(1)
        ' "$@"
        """#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        for name in ["one", "two"] {
            let directory = fixture.directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let commands = try await backend.commands(directory: directory)
            #expect(commands.map(\.name) == [name])
            #expect(commands.first?.argumentHint == "[words]")
        }
    }

    @Test func slashArgumentsRemainUserTextAfterSelectingTheHintedCommand() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
claude_init()
r=read(); assert r['message']['content']=='/shout quiet little words'
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        let command = AgentCommand(name: "shout", description: "Repeat", argumentHint: "[words]")
        try await run.send(.init(text: "/shout quiet little words", command: command), willDeliver: {})
        _ = try await collectTurn(run)
        try fixture.assertComplete(); try await run.shutdown()
    }
}
