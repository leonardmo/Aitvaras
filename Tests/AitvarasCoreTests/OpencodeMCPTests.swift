import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct OpencodeMCPTests {
    @Test func optInUsesPrivateCompleteConfigAndKeepsPermissionBoundary() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo", args: ["example"], env: ["ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")]),
            "remote": .init(transport: .http, url: "https://service.example.invalid/mcp")])
        var setup = WorkspaceAgentSetup(projectID: project.id); setup.localMayUseMCP = true
        try stores.saveWorkspaceAgentSetup(setup)
        let wire = OpencodeFakeTransport()
        let backend = OpencodeBackend(transport: wire, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory),
                                      catalog: { [.init(id: "test-model", name: "Example")] })
        let raw = try await backend.start(.init(directory: fixture.directory, model: "test-model", projectID: project.id))
        let path = try #require(await wire.mcpConfigPaths.last ?? nil)
        let config = try #require(JSONValue.parse(String(contentsOf: path, encoding: .utf8)))
        #expect(config["mcp"]?.objectValue?.keys.sorted() == ["echo"])
        #expect(config["mcp"]?["echo"]?["environment"]?["ACCESS"] == .string("synthetic-runtime-value"))
        #expect(config["enabled_providers"] == .array([.string("ollama")]))
        #expect(config["permission"]?["*"] == .string("ask"))
        #expect(raw.mcpSetup?.unavailableForLocal["remote"] == .remoteTransport)
        let run = AgentActionCoordinator(run: raw, mode: .ask, provenance: .init(chatID: UUID()), audit: { _ = try stores.record($0) })
        try await run.send(.init(text: "Use echo"), willDeliver: {})
        await wire.emit(localEvent("permission.asked", ["id": .string("permission_echo"), "action": .string("mcp__echo__echo")]))
        try await waitOpencode { await run.pendingRequests().count == 1 }
        #expect(await !wire.calls.contains { $0.path.hasSuffix("/reply") })
        let request = try #require(await run.pendingRequests().first)
        try await run.respond(to: request, with: .allow(updatedInput: nil))
        #expect(await wire.calls.last?.body?["decision"] == .string("once"))
        await wire.emit(localEvent("session.execution.succeeded"))
        try await run.shutdown(); await backend.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let environment = OpencodeConfiguration(root: fixture.directory).environment(["OPENCODE_CONFIG_CONTENT": "untrusted"], runtimeConfig: path)
        #expect(environment["OPENCODE_CONFIG"] == path.path)
        #expect(environment["OPENCODE_CONFIG_CONTENT"] == nil)
        #expect(!environment.values.contains("synthetic-runtime-value"))
    }

    @Test func revisionChangeWithIdenticalRootsRestartsIdleServerAndCleansOldFile() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        var setup = WorkspaceAgentSetup(projectID: project.id); setup.localMayUseMCP = true
        try stores.saveWorkspaceAgentSetup(setup)
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")])
        let wire = OpencodeFakeTransport()
        let backend = OpencodeBackend(transport: wire, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory),
                                      catalog: { [.init(id: "test-model", name: "Example")] })
        let configuration = AgentSessionConfiguration(directory: fixture.directory, model: "test-model", projectID: project.id)
        let first = try await backend.start(configuration)
        let firstPath = try #require(await wire.mcpConfigPaths.last ?? nil)
        setup.disabledGlobalServers = ["echo"]; try stores.saveWorkspaceAgentSetup(setup)
        let second = try await backend.start(configuration)
        #expect(await wire.opens == 2)
        #expect(await wire.mcpConfigPaths.last == .some(nil))
        #expect(first.mcpSetup?.revision != second.mcpSetup?.revision)
        #expect(!FileManager.default.fileExists(atPath: firstPath.path))
        try await second.shutdown(); await backend.shutdown()
    }

    @Test func activeServerRejectsChangedSetupWithoutWideningOrDeletingItsFile() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        var setup = WorkspaceAgentSetup(projectID: project.id); setup.localMayUseMCP = true
        try stores.saveWorkspaceAgentSetup(setup)
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")])
        let wire = OpencodeFakeTransport()
        let backend = OpencodeBackend(transport: wire, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory),
                                      catalog: { [.init(id: "test-model", name: "Example")] })
        let configuration = AgentSessionConfiguration(directory: fixture.directory, model: "test-model", projectID: project.id)
        let run = try await backend.start(configuration)
        try await run.send(.init(text: "Working"), willDeliver: {})
        let path = try #require(await wire.mcpConfigPaths.last ?? nil)
        setup.localMayUseMCP = false; try stores.saveWorkspaceAgentSetup(setup)
        await #expect(throws: AgentFailure.invalidTransition) { try await backend.start(configuration) }
        #expect(await wire.opens == 1); #expect(FileManager.default.fileExists(atPath: path.path))
        await run.abort(); await backend.shutdown()
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test(arguments: ["open", "session", "cancel"])
    func failedOrCancelledStartupCleansRuntime(scenario: String) async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        var setup = WorkspaceAgentSetup(projectID: project.id); setup.localMayUseMCP = true
        try stores.saveWorkspaceAgentSetup(setup)
        try stores.saveGlobalAgentMCPServers(["echo": .init(command: "echo")])
        let wire = OpencodeFakeTransport()
        if scenario == "open" { await wire.setOpenFailure(true) }
        if scenario == "session" { await wire.setFailure(true) }
        if scenario == "cancel" { await wire.pauseNextOpen() }
        let backend = OpencodeBackend(transport: wire, mcpPolicy: mcpTestPolicy(stores, root: fixture.directory),
                                      catalog: { [.init(id: "test-model", name: "Example")] })
        let configuration = AgentSessionConfiguration(directory: fixture.directory, model: "test-model", projectID: project.id)
        if scenario == "cancel" {
            let task = Task { try await backend.start(configuration) }
            try await waitOpencode { await wire.openIsPaused }
            await backend.shutdown(); task.cancel(); await wire.releaseOpen()
            await #expect(throws: (any Error).self) { try await task.value }
        } else {
            await #expect(throws: (any Error).self) { try await backend.start(configuration) }
        }
        let path = try #require(await wire.mcpConfigPaths.last ?? nil)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        await backend.shutdown()
    }

    @Test func localDefaultsOffAndOnlyMatchingApprovedRepoDefinitionsAreTranslated() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: fixture.directory.path)])
        try Data(#"{"mcpServers":{"echo":{"command":"echo"}}}"#.utf8).write(to: fixture.directory.appendingPathComponent(".mcp.json"))
        let policy = mcpTestPolicy(stores, root: fixture.directory)
        let wire = OpencodeFakeTransport()
        let backend = OpencodeBackend(transport: wire, mcpPolicy: policy, catalog: { [.init(id: "test-model", name: "Example")] })
        let configuration = AgentSessionConfiguration(directory: fixture.directory, model: "test-model", projectID: project.id)
        let off = try await backend.start(configuration)
        #expect(await wire.mcpConfigPaths.last == .some(nil))
        try await off.shutdown()
        var setup = WorkspaceAgentSetup(projectID: project.id)
        setup.localMayUseMCP = true; setup.approvedProjectServers = ["echo"]
        setup.approvedProjectServerFingerprints = try policy.snapshot(directory: fixture.directory, projectID: project.id).resolution.repositoryFingerprints
        try stores.saveWorkspaceAgentSetup(setup)
        let approved = try await backend.start(configuration)
        let path = try #require(await wire.mcpConfigPaths.last ?? nil)
        #expect(try String(contentsOf: path, encoding: .utf8).contains("echo"))
        try await approved.shutdown(); await backend.shutdown()
    }
}
