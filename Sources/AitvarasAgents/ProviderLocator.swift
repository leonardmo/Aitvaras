import Foundation

public enum ProviderLocator {
    public static func executable(for provider: AgentProvider, environment: [String: String],
                                  overrides: [AgentProvider: URL] = [:]) -> URL? {
        if let explicit = overrides[provider] { return executableFile(explicit) ? explicit : nil }
        guard provider != .local else { return nil }
        let name = provider.rawValue
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = environment["HOME"], home.hasPrefix("/") {
            directories += [home + "/.local/bin", home + "/.claude/local"]
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return directories.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name)
        }.first(where: executableFile)
    }

    private static func executableFile(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return url.isFileURL && url.path.hasPrefix("/")
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
