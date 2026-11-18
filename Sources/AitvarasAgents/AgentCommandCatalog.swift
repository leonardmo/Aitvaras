import Foundation

public struct AgentCommand: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let argumentHint: String?
    public let skillPath: String?
    public let source: String?
    public enum Group: String, Sendable, CaseIterable, Identifiable {
        case project = "Project", user = "User", plugin = "Plugin", builtIn = "Built-in", unknown = "Source not reported"
        public var id: String { rawValue }
    }
    public var group: Group {
        switch source?.lowercased() {
        case "project", "repo": .project
        case "user", "local": .user
        case "plugin": .plugin
        case "builtin", "built-in", "built_in": .builtIn
        default: .unknown
        }
    }
    public var id: String { name }
    public var insertion: String { (skillPath == nil ? "/" : "$") + name }

    public init(name: String, description: String, argumentHint: String? = nil, skillPath: String? = nil, source: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.skillPath = skillPath; self.source = source
    }
    public func argumentPlaceholder(in text: String) -> String? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) == insertion,
              let argumentHint, !argumentHint.isEmpty else { return nil }
        return AgentTranscriptContent.bounded(argumentHint, limit: 512)
    }
}

/// A catalog belongs to a composer, project directory and setup revision.
/// Equality also guards responses from cancelled, older project requests.
public struct AgentCommandCatalogContext: Sendable, Hashable {
    public let ownerID: UUID
    public let projectID: UUID?
    public let directory: URL?
    public let provider: AgentProvider
    public let revision: UUID
    public init(ownerID: UUID, projectID: UUID?, directory: URL?, provider: AgentProvider, revision: UUID) {
        self.ownerID = ownerID; self.projectID = projectID; self.directory = directory
        self.provider = provider; self.revision = revision
    }
}

/// Provider commands come only from discovery. Aitvaras-owned conversation
/// commands are added explicitly by the composer, never guessed from a repo.
public enum AgentCommandCatalog {
    public static let sideQuestion = AgentCommand(name: "btw", description: "Ask a side question without adding it to the chat", argumentHint: "<question>", source: "builtin")
    public static func withConversationCommands(_ values: [AgentCommand]) -> [AgentCommand] {
        unique(values.filter { $0.name != "btw" } + [sideQuestion])
    }
    public static func claude(_ initialize: JSONValue) throws -> [AgentCommand] {
        guard let commands = initialize["commands"]?.arrayValue else { throw AgentFailure.unsupported }
        return unique(commands.compactMap {
            guard let name = $0["name"]?.stringValue, validName(name) else { return nil }
            return AgentCommand(name: name, description: $0["description"]?.stringValue ?? "",
                                argumentHint: $0["argumentHint"]?.stringValue, source: $0["source"]?.stringValue ?? $0["scope"]?.stringValue)
        })
    }
    public static func codex(_ response: JSONValue, directory: URL) throws -> [AgentCommand] {
        guard let entries = response["data"]?.arrayValue else { throw AgentFailure.invalidRequest }
        let cwd = directory.resolvingSymlinksInPath().standardizedFileURL.path
        return unique(entries.filter {
            $0["cwd"]?.stringValue.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == cwd } == true
        }.flatMap { entry in
            (entry["skills"]?.arrayValue ?? []).compactMap { skill -> AgentCommand? in
                guard skill["enabled"]?.boolValue == true,
                      let name = skill["name"]?.stringValue, validName(name),
                      let path = skill["path"]?.stringValue, path.hasPrefix("/") else { return nil }
                return AgentCommand(name: name,
                    description: skill["interface"]?["shortDescription"]?.stringValue
                        ?? skill["shortDescription"]?.stringValue ?? skill["description"]?.stringValue ?? "",
                    skillPath: path)
            }
        })
    }
    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "/" || $0 == "$" })
    }
    private static func unique(_ values: [AgentCommand]) -> [AgentCommand] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }
}
