import Foundation
import Darwin
import AitvarasCore

/// Owns one run's transient credentials. Explicitly remove after the child exits;
/// deinit is a final synchronous cleanup backstop, not the run lifecycle.
public actor AgentMCPRuntimeFile {
    public enum Format: Sendable { case claude, opencode }
    public typealias SecretResolver = @Sendable (String) async throws -> String?
    public nonisolated let url: URL
    private var location: Location?
    private let projectID: UUID
    private let runID: UUID
    private let audit: AgentActionCoordinator.Audit
    private var redactions: [String]

    private struct Location: Sendable {
        let directory: Int32
        let name: String
        let device: dev_t
        let inode: ino_t
    }

    private init(url: URL, location: Location, projectID: UUID, runID: UUID,
                 audit: @escaping AgentActionCoordinator.Audit, redactions: [String]) {
        self.url = url; self.location = location; self.projectID = projectID; self.runID = runID; self.audit = audit
        self.redactions = redactions
    }
    deinit { if let location { try? Self.erase(location) } }

    /// `resolveSecret` must read the app's profile-scoped Keychain. Tests inject
    /// a synthetic resolver. No resolved value is returned to configuration/storage.
    public static func create(stateDirectory: URL, projectID: UUID, runID: UUID,
                              servers: [String: AgentMCPServer], format: Format = .claude,
                              baseConfiguration: JSONValue? = nil,
                              policy: AutonomyPolicy = .init(), audit: @escaping AgentActionCoordinator.Audit,
                              resolveSecret: @escaping SecretResolver) async throws -> AgentMCPRuntimeFile {
        try AgentMCPConfiguration.validate(servers)
        guard servers.values.allSatisfy({ $0.management == nil }) else { throw AgentMCPError.invalidConfiguration }
        let tool = ToolDefinition(name: "runtimeConfiguration", description: "Prepare MCP runtime", parametersJSON: "{}", risk: .reversibleWrite)
        guard policy.verdict(for: tool, connectorID: "agent.mcp") == .allow else { throw AgentMCPError.runtimeFile }
        try await record("authorized", projectID: projectID, runID: runID, audit: audit)
        do {
            try Task.checkCancellation()
            // Keep the cache local to creation. Never retain resolved values in the actor.
            var secrets: [String: String] = [:]
            func resolve(_ values: [String: AgentMCPValue], headers: Bool = false) async throws -> JSONValue {
                var result: [String: JSONValue] = [:]
                for key in values.keys.sorted() {
                    try Task.checkCancellation()
                    let text: String
                    switch values[key]! {
                    case .literal(let literal): text = literal
                    case .secretReference(let reference):
                        if let cached = secrets[reference] { text = cached }
                        else {
                            let resolved: String?
                            do { resolved = try await resolveSecret(reference) }
                            catch is CancellationError { throw CancellationError() }
                            catch { throw AgentMCPError.secretUnavailable }
                            try Task.checkCancellation()
                            guard let resolved else { throw AgentMCPError.secretUnavailable }
                            secrets[reference] = resolved; text = resolved
                        }
                    }
                    guard !text.contains("\0"), !headers || !text.contains(where: { $0.isNewline }) else {
                        throw AgentMCPError.secretUnavailable
                    }
                    result[key] = .string(text)
                }
                return .object(result)
            }
            var entries: [String: JSONValue] = [:]
            for name in servers.keys.sorted() {
                let server = servers[name]!
                switch format {
                case .claude:
                    var fields: [String: JSONValue] = ["type": .string(server.transport.rawValue)]
                    if server.transport == .stdio {
                        fields["command"] = .string(server.command!)
                        fields["args"] = .array(server.args.map(JSONValue.string))
                        fields["env"] = try await resolve(server.env)
                    } else {
                        fields["url"] = .string(server.url!)
                        fields["headers"] = try await resolve(server.headers, headers: true)
                    }
                    entries[name] = .object(fields)
                case .opencode:
                    guard server.transport == .stdio else { throw AgentMCPError.invalidConfiguration }
                    entries[name] = .object(["type": .string("local"), "enabled": .bool(true),
                        "command": .array(([server.command!] + server.args).map(JSONValue.string)),
                        "environment": try await resolve(server.env)])
                }
            }
            let key = format == .claude ? "mcpServers" : "mcp"
            var configuration = baseConfiguration?.objectValue ?? [:]
            configuration[key] = .object(entries)
            let data = Data(JSONValue.object(configuration).jsonString.utf8)
            guard data.count <= AgentMCPConfiguration.maximumBytes else { throw AgentMCPError.runtimeFile }
            try Task.checkCancellation()
            let (url, location) = try write(data, stateDirectory: stateDirectory, projectID: projectID, runID: runID)
            do {
                try Task.checkCancellation()
                try await record("created", projectID: projectID, runID: runID, audit: audit)
                try Task.checkCancellation()
            } catch {
                try? erase(location)
                throw error
            }
            return AgentMCPRuntimeFile(url: url, location: location, projectID: projectID, runID: runID, audit: audit, redactions: Array(secrets.values))
        } catch {
            try? await record(error is CancellationError ? "cancelled" : "failed", projectID: projectID, runID: runID, audit: audit)
            throw error
        }
    }

    public func remove(preservingRedactions: Bool = false) async throws {
        if !preservingRedactions { redactions.removeAll() }
        guard let location else { return }
        // Erasure cannot be prevented by a failed audit sink. Retain ownership if
        // unlink fails, so the caller can retry instead of losing the cleanup handle.
        do { try Self.erase(location) }
        catch { throw AgentMCPError.runtimeFile }
        self.location = nil
        try await Self.record("removed", projectID: projectID, runID: runID, audit: audit)
    }

    // The metadata reader applies the final bound after both sources of
    // credentials have been removed.
    func redacted(_ text: String) -> String { AgentHookText.safe(text, secrets: redactions, limit: Int.max) }

    private static func record(_ result: String, projectID: UUID, runID: UUID,
                               audit: AgentActionCoordinator.Audit) async throws {
        do {
            try await audit(ActivityEvent(kind: .toolExecuted, connectorID: "agent.mcp", summary: "MCP runtime: \(result)",
                detailJSON: JSONValue.object(["projectID": .string(projectID.uuidString),
                    "result": .string(result), "risk": .string(ActionRisk.reversibleWrite.rawValue)]).jsonString,
                runID: runID))
        } catch is CancellationError { throw CancellationError() }
        catch { throw AgentMCPError.auditFailed }
    }

    /// Directory descriptors anchor every operation. Refuse links and insecure
    /// existing private directories; never chmod somebody else's directory.
    private static func write(_ data: Data, stateDirectory: URL, projectID: UUID, runID: UUID) throws -> (URL, Location) {
        guard stateDirectory.isFileURL else { throw AgentMCPError.runtimeFile }
        var directory = open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AgentMCPError.runtimeFile }
        defer { if directory >= 0 { close(directory) } }
        var url = stateDirectory
        for part in ["Runtime", "mcp", projectID.uuidString] {
            if mkdirat(directory, part, 0o700) != 0, errno != EEXIST { throw AgentMCPError.runtimeFile }
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw AgentMCPError.runtimeFile }
            var info = stat()
            guard fstat(next, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                close(next); throw AgentMCPError.runtimeFile
            }
            close(directory); directory = next; url.appendPathComponent(part, isDirectory: true)
        }
        let name = runID.uuidString + ".json"
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw AgentMCPError.runtimeFile }
        defer { close(file) }
        var success = false
        defer { if !success { unlinkat(directory, name, 0) } }
        // A restrictive inherited umask may remove owner permissions; this only
        // restores 0600 on our exclusive descriptor, before any credential write.
        guard fchmod(file, 0o600) == 0 else { throw AgentMCPError.runtimeFile }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw AgentMCPError.runtimeFile }; offset += count
            }
        }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw AgentMCPError.runtimeFile }
        let location = Location(directory: directory, name: name, device: info.st_dev, inode: info.st_ino)
        url.appendPathComponent(name)
        success = true; directory = -1 // ownership transfers to Location
        return (url, location)
    }

    private static func erase(_ location: Location) throws {
        var info = stat()
        if fstatat(location.directory, location.name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw AgentMCPError.runtimeFile }
        } else if info.st_dev == location.device, info.st_ino == location.inode {
            guard unlinkat(location.directory, location.name, 0) == 0 || errno == ENOENT else { throw AgentMCPError.runtimeFile }
        }
        // A replaced file belongs to somebody else; never remove it.
        close(location.directory)
    }
}
