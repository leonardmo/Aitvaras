import Foundation
import Testing
import AitvarasCore
import AitvarasAgents
@testable import AitvarasStore

private struct GitFixture {
    let root: URL
    let git: GitWorkspace
    let stores: Stores
    let chat: WorkspaceChat
    let actions: AgentGitActionCoordinator
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-fixture-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        git = GitWorkspace(environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "LANG": "C", "GIT_DIR": "/invalid"])
        stores = try inMemoryStores()
        (chat, _) = try agentStoreChat(stores, cwd: root.path)
        let auditStore = stores
        actions = AgentGitActionCoordinator(git: git, persistence: stores, audit: { _ = try auditStore.record($0) })
    }
    func initialize() async throws {
        try await git.command(["init", "-b", "main"], in: root)
        try await git.command(["config", "user.name", "Example"], in: root)
        try await git.command(["config", "user.email", "person@example.org"], in: root)
        try write("base\n", "file.txt")
        try await git.command(["add", "--", "file.txt"], in: root)
        try await git.command(["commit", "-m", "Initial fixture"], in: root)
    }
    func write(_ text: String, _ path: String, directory: URL? = nil) throws {
        try Data(text.utf8).write(to: (directory ?? root).appendingPathComponent(path))
    }
    func owned(folders: [URL]? = nil) async throws -> AgentWorktree {
        try await actions.create(chatID: chat.id, projectID: chat.projectID, folders: folders ?? [root], storage: root.appendingPathComponent("owned"))
    }
    func remote() async throws -> URL {
        let remote = root.appendingPathComponent("remote.git")
        try await git.command(["init", "--bare", "-b", "main", remote.path], in: root)
        try await git.command(["remote", "add", "origin", remote.path], in: root)
        try await git.command(["push", "origin", "main"], in: root)
        return remote
    }
    func commit(_ text: String, at directory: URL? = nil) async throws {
        let directory = directory ?? root
        try write(text, "file.txt", directory: directory)
        try await git.command(["add", "--", "file.txt"], in: directory)
        try await git.command(["commit", "-m", "Update fixture"], in: directory)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.timeLimit(.minutes(2))) struct AgentWorktreeTests {
    @Test func durableCreationDuplicateAndMultiFolderMapping() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let external = f.root.appendingPathComponent("external")
        let nested = f.root.appendingPathComponent("nested")
        let owned = try await f.owned(folders: [f.root, nested, external])
        #expect(owned.state == .ready)
        #expect(owned.additionalRoots.map(\.path) == [owned.worktreePath + "/nested", owned.worktreePath + "/external"])
        #expect(owned.directory(for: nested).path == owned.worktreePath + "/nested")
        let duplicate = try await f.owned()
        #expect(duplicate == owned)
        #expect(try f.stores.agentWorktree(chatID: f.chat.id) == owned)
        #expect(try await f.actions.mapping(chatID: f.chat.id) == owned)
        try await f.git.command(["checkout", "--detach"], in: URL(fileURLWithPath: owned.worktreePath))
        await #expect(throws: AgentGitError.ownershipConflict) { try await f.actions.mapping(chatID: f.chat.id) }
    }
    @Test func failedCreationNeverFallsBackOrRemovesForeignDirectory() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let storage = f.root.appendingPathComponent("owned")
        let collision = storage.appendingPathComponent(f.chat.id.uuidString)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try f.write("keep", "foreign.txt", directory: collision)
        await #expect(throws: AgentGitError.ownershipConflict) { try await f.owned() }
        #expect(try f.stores.agentWorktree(chatID: f.chat.id)?.state == .failed)
        await #expect(throws: AgentGitError.creationFailed) { try await f.actions.mapping(chatID: f.chat.id) }
        #expect(try String(contentsOf: collision.appendingPathComponent("foreign.txt"), encoding: .utf8) == "keep")
    }
    @Test func isolationIntentSurvivesPreflightFailure() async throws {
        let f = try GitFixture(); defer { f.remove() }
        let chat = try f.stores.createWorkspaceChat(projectID: f.chat.projectID, title: "Isolated", requiresWorktree: true)
        await #expect(throws: AgentGitError.creationFailed) { try await f.actions.mapping(chatID: chat.id) }
        await #expect(throws: AgentGitError.commandFailed) {
            try await f.actions.create(chatID: chat.id, projectID: chat.projectID, folders: [f.root], storage: f.root.appendingPathComponent("owned"))
        }
        #expect(try f.stores.agentWorktree(chatID: chat.id)?.state == .failed)
        await #expect(throws: AgentGitError.creationFailed) { try await f.actions.mapping(chatID: chat.id) }
    }
    @Test func ownershipConstraintsAndRestart() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let owned = try await f.owned()
        #expect(throws: (any Error).self) { try f.stores.reserveAgentWorktree(owned) }
        #expect(throws: AgentStoreError.identityConflict) { try f.stores.finishAgentWorktree(chatID: f.chat.id, state: .failed) }
        let restarted = AgentGitActionCoordinator(git: f.git, persistence: f.stores, audit: { _ in })
        #expect(try await restarted.mapping(chatID: f.chat.id) == owned)
        var session = AgentChatSession(chatID: f.chat.id, provider: .codex, cwd: owned.worktreePath, model: "default")
        session.additionalRootsJSON = owned.additionalRootsJSON
        try f.stores.saveAgentSession(session)
        #expect(try f.stores.agentSession(chatID: f.chat.id, provider: .codex)?.configuration.directory.path == owned.worktreePath)
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentChangesTests {
    @Test func newFilesHaveReadableStatusAndEmptyPreview() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("", "empty.txt")
        try f.write("hello\n", "new file.txt")
        try f.write("changed\n", "file.txt")
        let changes = try await f.git.changes(in: f.root)
        let empty = try #require(changes.files.first { $0.path == "empty.txt" })
        #expect(empty.diff == "Empty file")
        #expect(empty.statusLabel == "New")
        #expect(empty.statusSymbol == "plus.circle")
        let new = try #require(changes.files.first { $0.path == "new file.txt" })
        #expect(new.diff.hasPrefix("--- /dev/null\n+++ b/new file.txt\n"))
        #expect(changes.files.first { $0.path == "file.txt" }?.statusLabel == "Modified")
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("file.txt"))
        #expect(try await f.git.changes(in: f.root).files.first { $0.path == "file.txt" }?.statusLabel == "Deleted")
    }

    @Test func stagedUntrackedDeletedRenamedAndUnusualNames() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("second", "delete.txt")
        try await f.git.command(["add", "--", "delete.txt"], in: f.root)
        try await f.git.command(["commit", "-m", "Add deletion fixture"], in: f.root)
        try await f.git.command(["mv", "--", "file.txt", "renamed\nname.txt"], in: f.root)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("delete.txt"))
        let odd = "- :(literal)*\t\".txt"
        try f.write("new\n", odd)
        let changes = try await f.git.changes(in: f.root)
        #expect(changes.files.count == 3)
        #expect(changes.files.first { $0.path == "renamed\nname.txt" }?.originalPath == "file.txt")
        #expect(changes.files.first { $0.path == odd }?.isUntracked == true)
        #expect(changes.files.first { $0.path == odd }?.diff.contains("+new") == true)
        #expect(changes.files.first { $0.path == "delete.txt" }?.diff.contains("-second") == true)
        #expect(try await f.git.changes(in: f.root).fingerprint == changes.fingerprint)
    }
    @Test func binaryLargeAndStaleContents() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try Data([0, 1, 255]).write(to: f.root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: 300_000).write(to: f.root.appendingPathComponent("large"))
        let first = try await f.git.changes(in: f.root)
        #expect(first.files.allSatisfy { $0.diffUnavailable })
        try Data([0, 2, 255]).write(to: f.root.appendingPathComponent("binary"))
        #expect(try await f.git.changes(in: f.root).fingerprint != first.fingerprint)
    }
    @Test func contentBoundariesAndExecutableModeInvalidateReview() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("a", "first"); try f.write("bc", "second")
        let first = try await f.git.changes(in: f.root)
        try f.write("ab", "first"); try f.write("c", "second")
        let second = try await f.git.changes(in: f.root)
        #expect(first.fingerprint != second.fingerprint)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.root.appendingPathComponent("first").path)
        #expect(try await f.git.changes(in: f.root).fingerprint != second.fingerprint)
    }
    @Test func malformedStatusAndCommandFailure() async throws {
        #expect(throws: AgentGitError.invalidOutput) { try GitWorkspace.parseStatus("R  new\0") }
        #expect(throws: AgentGitError.invalidOutput) { try GitWorkspace.parseStatus("?? ../escape\0") }
        let fake = try AgentExecutableFixture("exit 7"); defer { fake.remove() }
        let git = GitWorkspace(executable: fake.executable, environment: fake.environment)
        await #expect(throws: AgentGitError.commandFailed) { try await git.changes(in: fake.directory) }
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentGitActionTests {
    @Test func explicitCommitIncludesReviewedFilesAndNoAttribution() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("edit\n", "file.txt"); try f.write("new", "new.txt")
        let before = try await f.git.changes(in: f.root)
        await #expect(throws: AgentGitError.confirmationRequired) {
            try await f.actions.commit(chatID: f.chat.id, expected: before, message: "Edit fixture", confirmed: false)
        }
        try await f.actions.commit(chatID: f.chat.id, expected: before, message: "Edit fixture", confirmed: true)
        #expect(try await f.git.changes(in: f.root).files.isEmpty)
        #expect(try await f.git.command(["log", "-1", "--format=%B"], in: f.root) == "Edit fixture\n")
        let activity = try f.stores.recentActivity(limit: 10)
        #expect(activity.contains { $0.connectorID == "git" && $0.summary == "Git commit: completed" })
        #expect(!activity.contains { $0.detailJSON?.contains("new.txt") == true })
    }
    @Test func staleStateAndHookFailurePreserveChanges() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("one", "file.txt")
        let stale = try await f.git.changes(in: f.root)
        try f.write("two", "file.txt")
        await #expect(throws: AgentGitError.staleChanges) {
            try await f.actions.commit(chatID: f.chat.id, expected: stale, message: "Edit", confirmed: true)
        }
        let hook = f.root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let current = try await f.git.changes(in: f.root)
        await #expect(throws: AgentGitError.commandFailed) {
            try await f.actions.commit(chatID: f.chat.id, expected: current, message: "Edit", confirmed: true)
        }
        #expect(try String(contentsOf: f.root.appendingPathComponent("file.txt"), encoding: .utf8) == "two")
    }
    @Test func discardOnlyOwnedDirtyWorktreeAndRejectForeignCheckout() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("foreign edit", "file.txt")
        let shared = try await f.git.changes(in: f.root)
        await #expect(throws: AgentGitError.ownershipConflict) {
            try await f.actions.discard(chatID: f.chat.id, expected: shared, confirmed: true)
        }
        let owned = try await f.owned(); let directory = URL(fileURLWithPath: owned.worktreePath)
        try f.write("owned edit", "file.txt", directory: directory)
        try f.write("scratch", "new.txt", directory: directory)
        try await f.git.command(["add", "--", "new.txt"], in: directory)
        try f.write("loose", "loose.txt", directory: directory)
        let changes = try await f.git.changes(in: directory)
        try await f.actions.discard(chatID: f.chat.id, expected: changes, confirmed: true)
        #expect(try await f.git.changes(in: directory).files.isEmpty)
        #expect(try String(contentsOf: f.root.appendingPathComponent("file.txt"), encoding: .utf8) == "foreign edit")
        #expect(FileManager.default.fileExists(atPath: owned.worktreePath))
    }
    @Test func interruptionDuringCommitKeepsFilesAndAuditsFailure() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let fake = try AgentExecutableFixture(#"""
if [ "$2" = "commit" ]; then
    /usr/bin/touch .git/commit-started
    exec /bin/sleep 30
fi
exec /usr/bin/git "$@"
"""#); defer { fake.remove() }
        let git = GitWorkspace(executable: fake.executable, environment: fake.environment)
        let actions = AgentGitActionCoordinator(git: git, persistence: f.stores, audit: { _ = try f.stores.record($0) })
        try f.write("pending", "file.txt")
        let before = try await git.changes(in: f.root)
        let task = Task { try await actions.commit(chatID: f.chat.id, expected: before, message: "Interrupted", confirmed: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".git/commit-started").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".git/commit-started").path))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try String(contentsOf: f.root.appendingPathComponent("file.txt"), encoding: .utf8) == "pending")
        #expect(try await f.git.command(["log", "-1", "--format=%s"], in: f.root) == "Initial fixture")
        #expect(try f.stores.recentActivity(limit: 10).contains { $0.summary == "Git commit: interrupted" || $0.summary == "Git commit: failed" })
    }
    @Test func bogusChatAndForeignSnapshotAreRejected() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("edit", "file.txt")
        let expected = try await f.git.changes(in: f.root)
        await #expect(throws: AgentStoreError.missingChat) {
            try await f.actions.commit(chatID: UUID(), expected: expected, message: "Edit", confirmed: true)
        }
        let foreign = try GitFixture(); defer { foreign.remove() }; try await foreign.initialize()
        try foreign.write("foreign", "file.txt")
        let foreignChanges = try await foreign.git.changes(in: foreign.root)
        await #expect(throws: AgentGitError.ownershipConflict) {
            try await f.actions.commit(chatID: f.chat.id, expected: foreignChanges, message: "Edit", confirmed: true)
        }
    }
    @Test func auditFailureAndCancellationPreventMutation() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try f.write("edit", "file.txt")
        let before = try await f.git.changes(in: f.root)
        let failing = AgentGitActionCoordinator(git: f.git, persistence: f.stores, audit: { _ in throw AgentFailure.unknown })
        await #expect(throws: AgentFailure.unknown) {
            try await failing.commit(chatID: f.chat.id, expected: before, message: "Edit", confirmed: true)
        }
        let cancelled = Task {
            try await Task.sleep(for: .seconds(10))
            try await f.actions.commit(chatID: f.chat.id, expected: before, message: "Edit", confirmed: true)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await f.git.changes(in: f.root).fingerprint == before.fingerprint)
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentGitPushTests {
    @Test func branchStatusTracksUpstreamAheadBehindAndDetached() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let initial = try await f.git.branchStatus(at: f.root)
        #expect(initial.branch == "main" && !initial.detached && initial.upstream == nil && !initial.hasRemote)
        #expect(initial.ahead == 0 && initial.behind == 0)
        _ = try await f.remote()
        #expect(try await f.git.branchStatus(at: f.root).isDefaultBranch)
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        #expect(try await f.git.branchStatus(at: f.root).upstream == nil)
        try await f.git.push(at: f.root, branch: "feature")
        let published = try await f.git.branchStatus(at: f.root)
        #expect(published.upstream == "origin/feature" && !published.isDefaultBranch && published.remoteHost == nil)
        try await f.commit("ahead")
        #expect(try await f.git.branchStatus(at: f.root).ahead == 1)
        try await f.git.push(at: f.root, branch: "feature")
        try await f.git.command(["reset", "--hard", "HEAD^"], in: f.root)
        let behind = try await f.git.branchStatus(at: f.root)
        #expect(behind.behind == 1 && behind.ahead == 0)
        try await f.git.command(["checkout", "--detach"], in: f.root)
        let detached = try await f.git.branchStatus(at: f.root)
        #expect(detached.detached && detached.upstream == nil)
    }

    @Test func defaultBranchUsesOriginHeadThenMainOrMasterFallback() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); _ = try await f.remote()
        try await f.git.command(["checkout", "-b", "trunk"], in: f.root)
        try await f.git.command(["push", "origin", "trunk"], in: f.root)
        try await f.git.command(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: f.root)
        #expect(try await f.git.branchStatus(at: f.root).isDefaultBranch)
        try await f.git.command(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], in: f.root)
        #expect(try await f.git.branchStatus(at: f.root).isDefaultBranch == false)
        try await f.git.command(["update-ref", "-d", "refs/remotes/origin/main"], in: f.root)
        try await f.git.command(["update-ref", "refs/remotes/origin/master", "HEAD"], in: f.root)
        try await f.git.command(["checkout", "-b", "master"], in: f.root)
        #expect(try await f.git.branchStatus(at: f.root).isDefaultBranch)
    }

    @Test func ordinaryPushRequiresConfirmationAndAuditsMetadataOnly() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); _ = try await f.remote()
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        await #expect(throws: AgentGitError.confirmationRequired) { try await f.actions.push(chatID: f.chat.id, confirmed: false) }
        #expect(try await f.git.branchStatus(at: f.root).upstream == nil)
        await #expect(throws: AgentGitError.ownershipConflict) {
            try await f.actions.push(chatID: f.chat.id, confirmed: true, expectedDirectory: f.root, expectedBranch: "previous-branch")
        }
        try await f.actions.push(chatID: f.chat.id, confirmed: true)
        #expect(try await f.git.branchStatus(at: f.root).upstream == "origin/feature")
        let events = try f.stores.recentActivity(limit: 20).filter { $0.connectorID == "git" }
        #expect(events.contains { $0.summary == "Git push: completed" })
        for event in events {
            let detail = try #require(event.detailJSON)
            let object = try #require(JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: String])
            #expect(Set(object.keys) == ["chatID", "risk", "result"])
            #expect(object["chatID"] == f.chat.id.uuidString && object["risk"] == "confirmable")
            #expect(!detail.contains(f.root.path) && !detail.contains("feature") && !detail.contains("file.txt"))
        }
        let foreign = try GitFixture(); defer { foreign.remove() }; try await foreign.initialize()
        await #expect(throws: AgentGitError.ownershipConflict) {
            try await f.actions.push(chatID: f.chat.id, confirmed: true, expectedDirectory: foreign.root)
        }
    }

    @Test func refusesDefaultDetachedAndForeignOwnedBranches() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); _ = try await f.remote()
        await #expect(throws: AgentGitError.defaultBranch) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        try await f.git.command(["checkout", "--detach"], in: f.root)
        await #expect(throws: AgentGitError.detachedHEAD) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        try await f.git.command(["checkout", "main"], in: f.root)
        let owned = try await f.owned(), directory = URL(fileURLWithPath: owned.worktreePath)
        try await f.actions.push(chatID: f.chat.id, confirmed: true)
        #expect(try await f.git.branchStatus(at: directory).upstream == "origin/" + owned.branch)
        try await f.git.command(["checkout", "-b", "foreign"], in: directory)
        await #expect(throws: AgentGitError.ownershipConflict) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        try await f.git.command(["checkout", "--detach"], in: directory)
        await #expect(throws: AgentGitError.detachedHEAD) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
    }

    @Test func nonFastForwardNeverOverwritesRemote() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); let remote = try await f.remote()
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        try await f.git.push(at: f.root, branch: "feature")
        try await f.commit("remote commit")
        try await f.git.push(at: f.root, branch: "feature")
        let remoteTip = try await f.git.command(["rev-parse", "refs/heads/feature"], in: remote)
        try await f.git.command(["reset", "--hard", "HEAD^"], in: f.root)
        try await f.commit("divergent commit")
        await #expect(throws: AgentGitError.rejectedNonFastForward) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        #expect(try await f.git.command(["rev-parse", "refs/heads/feature"], in: remote) == remoteTip)
        let divergent = try await f.git.branchStatus(at: f.root)
        #expect(divergent.ahead == 1 && divergent.behind == 1)
    }

    @Test func noRemoteAuditFailureAndBranchMismatchPreventPush() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        await #expect(throws: AgentGitError.noRemote) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        _ = try await f.remote()
        let failing = AgentGitActionCoordinator(git: f.git, persistence: f.stores, audit: { _ in throw AgentFailure.unknown })
        await #expect(throws: AgentFailure.unknown) { try await failing.push(chatID: f.chat.id, confirmed: true) }
        #expect(try await f.git.branchStatus(at: f.root).upstream == nil)
        await #expect(throws: AgentGitError.ownershipConflict) { try await f.git.push(at: f.root, branch: "main") }
        await #expect(throws: AgentGitError.unsafeBranch) { try await f.git.push(at: f.root, branch: "+feature:main") }
        try await f.git.command(["checkout", "-b", "+feature"], in: f.root)
        await #expect(throws: AgentGitError.unsafeBranch) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        await #expect(throws: AgentGitError.unsafeBranch) { try await f.git.push(at: f.root, branch: "+feature") }
        try await f.git.command(["checkout", "-b", "refs/heads/feature"], in: f.root)
        await #expect(throws: AgentGitError.unsafeBranch) { try await f.git.push(at: f.root, branch: "refs/heads/feature") }
    }

    @Test func branchChangeDuringAuthorizationPreventsPush() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); let remote = try await f.remote()
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        let actions = AgentGitActionCoordinator(git: f.git, persistence: f.stores, audit: { event in
            if event.summary == "Git push: authorized" {
                try await f.git.command(["checkout", "-b", "changed-branch"], in: f.root)
            }
        })
        await #expect(throws: AgentGitError.ownershipConflict) { try await actions.push(chatID: f.chat.id, confirmed: true) }
        #expect(try await f.git.command(["for-each-ref", "--format=%(refname)", "refs/heads/feature", "refs/heads/changed-branch"], in: remote).isEmpty)
    }

    @Test func busyPushBlocksOtherWritesAndCancellationKeepsRemoteUnchanged() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize(); let remote = try await f.remote()
        let owned = try await f.owned(), directory = URL(fileURLWithPath: owned.worktreePath)
        try f.write("edit", "file.txt", directory: directory)
        let expected = try await f.git.changes(in: directory)
        let hook = f.root.appendingPathComponent(".git/hooks/pre-push")
        try Data("#!/bin/sh\ntouch push-started\nsleep 10\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let push = Task { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        let signal = directory.appendingPathComponent("push-started")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: signal.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: signal.path) else { push.cancel(); try? await push.value; Issue.record("Push did not reach the fixture hook"); return }
        await #expect(throws: AgentGitError.busy) { try await f.actions.push(chatID: f.chat.id, confirmed: true) }
        await #expect(throws: AgentGitError.busy) {
            try await f.actions.commit(chatID: f.chat.id, expected: expected, message: "Edit", confirmed: true)
        }
        push.cancel()
        await #expect(throws: CancellationError.self) { try await push.value }
        #expect(try await f.git.command(["for-each-ref", "--format=%(refname)", "refs/heads/" + owned.branch], in: remote).isEmpty)
        #expect(try f.stores.recentActivity(limit: 20).contains { $0.summary == "Git push: interrupted" })
    }

    @Test func hostParsingDropsCredentialsAndPaths() {
        #expect(GitWorkspace.remoteHost("https://user:fixture-password@git.example.org/team/repo.git") == "git.example.org")
        #expect(GitWorkspace.remoteHost("ssh://user@git.example.org:2222/team/repo.git") == "git.example.org")
        #expect(GitWorkspace.remoteHost("git@git.example.org:team/repo.git") == "git.example.org")
        #expect(GitWorkspace.remoteHost("/tmp/remote.git") == nil)
        #expect(GitWorkspace.remoteHost("file:///tmp/remote.git") == nil)
    }

    @Test func pushFromSingleBranchCloneLeavesAResolvableUpstream() async throws {
        let f = try GitFixture(); defer { f.remove() }; try await f.initialize()
        let remote = try await f.remote()
        // A single-branch clone's fetch refspec covers only main, so `push -u`
        // alone cannot create a remote-tracking ref for a new branch.
        let clone = f.root.appendingPathComponent("single")
        try await f.git.command(["clone", "-q", "--single-branch", "--branch", "main", remote.path, clone.path], in: f.root)
        try await f.git.command(["config", "user.name", "Example"], in: clone)
        try await f.git.command(["config", "user.email", "person@example.org"], in: clone)
        try await f.git.command(["checkout", "-q", "-b", "feature/single"], in: clone)
        try await f.commit("single\n", at: clone)
        try await f.git.push(at: clone, branch: "feature/single")
        let status = try await f.git.branchStatus(at: clone)
        #expect(status.upstream == "origin/feature/single")
        #expect(status.ahead == 0 && status.behind == 0)
    }

    @Test func pushEnvironmentKeepsCredentialsAndStripsOverrides() async throws {
        let fake = try AgentExecutableFixture(#"""
case "$2" in
  symbolic-ref) printf feature ;;
  check-ref-format) exit 0 ;;
  rev-parse) printf refs/heads/feature ;;
  remote) printf /tmp/remote.git ;;
  push)
    test "$#" = 5 && test "$3" = -u && test "$4" = origin && test "$5" = feature || exit 9
    test "$GIT_TERMINAL_PROMPT" = 0 && test "$GIT_OPTIONAL_LOCKS" = 0 && test "$GIT_LITERAL_PATHSPECS" = 1 || exit 9
    test "$GIT_ASKPASS" = fixture-askpass && test "$GH_TOKEN" = fixture-value && test "$SSH_AUTH_SOCK" = fixture-socket || exit 9
    test -n "$HOME" && test "$PATH" = /usr/bin:/bin || exit 9
    test -z "$GIT_DIR$GIT_WORK_TREE$GIT_INDEX_FILE$GIT_CONFIG_COUNT$GIT_CONFIG_KEY_0$GIT_CONFIG_VALUE_0$GIT_SSH_COMMAND$GIT_EXEC_PATH$GIT_TEST_SENTINEL" || exit 9
    printf called >> "$HOME/push-calls" ;;
  *) exit 9 ;;
