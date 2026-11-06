import Foundation

public struct AgentFileMention: Codable, Sendable, Equatable, Identifiable {
    public let path: String
    public let name: String
    public var id: String { path }
    // JSON quoting handles spaces, quotes, backslashes and newlines without
    // treating a filename as shell syntax. No shell participates in selection.
    public var insertion: String { "@" + JSONValue.string(path).jsonString }
    public init(path: String, name: String) { self.path = path; self.name = name }

    public static func codex(_ response: JSONValue, directory: URL) throws -> [Self] {
        guard let files = response["files"]?.arrayValue else { throw AgentFailure.invalidRequest }
        var seen = Set<String>()
        return files.compactMap { file in
            guard file["match_type"]?.stringValue == "file",
                  let root = file["root"]?.stringValue,
                  URL(fileURLWithPath: root).resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path,
                  let path = file["path"]?.stringValue else { return nil }
            let absolutePath = path.hasPrefix("/") ? path : directory.path + "/" + path
            let url = URL(fileURLWithPath: absolutePath).standardizedFileURL
            guard contains(url, in: directory), seen.insert(url.path).inserted else { return nil }
            return Self(path: url.path, name: file["file_name"]?.stringValue ?? url.lastPathComponent)
        }
    }
    public static func localSearch(query: String, directory: URL) throws -> [Self] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw AgentFailure.invalidRequest }
        var matches: [Self] = [], visited = 0
        for case let url as URL in walker {
            try Task.checkCancellation()
            visited += 1
            if visited > 20_000 { break }
            if ["node_modules", "build", "vendor"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true else { walker.skipDescendants(); continue }
            guard values?.isRegularFile == true, contains(url, in: directory),
                  query.isEmpty || url.path.localizedCaseInsensitiveContains(query) else { continue }
            matches.append(Self(path: url.path, name: url.pathComponents.suffix(walker.level).joined(separator: "/")))
            if matches.count == 100 { break }
        }
        return matches.sorted { $0.name < $1.name }
    }
    private static func contains(_ url: URL, in root: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
}

/// Selections survive navigation but never migrate to another chat/provider.
public struct AgentComposerSelection: Sendable, Equatable {
    public var attachments: [AgentAttachment] = []
    public var mentions: [AgentFileMention] = []
    public var command: AgentCommand?
    public init() {}
    public mutating func add(_ attachment: AgentAttachment) throws {
        guard attachments.count < AgentAttachment.maximumCount else { throw AgentAttachmentError.tooMany }
        guard attachments.reduce(attachment.data.count, { $0 + $1.data.count }) <= AgentAttachment.maximumBytes else { throw AgentAttachmentError.tooLarge }
        attachments.append(attachment)
    }
}

public struct AgentComposerSelections: Sendable {
    private struct Key: Hashable { let chat: UUID; let provider: AgentProvider }
    private var values: [Key: AgentComposerSelection] = [:]
    public init() {}
    public subscript(chat: UUID, provider: AgentProvider) -> AgentComposerSelection {
        get { values[Key(chat: chat, provider: provider)] ?? .init() }
        set { values[Key(chat: chat, provider: provider)] = newValue }
    }
}

/// Completion is only a suggestion until the user chooses a row. These tokens
/// are composer syntax, never shell commands or implicit attachment reads.
public struct AgentComposerTrigger: Sendable, Equatable {
    public enum Kind: Sendable { case file, command }
    public let kind: Kind
    public let token: String
    public var query: String { String(token.dropFirst()) }
    public static func detect(_ text: String) -> Self? {
        if text.hasPrefix("/"), !text.contains(where: \.isWhitespace) {
            return .init(kind: .command, token: text)
        }
        guard let token = text.split(whereSeparator: \.isWhitespace).last,
              token.hasPrefix("@"), !token.contains("\""), text.hasSuffix(token) else { return nil }
        return .init(kind: .file, token: String(token))
    }
    public func selecting(_ insertion: String, in text: String) -> String? {
        guard text.hasSuffix(token) else { return nil }
        return String(text.dropLast(token.count)) + insertion + " "
    }
}
