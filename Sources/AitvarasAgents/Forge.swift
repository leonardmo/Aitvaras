import Foundation

public enum ForgeKind: String, Codable, Sendable, CaseIterable {
    case github, gitlab
    public var executableName: String { self == .github ? "gh" : "glab" }
    public var title: String { self == .github ? "GitHub" : "GitLab" }
    public var requestName: String { self == .github ? "pull request" : "merge request" }
    public var publicHost: String { self == .github ? "github.com" : "gitlab.com" }
    func sameRepository(_ lhs: String, _ rhs: String) -> Bool {
        self == .github ? lhs.lowercased() == rhs.lowercased() : lhs == rhs
    }
}
public enum ForgeError: String, Error, Sendable {
    case notInstalled, signedOut, notFound, unsupportedHost, network, failed
    public var message: String {
        switch self {
        case .notInstalled: "Install the forge CLI to see pull requests."
        case .signedOut: "Sign in to the forge CLI to continue."
        case .notFound: "No request exists for this branch."
        case .unsupportedHost: "Pull requests are not supported for this host."
        case .network: "Could not reach the Git host. Try again."
        case .failed: "Forge operation failed. Refresh before trying again."
        }
    }
}
public struct ForgeAuthStatus: Sendable, Equatable {
    public let installed: Bool
    public let signedInHosts: [String]
    public let knownHosts: [String]
    public init(installed: Bool, signedInHosts: [String], knownHosts: [String] = []) {
        self.installed = installed; self.signedInHosts = signedInHosts; self.knownHosts = Array(Set(knownHosts + signedInHosts)).sorted()
    }
    public func isSignedIn(host: String) -> Bool { signedInHosts.contains(host.lowercased()) }
}
public struct ForgePullRequest: Sendable, Equatable {
    public enum State: String, Codable, Sendable { case open, draft, merged, closed }
    public enum Mergeable: String, Codable, Sendable { case yes, no, unknown, conflicting }
    public let forge: ForgeKind
    public let host: String
    public let repo: String
    public let number: Int
    public let url: URL
    public let title: String
    public let state: State
    public let mergeable: Mergeable
    public let reviewDecision: String?
    public var base: String? = nil
    public var head: String? = nil
    public var sourceIsFork = false
}
public struct ForgeCheck: Sendable, Equatable {
    public enum Status: String, Sendable { case pending, passing, failing, skipped }
    public let name: String
    public let status: Status
    public let url: URL?
    public let identity: String?
    fileprivate let logTarget: LogTarget?

    fileprivate enum LogTarget: Sendable, Equatable {
        case actions(run: Int, job: Int?), gitlab(job: Int)
    }

    init(name: String, status: Status, url: URL?) {
        self.init(name: name, status: status, url: url, logTarget: nil)
    }

    fileprivate init(name: String, status: Status, url: URL?, logTarget: LogTarget?) {
        self.name = name; self.status = status; self.url = url; self.logTarget = logTarget
        switch logTarget {
        case .actions(let run, let job): identity = "actions/\(run)/\(job.map(String.init) ?? name)"
        case .gitlab(let job): identity = "job/\(job)"
        case nil: identity = nil
        }
    }
}
public struct ForgeComment: Sendable, Equatable {
    public let id: String
    public let author: String
    public let body: String
    public let url: URL?
    public let createdAt: Date
}
public protocol Forge: Sendable {
    var kind: ForgeKind { get }
    func authStatus(host: String) async throws -> ForgeAuthStatus
    func currentPullRequest(directory: URL, branch: String) async throws -> ForgePullRequest?
    func pullRequest(directory: URL, number: Int) async throws -> ForgePullRequest?
    func createPullRequest(directory: URL, branch: String, base: String, title: String, body: String, draft: Bool) async throws -> ForgePullRequest
    func checks(directory: URL, number: Int) async throws -> [ForgeCheck]
    func comments(directory: URL, number: Int) async throws -> [ForgeComment]
    func failedLog(directory: URL, number: Int, check: ForgeCheck) async -> String?
}