esac
"""#); defer { fake.remove() }
        var environment = fake.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_SSH_COMMAND", "GIT_EXEC_PATH", "GIT_TEST_SENTINEL"] { environment[key] = "invalid" }
        environment.merge(["GIT_ASKPASS": "fixture-askpass", "GH_TOKEN": "fixture-value", "SSH_AUTH_SOCK": "fixture-socket", "GIT_TERMINAL_PROMPT": "1"]) { _, new in new }
        let git = GitWorkspace(executable: fake.executable, environment: environment)
        try await git.push(at: fake.directory, branch: "feature")
        #expect(try String(contentsOf: fake.directory.appendingPathComponent("push-calls"), encoding: .utf8) == "called")
    }

    @Test(arguments: [
        ("Authentication failed for https://user:fixture-password@git.example.org/repo", AgentGitError.authenticationRequired),
        ("Permission denied (publickey).", .authenticationRequired),
        ("Could not resolve host: git.example.org", .network),
        ("! [rejected] feature -> feature (non-fast-forward)", .rejectedNonFastForward),
        ("remote: hook declined https://user:fixture-password@git.example.org/repo", .commandFailed)
    ])
    func errorsAreTypedAndDoNotExposeOutput(diagnostic: String, expected: AgentGitError) async throws {
        let fake = try AgentExecutableFixture(#"""
