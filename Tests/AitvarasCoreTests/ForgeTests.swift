import Foundation
import Testing
import AitvarasCore
@testable import AitvarasAgents
@testable import AitvarasStore

private let githubPR = #"{"number":7,"url":"https://github.com/example/repo/pull/7","title":"Example request","state":"OPEN","isDraft":true,"mergeable":"CONFLICTING","reviewDecision":"CHANGES_REQUESTED","future":true}"#
private let gitlabPR = #"{"iid":9,"web_url":"https://gitlab.com/example/repo/-/merge_requests/9","title":"Example request","state":"opened","draft":true,"detailed_merge_status":"mergeable","unknown":42}"#
private struct ForgeFixture {
    let fake: AgentExecutableFixture
    let git: GitWorkspace
    var root: URL { fake.directory.resolvingSymlinksInPath() }
    init(_ script: String) throws {
        fake = try AgentExecutableFixture(script)
        git = GitWorkspace(environment: ["HOME": fake.directory.path, "PATH": "/usr/bin:/bin"])
    }
    func initialize(host: String = "github.com") async throws {
        try await git.command(["init", "-b", "main"], in: root)
        try await git.command(["config", "user.name", "Example"], in: root)
        try await git.command(["config", "user.email", "person@example.org"], in: root)
        try await git.command(["commit", "--allow-empty", "-m", "Initial fixture"], in: root)
        try await git.command(["remote", "add", "origin", "https://\(host)/example/repo.git"], in: root)
    }
    var environment: [String: String] { ["HOME": root.path, "PATH": "/usr/bin:/bin", "GIT_DIR": "/invalid", "GH_REPO": "wrong/repo", "GLAB_REPO": "wrong/repo"] }
    func remove() { fake.remove() }
}

