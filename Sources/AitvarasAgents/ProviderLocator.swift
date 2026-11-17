import Foundation

public enum ProviderLocator {
    public static func executable(for provider: AgentProvider, environment: [String: String],
                                  overrides: [AgentProvider: URL] = [:]) -> URL? {
        if let explicit = overrides[provider] { return executableFile(explicit) ? explicit : nil }
        let name = provider == .local ? "opencode" : provider.rawValue
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = environment["HOME"], home.hasPrefix("/") {
            directories += [home + "/.local/bin", home + "/.claude/local"]
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let onPath = directories.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name)
        }.first(where: executableFile)
        return onPath ?? bundled(provider).first(where: executableFile)
    }

    /// The desktop apps ship their CLI inside the bundle and don't put it on PATH.
    private static func bundled(_ provider: AgentProvider) -> [URL] {
        guard provider == .codex else { return [] }
        return ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                "/Applications/Codex.app/Contents/Resources/codex"].map { URL(fileURLWithPath: $0) }
    }

    private static func executableFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && url.path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