case "$2" in
  symbolic-ref) printf feature ;;
  check-ref-format) exit 0 ;;
  rev-parse) printf refs/heads/feature ;;
  remote) printf /tmp/remote.git ;;
  push) printf called >> "$HOME/push-calls"; printf '%s' "$FIXTURE_DIAGNOSTIC" >&2; exit 1 ;;
  *) exit 9 ;;
esac
"""#); defer { fake.remove() }
        let git = GitWorkspace(executable: fake.executable, environment: fake.environment.merging(["FIXTURE_DIAGNOSTIC": diagnostic]) { _, new in new })
        await #expect(throws: expected) { try await git.push(at: fake.directory, branch: "feature") }
        #expect(try String(contentsOf: fake.directory.appendingPathComponent("push-calls"), encoding: .utf8) == "called")
        #expect(!expected.message.contains("https:") && !expected.message.contains("fixture-password"))
    }

    @Test func pushTimesOutWithoutRetry() async throws {
        let fake = try AgentExecutableFixture(#"""
case "$2" in
  symbolic-ref) printf feature ;;
  check-ref-format) exit 0 ;;
  rev-parse) printf refs/heads/feature ;;
  remote) printf /tmp/remote.git ;;
  push) printf called >> "$HOME/push-calls"; exec /bin/sleep 10 ;;
  *) exit 9 ;;
