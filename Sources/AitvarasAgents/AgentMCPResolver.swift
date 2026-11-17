import Foundation
import Darwin

public struct AgentMCPProjectConfiguration: Sendable, Equatable {
    public var approvedServers: [String: String]
    public var deniedServers: Set<String>
    public var projectServers: [String: AgentMCPServer]
    public var disabledGlobalServers: Set<String>
    public var localMayUseMCP: Bool
    public init(approvedServers: [String: String] = [:], deniedServers: Set<String> = [],
                projectServers: [String: AgentMCPServer] = [:], disabledGlobalServers: Set<String> = [],
                localMayUseMCP: Bool = false) {
        self.approvedServers = approvedServers; self.deniedServers = deniedServers
        self.projectServers = projectServers; self.disabledGlobalServers = disabledGlobalServers
        self.localMayUseMCP = localMayUseMCP
    }
}

public struct AgentMCPResolution: Sendable, Equatable {
    public enum LocalUnavailableReason: String, Sendable {
        case optInRequired, remoteTransport
        public var explanation: String {
            switch self {
            case .optInRequired: "Allow Local to use MCP servers in this project first."
            case .remoteTransport: "Not available for Local: only stdio MCP servers are supported."
            }
        }
    }
    public let repositoryServers: [String: AgentMCPServer]
    public let repositoryFingerprints: [String: String]
    public let disabledProjectServers: [String]
    /// App-added only: approved repo servers stay native in Claude, without duplication.
    public let claudeServers: [String: AgentMCPServer]
    public let effectiveServers: [String: AgentMCPServer]
    public let localServers: [String: AgentMCPServer]
    public let unavailableForLocal: [String: LocalUnavailableReason]
    public var settingsJSON: String {
        JSONValue.object(["disabledMcpjsonServers": .array(disabledProjectServers.map(JSONValue.string))]).jsonString
    }
}

public enum AgentMCPResolver {
    /// Call immediately before each launch. No inventory cache: approval is checked
    /// against a fresh, bounded read at the actual run cwd (including worktrees).
    /// The CLI reads again later; callers must not claim this removes that residual window.
    public static func prepare(directory: URL, setup: AgentMCPProjectConfiguration,
                               globalServers: [String: AgentMCPServer] = [:]) throws -> AgentMCPResolution {
        try AgentMCPConfiguration.validate(globalServers)
        try AgentMCPConfiguration.validate(setup.projectServers)
        for name in Set(setup.approvedServers.keys).union(setup.deniedServers).union(setup.disabledGlobalServers) {
            try AgentMCPConfiguration.validateName(name)
        }
        let repo = try readRepository(directory: directory)
        let fingerprints = try repo.mapValues { try $0.fingerprint() }
        var app = globalServers.filter { !setup.disabledGlobalServers.contains($0.key) }
        app.merge(setup.projectServers) { _, project in project }
        guard Set(app.keys).isDisjoint(with: repo.keys) else { throw AgentMCPError.nameCollision }
        let disabled = repo.keys.filter {
            setup.deniedServers.contains($0) || setup.approvedServers[$0] != fingerprints[$0]
        }.sorted()
        let disabledSet = Set(disabled)
        var effective = app
        effective.merge(repo.filter { !disabledSet.contains($0.key) }) { _, repository in repository }
        var local: [String: AgentMCPServer] = [:]
        var unavailable: [String: AgentMCPResolution.LocalUnavailableReason] = [:]
        for (name, server) in effective {
            if server.transport != .stdio { unavailable[name] = .remoteTransport }
            else if !setup.localMayUseMCP { unavailable[name] = .optInRequired }
            else { local[name] = server }
        }
        return .init(repositoryServers: repo, repositoryFingerprints: fingerprints,
                     disabledProjectServers: disabled, claudeServers: app, effectiveServers: effective,
                     localServers: local, unavailableForLocal: unavailable)
    }

    private static func readRepository(directory: URL) throws -> [String: AgentMCPServer] {
        guard directory.isFileURL else { throw AgentMCPError.invalidRepository }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { throw AgentMCPError.invalidRepository }
        defer { close(root) }
        let fd = openat(root, ".mcp.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw AgentMCPError.invalidRepository
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= AgentMCPConfiguration.maximumBytes else { throw AgentMCPError.invalidRepository }
        do {
            let data = try handle.read(upToCount: AgentMCPConfiguration.maximumBytes + 1) ?? Data()
            guard data.count <= AgentMCPConfiguration.maximumBytes, let text = String(data: data, encoding: .utf8),
                  let root = JSONValue.parse(text)?.objectValue,
                  Set(root.keys) == ["mcpServers"], let raw = root["mcpServers"]?.objectValue,
                  raw.count <= 128 else { throw AgentMCPError.invalidRepository }
            var result: [String: AgentMCPServer] = [:]
            for (name, value) in raw {
                try AgentMCPConfiguration.validateName(name)
                guard let fields = value.objectValue,
                      Set(fields.keys).isSubset(of: ["type", "command", "args", "env", "url", "headers"]) else {
                    throw AgentMCPError.invalidRepository
                }
                let transport: AgentMCPServer.Transport
                if let type = fields["type"] {
                    guard let text = type.stringValue, let parsed = AgentMCPServer.Transport(rawValue: text) else {
                        throw AgentMCPError.invalidRepository
                    }
                    transport = parsed
                } else { transport = .stdio }
                func string(_ key: String) throws -> String? {
                    guard let value = fields[key] else { return nil }
                    guard let text = value.stringValue else { throw AgentMCPError.invalidRepository }; return text
                }
                func values(_ key: String) throws -> [String: AgentMCPValue] {
                    guard let value = fields[key] else { return [:] }
                    guard let object = value.objectValue else { throw AgentMCPError.invalidRepository }
                    return try object.mapValues {
                        guard let text = $0.stringValue else { throw AgentMCPError.invalidRepository }
                        return .literal(text)
                    }
                }
                var args: [String] = []
                if let value = fields["args"] {
                    guard let array = value.arrayValue else { throw AgentMCPError.invalidRepository }
                    args = try array.map {
                        guard let text = $0.stringValue else { throw AgentMCPError.invalidRepository }; return text
                    }
                }
                let server = AgentMCPServer(transport: transport, command: try string("command"), args: args,
                    env: try values("env"), url: try string("url"), headers: try values("headers"))
                try server.validate(); result[name] = server
            }
            return result
        } catch { throw AgentMCPError.invalidRepository }
    }
}
