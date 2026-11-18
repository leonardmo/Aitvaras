import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPSecurityTests {
    @Test(arguments: [
        #"{"mcpServers":{},"mcpServers":{"echo":{"command":"echo"}}}"#,
        #"{"mcpServers":{"echo":{"command":"echo"},"echo":{"command":"other"}}}"#,
        #"{"mcpServers":{"echo":{"command":"echo","command":"other"}}}"#,
        #"{"mcpServers":{"echo":{"command":"echo","env":{"KEY":"one","KEY":"two"}}}}"#,
        #"{"extra":[{"a":1,"\u0061":2}],"mcpServers":{}}"#,
        #"{"mcpServers":{"e\u0301":{"command":"echo"}}}"#,
        #"{"mcpServers":{"\u00e9":{"command":"echo"},"e\u0301":{"command":"other"}}}"#
    ])
    func ambiguousJSONFailsClosed(json: String) throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let data = Data(json.utf8)
        #expect(throws: (any Error).self) { try AgentMCPResolver.repositoryEntries(data: data, source: ".mcp.json") }
        try data.write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let result = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        #expect(result.repositoryUnreadable)
        #expect(result.effectiveServers.isEmpty)
    }

    @Test func escapedKeysAndDuplicateNamesInSeparateObjectsRemainValid() throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        try Data(#"{"extra":{"a":1},"mcpServers":{"\u0065cho":{"command":"echo","env":{"a":"one"}}}}"#.utf8)
            .write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let result = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        #expect(!result.repositoryUnreadable)
        #expect(result.disabledProjectServers == ["echo"])
    }

    @Test func fingerprintPreservesDistinctUnicodeKeysInsideUnknownOptions() throws {
        let first = try AgentMCPJSON.parse(Data(#"{"command":"echo","oauth":{"\u00e9":1,"e\u0301":2}}"#.utf8))
        let changed = try AgentMCPJSON.parse(Data(#"{"command":"echo","oauth":{"\u00e9":1,"e\u0301":3}}"#.utf8))
        #expect(first.canonical != changed.canonical)
        #expect(try AgentMCPJSON.parse(first.canonical).canonical == first.canonical)
    }

    @Test func ancestorsGateEveryNameAndDifferingDuplicatesCannotBeApproved() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let child = fixture.directory.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let parentJSON = #"{"mcpServers":{"echo":{"command":"echo"},"docs":{"command":"parent"},"inherited":{"command":"echo"}}}"#
        try Data(parentJSON.utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        try Data(#"{"mcpServers":{"echo":{"command":"echo"},"docs":{"command":"child"}}}"#.utf8)
            .write(to: child.appendingPathComponent(".mcp.json"))
        let inventory = try AgentMCPResolver.prepare(directory: child, setup: .init())
        #expect(inventory.disabledProjectServers == ["docs", "echo", "inherited"])
        #expect(inventory.repositoryEntries["echo"]?.sourceFiles == [".mcp.json", "../.mcp.json"])
        #expect(inventory.repositoryEntries["docs"]?.unsupportedReason == "defined differently in several .mcp.json files")
        let approved = try AgentMCPResolver.prepare(directory: child, setup: .init(approvedServers: inventory.repositoryFingerprints))
        #expect(approved.disabledProjectServers == ["docs"])
        #expect(Set(approved.effectiveServers.keys) == ["echo", "inherited"])
        let stores = try inMemoryStores(), chat = try setupProjectChat(stores, directory: child)
        let setup = coordinator(stores, SetupVault())
        let state = try await setup.state(projectID: chat.projectID, provider: .claude)
        #expect(state.servers.first { $0.name == "echo" }?.sourceLabel == "Repo · .mcp.json, ../.mcp.json")
        #expect(state.servers.first { $0.name == "inherited" }?.sourceLabel == "Repo · ../.mcp.json")
        #expect(state.servers.first { $0.name == "docs" }?.canApprove == false)
        await #expect(throws: AgentMCPError.invalidApproval) {
            try await setup.edit(projectID: chat.projectID, edit: .approve(name: "docs", fingerprint: inventory.repositoryFingerprints["docs"]!))
        }
        try Data("invalid".utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let unreadable = try AgentMCPResolver.prepare(directory: child, setup: .init(approvedServers: inventory.repositoryFingerprints))
        #expect(unreadable.repositoryUnreadable)
        #expect(unreadable.effectiveServers.isEmpty)
        #expect(unreadable.disabledProjectServers == ["docs", "echo"])
    }

    @Test(arguments: ["telegram.token", "homelab.token", "agent.mcp.invalid", "agent.mcp.00000000-0000-4000-8000-000000000001.suffix"])
    func foreignSecretReferencesCannotDecodeSaveOrResolve(reference: String) async throws {
        let value = #"{"secretKey":""# + reference + #""}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentMCPValue.self, from: Data(value.utf8)) }
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let stores = try inMemoryStores()
        let server = AgentMCPServer(command: "echo", env: ["ACCESS": .secretReference(reference)])
        #expect(throws: AgentMCPError.invalidConfiguration) { try stores.saveGlobalAgentMCPServers(["echo": server]) }
        await #expect(throws: AgentMCPError.invalidConfiguration) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(), servers: ["echo": server],
                audit: { _ in }, resolveSecret: { _ in Issue.record("Foreign reference reached resolver"); return nil })
        }
    }

    @Test(arguments: [false, true])
    func unapprovedInitStopsBeforeAnyToolAndIsAudited(beforeInitialize: Bool) async throws {
        let prefix = beforeInitialize ? "r=read()" : "claude_init(); read()"
        let fixture = try BackendExecutableFixture(script: prefix + #"""

emit({'type':'system','subtype':'init','apiKeySource':'none','mcp_servers':[{'name':'unexpected','source':'project','status':'connected'}]})
emit({'type':'assistant','message':{'id':'message-example','role':'assistant','content':[{'type':'tool_use','id':'tool-example','name':'Bash','input':{'command':'echo example'}}]}})
for _ in range(5):
    time.sleep(1)
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        let backend = ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
        if beforeInitialize {
            await #expect(throws: AgentFailure.unapprovedProjectMCP) { try await backend.start(.init(directory: fixture.directory, model: "default", projectID: project.id)) }
        } else {
            let run = try await backend.start(.init(directory: fixture.directory, model: "default", projectID: project.id))
            try await run.send(.init(text: "Example"), willDeliver: {})
            var observedFailure = false, tools = 0
            do {
                for try await event in run.events {
                    if case .toolStarted = event.kind { tools += 1 }
                    if case .turnEnded(.failed(.unapprovedProjectMCP)) = event.kind { observedFailure = true }
                }
            } catch { #expect(error as? AgentFailure == .unapprovedProjectMCP); observedFailure = true }
            #expect(observedFailure); #expect(tools == 0)
            try await run.shutdown()
        }
        #expect(try stores.activity(since: .distantPast).contains { $0.summary == "Unapproved project MCP server reported; run stopped" })
        #expect(AgentFailure.sendMessage(for: AgentFailure.unapprovedProjectMCP, provider: .claude).contains("Agent setup"))
    }

    @Test func reportedProjectNamesMustRemainASCIIEvenWhenCanonicallyEquivalent() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let policy = AgentMCPLaunchPolicy(load: { _, _ in .init(projectID: UUID()) }, audit: { _ in })
        let original = try policy.snapshot(directory: fixture.directory)
        let resolution = AgentMCPResolution(repositoryServers: ["K": .init(command: "echo")], repositoryEntries: [:],
            repositoryUnreadable: false, repositoryFingerprints: [:], disabledProjectServers: [], claudeServers: [:],
            effectiveServers: ["K": .init(command: "echo")], localServers: [:], unavailableForLocal: [:])
        let snapshot = AgentMCPLaunchSnapshot(projectID: original.projectID, resolution: resolution, status: original.status, permissionSource: .repo)
        try await policy.validateProjectServers(JSONValue.parse(#"{"mcp_servers":[{"name":"K","source":"project"}]}"#)!, snapshot: snapshot, runID: UUID())
        await #expect(throws: AgentFailure.unapprovedProjectMCP) {
            try await policy.validateProjectServers(JSONValue.parse(#"{"mcp_servers":[{"name":"\u212a","source":"project","status":"connected"}]}"#)!, snapshot: snapshot, runID: UUID())
        }
    }

    @Test func claudeRuntimeFileIsGoneAfterInitWhileRedactionStillWorks() async throws {
        let fixture = try BackendExecutableFixture(script: #"""
path=sys.argv[sys.argv.index('--mcp-config')+1]
assert os.path.isfile(path)
claude_init()
read()
emit({'type':'system','subtype':'init','apiKeySource':'none','mcp_servers':[]})
emit({'type':'system','subtype':'hook_response','hook_id':'hook-example','hook_name':'PreToolUse:Bash','hook_event':'PreToolUse','stderr':'synthetic-runtime-value','exit_code':2,'outcome':'error'})
emit({'type':'result','is_error':False})
done()
"""#)
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo", env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])])
        let run = try await ClaudeBackend(executable: fixture.executable, environment: fixture.environment, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory))
            .start(.init(directory: fixture.directory, model: "default", projectID: project.id))
        try await run.send(.init(text: "Example"), willDeliver: {})
        var checked = false
        for try await event in run.events {
            if case .setupReported(let setup) = event.kind, setup.serversAvailable {
                let directory = fixture.directory.appendingPathComponent("Runtime/mcp/" + project.id.uuidString)
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
                checked = true
            }
            if case .hook(let hook) = event.kind { #expect(!(hook.reason ?? "").contains("synthetic-runtime-value")) }
            if case .turnEnded = event.kind { break }
        }
        #expect(checked)
        try fixture.assertComplete(); try await run.shutdown()
    }

    @Test func startupSweepRemovesOnlyOwnedRegularRuntimeFilesAndNeverFollowsLinks() async throws {
        let fixture = try AgentExecutableFixture("exit 0"); defer { fixture.remove() }
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(), servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        let projectDirectory = file.url.deletingLastPathComponent()
        let target = fixture.directory.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: target)
        let link = projectDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let directory = projectDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let unknown = projectDirectory.appendingPathComponent("unrelated.json")
        try Data("keep".utf8).write(to: unknown)
        let foreign = fixture.directory.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let foreignFile = foreign.appendingPathComponent(UUID().uuidString + ".json")
        try Data("keep".utf8).write(to: foreignFile)
        try FileManager.default.createSymbolicLink(at: projectDirectory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString), withDestinationURL: foreign)
        try await AgentMCPRuntimeFile.sweep(stateDirectory: fixture.directory, audit: { _ in })
        #expect(FileManager.default.fileExists(atPath: foreignFile.path))
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        try await file.remove()
        // A symlink at an expected root must fail startup rather than traverse it.
        let other = fixture.directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("Runtime"), withDestinationURL: fixture.directory.appendingPathComponent("Runtime"))
        await #expect(throws: AgentMCPError.runtimeFile) { try await AgentMCPRuntimeFile.sweep(stateDirectory: other, audit: { _ in }) }
    }
}