esac
"""#); defer { fake.remove() }
        let git = GitWorkspace(executable: fake.executable, environment: fake.environment, pushTimeout: .milliseconds(100))
        await #expect(throws: AgentGitError.timedOut) { try await git.push(at: fake.directory, branch: "feature") }
        #expect(try String(contentsOf: fake.directory.appendingPathComponent("push-calls"), encoding: .utf8) == "called")
    }
}

@Suite(.timeLimit(.minutes(2))) struct AgentGitProviderMappingTests {
    @Test(arguments: [AgentProvider.claude, .codex])
    func nativeLaunchAndResumeKeepCwdAndAdditionalRoot(provider: AgentProvider) async throws {
        let script = provider == .claude ? #"""
assert os.getcwd()==os.path.realpath(root)
assert sys.argv[sys.argv.index('--add-dir')+1]==root+'/extra'
assert sys.argv[sys.argv.index('--resume')+1]=='session-test'
claude_init()
read()
emit({'type':'result','subtype':'success','session_id':'session-test','is_error':False})
done()
"""# : #"""
codex_init()
r=read(); account(r)
r=read()
assert r['method']=='thread/resume'
assert r['params']['cwd']==root
assert r['params']['threadId']=='session-test'
emit({'id':r['id'],'result':{'thread':{'id':'session-test','modelProvider':'openai'}}})
r=read()
assert r['method']=='turn/start'
assert r['params']['sandboxPolicy']=={'type':'workspaceWrite','writableRoots':[root+'/extra']}
emit({'id':r['id'],'result':{'turn':{'id':'turn-test'}}})
emit({'method':'turn/completed','params':{'threadId':'session-test','turn':{'id':'turn-test','status':'completed','items':[]}}})
done()
"""#
        let fixture = try BackendExecutableFixture(script: script); defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory,
            resume: .init(provider: provider, profile: "default", nativeID: "session-test"), model: "default",
            additionalDirectories: [fixture.directory.appendingPathComponent("extra")]))
        try await run.send(.init(text: "Continue"), willDeliver: {})
        for try await event in run.events { if case .turnEnded(.completed) = event.kind { break } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("done").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await run.shutdown()
        try fixture.assertComplete()
    }
    @Test func olderSerializedSessionDefaultsToNoAdditionalRoots() throws {
        let session = AgentChatSession(chatID: UUID(), provider: .claude, cwd: "/tmp", model: "default")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "additionalRootsJSON")
        let restored = try JSONDecoder().decode(AgentChatSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored == session)
    }
}
