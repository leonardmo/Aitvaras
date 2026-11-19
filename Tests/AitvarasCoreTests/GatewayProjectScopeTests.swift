import Foundation
import GRDB
import Testing
import AitvarasAgents
import AitvarasCore
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(1))) struct GatewayProjectScopeTests {
    @Test func deepestFolderWinsAndLaunchDoesNotFollowFolderChanges() throws {
        let stores = try inMemoryStores()
        let base = URL(fileURLWithPath: "/example/gateway")
        let nested = base.appendingPathComponent("nested")
        let parent = try stores.createWorkspaceProject(title: "Example parent", folders: [.init(path: base.path)])
        let child = try stores.createWorkspaceProject(title: "Example nested", folders: [.init(path: nested.path)])
        let directory = nested.appendingPathComponent("child")
        let launch = try stores.gatewayLaunchContext(client: .codex, startingDirectory: directory)
        #expect(launch.projectID == child.id)
        let before = try stores.gatewayToolScopeSettings(projectID: child.id)
        try stores.saveGatewayToolScopes(projectID: child.id, scopes: [.memory], expectedRevision: before.revision)
        try stores.replaceWorkspaceFolders(projectID: child.id, folders: [])
        let newLaunch = try stores.gatewayLaunchContext(client: .codex, startingDirectory: directory)
        #expect(newLaunch.projectID == parent.id)
        let gate = stores.gatewayToolScopeGate()
        #expect(try gate.listedTools([queryTool], for: launch).count == 1)
        #expect(try gate.listedTools([queryTool], for: newLaunch).isEmpty)
        #expect(try stores.gatewayLaunchContext(client: .claude, startingDirectory: URL(fileURLWithPath: base.path + "-other")).projectID == nil)
    }

    @Test func launchUsesChatOwnershipAndReadyWorktreesButRejectsAmbiguity() throws {
        let stores = try inMemoryStores()
        let parentRoot = URL(fileURLWithPath: "/example/gateway-project")
        let tree = parentRoot.appendingPathComponent("worktree")
        let parent = try stores.createWorkspaceProject(title: "Example parent", folders: [.init(path: parentRoot.path)])
        let owner = try stores.createWorkspaceProject(title: "Worktree owner")
        let chat = try stores.createWorkspaceChat(projectID: owner.id, title: "Example chat")
        let repo = URL(fileURLWithPath: "/example/source")
        try stores.reserveAgentWorktree(.init(chatID: chat.id, projectID: owner.id, repository: repo, worktree: tree,
                                             branch: "example", additionalRoots: []))
        #expect(throws: AgentStoreError.identityConflict) {
            try stores.gatewayLaunchContext(client: .claude, startingDirectory: tree)
        }
        try stores.finishAgentWorktree(chatID: chat.id, state: .ready)
        #expect(try stores.gatewayLaunchContext(client: .claude, startingDirectory: tree).projectID == owner.id)
        let folder = tree.appendingPathComponent("registered")
        try stores.replaceWorkspaceFolders(projectID: parent.id, folders: [.init(path: folder.path)])
        #expect(try stores.gatewayLaunchContext(client: .claude, startingDirectory: folder).projectID == parent.id)
        _ = try stores.createWorkspaceProject(title: "Other project", folders: [.init(path: folder.path)])
        #expect(throws: AgentStoreError.identityConflict) {
            try stores.gatewayLaunchContext(client: .claude, startingDirectory: folder)
        }
        #expect(try stores.gatewayLaunchContext(client: .claude, owningChatID: chat.id).projectID == owner.id)
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        #expect(throws: AgentStoreError.missingChat) { try stores.gatewayLaunchContext(client: .claude, owningChatID: chat.id) }
    }

    @Test func aSymlinkOutOfARegisteredFolderDoesNotBorrowItsProject() throws {
        let stores = try inMemoryStores()
        let fs = FileManager.default
        let root = fs.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let allowed = root.appendingPathComponent("project")
        let outside = root.appendingPathComponent("outside")
        try fs.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: root) }
        try fs.createDirectory(at: outside, withIntermediateDirectories: false)
        let escape = allowed.appendingPathComponent("escape")
        try fs.createSymbolicLink(at: escape, withDestinationURL: outside)
        let project = try stores.createWorkspaceProject(title: "Example", folders: [.init(path: allowed.path)])
        #expect(try stores.gatewayLaunchContext(client: .claude, startingDirectory: allowed).projectID == project.id)
        #expect(try stores.gatewayLaunchContext(client: .claude, startingDirectory: escape).projectID == nil)
    }

    @Test func grantsDefaultToDeniedAndRevocationAppliesAtDispatch() async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        let context = GatewayLaunchContext(client: .codex, projectID: project.id)
        let gate = stores.gatewayToolScopeGate()
        #expect(try gate.listedTools([queryTool], for: context).isEmpty)
        await #expect(throws: GatewayToolScopeError.notGranted) {
            try await gate.execute(queryTool, for: context, arguments: .object([:])) { _, _ in throw UnexpectedCall.executed }
        }
        let saved = try stores.saveGatewayToolScopes(projectID: project.id, scopes: [.memory], expectedRevision: 0)
        #expect(try gate.listedTools([queryTool, recordTool], for: context).map(\.definition.name) == [queryTool.definition.name])
        let access = try await gate.execute(queryTool, for: context, arguments: .object([:])) { access, _ in access }
        #expect(access.projectID == project.id)
        let outside = GatewayLaunchContext(client: .claude, projectID: nil)
        #expect(try gate.listedTools([queryTool], for: outside).isEmpty)
        await #expect(throws: GatewayToolScopeError.notGranted) {
            try await gate.execute(queryTool, for: outside, arguments: .object([:])) { _, _ in throw UnexpectedCall.executed }
        }

        try stores.saveGatewayToolScopes(projectID: project.id, scopes: [], expectedRevision: saved.revision)
        #expect(throws: WorkspacePolicyError.staleReview) {
            try stores.saveGatewayToolScopes(projectID: project.id, scopes: [.memory], expectedRevision: saved.revision)
        }
        await #expect(throws: GatewayToolScopeError.notGranted) {
            try await gate.execute(queryTool, for: context, arguments: .object([:])) { _, _ in throw UnexpectedCall.executed }
        }
    }

    @Test func recordScopeRejectsForgedForeignAndUnknownIDs() async throws {
        let stores = try inMemoryStores()
        let one = try stores.createWorkspaceProject(title: "One")
        let two = try stores.createWorkspaceProject(title: "Two")
        let owned = try stores.createWorkspaceChat(projectID: one.id, title: "Owned")
        let foreign = try stores.createWorkspaceChat(projectID: two.id, title: "Foreign")
        let launch = GatewayLaunchContext(client: .claude, projectID: one.id)
        try stores.saveGatewayToolScopes(projectID: one.id, scopes: [.activity], expectedRevision: 0)
        let gate = stores.gatewayToolScopeGate()
        let owner: @Sendable (GatewayToolScope, String) throws -> UUID? = { scope, value in
            guard scope == .activity, let id = UUID(uuidString: value) else { return nil }
            return try stores.workspaceChat(id: id)?.projectID
        }
        for id in [foreign.id, UUID()] {
            await #expect(throws: GatewayToolScopeError.recordOutsideProject) {
                try await gate.execute(recordTool, for: launch,
                    arguments: .object(["id": .string(id.uuidString), "projectID": .string(two.id.uuidString)]),
                    recordOwner: owner) { _, _ in throw UnexpectedCall.executed }
            }
        }
        await #expect(throws: GatewayToolScopeError.invalidArguments) {
            try await gate.execute(recordTool, for: launch, arguments: .object([:]), recordOwner: owner) {
                _, _ in throw UnexpectedCall.executed
            }
        }
        let access = try await gate.execute(recordTool, for: launch,
            arguments: .object(["id": .string(owned.id.uuidString)]), recordOwner: owner) { access, _ in access }
        #expect(access.projectID == one.id)
    }

    @Test func auditFailureDoesNotPersistScopeGrants() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Example")
        try stores.db.queue.write { dbc in
            try dbc.execute(sql: "CREATE TRIGGER gatewayAuditFailure BEFORE INSERT ON activityEvent BEGIN SELECT RAISE(ABORT, 'fixture failure'); END")
        }
        #expect(throws: DatabaseError.self) {
            try stores.saveGatewayToolScopes(projectID: project.id, scopes: [.memory], expectedRevision: 0)
        }
        let settings = try stores.gatewayToolScopeSettings(projectID: project.id)
        #expect(settings.revision == 0)
        #expect(settings.scopes.isEmpty)
    }

    private enum UnexpectedCall: Error { case executed }
    private var queryTool: GatewayScopedTool {
        .init(definition: .init(name: "search", description: "Search scoped data", parametersJSON: "{}", risk: .read),
              scope: .memory, access: .projectQuery)
    }

    private var recordTool: GatewayScopedTool {
        .init(definition: .init(name: "get", description: "Get scoped data", parametersJSON: "{}", risk: .read),
              scope: .activity, access: .records(idArguments: ["id"]))
    }
}
