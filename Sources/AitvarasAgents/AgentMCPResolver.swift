import Foundation
import Darwin
import CryptoKit

public struct AgentMCPRepositoryServer: Sendable, Equatable {
    public let server: AgentMCPServer?
    /// Transient inventory only; never save repo configuration in the database.
    public let canonicalJSON: String
    public let fingerprint: String
    public let sourceFiles: [String]
    public let conflicting: Bool
    public var unsupportedReason: String? {
        conflicting ? "defined differently in several .mcp.json files" : server == nil ? "Unsupported MCP server configuration." : nil
    }
    public let hasAdditionalOptions: Bool
}

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
        case optInRequired, remoteTransport, unsupportedOptions
        public var explanation: String {
            switch self {
            case .optInRequired: "Allow Local to use MCP servers in this project first."
            case .remoteTransport: "Not available for Local: only stdio MCP servers are supported."
            case .unsupportedOptions: "Not available for Local: additional repo options cannot be translated."
            }
        }
    }
    public let repositoryServers: [String: AgentMCPServer]
    public let repositoryEntries: [String: AgentMCPRepositoryServer]
    public let repositoryUnreadable: Bool
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
    public static func repositoryInventory(directory: URL) -> (entries: [String: AgentMCPRepositoryServer], unreadable: Bool) {
        readRepository(directory: directory)
    }
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
        let inventory = readRepository(directory: directory)
        let entries = inventory.entries
        let repo = entries.compactMapValues(\.server)
        let fingerprints = entries.mapValues(\.fingerprint)
        // Managed connections are never materialized as a native CLI config.
        var app = globalServers.filter { $0.value.management == nil && !setup.disabledGlobalServers.contains($0.key) }
        app.merge(setup.projectServers.filter { $0.value.management == nil }) { _, project in project }
        guard Set(app.keys).isDisjoint(with: entries.keys) else { throw AgentMCPError.nameCollision }
        let disabled = entries.keys.filter {
            inventory.unreadable || entries[$0]?.server == nil || entries[$0]?.conflicting == true || setup.deniedServers.contains($0) || setup.approvedServers[$0] != fingerprints[$0]
        }.sorted()
        let disabledSet = Set(disabled)
        var effective = app
        effective.merge(repo.filter { !disabledSet.contains($0.key) }) { _, repository in repository }
        var local: [String: AgentMCPServer] = [:]
        var unavailable: [String: AgentMCPResolution.LocalUnavailableReason] = [:]
        for (name, server) in effective {
            if server.transport != .stdio { unavailable[name] = .remoteTransport }
            else if entries[name]?.hasAdditionalOptions == true { unavailable[name] = .unsupportedOptions }
            else if !setup.localMayUseMCP { unavailable[name] = .optInRequired }
            else { local[name] = server }
        }
        return .init(repositoryServers: repo, repositoryEntries: entries, repositoryUnreadable: inventory.unreadable,
                     repositoryFingerprints: fingerprints,
                     disabledProjectServers: disabled, claudeServers: app, effectiveServers: effective,
                     localServers: local, unavailableForLocal: unavailable)
    }

    private static func readRepository(directory: URL) -> (entries: [String: AgentMCPRepositoryServer], unreadable: Bool) {
        guard directory.isFileURL else { return ([:], true) }
        // Walk actual directory descriptors, not lexical parents or symlinks.
        var fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return ([:], true) }
        defer { close(fd) }
        var entries: [String: AgentMCPRepositoryServer] = [:], unreadable = false
        var prefix = ""
        for _ in 0..<256 {
            do {
                for (name, entry) in try inventory(directoryFD: fd, source: prefix + ".mcp.json") {
                    if let old = entries[name] {
                        let conflict = old.conflicting || old.fingerprint != entry.fingerprint
                        entries[name] = .init(server: conflict ? nil : old.server, canonicalJSON: old.canonicalJSON,
                            fingerprint: old.fingerprint, sourceFiles: old.sourceFiles + entry.sourceFiles,
                            conflicting: conflict, hasAdditionalOptions: old.hasAdditionalOptions)
                    } else { entries[name] = entry }
                }
                if entries.count > 128 { return (entries, true) }
            } catch { unreadable = true }
            var current = stat(), parent = stat()
            let next = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return (entries, true) }
            guard fstat(fd, &current) == 0, fstat(next, &parent) == 0 else { close(next); return (entries, true) }
            if current.st_dev == parent.st_dev && current.st_ino == parent.st_ino {
                close(next); return (entries, unreadable)
            }
            close(fd); fd = next; prefix += "../"
        }
        return (entries, true)
    }

    private static func inventory(directoryFD: Int32, source: String) throws -> [String: AgentMCPRepositoryServer] {
        let fd = openat(directoryFD, ".mcp.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [:] }
            throw AgentMCPError.invalidRepository
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= AgentMCPConfiguration.maximumBytes else { throw AgentMCPError.invalidRepository }
        let data = try handle.read(upToCount: AgentMCPConfiguration.maximumBytes + 1) ?? Data()
        return try repositoryEntries(data: data, source: source)
    }

    /// Pure inventory parsing, also exercised without any filesystem authority.
    static func repositoryEntries(data: Data, source: String) throws -> [String: AgentMCPRepositoryServer] {
        guard data.count <= AgentMCPConfiguration.maximumBytes, String(data: data, encoding: .utf8) != nil,
              let root = try AgentMCPJSON.parse(data).fields,
              let serversJSON = root.first(where: { $0.0 == Data("mcpServers".utf8) })?.1,
              let raw = try AgentMCPJSON.parse(serversJSON).fields,
              raw.count <= 128 else { throw AgentMCPError.invalidRepository }
        var result: [String: AgentMCPRepositoryServer] = [:]
        for (key, rawValue) in raw {
            let name = String(decoding: key, as: UTF8.self)
            // Reject the whole file before Swift dictionaries can merge NFC/NFD names.
            try AgentMCPConfiguration.validateName(name)
            let canonical = rawValue
            let fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
            let value = JSONValue.parse(String(decoding: canonical, as: UTF8.self)) ?? .null
            let known: Set<String> = ["type", "command", "args", "env", "url", "headers"]
            let additional = value.objectValue.map { !Set($0.keys).isSubset(of: known) } ?? false
            let server = try? typedServer(name: name, value: value)
            result[name] = .init(server: server, canonicalJSON: String(decoding: canonical, as: UTF8.self),
                fingerprint: fingerprint, sourceFiles: [source], conflicting: false, hasAdditionalOptions: additional)
        }
        return result
    }

    private static func typedServer(name: String, value: JSONValue) throws -> AgentMCPServer {
        try AgentMCPConfiguration.validateName(name)
        guard let fields = value.objectValue else { throw AgentMCPError.invalidRepository }
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
        try server.validate(); return server
    }
}
