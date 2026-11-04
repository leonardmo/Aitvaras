import Foundation

public enum ProviderEnvironment {
    private static let denied: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_API_KEY_HELPER", "CLAUDE_CONFIG_DIR", "OPENAI_API_KEY", "OPENAI_BASE_URL",
        "OPENAI_API_BASE", "OPENAI_ORG_ID", "OPENAI_ORGANIZATION", "OPENAI_PROJECT_ID", "CODEX_API_KEY",
        "CODEX_HOME", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE", "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_API_KEY",
        "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL",
        "NODE_OPTIONS", "NODE_PATH", "BASH_ENV", "ENV", "ZDOTDIR"
    ]

    /// Overrides are an explicit injection seam. Credential/endpoint overrides
    /// remain forbidden; only the two profile locations may bypass the denylist.
    public static func make(inherited: [String: String] = ProcessInfo.processInfo.environment,
                            loginShellPATH: String? = nil, overrides: [String: String] = [:]) -> [String: String] {
        var environment = inherited
        if let loginShellPATH, !loginShellPATH.isEmpty {
            let paths = (loginShellPATH + ":" + (inherited["PATH"] ?? "")).split(separator: ":").map(String.init)
            var seen = Set<String>()
            environment["PATH"] = paths.filter { seen.insert($0).inserted }.joined(separator: ":")
        }
        environment.merge(overrides) { _, explicit in explicit }
        for key in environment.keys where denied.contains(key) || key.hasPrefix("DYLD_") || key.hasPrefix("LD_") {
            if ["CODEX_HOME", "CLAUDE_CONFIG_DIR"].contains(key), overrides[key] != nil { continue }
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// Read only PATH from shell startup; never import its credentials or stdout
    /// diagnostics. Call off the UI path and reuse the result for provider children.
    public static func resolve(inherited: [String: String] = ProcessInfo.processInfo.environment,
                               overrides: [String: String] = [:]) async throws -> [String: String] {
        let environment = make(inherited: inherited, overrides: overrides)
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/") else { throw AgentFailure.invalidRequest }
        let result = try await OneShotProcess.run(executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "/usr/bin/printf '\\036%s\\037' \"$PATH\""],
            environment: environment, timeout: .seconds(5))
        guard !result.timedOut, result.exitCode == 0,
              let begin = result.stdout.lastIndex(of: "\u{1e}"),
              let end = result.stdout[begin...].firstIndex(of: "\u{1f}") else { throw AgentFailure.unknown }
        let path = String(result.stdout[result.stdout.index(after: begin)..<end])
        return make(inherited: inherited, loginShellPATH: path, overrides: overrides)
    }
}
