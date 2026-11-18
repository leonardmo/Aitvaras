import Foundation

public struct AgentCommand: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let argumentHint: String?
    public let skillPath: String?
    public let source: String?
    public enum Group: String, Sendable, CaseIterable, Identifiable {
        case project = "Project", user = "User", plugin = "Plugin", builtIn = "Built-in", unknown = "Other"
        public var id: String { rawValue }
        public var initiallyExpanded: Bool { self == .project }
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

/// Display hints only. Never adds commands or changes what the CLI executes.
public struct AgentCommandSources: Sendable, Equatable {
    public var project: Set<String> = []
    public var user: Set<String> = []
    public init() {}

    public func group(for command: AgentCommand) -> AgentCommand.Group {
        if command.group != .unknown { return command.group }
        if project.contains(command.name) { return .project }
        if user.contains(command.name) { return .user }
        if command.name.contains(":") { return .plugin }
        if Self.builtIns.contains(command.name) { return .builtIn }
        return .unknown
    }
    // Exact CLI names only; an unrecognized command remains Other.
    private static let builtIns: Set<String> = [
        "btw", "clear", "compact", "config", "context", "cost", "doctor", "exit",
        "help", "init", "login", "logout", "mcp", "memory", "model", "permissions",
        "plan", "resume", "status", "tasks", "usage", "vim"
    ]
    public static func read(projectDirectory: URL, userDirectory: URL?) -> Self {
        var result = Self()
        result.project = names(in: projectDirectory.appendingPathComponent(".claude"))
        if let userDirectory { result.user = names(in: userDirectory) }
        return result
    }
    private static func names(in root: URL) -> Set<String> {
        let manager = FileManager.default
        func entries(_ name: String) -> [URL] {
            ((try? manager.contentsOfDirectory(at: root.appendingPathComponent(name),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(2048).map { $0 }
        }
        // User skills are often symlinked folders; fileExists follows links.
        let skills = entries("skills").filter {
            manager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        }.map(\.lastPathComponent)
        let commands = entries("commands").filter {
            var directory: ObjCBool = false
            return $0.pathExtension == "md" && manager.fileExists(atPath: $0.path, isDirectory: &directory) && !directory.boolValue
        }.map { $0.deletingPathExtension().lastPathComponent }
        return Set(skills + commands)
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
    public static func search(_ commands: [AgentCommand], query: String) -> [AgentCommand] {
        func rank(_ command: AgentCommand) -> Int {
            if query.isEmpty || command.name.lowercased().hasPrefix(query.lowercased()) { return 0 }
            if command.name.localizedCaseInsensitiveContains(query) { return 1 }
            if command.description.localizedCaseInsensitiveContains(query) { return 2 }
            return 3
        }
        return commands.filter { rank($0) < 3 }.sorted {
            let lhs = rank($0), rhs = rank($1)
            if lhs != rhs { return lhs < rhs }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
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