/// Host selection never guesses from a company's hostname. Enterprise hosts
/// must be advertised by exactly one installed CLI's auth status.
public struct ForgeRegistry: Sendable {
    public let github: GitHubForge
    public let gitlab: GitLabForge
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        github = GitHubForge(environment: environment); gitlab = GitLabForge(environment: environment)
    }
    public init(github: GitHubForge, gitlab: GitLabForge) { self.github = github; self.gitlab = gitlab }
    func forge(kind: ForgeKind) -> any Forge {
        switch kind {
        case .github: github
        case .gitlab: gitlab
        }
    }
    public func forge(host: String?) async throws -> any Forge {
        guard let rawHost = host, ForgeCLI.validHost(rawHost) else { throw ForgeError.unsupportedHost }
        let host = rawHost.lowercased()
        if host == "github.com" { return github }
        if host == "gitlab.com" { return gitlab }
        let gh = (try? await github.authStatus(host: host)) ?? .init(installed: false, signedInHosts: [])
        let gl = (try? await gitlab.authStatus(host: host)) ?? .init(installed: false, signedInHosts: [])
        if gh.knownHosts.contains(host), !gl.knownHosts.contains(host) { return github }
        if gl.knownHosts.contains(host), !gh.knownHosts.contains(host) { return gitlab }
        throw ForgeError.unsupportedHost
    }
}

public struct GitHubForge: Forge {
    public let kind = ForgeKind.github
    private let cli: ForgeCLI
    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(60)) {
        cli = ForgeCLI(kind: .github, executable: executable, environment: environment, timeout: timeout)
    }
    public func authStatus(host: String) async throws -> ForgeAuthStatus { try await cli.authStatus(host: host) }
    public func currentPullRequest(directory: URL, branch: String) async throws -> ForgePullRequest? { try await cli.view(directory, branch) }
    public func pullRequest(directory: URL, number: Int) async throws -> ForgePullRequest? {
        guard number > 0 else { throw ForgeError.failed }
        return try await cli.view(directory, String(number), byNumber: true)
    }
    public func createPullRequest(directory: URL, branch: String, base: String, title: String, body: String, draft: Bool) async throws -> ForgePullRequest { try await cli.create(directory, branch, base, title, body, draft) }
    public func checks(directory: URL, number: Int) async throws -> [ForgeCheck] { try await cli.checks(directory, number) }
    public func comments(directory: URL, number: Int) async throws -> [ForgeComment] { try await cli.comments(directory, number) }
    public func failedLog(directory: URL, number: Int, check: ForgeCheck) async -> String? { await cli.failedLog(directory, number, check) }
    public func signIn(host: String, onDeviceCode: @escaping @Sendable (String) async -> Void = { _ in }, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws { try await cli.signIn(host, onDeviceCode, onBrowserURL) }
}
public struct GitLabForge: Forge {
    public let kind = ForgeKind.gitlab
    private let cli: ForgeCLI
    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(60)) {
        cli = ForgeCLI(kind: .gitlab, executable: executable, environment: environment, timeout: timeout)
    }
    public func authStatus(host: String) async throws -> ForgeAuthStatus { try await cli.authStatus(host: host) }
    public func currentPullRequest(directory: URL, branch: String) async throws -> ForgePullRequest? { try await cli.view(directory, branch) }
    public func pullRequest(directory: URL, number: Int) async throws -> ForgePullRequest? {
        guard number > 0 else { throw ForgeError.failed }
        return try await cli.view(directory, String(number), byNumber: true)
    }
    public func createPullRequest(directory: URL, branch: String, base: String, title: String, body: String, draft: Bool) async throws -> ForgePullRequest { try await cli.create(directory, branch, base, title, body, draft) }
    public func checks(directory: URL, number: Int) async throws -> [ForgeCheck] { try await cli.checks(directory, number) }
    public func comments(directory: URL, number: Int) async throws -> [ForgeComment] { try await cli.comments(directory, number) }
    public func failedLog(directory: URL, number: Int, check: ForgeCheck) async -> String? { await cli.failedLog(directory, number, check) }
    public func signIn(host: String, onDeviceCode: @escaping @Sendable (String) async -> Void = { _ in }, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws { try await cli.signIn(host, onDeviceCode, onBrowserURL) }
}

