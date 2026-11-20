import Darwin
import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct GatewayCLIConfigurationTests {
    private static let executable = URL(fileURLWithPath: "/example/Example App/aitvaras-mcp")
    private static let profile = URL(fileURLWithPath: "/example/Profile One")

    @Test func claudeUsesHelpFlagAndPrivateLaunchFile() async throws {
        #expect(try help("claude").contains("--mcp-config <configs...>"))
        let configuration = GatewayCLIConfiguration(executable: Self.executable, stateDirectory: Self.profile)
        let launcher = GatewayLauncher(gateway: configuration, register: { _ in },
            locate: { _, _ in URL(fileURLWithPath: "/example/claude") },
            supervise: { _, args, env in
                try #require(args.count == 7)
                #expect(Array(args.prefix(3)) == ["--model", "haiku", "prompt"])
                #expect(args[3] == "--mcp-config")
                #expect(Array(args.suffix(2)) == ["--", "--mcp-config"])
                #expect(env["CLAUDE_CONFIG_DIR"] == "/example/config")
                let path = args[4]
                let config = JSONValue.parse(try String(contentsOfFile: path, encoding: .utf8))
                let server = config?["mcpServers"]?["aitvaras"]
                #expect(config?["mcpServers"]?.objectValue?.count == 1)
                #expect(server?["type"] == .string("stdio"))
                #expect(server?["command"] == .string(Self.executable.path))
                #expect(server?["env"]?["AITVARAS_STATE_DIR"] == .string(Self.profile.path))
                var info = stat()
                #expect(lstat(path, &info) == 0)
                #expect(info.st_mode & 0o777 == 0o600)
                #expect(lstat(URL(fileURLWithPath: path).deletingLastPathComponent().path, &info) == 0)
                #expect(info.st_mode & 0o777 == 0o700)
                throw SupervisionFailure(path: path)
            })
        do {
            _ = try await launcher.run(arguments: ["claude", "--model", "haiku", "prompt", "--", "--mcp-config"],
                environment: ["CLAUDE_CONFIG_DIR": "/example/config", "AITVARAS_STATE_DIR": Self.profile.path])
            Issue.record("Expected the injected supervisor failure")
        } catch let expected as SupervisionFailure {
            #expect(!FileManager.default.fileExists(atPath: expected.path))
            #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: expected.path).deletingLastPathComponent().path))
        }
        await #expect(throws: GatewayLauncherError.unsupportedConfiguration) {
            try await launcher.run(arguments: ["claude", "--mcp-config=/example/other"], environment: [:])
        }
    }

    @Test func codexUsesHelpOverrideBeforeSubcommandAndQuotesValues() async throws {
        let help = try help("codex")
        #expect(help.contains("-c, --config <key=value>"))
        #expect(help.contains("  app-server "))
        let quoted = URL(fileURLWithPath: #"/example/An "App"\bundle/aitvaras-mcp"#)
        let configuration = GatewayCLIConfiguration(executable: quoted, stateDirectory: Self.profile)
        let launcher = GatewayLauncher(gateway: configuration, register: { _ in },
            locate: { _, _ in URL(fileURLWithPath: "/example/codex") },
            supervise: { _, args, env in
                #expect(args == ["-c",
                    #"mcp_servers.aitvaras={ command = "/example/An \"App\"\\bundle/aitvaras-mcp", args = [], enabled = true, env = { AITVARAS_STATE_DIR = "/example/Profile One" } }"#,
                    "exec", "-c", "model_reasoning_effort=\"low\"", "--", "prompt"])
                #expect(env["CODEX_HOME"] == "/example/config")
                return 37
            })
        #expect(try await launcher.run(arguments: ["codex", "exec", "-c", "model_reasoning_effort=\"low\"", "--", "prompt"],
            environment: ["CODEX_HOME": "/example/config", "AITVARAS_STATE_DIR": Self.profile.path]) == 37)
        await #expect(throws: GatewayLauncherError.unsupportedConfiguration) {
            try await launcher.run(arguments: ["codex", "--config", "mcp_servers.aitvaras.enabled=false"], environment: [:])
        }
    }

    private func help(_ provider: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agents/gateway/\(provider)-help.txt")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private struct SupervisionFailure: Error { let path: String }
}
