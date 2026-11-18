import Foundation
import Darwin

public struct AgentHookMetadata: Sendable, Equatable {
    public let event: String
    public let matcher: String?
    public let statusMessage: String?
    public let source: String
}
public struct AgentRuleMetadata: Sendable, Equatable {
    public let name: String
    public let paths: [String]
}
public struct AgentProjectMetadata: Sendable, Equatable {
    public var commandSources = AgentCommandSources()
    public var hooks: [AgentHookMetadata] = []
    public var rules: [AgentRuleMetadata] = []
    public var warnings: [String] = []
    public init() {}

    func statusMessage(event: String, tool: String) -> String? {
        let messages = hooks.filter { $0.event == event && Self.matches($0.matcher, tool: tool) }.compactMap(\.statusMessage)
        let unique = Array(Set(messages)).sorted()
        return unique.isEmpty ? nil : AgentHookText.safe(unique.joined(separator: " · "), limit: 512)
    }
    // Display only. Native hooks still perform the authoritative matching.
    private static func matches(_ matcher: String?, tool: String) -> Bool {
        guard let matcher, !matcher.isEmpty, matcher != "*" else { return true }
        guard let expression = try? NSRegularExpression(pattern: matcher) else { return false }
        return expression.firstMatch(in: tool, range: NSRange(tool.startIndex..., in: tool)) != nil
    }
}

enum AgentHookText {
    static func safe(_ text: String, secrets: [String] = [], limit: Int = 2048) -> String {
        var result = text
        for secret in Set(secrets).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let replacements = [
            (#"(?i)\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+"#, "[redacted credential]"),
            (#"(?i)(\b(?:[\w-]*(?:token|secret|password|api[_-]?key)[\w-]*|authorization|cookie|set-cookie)\b[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "$1[redacted]"),
            (#"https?://[^\s<>\"']+"#, "[redacted URL]"),
            (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[redacted credential]")]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        result = result.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
            .map(String.init).joined()
        return AgentTranscriptContent.bounded(result, limit: limit)
    }
    static func sensitiveKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return ["token", "secret", "password", "key", "authorization", "cookie"].contains { key.contains($0) }
    }
}

/// Secrets used for redaction remain private to this actor, never in metadata snapshots.
public actor AgentProjectMetadataReader {
    private let projectDirectory: URL
    private let userDirectory: URL?
    private var secrets: [String]
    public init(projectDirectory: URL, userDirectory: URL? = nil, environment: [String: String] = [:]) {
        self.projectDirectory = projectDirectory; self.userDirectory = userDirectory
        secrets = environment.filter { AgentHookText.sensitiveKey($0.key) }.map(\.value)
    }
    public func read() -> AgentProjectMetadata {
        var metadata = AgentProjectMetadata()
        metadata.commandSources = .read(projectDirectory: projectDirectory, userDirectory: userDirectory)
        var files: [(URL, String)] = []
        if let userDirectory { files.append((userDirectory.appendingPathComponent("settings.json"), "User settings")) }
        var projectInfo = stat()
        let projectRoot = projectDirectory.appendingPathComponent(".claude")
        let projectAvailable = lstat(projectRoot.path, &projectInfo) == 0 && projectInfo.st_mode & S_IFMT == S_IFDIR
        if projectAvailable {
            files += [(projectRoot.appendingPathComponent("settings.json"), ".claude/settings.json"),
                      (projectRoot.appendingPathComponent("settings.local.json"), ".claude/settings.local.json")]
        }
        var settings: [(JSONValue, String)] = []
        for (url, source) in files {
            do {
                guard let text = try Self.text(url, limit: 262_144) else { continue }
                guard let root = JSONValue.parse(text), root.objectValue != nil else { throw AgentMCPError.invalidConfiguration }
                if let env = root["env"]?.objectValue {
                    secrets += env.filter { AgentHookText.sensitiveKey($0.key) }.compactMap { $0.value.stringValue }
                }
                settings.append((root, source))
            } catch { metadata.warnings.append("Hook settings could not be read.") }
        }
        for (root, source) in settings {
            for (event, entries) in (root["hooks"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                for entry in (entries.arrayValue ?? []).prefix(128) {
                    // Inventory metadata for every hook type without retaining
                    // executable commands, prompts or request bodies.
                    for hook in (entry["hooks"]?.arrayValue ?? []).prefix(128) where hook["type"]?.stringValue != nil {
                        guard metadata.hooks.count < 512 else { break }
                        metadata.hooks.append(.init(event: redact(event, limit: 128),
                            matcher: entry["matcher"]?.stringValue.map { redact($0, limit: 512) },
                            statusMessage: hook["statusMessage"]?.stringValue.map { redact($0, limit: 512) }, source: source))
                    }
                }
            }
        }
        let rules = projectDirectory.appendingPathComponent(".claude/rules", isDirectory: true)
        var budget = 512
        do { if projectAvailable { try Self.rules(in: rules, relative: "", metadata: &metadata, secrets: secrets, depth: 0, budget: &budget) } }
        catch { metadata.warnings.append("Rules inventory could not be read.") }
        metadata.warnings = Array(Set(metadata.warnings)).sorted()
        return metadata
    }
    public func redact(_ text: String, limit: Int = 2048) -> String { AgentHookText.safe(text, secrets: secrets, limit: limit) }

    private static func text(_ url: URL, limit: Int) throws -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw AgentMCPError.invalidConfiguration
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit,
              let text = String(data: data, encoding: .utf8) else { throw AgentMCPError.invalidConfiguration }
        return text
    }
    private static func rules(in directory: URL, relative: String, metadata: inout AgentProjectMetadata,
                              secrets: [String], depth: Int, budget: inout Int) throws {
        guard depth < 8, metadata.rules.count < 256, budget > 0 else { return }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return }; throw AgentMCPError.invalidConfiguration
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AgentMCPError.invalidConfiguration }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(256) {
            guard budget > 0 else { return }; budget -= 1
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { continue }
            let name = relative + file.lastPathComponent
            if values.isDirectory == true {
                try rules(in: file, relative: name + "/", metadata: &metadata, secrets: secrets, depth: depth + 1, budget: &budget)
            } else if file.pathExtension == "md", let text = try text(file, limit: 65_536), metadata.rules.count < 256 {
                metadata.rules.append(.init(name: AgentHookText.safe(name, secrets: secrets, limit: 512), paths: paths(text).map { AgentHookText.safe($0, secrets: secrets, limit: 512) }))
            }
        }
    }
    private static func paths(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        var paths: [String] = [], reading = false
        for line in lines[1..<end] {
            if line.hasPrefix("paths:") {
                reading = true
                let tail = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let array = JSONValue.parse(tail)?.arrayValue { paths += array.compactMap(\.stringValue) }
                else if tail.hasPrefix("["), tail.hasSuffix("]") {
                    paths += tail.dropFirst().dropLast().split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                }
                else if !tail.isEmpty { paths.append(tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
            } else if reading {
                let line = line.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("- ") else { reading = false; continue }
                paths.append(String(line.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return Array(paths.prefix(128))
    }
}
