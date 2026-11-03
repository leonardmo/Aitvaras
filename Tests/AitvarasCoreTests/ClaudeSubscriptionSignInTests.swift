import Darwin
import Foundation
import Testing
@testable import AitvarasConnectors

/// Synthetic local executables only. These never authenticate or call a model.
struct ClaudeSubscriptionSignInTests {
    @Test func exactSubscriptionArgumentsAndIsolatedEnvironment() async throws {
        let fixture = try Fixture("""
        test "$1" = auth && test "$2" = login && test "$3" = --claudeai || exit 9
        /usr/bin/env > '\(Fixture.environmentFile)'
        exit 0
        """)
        defer { fixture.remove() }
        let host = fixture.host()
        try await host.signIn(guidance: fixture.guidance(separate: true), onBrowserURL: { _ in })
        let contents = try String(contentsOf: fixture.directory.appendingPathComponent("environment"), encoding: .utf8)
        let keys = Set(contents.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        #expect(keys.isSubset(of: ["HOME", "PATH", "LANG", "NO_COLOR", "TERM", "CLAUDE_CONFIG_DIR", "PWD", "SHLVL", "_"]))
        #expect(contents.contains("HOME=\(fixture.directory.path)"))
        #expect(contents.contains("CLAUDE_CONFIG_DIR=\(fixture.directory.appendingPathComponent("account").path)"))
    }

    @Test func sharedModeOmitsConfigurationOverride() async throws {
        let fixture = try Fixture("test -z \"${CLAUDE_CONFIG_DIR+x}\" || exit 9\nexit 0")
        defer { fixture.remove() }
        try await fixture.host().signIn(guidance: fixture.guidance(), onBrowserURL: { _ in })
    }

    @Test func nonzeroExitIsGenericAndDoesNotLeakOutput() async throws {
        let fixture = try Fixture("echo SYNTHETIC_PRIVATE_DIAGNOSTIC >&2\nexit 7")
        defer { fixture.remove() }
        do {
            try await fixture.host().signIn(guidance: fixture.guidance(), onBrowserURL: { _ in })
            Issue.record("Nonzero sign-in succeeded")
        } catch {
            #expect(error as? ClaudeSubscriptionSignInError == .loginFailed)
            #expect(!error.localizedDescription.contains("SYNTHETIC_PRIVATE_DIAGNOSTIC"))
        }
    }

    @Test func refusesNonSubscriptionAndInjectedEnvironmentBeforeLaunch() async throws {
        let fixture = try Fixture("exit 0")
        defer { fixture.remove() }
        let invalid = ClaudeLoginGuidance(executable: fixture.executable.path, configDirectory: fixture.directory.path,
                                          arguments: ["auth", "login", "--console"], environment: [:])
        await #expect(throws: ClaudeSubscriptionSignInError.invalidGuidance) {
            try await fixture.host().signIn(guidance: invalid, onBrowserURL: { _ in })
        }
        let injected = ClaudeLoginGuidance(executable: fixture.executable.path, configDirectory: fixture.directory.path,
                                           arguments: ["auth", "login", "--claudeai"], environment: ["ANTHROPIC_API_KEY": "synthetic"])
        await #expect(throws: ClaudeSubscriptionSignInError.invalidGuidance) {
            try await fixture.host().signIn(guidance: injected, onBrowserURL: { _ in })
        }
    }

    @Test func onlyAllowlistedCompleteBrowserURLsAndChunkedOutput() async throws {
        let fixture = try Fixture("""
        printf 'https://claude.ai.evil.invalid/oauth/authorize?state=bad\n'
        printf 'https://user@claude.ai/oauth/authorize?state=bad\n'
        printf 'https://claude.ai/oauth/authorize?state=bad#fragment\n'
        printf 'https://claude.ai/oauth/'
        /bin/sleep 0.05
        printf 'authorize?state=synthetic&client_id=synthetic\n'
        printf 'Paste code here if prompted > '
        exit 0
        """)
        defer { fixture.remove() }
        let recorder = URLs()
        try await fixture.host().signIn(guidance: fixture.guidance(), onBrowserURL: { await recorder.append($0) })
        #expect(await recorder.values == ["https://claude.ai/oauth/authorize?state=synthetic&client_id=synthetic"])
    }

    @Test func browserURLParserRejectsUnsafeShapes() {
        let rejected = ["http://claude.ai/oauth/authorize\n", "https://claude.ai:443/oauth/authorize\n",
                        "https://claude.ai/oauth/authorize#code\n", "https://claude.ai/oauth/callback\n",
                        "https://claude.ai/oauth/authorize"]
        for value in rejected {
            // Final token without whitespace is deliberately incomplete.
            #expect(ClaudeSignInOutput.browserURLs(in: value).isEmpty)
        }
        #expect(ClaudeSignInOutput.browserURLs(in: "https://claude.ai/oauth/authorize?state=synthetic\n").count == 1)
    }

    @Test func excessiveOutputStopsTheOwnedCLI() async throws {
        let fixture = try Fixture("/usr/bin/yes SYNTHETIC | /usr/bin/head -c 8192\nexit 0")
        defer { fixture.remove() }
        await #expect(throws: ClaudeSubscriptionSignInError.outputLimit) {
            try await fixture.host(outputLimit: 1024).signIn(guidance: fixture.guidance(), onBrowserURL: { _ in })
        }
    }

    @Test func cancellationAcknowledgesActualCLIExit() async throws {
        let fixture = try Fixture("echo $$ > '\(Fixture.pidFile)'\nexec /bin/sleep 30")
        defer { fixture.remove() }
        let host = fixture.host()
        let task = Task { try await host.signIn(guidance: fixture.guidance(), onBrowserURL: { _ in }) }
        let pid = try await fixture.waitForPID()
        await host.cancel()
        await #expect(throws: ClaudeSubscriptionSignInError.cancelled) { try await task.value }
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func timeoutEscalatesWhenCLIRefusesTermination() async throws {
        let fixture = try Fixture("trap '' TERM\nwhile :; do :; done")
        defer { fixture.remove() }
        await #expect(throws: ClaudeSubscriptionSignInError.timeout) {
            try await fixture.host(timeout: 0.1).signIn(guidance: fixture.guidance(), onBrowserURL: { _ in })
        }
    }

    private actor URLs {
        var values: [String] = []
        func append(_ url: URL) { values.append(url.absoluteString) }
    }
    private struct Fixture: Sendable {
        // Per-test files live next to their private fixture executable, not here;
        // placeholders are replaced while building the synthetic script.
        static let environmentFile = "SYNTHETIC_ENV_FILE"
        static let pidFile = "SYNTHETIC_PID_FILE"
        let directory: URL, executable: URL
        init(_ script: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-sign-in-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            executable = directory.appendingPathComponent("synthetic-claude")
            let source = "#!/bin/sh\n" + script.replacingOccurrences(of: Self.environmentFile, with: directory.appendingPathComponent("environment").path)
                .replacingOccurrences(of: Self.pidFile, with: directory.appendingPathComponent("pid").path)
            try Data(source.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func guidance(separate: Bool = false) -> ClaudeLoginGuidance {
            let config = directory.appendingPathComponent("account").path
            return .init(executable: executable.path, configDirectory: config, arguments: ["auth", "login", "--claudeai"],
                         environment: separate ? ["CLAUDE_CONFIG_DIR": config] : [:])
        }
        func host(timeout: TimeInterval = 5, outputLimit: Int = 262144) -> ClaudeSubscriptionSignIn {
            .init(profileDirectory: directory, homeDirectory: directory, timeout: timeout, outputLimit: outputLimit)
        }
        func waitForPID() async throws -> Int32 {
            for _ in 0..<100 {
                if let contents = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
                   let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw ClaudeSubscriptionSignInError.timeout
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
