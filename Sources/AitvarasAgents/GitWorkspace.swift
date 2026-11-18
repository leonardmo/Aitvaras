import Foundation
import CryptoKit

/// All arguments are passed directly to git. NUL-delimited porcelain preserves
/// spaces, tabs, newlines and rename pairs without decoding git's quoted paths.
public actor GitWorkspace {
    private let executable: URL
    private let environment: [String: String]
    private let pushEnvironment: [String: String]
    private let pushTimeout: Duration
    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/git"), environment: [String: String] = ProcessInfo.processInfo.environment, pushTimeout: Duration = .seconds(120)) {
        self.executable = executable
        self.pushTimeout = pushTimeout
        // Credential helpers retain HOME/PATH, SSH_AUTH_SOCK, GH_* and askpass.
        // Never inherit repository, config, index or transport GIT_* overrides.
        self.pushEnvironment = environment.filter { !$0.key.hasPrefix("GIT_") || $0.key == "GIT_ASKPASS" }
            .merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1",
                      "LC_ALL": "C"]) { _, new in new }
        // Repository/index overrides must not redirect a selected chat's writes.
        self.environment = environment.filter { !$0.key.hasPrefix("GIT_") }
            .merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1"]) { _, new in new }
    }
    @discardableResult public func command(_ arguments: [String], in directory: URL) async throws -> String {
        let output = try await OneShotProcess.run(executable: executable,
            arguments: ["--no-pager"] + arguments, currentDirectory: directory, environment: environment, timeout: .seconds(30))
        guard !output.timedOut, output.exitCode == 0 else { throw AgentGitError.commandFailed }
        return output.stdout
    }
    private func optionalCommand(_ arguments: [String], in directory: URL, absent: Int32) async throws -> String? {
        let output = try await OneShotProcess.run(executable: executable, arguments: ["--no-pager"] + arguments,
            currentDirectory: directory, environment: environment, timeout: .seconds(30))
        guard !output.timedOut else { throw AgentGitError.commandFailed }
        if output.exitCode == absent { return nil }
        guard output.exitCode == 0 else { throw AgentGitError.commandFailed }
        return output.stdout
    }

    public func branchStatus(at directory: URL) async throws -> GitBranchStatus {
        let branch = try await optionalCommand(["symbolic-ref", "--short", "-q", "HEAD"], in: directory, absent: 1)
        let upstream = try await optionalCommand(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: directory, absent: 128)
        var ahead = 0, behind = 0
        if upstream != nil {
            let counts = try await command(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: directory)
                .split(whereSeparator: \.isWhitespace)
            guard counts.count == 2, let left = Int(counts[0]), let right = Int(counts[1]), left >= 0, right >= 0 else {
                throw AgentGitError.invalidOutput
            }
            behind = left; ahead = right
        }
        let defaultRef = try await optionalCommand(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: directory, absent: 1)
        var defaultBranch = defaultRef.flatMap { $0.hasPrefix("refs/remotes/origin/") ? String($0.dropFirst(20)) : nil }
        if defaultBranch == nil {
            for candidate in ["main", "master"] {
                if try await optionalCommand(["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"], in: directory, absent: 1) != nil {
                    defaultBranch = candidate; break
                }
            }
        }
        // get-url failure means no origin; its diagnostic is never retained.
        let remote = try await optionalCommand(["remote", "get-url", "origin"], in: directory, absent: 2)
        return GitBranchStatus(branch: branch ?? "HEAD", detached: branch == nil, upstream: upstream,
            ahead: ahead, behind: behind, remoteHost: remote.flatMap(Self.remoteHost),
            isDefaultBranch: branch != nil && branch == defaultBranch, hasRemote: remote != nil)
    }

    public func defaultBranch(at directory: URL) async throws -> String {
        if let ref = try await optionalCommand(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: directory, absent: 1), ref.hasPrefix("refs/remotes/origin/") {
            return String(ref.dropFirst(20))
        }
        for name in ["main", "master"] {
            if try await optionalCommand(["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + name], in: directory, absent: 1) != nil { return name }
        }
        throw AgentGitError.invalidOutput
    }

    /// Extract only a hostname from URL or scp syntax. Local paths have no host.
    public static func remoteHost(_ remote: String) -> String? {
        let host: String?
        if remote.contains("://") {
            let url = URLComponents(string: remote)
            host = url?.scheme == "file" ? nil : url?.host
        } else if !remote.hasPrefix("/"), !remote.hasPrefix("."), let colon = remote.firstIndex(of: ":") {
            host = remote[..<colon].split(separator: "@").last.map(String.init)
        } else { host = nil }
        guard let host, !host.isEmpty,
              host.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-:[]".unicodeScalars.contains($0) }) else { return nil }
        return host
    }

    /// Push exactly the checked-out branch to the same name. No force/refspec
    /// option is accepted; failures are fixed kinds, never raw remote output.
    public func push(at directory: URL, branch: String) async throws {
        guard !branch.hasPrefix("+"), !branch.hasPrefix("-"), !branch.hasPrefix("refs/"), !branch.contains(":"), !branch.isEmpty else {
            throw AgentGitError.unsafeBranch
        }
        guard try await command(["symbolic-ref", "--short", "-q", "HEAD"], in: directory) == branch else {
            throw AgentGitError.ownershipConflict
        }
        _ = try await command(["check-ref-format", "refs/heads/\(branch)"], in: directory)
        // Git's abbreviated ref resolution must identify this exact local head.
        // In particular, a ref-like branch name must never select another ref.
        guard try await command(["rev-parse", "--symbolic-full-name", "--verify", branch], in: directory) == "refs/heads/\(branch)" else {
            throw AgentGitError.unsafeBranch
        }
        guard try await optionalCommand(["remote", "get-url", "origin"], in: directory, absent: 2) != nil else { throw AgentGitError.noRemote }
        let output: OneShotProcess.Output
        do {
            output = try await OneShotProcess.run(executable: executable,
                arguments: ["--no-pager", "push", "-u", "origin", branch], currentDirectory: directory,
                environment: pushEnvironment, timeout: pushTimeout)
        } catch is CancellationError { throw CancellationError() }
        catch { throw AgentGitError.commandFailed }
        if output.timedOut { throw AgentGitError.timedOut }
        guard output.exitCode != 0 else { return }
        let diagnostic = (output.stdout + "\n" + output.stderr).lowercased()
        if diagnostic.contains("non-fast-forward") || diagnostic.contains("fetch first") || diagnostic.contains("stale info") {
            throw AgentGitError.rejectedNonFastForward
        }
        if ["authentication failed", "could not read username", "could not read password", "permission denied", "authentication required", "terminal prompts disabled"].contains(where: diagnostic.contains) {
            throw AgentGitError.authenticationRequired
        }
        if ["could not resolve", "unable to access", "failed to connect", "connection refused", "network is unreachable", "connection timed out", "connection reset", "could not read from remote repository"].contains(where: diagnostic.contains) {
            throw AgentGitError.network
        }
        throw AgentGitError.commandFailed
    }

    public func repository(at directory: URL) async throws -> URL {
        let path = try await command(["rev-parse", "--show-toplevel"], in: directory)
        guard path.hasPrefix("/") else { throw AgentGitError.notRepository }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
    public func verify(_ value: AgentWorktree) async throws {
        guard value.state == .ready else { throw AgentGitError.creationFailed }
        let root = URL(fileURLWithPath: value.repositoryPath)
        let directory = URL(fileURLWithPath: value.worktreePath)
        guard directory.resolvingSymlinksInPath().path == value.worktreePath,
              try await repository(at: directory).path == directory.path else { throw AgentGitError.ownershipConflict }
        let listing = try await command(["worktree", "list", "--porcelain", "-z"], in: root)
        let records = listing.components(separatedBy: "\0\0")
        guard records.contains(where: { record in
            let fields = record.components(separatedBy: "\0")
            let registered = fields.first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
            return registered.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path } == value.worktreePath
                && fields.contains("branch refs/heads/\(value.branch)")
        }) else { throw AgentGitError.ownershipConflict }
        let common = try await command(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
        guard try await command(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory) == common else {
            throw AgentGitError.ownershipConflict
        }
    }
    public func create(_ value: AgentWorktree, startingAt revision: String = "HEAD") async throws {
        guard value.state == .creating, !FileManager.default.fileExists(atPath: value.worktreePath) else { throw AgentGitError.ownershipConflict }
        guard revision == "HEAD" || ([40, 64].contains(revision.count) && revision.allSatisfy(\.isHexDigit)) else { throw AgentGitError.invalidOutput }
        _ = try await command(["worktree", "add", "-b", value.branch, value.worktreePath, revision], in: URL(fileURLWithPath: value.repositoryPath))
    }
    public func changes(in directory: URL) async throws -> ChangesState {
        let root = try await repository(at: directory)
        let head = try await command(["rev-parse", "HEAD"], in: root)
        let status = try await command(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        let paths = try Self.parseStatus(status)
        let index = try await command(["diff", "--cached", "--raw", "-z", "--no-abbrev", "HEAD", "--"], in: root)
        var digest = SHA256(); digest.update(data: Data((root.path + "\0" + head + "\0" + status + index).utf8))
        var files: [AgentFileChange] = []
        for (code, path, original) in paths {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(path)
            var fileDigest = SHA256()
            // Hash exact bytes, including binary/large files, without retaining them.
            // Symlink targets are data; never follow them to an unrelated file.
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) {
                fileDigest.update(data: Data(String(describing: attributes[.posixPermissions]).utf8))
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    fileDigest.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: url.path).utf8))
                } else if attributes[.type] as? FileAttributeType == .typeRegular {
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                        try Task.checkCancellation(); fileDigest.update(data: data)
                    }
                } else { fileDigest.update(data: Data("nonregular".utf8)) }
            } else { fileDigest.update(data: Data("deleted".utf8)) }
            digest.update(data: Data(fileDigest.finalize()))
            var diff = "", unavailable = false
            do {
                if code == "??" {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    if attrs[.type] as? FileAttributeType == .typeRegular,
                       (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 256 * 1024,
                       let text = String(data: try Data(contentsOf: url), encoding: .utf8), !text.contains("\0") {
                        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
                        if text.hasSuffix("\n") { lines.removeLast() }
                        diff = text.isEmpty ? "Empty file" : "--- /dev/null\n+++ b/\(path)\n"
                        if !lines.isEmpty {
                            diff += "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
                            if !text.hasSuffix("\n") { diff += "\n\\ No newline at end of file" }
                        }
                    } else { unavailable = true }
                } else {
                    diff = try await command(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames", "HEAD", "--", path] + (original.map { [$0] } ?? []), in: root)
                    if diff.utf8.count > 256 * 1024 { diff = ""; unavailable = true }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if error as? AgentProcessError == .outputLimit { unavailable = true } else { throw error } }
            files.append(.init(path: path, originalPath: original, status: code, diff: diff, diffUnavailable: unavailable))
        }
        return ChangesState(directory: root, head: head, files: files, fingerprint: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    public static func parseStatus(_ output: String) throws -> [(String, String, String?)] {
        var parts = output.components(separatedBy: "\0"), result: [(String, String, String?)] = []
        if parts.last == "" { parts.removeLast() }
        var index = 0
        while index < parts.count {
            let record = parts[index]; index += 1
            guard record.utf8.count >= 4, record.dropFirst(2).first == " " else { throw AgentGitError.invalidOutput }
            let code = String(record.prefix(2)), path = String(record.dropFirst(3))
            guard validPath(path) else { throw AgentGitError.invalidOutput }
            var original: String?
            if code.contains("R") || code.contains("C") {
                guard index < parts.count, validPath(parts[index]) else { throw AgentGitError.invalidOutput }
                original = parts[index]; index += 1
            }
            result.append((code, path, original))
        }
        return result
    }
    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.components(separatedBy: "/").contains("..") && !path.contains("\0")
    }
}
