import Foundation
import Testing
@testable import AitvarasAgents

struct AgentComposerInputTests {
    @Test func absentAndMalformedCatalogsNeverInventCommands() throws {
        #expect(throws: AgentFailure.unsupported) { try AgentCommandCatalog.claude(.object([:])) }
        #expect(throws: AgentFailure.invalidRequest) {
            try AgentCommandCatalog.codex(.null, directory: URL(fileURLWithPath: "/tmp/project"))
        }
        // The checked-in real initialize recording has models but no commands.
        let recording = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/claude/ask-mode.jsonl"), encoding: .utf8)
        let initialize = try #require(recording.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
            .first { $0["type"]?.stringValue == "control_response" }?["response"]?["response"])
        #expect(throws: AgentFailure.unsupported) { try AgentCommandCatalog.claude(initialize) }
    }

    @Test func catalogsDeduplicateAndExcludeDisabledOrInvalidEntries() throws {
        let claude = try AgentCommandCatalog.claude(JSONValue.parse(#"{"commands":[{"name":"review","description":"Review changes","argumentHint":"[file]"},{"name":"review","description":"Duplicate"},{"name":"bad name"},{"name":"test","description":"Run tests"}]}"#)!)
        #expect(claude.map(\.name) == ["review", "test"])
        #expect(claude.first?.argumentHint == "[file]")
        #expect(claude.first?.insertion == "/review")
        let codex = try AgentCommandCatalog.codex(JSONValue.parse(#"{"data":[{"cwd":"/tmp/project","errors":[],"skills":[{"name":"review","description":"Review","enabled":true,"path":"/tmp/project/review/SKILL.md"},{"name":"review","description":"Duplicate","enabled":true,"path":"/tmp/project/other/SKILL.md"},{"name":"hidden","enabled":false,"path":"/tmp/project/hidden/SKILL.md"}]},{"cwd":"/tmp/other","skills":[{"name":"unrelated","enabled":true,"path":"/tmp/other/SKILL.md"}]}]}"#)!, directory: URL(fileURLWithPath: "/tmp/project"))
        #expect(codex.map(\.name) == ["review"])
        #expect(codex.first?.insertion == "$review")
    }

    @Test func explicitSelectionAndFilenameQuotingAreLossless() throws {
        let file = AgentFileMention(path: "/tmp/project/a \"quote\"\\line\n.txt", name: "a file")
        let quoted = try #require(JSONValue.parse(String(file.insertion.dropFirst())))
        #expect(quoted.stringValue == file.path)
        let draft = "Read @a"
        let trigger = try #require(AgentComposerTrigger.detect(draft))
        #expect(trigger.kind == .file)
        #expect(trigger.query == "a")
        #expect(draft == "Read @a") // Detection has no input mutation or I/O.
        #expect(trigger.selecting(file.insertion, in: "draft changed") == nil)
        let selected = try #require(trigger.selecting(file.insertion, in: draft))
        let command = AgentCommand(name: "review", description: "Review", skillPath: "/tmp/project/SKILL.md")
        let literal = try AgentInput(text: draft).codexContent()
        #expect(literal.arrayValue?.count == 1)
        let mention = try AgentInput(text: selected, mentions: [file]).codexContent()
        #expect(mention.arrayValue?.last?["type"] == .string("mention"))
        #expect(mention.arrayValue?.last?["path"] == .string(file.path))
        #expect(try AgentInput(text: "removed", mentions: [file], command: command).codexContent().arrayValue?.count == 1)
        #expect(try AgentInput(text: "$reviewer", command: command).codexContent().arrayValue?.count == 1)
        let skill = try AgentInput(text: "$review please", command: command).codexContent()
        #expect(skill.arrayValue?.last == .object(["type": .string("skill"), "name": .string("review"), "path": .string("/tmp/project/SKILL.md")]))
        #expect(AgentComposerTrigger.detect("/rev")?.kind == .command)
        #expect(AgentComposerTrigger.detect("/review done") == nil)
        #expect(AgentComposerTrigger.detect("person@example.org") == nil)
    }

    @Test func localSearchIsProjectScopedAndSkipsSymlinksAndHiddenFolders() throws {
        let fixture = try BackendExecutableFixture(script: "done()")
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".private"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a b.swift")
        try Data("source".utf8).write(to: file)
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".private/hidden.swift"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: fixture.executable)
        let matches = try AgentFileMention.localSearch(query: "", directory: root)
        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.name == "a b.swift")
        #expect(URL(fileURLWithPath: match.path).lastPathComponent == file.lastPathComponent)
        #expect(FileManager.default.contents(atPath: match.path) == Data("source".utf8))
        #expect(try AgentFileMention.localSearch(query: "absent", directory: root).isEmpty)
        let codex: JSONValue = .object(["files": .array([
            .object(["root": .string(root.path), "path": .string("a b.swift"), "file_name": .string("a b.swift"), "match_type": .string("file")]),
            .object(["root": .string(root.path), "path": .string("a b.swift"), "match_type": .string("file")]),
            .object(["root": .string(root.path), "path": .string("../provider"), "match_type": .string("file")]),
            .object(["root": .string(root.path), "path": .string("escape"), "match_type": .string("file")]),
            .object(["root": .string(root.path), "path": .string("folder"), "match_type": .string("directory")])])])
        let nativeMatches = try AgentFileMention.codex(codex, directory: root)
        #expect(nativeMatches.count == 1)
        let nativeMatch = try #require(nativeMatches.first)
        #expect(URL(fileURLWithPath: nativeMatch.path).lastPathComponent == file.lastPathComponent)
        #expect(FileManager.default.contents(atPath: nativeMatch.path) == Data("source".utf8))
    }

    @Test func claudeInitializeCatalogDoesNotSend() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
assert '--model' not in sys.argv
assert os.getcwd()==os.path.realpath(root)
r=read(); assert r['request']['subtype']=='initialize'
emit({'type':'control_response','response':{'subtype':'success','request_id':r['request_id'],'response':{'commands':[{'name':'review','description':'Review changes','argumentHint':'[file]'}]}}})
open('done','w').close()
# Discovery closes the process; it must never send a prompt.
assert sys.stdin.readline()==''
"""#)
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        #expect(try await backend.commands(directory: fixture.directory).map(\.name) == ["review"])
        try fixture.assertComplete()
    }

    @Test func unavailableClaudeCatalogIsReported() async throws {
        let fixture = try BackendExecutableFixture(script: "claude_init()\ndone()")
        defer { fixture.remove() }
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: AgentFailure.unsupported) { try await backend.commands(directory: fixture.directory) }
    }

    @Test func codexDiscoveryAndExplicitSelectionReachNativeInputs() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
r=read(); assert r['method']=='skills/list'
assert r['params']=={'cwds':[root],'forceReload':False}
emit({'id':r['id'],'result':{'data':[{'cwd':root,'errors':[],'skills':[{'name':'review','description':'Review','enabled':True,'path':root+'/SKILL.md','scope':'repo'}]}]}})
r=read(); assert r['method']=='fuzzyFileSearch'
assert r['params']=={'query':'a b','roots':[root]}
emit({'id':r['id'],'result':{'files':[{'root':root,'path':'a b.swift','file_name':'a b.swift','match_type':'file','score':1}]}})
start_thread()
r=read(); assert r['method']=='turn/start'
assert r['params']['input'][1:]==[{'type':'mention','name':'a b.swift','path':root+'/a b.swift'},{'type':'skill','name':'review','path':root+'/SKILL.md'}]
emit({'id':r['id'],'result':{'turn':{'id':'active'}}})
emit({'method':'turn/completed','params':{'threadId':'thread-test','turn':{'id':'active','status':'completed','items':[]}}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let commands = try await backend.commands(directory: fixture.directory)
        let files = try await backend.files(query: "a b", directory: fixture.directory)
        let command = try #require(commands.first), file = try #require(files.first)
        let run = try await backend.start(.init(directory: fixture.directory, model: "default"))
        try await run.send(.init(text: command.insertion + " " + file.insertion, mentions: [file], command: command), willDeliver: {})
        _ = try await collectTurn(run)
        try await waitAgentCondition { FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path) }
        try fixture.assertComplete()
        try await run.shutdown(); try await backend.shutdown()
    }

    @Test func garbageCatalogAndSearchResponseFailWithoutPromptDelivery() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
codex_init()
for method in ['skills/list','fuzzyFileSearch']:
    r=read(); assert r['method']==method
    emit({'id':r['id'],'result':{'unexpected':True}})
done()
"""#)
        defer { fixture.remove() }
        let backend = CodexBackend(executable: fixture.executable, environment: fixture.environment)
        await #expect(throws: AgentFailure.invalidRequest) { try await backend.commands(directory: fixture.directory) }
        await #expect(throws: AgentFailure.invalidRequest) { try await backend.files(query: "", directory: fixture.directory) }
        try await backend.shutdown()
    }
}
