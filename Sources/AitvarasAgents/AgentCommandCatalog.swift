import Foundation

public struct AgentCommand: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let description: String
    public let argumentHint: String?
    public let skillPath: String?
    public var id: String { name }
    public var insertion: String { (skillPath == nil ? "/" : "$") + name }

    public init(name: String, description: String, argumentHint: String? = nil, skillPath: String? = nil) {
        self.name = name; self.description = description; self.argumentHint = argumentHint; self.skillPath = skillPath
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

/// No built-in command guesses: an absent catalog is explicitly unavailable.
public enum AgentCommandCatalog {
    public static func claude(_ initialize: JSONValue) throws -> [AgentCommand] {
        guard let commands = initialize["commands"]?.arrayValue else { throw AgentFailure.unsupported }
        return unique(commands.compactMap {
            guard let name = $0["name"]?.stringValue, validName(name) else { return nil }
            return AgentCommand(name: name, description: $0["description"]?.stringValue ?? "",
                                argumentHint: $0["argumentHint"]?.stringValue)
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
