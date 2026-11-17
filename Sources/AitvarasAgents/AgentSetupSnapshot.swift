import Foundation

public struct AgentSetupServer: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case connected, needsAuth, failed, pending, unknown }
    public let name: String
    public let status: Status
    public let source: String?
    public let authentication: String?
    public var id: String { name }
    public init(name: String, status: Status, source: String? = nil, authentication: String? = nil) {
        self.name = name; self.status = status; self.source = source; self.authentication = authentication
    }
    static func status(_ raw: String?) -> Status {
        switch raw {
        case "connected", "ready": .connected
        case "needs-auth", "needsAuth", "notLoggedIn": .needsAuth
        case "failed", "error": .failed
        case "pending", "starting": .pending
        default: .unknown
        }
    }
}

/// Ephemeral discovery, never a transcript entry or a context handover.
public struct AgentSetupSnapshot: Sendable, Equatable {
    public let provider: AgentProvider
    public var servers: [AgentSetupServer] = []
    public var commands: [AgentCommand] = []
    public var skills: [String] = []
    public var agents: [String] = []
    public var metadata = AgentProjectMetadata()
    public var serversAvailable = false
    public var commandsAvailable = false
    public init(provider: AgentProvider) { self.provider = provider }

    mutating func initialize(_ value: JSONValue) {
        if let catalog = try? AgentCommandCatalog.claude(value) {
            mergeCommands(catalog); commandsAvailable = true
        }
    }
    mutating func claudeInit(_ value: JSONValue) {
        if let values = value["mcp_servers"]?.arrayValue {
            var seen = Set<String>()
            servers = values.prefix(512).compactMap {
                guard let name = Self.name($0["name"]), seen.insert(name).inserted else { return nil }
                let source = $0["source"]?.stringValue
                return AgentSetupServer(name: name, status: AgentSetupServer.status($0["status"]?.stringValue),
                    source: ["project", "claudeai", "plugin", "user", "local"].contains(source) ? source : nil)
            }.sorted { $0.name < $1.name }
            serversAvailable = true
        }
        if let values = value["slash_commands"]?.arrayValue {
            mergeCommands(values.prefix(1024).compactMap {
                guard let name = Self.name($0) ?? Self.name($0["name"]), !name.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "$" }) else { return nil }
                return AgentCommand(name: name, description: "")
            })
            commandsAvailable = true
        }
        if let values = value["skills"]?.arrayValue { skills = Self.names(values) }
        if let values = value["agents"]?.arrayValue { agents = Self.names(values) }
    }
    private mutating func mergeCommands(_ values: [AgentCommand]) {
        var byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        for value in values {
            if let old = byName[value.name] {
                byName[value.name] = AgentCommand(name: value.name,
                    description: value.description.isEmpty ? old.description : value.description,
                    argumentHint: value.argumentHint ?? old.argumentHint, skillPath: value.skillPath ?? old.skillPath)
            } else { byName[value.name] = value }
        }
        commands = Array(byName.values).sorted { $0.name < $1.name }.prefix(1024).map { $0 }
    }
    private static func names(_ values: [JSONValue]) -> [String] {
        Array(Set(values.prefix(1024).compactMap { name($0) ?? name($0["name"]) })).sorted()
    }
    static func name(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty, text.utf8.count <= 256,
              !text.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return text
    }
}

public struct AgentHookEvent: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable { case running, success, blocked, error, interrupted }
    public let id: String
    public let name: String
    public let event: String
    public let phase: Phase
    public let statusMessage: String?
    public let reason: String?
    public let toolUseID: String?
    public init(id: String, name: String, event: String, phase: Phase,
                statusMessage: String? = nil, reason: String? = nil, toolUseID: String? = nil) {
        self.id = id; self.name = name; self.event = event; self.phase = phase
        self.statusMessage = statusMessage; self.reason = reason; self.toolUseID = toolUseID
    }
}
