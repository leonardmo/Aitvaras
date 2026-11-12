import Foundation
import Testing
@testable import AitvarasAgents

struct ProviderEnvironmentTests {
    @Test func missingUSERBugRegressionPreservesOfficialLoginIdentity() {
        let result = ProviderEnvironment.make(inherited: ["USER": "example-user", "LOGNAME": "example-user",
            "HOME": "/home/user", "LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin", "CUSTOM_TOOL_SETTING": "enabled"])
        #expect(result["USER"] == "example-user")
        #expect(result["LOGNAME"] == "example-user")
        #expect(result["HOME"] == "/home/user")
        #expect(result["CUSTOM_TOOL_SETTING"] == "enabled")
    }

    @Test func stripsCredentialEndpointProfileAndInjectionOverrides() {
        let denied = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
            "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "CODEX_HOME", "CLAUDE_CONFIG_DIR",
            "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
            "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS", "NODE_PATH", "BASH_ENV", "ENV", "ZDOTDIR"]
        let inherited = Dictionary(uniqueKeysWithValues: denied.map { ($0, "synthetic") })
        let result = ProviderEnvironment.make(inherited: inherited,
            overrides: ["OPENAI_API_KEY": "synthetic", "ANTHROPIC_AUTH_TOKEN": "synthetic"])
        #expect(result.isEmpty)
    }

    @Test func profileOverridesRequireExplicitInjectionAndDoNotChangeParent() {
        let inherited = ["CODEX_HOME": "/home/user/default", "CLAUDE_CONFIG_DIR": "/home/user/default", "USER": "example-user"]
        let result = ProviderEnvironment.make(inherited: inherited,
            overrides: ["CODEX_HOME": "/tmp/synthetic-codex", "CLAUDE_CONFIG_DIR": "/tmp/synthetic-claude"])
        #expect(result["CODEX_HOME"] == "/tmp/synthetic-codex")
        #expect(result["CLAUDE_CONFIG_DIR"] == "/tmp/synthetic-claude")
        #expect(inherited["CODEX_HOME"] == "/home/user/default")
    }

    @Test func mergesLoginPATHWithoutLosingInheritedToolLocations() {
        let result = ProviderEnvironment.make(inherited: ["PATH": "/usr/bin:/bin:/opt/example/bin"],
            loginShellPATH: "/opt/tools/bin:/usr/bin:/opt/tools/bin")
        #expect(result["PATH"] == "/opt/tools/bin:/usr/bin:/bin:/opt/example/bin")
        #expect(ProviderEnvironment.make(inherited: ["PATH": "/usr/bin"], loginShellPATH: "")["PATH"] == "/usr/bin")
    }

    @Test func resolvesOnlyLoginShellPATHAndSanitizesBeforeLaunch() async throws {
        let fixture = try AgentExecutableFixture("""
        test "$1" = -lc || exit 1
        test "$USER" = example-user || exit 2
        test -z "${ANTHROPIC_API_KEY+x}" || exit 3
        printf 'shell startup diagnostic\\n'
        printf '\\036/opt/example/bin:/usr/bin\\037'
        """)
        defer { fixture.remove() }
        let result = try await ProviderEnvironment.resolve(inherited: [
            "HOME": fixture.directory.path, "USER": "example-user", "SHELL": fixture.executable.path,
            "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "synthetic"
        ])
        #expect(result["PATH"] == "/opt/example/bin:/usr/bin:/bin")
        #expect(result["USER"] == "example-user")
        #expect(result["ANTHROPIC_API_KEY"] == nil)
    }

    @Test func shellFailureAndMissingPATHMarkerAreObservable() async throws {
        for body in ["exit 9", "printf ordinary-output"] {
            let fixture = try AgentExecutableFixture(body)
            defer { fixture.remove() }
            await #expect(throws: AgentFailure.unknown) {
                _ = try await ProviderEnvironment.resolve(inherited: fixture.environment.merging(["SHELL": fixture.executable.path]) { _, v in v })
            }
        }
    }

    @Test func locatorUsesPATHAndExplicitOverrides() throws {
        let fixture = try AgentExecutableFixture("exit 0", name: "claude")
        defer { fixture.remove() }
        #expect(ProviderLocator.executable(for: .claude, environment: ["PATH": fixture.directory.path]) == fixture.executable)
        #expect(ProviderLocator.executable(for: .codex, environment: [:], overrides: [.codex: fixture.executable]) == fixture.executable)
        #expect(ProviderLocator.executable(for: .codex, environment: ["PATH": fixture.directory.path],
            overrides: [.codex: fixture.directory.appendingPathComponent("missing")]) == nil)
        #expect(ProviderLocator.executable(for: .claude, environment: [:], overrides: [.claude: fixture.directory]) == nil)
        #expect(ProviderLocator.executable(for: .local, environment: [:]) == nil)
    }
}
