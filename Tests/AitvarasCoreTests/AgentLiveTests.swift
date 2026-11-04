import Foundation
import Testing
@testable import AitvarasAgents

/// Real CLIs on the real login, cheapest models, a throwaway folder. Run with
/// `make live`, which starts this from a launchd-style environment on purpose:
/// that difference is what broke sign-in before. Spends a little subscription usage.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AITVARAS_LIVE_AGENTS"] == "1"))
struct AgentLiveTests {
    static let providers: [AgentProvider] = [.claude, .codex]

    private func backend(_ provider: AgentProvider, overrides: [String: String] = [:]) async throws -> any AgentBackend {
        let environment = try await ProviderEnvironment.resolve()
        return provider == .claude ? ClaudeBackend(environment: environment, overrides: overrides)
            : CodexBackend(environment: environment, overrides: overrides)
    }

    private func model(_ provider: AgentProvider) -> String { provider == .claude ? "haiku" : "gpt-6-luna" }

    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/aitvaras-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q"]
        git.currentDirectoryURL = url
        try git.run(); git.waitUntilExit()
        return url
    }

    private func text(_ events: [AgentEvent]) -> String {
        events.compactMap { event -> String? in
            switch event.kind {
            case .textDelta(let delta): delta
            case .message(_, let role, let text) where role == "assistant": text
            default: nil
            }
        }.joined()
    }

    private func session(_ events: [AgentEvent]) -> AgentSessionID? {
        events.lazy.compactMap { event -> AgentSessionID? in
            if case .sessionStarted(let id) = event.kind { return id }
            return event.scope.session
        }.first
    }

    @Test(arguments: providers) func signedInWithSubscriptionAndHasModels(provider: AgentProvider) async throws {
        let backend = try await backend(provider)
        let status = try await backend.status()
        #expect(status.installed)
        #expect(status.authentication == .subscription)
        #expect(try await backend.models().isEmpty == false)
    }

    @Test(arguments: providers) func twoTurnsThenResumeInANewProcess(provider: AgentProvider) async throws {
        let backend = try await backend(provider), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await backend.start(.init(directory: directory, model: model(provider), mode: .plan))
        try await run.send(AgentInput(text: "The code word is heron. Reply with only: ok"), willDeliver: {})
        let first = try await collectTurn(run)
        #expect(first.last?.kind == .turnEnded(.completed))
        #expect(first.contains { $0.kind == .delivery(.acknowledged) })
        #expect(text(first).lowercased().contains("ok"))
        try await run.send(AgentInput(text: "Reply with only: pong"), willDeliver: {})
        let second = try await collectTurn(run)
        #expect(second.last?.kind == .turnEnded(.completed))
        #expect(text(second).lowercased().contains("pong"))
        let id = try #require(session(first))
        try await run.shutdown()

        let resumed = try await backend.start(.init(directory: directory, resume: id, model: model(provider), mode: .plan))
        try await resumed.send(AgentInput(text: "What was the code word? Reply with only that word."), willDeliver: {})
        let third = try await collectTurn(resumed)
        #expect(third.last?.kind == .turnEnded(.completed))
        #expect(text(third).lowercased().contains("heron"))
        try await resumed.shutdown()
    }

    private func shellTurn(_ provider: AgentProvider, allow: Bool, in directory: URL) async throws -> [AgentEvent] {
        let backend = try await backend(provider)
        let run = try await backend.start(.init(directory: directory, model: model(provider), mode: .ask))
        try await run.send(AgentInput(text: "Run this exact shell command and nothing else: touch made-by-shell.txt"), willDeliver: {})
        let events = try await collectTurn(run, answer: { request in
            switch request.kind {
            case .preToolUse, .postToolUse: .continueHook
            default: allow ? .allow(updatedInput: nil) : .deny
            }
        })
        try await run.shutdown()
        return events
    }

    private func askedPermission(_ events: [AgentEvent]) -> Bool {
        events.contains { event in
            guard case .request(let request) = event.kind else { return false }
            switch request.kind {
            case .permission, .permissions: return true
            default: return false
            }
        }
    }

    @Test(arguments: providers) func shellCommandApproved(provider: AgentProvider) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await shellTurn(provider, allow: true, in: directory)
        #expect(askedPermission(events))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("made-by-shell.txt").path))
    }

    @Test(arguments: providers) func shellCommandDeniedDoesNotRun(provider: AgentProvider) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = try await shellTurn(provider, allow: false, in: directory)
        #expect(askedPermission(events))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("made-by-shell.txt").path))
    }

    @Test(arguments: providers) func stopEndsTheTurn(provider: AgentProvider) async throws {
        let backend = try await backend(provider), directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = try await backend.start(.init(directory: directory, model: model(provider), mode: .plan))
        try await run.send(AgentInput(text: "Write a 400 word story about a dragon."), willDeliver: {})
        let events = try await collectTurn(run, interrupt: true)
        #expect(events.last?.kind == .turnEnded(.interrupted))
        try await run.shutdown()
    }

    @Test(arguments: providers) func signedOutProfileIsReportedAsSignedOut(provider: AgentProvider) async throws {
        let profile = try folder()
        defer { try? FileManager.default.removeItem(at: profile) }
        let key = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let backend = try await backend(provider, overrides: [key: profile.path])
        #expect(try await backend.status().authentication == .signedOut)
    }
}