@Suite(.timeLimit(.minutes(2))) struct ForgeTests {
    @Test func githubParsingCreateChecksAndComments() async throws {
        let f = try ForgeFixture("""
        test -z "$GIT_DIR" || exit 99
        case "$1 $2" in
        'auth status') echo '{"hosts":{"github.com":[{"state":"success","active":true}],"forge.example.org":[{"state":"success"}]}}';;
        'pr view') test "$GH_REPO" = 'github.com/example/repo' || exit 99; echo '\(githubPR)';;
        'pr create') test "$GH_REPO" = 'github.com/example/repo' || exit 99; printf '%s\\n' "$@" > create-args; echo 'https://github.com/example/repo/pull/7';;
        'pr checks') echo '[{"name":"Build","state":"SUCCESS","link":"https://example.org/check"},{"name":"Test","state":"FAILURE"},{"name":"Queue","state":"IN_PROGRESS"},{"name":"Skip","state":"SKIPPED"},{"name":"Future","state":"FUTURE"}]'; exit 1;;
        'api repos/{owner}/{repo}/issues/7/comments') echo '[[{"id":3,"user":{"login":"example"},"body":"A comment","created_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/example/repo/issues/7#issuecomment-3"}]]';;
        'api repos/{owner}/{repo}/pulls/7/comments') echo '[]';;
        *) exit 99;;
        esac
        """)
        defer { f.remove() }; try await f.initialize()
        let forge = GitHubForge(executable: f.fake.executable, environment: f.environment)
        let auth = try await forge.authStatus(host: "github.com")
        #expect(auth.installed && auth.isSignedIn(host: "github.com"))
        #expect(auth.signedInHosts.contains("forge.example.org"))
        let view = try #require(try await forge.currentPullRequest(directory: f.root, branch: "feature"))
        #expect(view.repo == "example/repo" && view.number == 7 && view.state == .draft && view.mergeable == .conflicting)
        #expect(view.reviewDecision == "CHANGES_REQUESTED")
        let created = try await forge.createPullRequest(directory: f.root, branch: "feature", base: "main", title: "Literal $(false)", body: "- One\n- Two", draft: true)
        #expect(created == view)
        let args = try String(contentsOf: f.root.appendingPathComponent("create-args"), encoding: .utf8)
        #expect(args.contains("--draft") && args.contains("Literal $(false)") && args.contains("- One\n- Two"))
        let checks = try await forge.checks(directory: f.root, number: 7)
        #expect(checks.map(\.status) == [.passing, .failing, .pending, .skipped, .pending])
        let comments = try await forge.comments(directory: f.root, number: 7)
        #expect(comments.count == 1 && comments[0].id == "3" && comments[0].author == "example" && comments[0].body == "A comment")
    }
    @Test func gitlabParsingCreateChecksAndComments() async throws {
        let f = try ForgeFixture("""
        case "$1 $2" in
        'auth status') printf 'gitlab.com\\n  ✓ Logged in to gitlab.com as example\\nforge.example.org\\n  ✓ Logged in to forge.example.org as example\\n';;
        'mr view') test "$GLAB_REPO" = 'gitlab.com/example/repo' || exit 99; echo '\(gitlabPR)';;
        'api projects/example%2Frepo/merge_requests/9/approvals') echo '{"approved":true,"approvals_required":1,"approvals_left":0}';;
        'mr create') printf '%s\\n' "$@" > create-args; echo 'https://gitlab.com/example/repo/-/merge_requests/9';;
        'api projects/example%2Frepo/merge_requests/9/pipelines') echo '[{"id":4},{"id":3}]';;
        'api projects/example%2Frepo/pipelines/4/jobs') echo '[{"name":"Build","status":"success","web_url":"https://gitlab.com/example/repo/-/jobs/4"},{"name":"Test","status":"failed"},{"name":"Queue","status":"created"},{"name":"Manual","status":"manual"}]';;
        'api projects/example%2Frepo/merge_requests/9/notes') echo '[{"id":5,"author":{"username":"example"},"body":"Review note","created_at":"2026-01-01T00:00:00.123Z"}]'; echo '[]';;
        *) exit 99;;
        esac
        """)
        defer { f.remove() }; try await f.initialize(host: "gitlab.com")
        let forge = GitLabForge(executable: f.fake.executable, environment: f.environment)
        #expect(try await forge.authStatus(host: "gitlab.com").signedInHosts == ["forge.example.org", "gitlab.com"])
        let view = try #require(try await forge.currentPullRequest(directory: f.root, branch: "feature"))
        #expect(view.reviewDecision == "APPROVED")
        #expect(view.number == 9 && view.state == .draft && view.mergeable == .yes && view.repo == "example/repo")
        #expect(try await forge.createPullRequest(directory: f.root, branch: "feature", base: "main", title: "Example", body: "Description", draft: true) == view)
        #expect(try await forge.checks(directory: f.root, number: 9).map(\.status) == [.passing, .failing, .pending, .skipped])
        #expect(try await forge.comments(directory: f.root, number: 9).first?.body == "Review note")
        let args = try String(contentsOf: f.root.appendingPathComponent("create-args"), encoding: .utf8)
        #expect(args.contains("--draft") && args.contains("--yes"))
    }
    @Test func selectionAuthStatesAndUnsupportedHost() async throws {
        let gh = try AgentExecutableFixture("echo '{\"hosts\":{\"forge.example.org\":[{\"state\":\"failed\",\"active\":true}],\"github.com\":[{\"state\":\"success\"}]}}'; exit 1")
        let gl = try AgentExecutableFixture("printf 'gitlab.com\\n  ✓ Logged in to gitlab.com as example\\n'")
        defer { gh.remove(); gl.remove() }
        let registry = ForgeRegistry(github: GitHubForge(executable: gh.executable), gitlab: GitLabForge(executable: gl.executable))
        #expect(try await registry.forge(host: "github.com").kind == .github)
        #expect(try await registry.forge(host: "gitlab.com").kind == .gitlab)
        #expect(try await registry.forge(host: "forge.example.org").kind == .github)
        let auth = try await registry.github.authStatus(host: "forge.example.org")
        #expect(!auth.isSignedIn(host: "forge.example.org") && auth.knownHosts.contains("forge.example.org"))
        await #expect(throws: ForgeError.unsupportedHost) { try await registry.forge(host: "other.example.org") }
        await #expect(throws: ForgeError.unsupportedHost) { try await registry.forge(host: nil) }
        let absent = GitHubForge(executable: gh.directory.appendingPathComponent("missing"))
        // An explicit nonexistent executable has the same not-installed state.
        #expect(try await absent.authStatus(host: "github.com").installed == false)
    }
    @Test(arguments: [("echo 'no pull requests found' >&2; exit 1", ForgeError.notFound), ("echo 'authentication required' >&2; exit 4", .signedOut), ("echo 'could not resolve host' >&2; exit 1", .network), ("echo 'private diagnostic' >&2; exit 9", .failed), ("echo 'garbage'", .failed)])
    func fixedErrors(script: String, expected: ForgeError) async throws {
        let f = try ForgeFixture(script); defer { f.remove() }; try await f.initialize()
        let forge: any Forge = GitHubForge(executable: f.fake.executable, environment: f.environment)
        let gitlab: any Forge = GitLabForge(executable: f.fake.executable, environment: f.environment)
        for forge in [forge, gitlab] {
        if expected == .notFound { #expect(try await forge.currentPullRequest(directory: f.root, branch: "feature") == nil) }
        else { await #expect(throws: expected) { try await forge.currentPullRequest(directory: f.root, branch: "feature") } }
        }
    }
    @Test func malformedOutputAndTimeoutFailClosed() async throws {
        let f = try ForgeFixture("echo '{\"number\":7,\"url\":\"http://example.org/request\"}'")
        defer { f.remove() }; try await f.initialize()
        let forge = GitLabForge(executable: f.fake.executable, environment: f.environment)
        await #expect(throws: ForgeError.failed) { try await forge.currentPullRequest(directory: f.root, branch: "feature") }
        await #expect(throws: ForgeError.failed) { try await forge.checks(directory: f.root, number: -1) }
        let slow = try AgentExecutableFixture("sleep 5"); defer { slow.remove() }
        let timed = GitHubForge(executable: slow.executable, environment: f.environment, timeout: .milliseconds(30))
        await #expect(throws: ForgeError.network) { try await timed.currentPullRequest(directory: f.root, branch: "feature") }
    }
    @Test func migrationLatestBindingAndWatermarksRoundTrip() async throws {
        let stores = try inMemoryStores(); let (chat, _) = try agentStoreChat(stores)
        let request = ForgePullRequest(forge: .github, host: "github.com", repo: "example/repo", number: 7, url: URL(string: "https://github.com/example/repo/pull/7")!, title: "Transient", state: .open, mergeable: .unknown, reviewDecision: nil)
        var record = AgentPullRequest(chatID: chat.id, request: request)
        try stores.bindAgentPullRequest(record)
        let initial = try #require(try stores.agentPullRequest(chatID: chat.id))
        #expect(initial.chatID == record.chatID && initial.forge == record.forge && initial.url == record.url && initial.repo == record.repo && initial.number == record.number)
        #expect(abs(initial.createdAt.timeIntervalSince(record.createdAt)) < 0.001)
        record = initial
        #expect(!record.watch && record.commentWatermark == nil && record.checkWatermark == nil)
        record.watch = true; record.commentWatermark = "3"; record.checkWatermark = "check-4"
        try stores.bindAgentPullRequest(record)
        #expect(try stores.agentPullRequest(chatID: chat.id) == record)
        let next = ForgePullRequest(forge: .gitlab, host: "gitlab.com", repo: "example/repo", number: 9, url: URL(string: "https://gitlab.com/example/repo/-/merge_requests/9")!, title: "Transient", state: .open, mergeable: .yes, reviewDecision: nil)
        try stores.bindAgentPullRequest(AgentPullRequest(chatID: chat.id, request: next))
        #expect(try stores.agentPullRequest(chatID: chat.id)?.number == 9)
        #expect(try stores.agentPullRequest(chatID: chat.id)?.watch == false)
    }
    @Test func confirmationDuplicateBindingStaleBranchAndPrivateAudit() async throws {
        let f = try ForgeFixture("""
        case "$1 $2" in
        'auth status') echo '{"hosts":{"github.com":[{"state":"success"}]}}';;
        'pr view') if test -f created; then echo '\(githubPR)'; else echo 'no pull requests found' >&2; exit 1; fi;;
        'pr create') if test -f fail-create; then echo 'private diagnostic' >&2; exit 9; fi; touch created; echo created >> create-count;;
        'pr checks') echo '[{"name":"Build","state":"SUCCESS"}]';;
        *) exit 99;;
        esac
        """)
        defer { f.remove() }; try await f.initialize()
        try await f.git.command(["update-ref", "refs/remotes/origin/main", "HEAD"], in: f.root)
        try await f.git.command(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: f.root)
        try await f.git.command(["checkout", "-b", "feature"], in: f.root)
        try await f.git.command(["commit", "--allow-empty", "-m", "First subject"], in: f.root)
        try await f.git.command(["commit", "--allow-empty", "-m", "Second subject"], in: f.root)
        try await f.git.command(["update-ref", "refs/remotes/origin/feature", "HEAD"], in: f.root)
        try await f.git.command(["branch", "--set-upstream-to=origin/feature", "feature"], in: f.root)
        let stores = try inMemoryStores(); let (chat, _) = try agentStoreChat(stores, cwd: f.root.path)
        let registry = ForgeRegistry(github: GitHubForge(executable: f.fake.executable, environment: f.environment), gitlab: GitLabForge(executable: f.fake.executable, environment: f.environment))
        let actions = AgentForgeActionCoordinator(git: f.git, persistence: stores, registry: registry, audit: { _ = try stores.record($0) })
        var draft = try await actions.draft(chatID: chat.id, directory: f.root)
        #expect(draft.base == "main" && draft.title == "First subject" && draft.body == "- First subject\n- Second subject")
        draft.title = "Private request title"; draft.body = "Private request description"
        await #expect(throws: AgentGitError.confirmationRequired) { try await actions.createPullRequest(chatID: chat.id, draft: draft, isDraft: true, confirmed: false) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("created").path))
        try Data().write(to: f.root.appendingPathComponent("fail-create"))
        await #expect(throws: ForgeError.failed) { try await actions.createPullRequest(chatID: chat.id, draft: draft, isDraft: true, confirmed: true) }
        #expect(try stores.agentPullRequest(chatID: chat.id) == nil)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("fail-create"))
        let request = try await actions.createPullRequest(chatID: chat.id, draft: draft, isDraft: true, confirmed: true)
        #expect(request.number == 7)
        #expect(try stores.agentPullRequest(chatID: chat.id)?.number == 7)
        _ = try await actions.createPullRequest(chatID: chat.id, draft: draft, isDraft: false, confirmed: true)
        #expect(try String(contentsOf: f.root.appendingPathComponent("create-count"), encoding: .utf8) == "created\n")
        #expect(try await actions.refresh(chatID: chat.id, directory: f.root).checks.count == 1)
        try await f.git.command(["commit", "--allow-empty", "-m", "Changed tip"], in: f.root)
        try await f.git.command(["update-ref", "refs/remotes/origin/feature", "HEAD"], in: f.root)
        await #expect(throws: AgentGitError.staleChanges) { try await actions.createPullRequest(chatID: chat.id, draft: draft, isDraft: false, confirmed: true) }
        let events = try stores.recentActivity(limit: 100)
        let audit = events.map { $0.summary + ($0.detailJSON ?? "") }.joined()
        #expect(!audit.contains(draft.title) && !audit.contains(draft.body) && !audit.contains(request.url.absoluteString) && !audit.contains("private diagnostic"))
        #expect(audit.contains("confirmable") && audit.contains("read") && audit.contains(chat.id.uuidString))
    }

    @Test func numericBranchesDoNotSelectRequestNumbers() async throws {
        let f = try ForgeFixture("""
        case "$1 $2" in
        'pr list'|'mr list') echo '[]';;
        'pr view'|'mr view') touch wrong-request; exit 9;;
        *) exit 99;;
        esac
        """)
        defer { f.remove() }; try await f.initialize()
        let github = GitHubForge(executable: f.fake.executable, environment: f.environment)
        let gitlab = GitLabForge(executable: f.fake.executable, environment: f.environment)
        #expect(try await github.currentPullRequest(directory: f.root, branch: "7") == nil)
        #expect(try await gitlab.currentPullRequest(directory: f.root, branch: "7") == nil)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("wrong-request").path))
    }
    @Test func originIdentitySupportsSSHAndNestedNamespaces() throws {
        let ssh = try ForgeCLI.repository("git@forge.example.org:group/subgroup/repo.git")
        #expect(ssh.host == "forge.example.org" && ssh.repo == "group/subgroup/repo")
        let https = try ForgeCLI.repository("https://forge.example.org/group/subgroup/repo.git")
        #expect(https.host == ssh.host && https.repo == ssh.repo)
        #expect(throws: ForgeError.unsupportedHost) { try ForgeCLI.repository("file:///tmp/repo.git") }
        #expect(throws: ForgeError.failed) { try ForgeCLI.repository("https://forge.example.org/group/../repo") }
    }
    @Test func signInValidatesURLsAndKeepsDeviceCodeTransient() async throws {
        let fake = try AgentExecutableFixture("""
        printf 'First copy your one-time code: ABCD-1234\\n' >&2
        printf 'http://example.org/unsafe\\nhttps://user:secret@example.org/unsafe\\nhttps://example.org/login\\n'
        sleep 1
        """)
        defer { fake.remove() }
        let forge = GitHubForge(executable: fake.executable, environment: fake.environment)
        let values = ForgeSignInValues()
        try await forge.signIn(host: "github.com", onDeviceCode: { await values.code($0) }, onBrowserURL: { await values.url($0) })
        #expect(await values.urls == [URL(string: "https://example.org/login")!])
        #expect(await values.codes == ["ABCD-1234"])
    }

}

private actor ForgeSignInValues {
    var urls: [URL] = []
    var codes: [String] = []
    func url(_ value: URL) { urls.append(value) }
    func code(_ value: String) { codes.append(value) }
}