actor ForgeCLI {
    @TaskLocal static var watchBinding: AgentPullRequest?
    let kind: ForgeKind
    let executable: URL?
    let environment: [String: String]
    let timeout: Duration
    init(kind: ForgeKind, executable: URL?, environment: [String: String], timeout: Duration) {
        self.kind = kind; self.timeout = timeout
        let paths = (environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let candidate = executable ?? paths.split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(kind.executableName) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        self.executable = candidate.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        self.environment = environment.filter { !$0.key.hasPrefix("GIT_") }.merging([
            "PATH": paths, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "LC_ALL": "C"
        ]) { _, new in new }
    }
    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && !host.hasPrefix("-") && host.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }
    func run(_ args: [String], _ directory: URL? = nil, allowed: Set<Int32> = [0],
             stdoutTailBytes: Int = 0) async throws -> OneShotProcess.Output {
        guard let executable else { throw ForgeError.notInstalled }
        do {
            var env = environment
            var arguments = args
            if let directory {
                let origin = try await GitWorkspace(environment: environment).command(["remote", "get-url", "origin"], in: directory)
                let identity = try Self.repository(origin)
                if let binding = Self.watchBinding {
                    guard binding.host == identity.host, kind.sameRepository(binding.repo, identity.repo) else { throw ForgeError.failed }
                }
                // Explicit origin beats CLI heuristics (e.g. an unrelated upstream
                // remote) and inherited GH_REPO/GLAB_REPO/host overrides.
                env["GH_REPO"] = identity.host + "/" + identity.repo
                env["GLAB_REPO"] = identity.host + "/" + identity.repo
                env["GH_HOST"] = identity.host; env["GITLAB_HOST"] = identity.host
                if kind == .gitlab {
                    if arguments.first == "api" {
                        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                        guard let project = identity.repo.addingPercentEncoding(withAllowedCharacters: allowed) else { throw ForgeError.failed }
                        arguments = arguments.map { $0.replacingOccurrences(of: "projects/:id/", with: "projects/" + project + "/") }
                        arguments += ["--hostname", identity.host]
                    } else {
                        arguments += ["--repo", identity.host + "/" + identity.repo]
                    }
                }
            }
            let output = try await OneShotProcess.run(executable: executable, arguments: arguments, currentDirectory: directory,
                environment: env, timeout: timeout, stdoutTailBytes: stdoutTailBytes)
            guard !output.timedOut else { throw ForgeError.network }
            guard allowed.contains(output.exitCode) else { throw Self.failure(output) }
            return output
        } catch is CancellationError { throw CancellationError() }
        catch let error as ForgeError { throw error }
        catch { throw ForgeError.failed }
    }
    static func repository(_ remote: String) throws -> (host: String, repo: String) {
        guard let host = GitWorkspace.remoteHost(remote), validHost(host) else { throw ForgeError.unsupportedHost }
        let path: String
        if remote.contains("://") { path = URLComponents(string: remote)?.path ?? "" }
        else if let colon = remote.firstIndex(of: ":") { path = String(remote[remote.index(after: colon)...]) }
        else { throw ForgeError.unsupportedHost }
        var repo = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !repo.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" || $0 == "%" || $0 == "\\" }) else { throw ForgeError.failed }
        return (host.lowercased(), repo)
    }
    static func failure(_ output: OneShotProcess.Output) -> ForgeError {
        let text = (output.stdout + "\n" + output.stderr).lowercased()
        if output.exitCode == 4 || ["not logged", "auth login", "authentication", "http 401"].contains(where: text.contains) { return .signedOut }
        if ["no pull requests found", "no merge request", "not found", "http 404"].contains(where: text.contains) { return .notFound }
        if ["could not resolve", "connection", "network", "timeout", "tls handshake"].contains(where: text.contains) { return .network }
        return .failed
    }
    func authStatus(host: String) async throws -> ForgeAuthStatus {
        guard Self.validHost(host) else { throw ForgeError.unsupportedHost }
        guard executable != nil else { return .init(installed: false, signedInHosts: []) }
        let output = try await run(kind == .github ? ["auth", "status", "--json", "hosts"] : ["auth", "status"], allowed: [0, 1, 4])
        var hosts: [String] = []
        var known: [String] = []
        if kind == .github {
            let root = try Self.object(output.stdout)
            if let listing = root["hosts"] as? [String: [[String: Any]]] {
                known = listing.keys.map { $0.lowercased() }
                hosts = listing.compactMap { host, accounts in
                    accounts.contains { ($0["state"] as? String) == "success" && ($0["active"] as? Bool ?? true) } ? host.lowercased() : nil
                }
            } else { throw ForgeError.failed }
        } else {
            // Only retain the hostname of successful entries; discard identity,
            // token masks and all remaining diagnostics immediately.
            for line in (output.stdout + "\n" + output.stderr).components(separatedBy: .newlines) {
                let header = line.trimmingCharacters(in: .whitespaces)
                if line == header, Self.validHost(header), header.contains(".") { known.append(header.lowercased()) }
                if let range = line.range(of: "Logged in to ") {
                    let candidate = String(line[range.upperBound...].prefix { !$0.isWhitespace })
                    if Self.validHost(candidate) { hosts.append(candidate.lowercased()) }
                }
            }
        }
        return .init(installed: true, signedInHosts: Array(Set(hosts)).sorted(), knownHosts: known)
    }
    static func object(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ForgeError.failed }
        return object
    }
    static func array(_ text: String) throws -> [[String: Any]] {
        // gh slurps pages into an outer array; glab may emit adjacent arrays.
        // Find complete top-level arrays without splitting inside JSON strings.
        var depth = 0, quoted = false, escaped = false, start: String.Index?
        var pages: [[Any]] = []
        for index in text.indices {
            let char = text[index]
            if depth == 0 {
                if char.isWhitespace { continue }
                guard char == "[" else { throw ForgeError.failed }
                start = index; depth = 1; continue
            }
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "[" || char == "{" { depth += 1 }
            else if char == "]" || char == "}" {
                depth -= 1
                if depth == 0, let start {
                    let data = Data(text[start...index].utf8)
                    guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { throw ForgeError.failed }
                    pages.append(array)
                }
            }
        }
        guard depth == 0, !quoted, !pages.isEmpty else { throw ForgeError.failed }
        let rows = pages.flatMap { $0 }.flatMap { ($0 as? [Any]) ?? [$0] }
        guard rows.allSatisfy({ $0 is [String: Any] }) else { throw ForgeError.failed }
        return rows.compactMap { $0 as? [String: Any] }
    }
    static func browserURL(_ value: Any?) throws -> URL {
        guard let raw = value as? String, let url = URL(string: raw), (try? ProviderSignIn.validate(url)) != nil else { throw ForgeError.failed }
        return url
    }
    func parsePR(_ text: String, review: String? = nil) throws -> ForgePullRequest {
        let row = try Self.object(text)
        let url = try Self.browserURL(row[kind == .github ? "url" : "web_url"])
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let number = row[kind == .github ? "number" : "iid"] as? Int, number > 0,
              let title = row["title"] as? String, let rawState = row["state"] as? String,
              let marker = parts.lastIndex(of: kind == .github ? "pull" : "merge_requests"), marker > 0 else { throw ForgeError.failed }
        var repoParts = Array(parts[..<marker]); if repoParts.last == "-" { repoParts.removeLast() }
        guard repoParts.count >= 2, parts.count == marker + 2, Int(parts[marker + 1]) == number else { throw ForgeError.failed }
        let raw = rawState.lowercased()
        let state: ForgePullRequest.State
        if raw == "merged" || row["merged_at"] is String { state = .merged }
        else if raw == "closed" { state = .closed }
        else if raw == "open" || raw == "opened" {
            state = (row["isDraft"] as? Bool ?? row["draft"] as? Bool ?? row["work_in_progress"] as? Bool ?? false) ? .draft : .open
        } else { throw ForgeError.failed }
        let merge = (row["mergeable"] as? String ?? row["detailed_merge_status"] as? String ?? row["merge_status"] as? String ?? "").lowercased()
        let mergeable: ForgePullRequest.Mergeable
        if row["has_conflicts"] as? Bool == true || ["conflicting", "conflict", "cannot_be_merged"].contains(merge) { mergeable = .conflicting }
        else if ["mergeable", "can_be_merged"].contains(merge) { mergeable = .yes }
        else if ["not_approved", "blocked_status", "ci_must_pass", "discussions_not_resolved", "draft_status"].contains(merge) { mergeable = .no }
        else { mergeable = .unknown }
        let sourceIsFork = kind == .github ? row["isCrossRepository"] as? Bool == true
            : (row["source_project_id"] as? Int) != (row["target_project_id"] as? Int)
        return .init(forge: kind, host: url.host!.lowercased(), repo: repoParts.joined(separator: "/"), number: number, url: url, title: title, state: state, mergeable: mergeable, reviewDecision: review ?? (row["reviewDecision"] as? String).flatMap { ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"].contains($0) ? $0 : nil },
                     base: row[kind == .github ? "baseRefName" : "target_branch"] as? String,
                     head: row[kind == .github ? "headRefName" : "source_branch"] as? String, sourceIsFork: sourceIsFork)
    }
    func view(_ directory: URL, _ branch: String, byNumber: Bool = false) async throws -> ForgePullRequest? {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0") else { throw ForgeError.failed }
        do {
            // A numeric branch must never be interpreted as an unrelated PR ID.
            let digits = branch.hasPrefix("#") ? String(branch.dropFirst()) : branch
            if !byNumber, !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                let list = kind == .github ? ["pr", "list", "--head", branch, "--state", "all", "--json", "number"] : ["mr", "list", "--source-branch", branch, "--all", "-F", "json"]
                let rows = try Self.array(try await run(list, directory).stdout)
                guard let number = rows.compactMap({ $0[kind == .github ? "number" : "iid"] as? Int }).filter({ $0 > 0 }).max() else { return nil }
                return try await view(directory, String(number), byNumber: true)
            }
            let args = kind == .github ? ["pr", "view", branch, "--json", "number,url,title,state,isDraft,mergeable,reviewDecision,baseRefName,headRefName,isCrossRepository"] : ["mr", "view", branch, "-F", "json"]
            let text = try await run(args, directory).stdout
            let request = try parsePR(text)
            if byNumber, request.number != Int(branch) { throw ForgeError.failed }
            if kind == .gitlab,
               let approvals = try? Self.object(try await run(["api", "projects/:id/merge_requests/\(request.number)/approvals"], directory).stdout) {
                let required = approvals["approvals_required"] as? Int ?? 0
                let remaining = approvals["approvals_left"] as? Int
                let review: String? = approvals["approved"] as? Bool == true || (required > 0 && remaining == 0) ? "APPROVED" : required > 0 ? "REVIEW_REQUIRED" : nil
                return try parsePR(text, review: review)
            }
            return request
        } catch ForgeError.notFound { return nil }
    }
    func create(_ directory: URL, _ branch: String, _ base: String, _ title: String, _ body: String, _ draft: Bool) async throws -> ForgePullRequest {
        guard !branch.isEmpty, !base.isEmpty, !branch.hasPrefix("-"), !base.hasPrefix("-"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [branch, base, title, body].allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 262144 }) else { throw ForgeError.failed }
        var args = kind == .github ? ["pr", "create", "--head", branch, "--base", base, "--title", title, "--body", body] : ["mr", "create", "--source-branch", branch, "--target-branch", base, "--title", title, "--description", body, "--yes"]
        if draft { args.append("--draft") }
        _ = try await run(args, directory)
        guard let result = try await view(directory, branch) else { throw ForgeError.failed }
        return result
    }
    func checks(_ directory: URL, _ number: Int) async throws -> [ForgeCheck] {
        guard number > 0 else { throw ForgeError.failed }
        let rows: [[String: Any]]
        if kind == .github {
            let output = try await run(["pr", "checks", String(number), "--json", "name,state,link"], directory, allowed: [0, 1, 8])
            if output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, output.exitCode == 1, output.stderr.lowercased().contains("no checks") { return [] }
            rows = try Self.array(output.stdout)
        } else {
            let pipelines = try Self.array(try await run(["api", "projects/:id/merge_requests/\(number)/pipelines"], directory).stdout)
            guard let id = pipelines.compactMap({ $0["id"] as? Int }).max() else { return [] }
            rows = try Self.array(try await run(["api", "projects/:id/pipelines/\(id)/jobs", "--paginate"], directory).stdout)
        }
        let origin = try Self.repository(try await GitWorkspace(environment: environment).command(["remote", "get-url", "origin"], in: directory))
        return try rows.map { row in
            guard let name = row["name"] as? String, let raw = (row["state"] ?? row["status"]) as? String else { throw ForgeError.failed }
            let status = raw.lowercased()
            let mapped: ForgeCheck.Status = ["success", "passed"].contains(status) ? .passing : ["failure", "failed", "error", "timed_out", "action_required", "startup_failure"].contains(status) ? .failing : ["skipped", "neutral", "cancelled", "canceled", "manual"].contains(status) ? .skipped : .pending
            let url = try? Self.browserURL(row[kind == .github ? "link" : "web_url"])
            let target: ForgeCheck.LogTarget?
            if kind == .github { target = Self.actionsTarget(url, host: origin.host, repo: origin.repo) }
            else if let job = row["id"] as? Int, job > 0 { target = .gitlab(job: job) }
            else { target = nil }
            return ForgeCheck(name: name, status: mapped, url: url, logTarget: target)
        }
    }
    private static func actionsTarget(_ url: URL?, host: String, repo: String) -> ForgeCheck.LogTarget? {
        guard let url, url.host?.lowercased() == host else { return nil }
        let prefix = "/" + repo + "/actions/runs/"
        guard url.path.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        let parts = url.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, let run = Int(first), run > 0 else { return nil }
        if parts.count == 1 { return .actions(run: run, job: nil) }
        guard parts.count == 3, parts[1] == "job", let job = Int(parts[2]), job > 0 else { return nil }
        return .actions(run: run, job: job)
    }
    func failedLog(_ directory: URL, _ number: Int, _ check: ForgeCheck) async -> String? {
        guard number > 0, check.status == .failing else { return nil }
        let args: [String]
        switch (kind, check.logTarget) {
        case (.github, .actions(let run, let job)):
            if let job { args = ["run", "view", "--job", String(job), "--log-failed"] }
            else { args = ["run", "view", String(run), "--log-failed"] }
        case (.gitlab, .gitlab(let job)):
            args = ["api", "projects/:id/jobs/\(job)/trace"]
        default: return nil
        }
        guard let output = try? await run(args, directory, stdoutTailBytes: 16_384), !output.stdout.isEmpty else { return nil }
        var lines = output.stdout.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let tail = lines.suffix(200).joined(separator: "\n")
        return String(decoding: tail.utf8.suffix(16_384).drop(while: { $0 & 0xC0 == 0x80 }), as: UTF8.self)
    }
    func comments(_ directory: URL, _ number: Int) async throws -> [ForgeComment] {
        guard number > 0 else { throw ForgeError.failed }
        let args = kind == .github ? ["api", "repos/{owner}/{repo}/issues/\(number)/comments", "--paginate", "--slurp"] : ["api", "projects/:id/merge_requests/\(number)/notes", "--paginate"]
        let rows = try Self.array(try await run(args, directory).stdout)
        let notes = try rows.filter { kind != .gitlab || $0["system"] as? Bool != true }.map { try comment($0) }
        guard kind == .github else { return notes }
        let inline = try Self.array(try await run(["api", "repos/{owner}/{repo}/pulls/\(number)/comments", "--paginate", "--slurp"], directory).stdout)
        let reviews = try Self.array(try await run(["api", "repos/{owner}/{repo}/pulls/\(number)/reviews", "--paginate", "--slurp"], directory).stdout)
        return notes + (try inline.map { try comment($0, prefix: "inline/") }) + (try reviews.compactMap { row in
            let state = row["state"] as? String
            let body = row["body"] as? String ?? ""
            guard state != "PENDING", state == "CHANGES_REQUESTED" || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return try comment(row, prefix: "review/", dateKey: "submitted_at", fallbackBody: "Changes requested.")
        })
    }
    private func comment(_ row: [String: Any], prefix: String = "", dateKey: String = "created_at",
                         fallbackBody: String? = nil) throws -> ForgeComment {
        guard let id = row["id"] as? Int, id > 0,
              let date = row[dateKey] as? String, let created = Self.date(date),
              let rawBody = (row["body"] as? String) ?? fallbackBody else { throw ForgeError.failed }
        let author = row[kind == .github ? "user" : "author"] as? [String: Any]
        let name = author?[kind == .github ? "login" : "username"] as? String ?? "Unknown author"
        let body = rawBody.isEmpty ? fallbackBody ?? rawBody : rawBody
        return ForgeComment(id: prefix + String(id), author: name, body: body,
                            url: try? Self.browserURL(row[kind == .github ? "html_url" : "web_url"]), createdAt: created)
    }
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds); return formatter.date(from: text)
    }
    func signIn(_ host: String, _ deviceCode: @escaping @Sendable (String) async -> Void, _ callback: @escaping @Sendable (URL) async -> Void) async throws {
        guard Self.validHost(host) else { throw ForgeError.unsupportedHost }
        guard let executable else { throw ForgeError.notInstalled }
        var env = environment
        env.removeValue(forKey: "GH_PROMPT_DISABLED")
        // CLI browser helpers print URLs into the managed stdout stream. The
        // application opens only HTTPS URLs after ProviderSignIn validation.
        env["GLAB_BROWSER"] = "/usr/bin/printf '%s\\n'"
        env["GH_BROWSER"] = "/usr/bin/printf '%s\\n'"; env["BROWSER"] = "/usr/bin/printf '%s\\n'"
        let args = kind == .github ? ["auth", "login", "--web", "--hostname", host, "--git-protocol", "https"] : ["auth", "login", "--hostname", host, "--web", "--git-protocol", "https"]
        let process = StreamingProcess(executable: executable, arguments: args, currentDirectory: nil, environment: env)
        do {
            try process.start()
            // Answer only the browser-opening Enter prompt; no credentials are
            // requested or accepted through this pipe.
            try? await process.write(line: "")
            process.closeInput()
            let codes = Task {
                var reported: String?
                while !Task.isCancelled {
                    let text = process.stderrText
                    if let range = text.range(of: #"(?i)one-time code: *([A-Z0-9]{4}-[A-Z0-9]{4})"#, options: .regularExpression) {
                        let code = String(text[range].suffix(9))
                        if code != reported { reported = code; await deviceCode(code) }
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            defer { codes.cancel() }
            let timer = Task { () -> Bool in
                do { try await Task.sleep(for: .seconds(300)) } catch { return false }
                process.terminate(); return true
            }
            defer { timer.cancel() }
            try await withTaskCancellationHandler {
                var bytes = 0
                for try await line in process.lines {
                    bytes += line.utf8.count; guard bytes < 65536 else { throw ForgeError.failed }
                    for word in line.split(whereSeparator: \.isWhitespace) {
                        if let url = URL(string: String(word)), (try? ProviderSignIn.validate(url)) != nil { await callback(url) }
                    }
                }
                let status = try await process.waitForExit()
                try Task.checkCancellation()
                timer.cancel()
                if await timer.value { throw ForgeError.network }
                guard status == 0 else { throw ForgeError.signedOut }
            } onCancel: { process.terminate() }
        } catch {
            try? await process.shutdown(grace: .zero)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? ForgeError { throw error }
            throw ForgeError.failed
        }
    }
}
