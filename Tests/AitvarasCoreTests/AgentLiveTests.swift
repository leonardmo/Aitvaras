import Foundation
import Testing
import AitvarasCore
@testable import AitvarasAgents

private actor LiveAuditLog {
    private(set) var count = 0
    func add(_ event: ActivityEvent) { count += 1 }
}

/// Real CLIs on the real login, cheapest models, a throwaway folder. Run with
/// `make live`, which starts this from a launchd-style environment on purpose:
/// that difference is what broke sign-in before. Spends a little subscription usage.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["AITVARAS_LIVE_AGENTS"] == "1"))
struct AgentLiveTests {
    static let providers: [AgentProvider] = [.claude, .codex]
    static var composerProviders: [AgentProvider] {
        if let value = ProcessInfo.processInfo.environment["AITVARAS_LIVE_PERMISSION_PROVIDER"],
           let provider = AgentProvider(rawValue: value), providers.contains(provider) { return [provider] }
        return providers
    }

    private func backend(_ provider: AgentProvider, overrides: [String: String] = [:],
                         hookExecutable: URL? = nil) async throws -> any AgentBackend {
        let environment = try await ProviderEnvironment.resolve()
        return provider == .claude ? ClaudeBackend(environment: environment, overrides: overrides)
            : CodexBackend(environment: environment, overrides: overrides, hookExecutable: hookExecutable)
    }

    private func model(_ provider: AgentProvider) -> String { provider == .claude ? "haiku" : "gpt-6-luna" }

    private func folder(repository: Bool = true) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/aitvaras-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard repository else { return url }
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

    /// The whole gate on a real CLI: Ask shows exactly one card and the audit has entries.
    @Test(arguments: providers) func coordinatorAsksOnceAndAudits(provider: AgentProvider) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try await backend(provider)
        let native = try await backend.start(.init(directory: directory, model: model(provider), mode: .ask))
        let log = LiveAuditLog()
        let run = AgentActionCoordinator(run: native, mode: .ask, provenance: .init(chatID: UUID()),
                                         audit: { await log.add($0) })
        try await run.send(AgentInput(text: "Run this exact shell command and nothing else: touch made-by-shell.txt"), willDeliver: {})
        var cards = 0
        for try await event in run.events {
            // Hook requests are answered by the coordinator; only pending ones are cards.
            if case .request(let request) = event.kind, await run.pendingRequests().contains(request) {
                cards += 1
                try await run.respond(to: request, with: .allow(updatedInput: nil))
            }
            if case .turnEnded = event.kind { break }
        }
        #expect(cards == 1)
        #expect(await log.count > 0)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("made-by-shell.txt").path))
        try await run.shutdown()
    }

    @Test(.timeLimit(.minutes(2)), arguments: composerProviders, [AgentChatPermissions.auto, .fullAccess, .ask])
    func composerPermissionsRunRoutineCompoundCommandsWithoutCards(
        provider: AgentProvider, permissions: AgentChatPermissions
    ) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try await backend(provider, hookExecutable: provider == .codex ? try livePermissionHelper() : nil)
        let cards = try await composerCommand(backend: backend, model: model(provider), permissions: permissions,
            in: directory, command: "printf 'permission fixture' | cat > permission-fixture.txt && cat permission-fixture.txt",
            allow: permissions == .ask)
        #expect(cards.count == (permissions == .ask ? 1 : 0))
        let marker = directory.appendingPathComponent("permission-fixture.txt")
        #expect(try String(contentsOf: marker, encoding: .utf8) == "permission fixture")
    }

    @Test(.timeLimit(.minutes(2)), arguments: composerProviders)
    func composerAutoDeniesCriticalCommandBeforeExecution(provider: AgentProvider) async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("approval-fixture")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let marker = fixture.appendingPathComponent("marker.txt")
        try Data("disposable test data".utf8).write(to: marker)
        let backend = try await backend(provider, hookExecutable: provider == .codex ? try livePermissionHelper() : nil)
        let cards = try await composerCommand(backend: backend, model: model(provider), permissions: .auto,
            in: directory, command: "printf 'check' | cat && rm -r approval-fixture")
        #expect(cards.count == 1)
        #expect(cards.first?.presentation.reason?.contains("recursively delete") == true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["routine", "approved", "denied", "full", "ask"])
    func composerPermissionsAgainstInstalledOpencode(scenario: String) async throws {
        let root = try folder(repository: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        let outside = root.appendingPathComponent("outside")
        for directory in [project, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let workingDirectory = ["routine", "ask"].contains(scenario) ? project : outside
        let fixture = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", Self.localPermissionModel, workingDirectory.path], currentDirectory: root)
        try fixture.start()
        do {
            var lines = fixture.lines.makeAsyncIterator()
            let port = try #require(try await lines.next().flatMap(UInt16.init))
            let config = OpencodeConfiguration(root: root.appendingPathComponent("profile"),
                                               temporaryDirectory: root.appendingPathComponent("temp"), ollamaPort: port)
            let backend = OpencodeBackend(environment: try await ProviderEnvironment.resolve(),
                                         configuration: config, shellHelper: try livePermissionHelper())
            let permissions: AgentChatPermissions = switch scenario {
            case "full": .fullAccess
            case "ask": .ask
            default: .auto
            }
            let cards = try await composerCommand(backend: backend, model: "fixture", permissions: permissions, in: project,
                command: "printf 'permission fixture' | cat > permission-fixture.txt",
                allow: ["approved", "ask"].contains(scenario), allowInterruption: scenario == "denied")
            let marker = workingDirectory.appendingPathComponent("permission-fixture.txt")
            #expect(cards.count == (["approved", "denied", "ask"].contains(scenario) ? 1 : 0))
            if scenario == "denied" {
                #expect(!FileManager.default.fileExists(atPath: marker.path))
            } else {
                #expect(try String(contentsOf: marker, encoding: .utf8) == "permission fixture")
            }
        } catch {
            try? await fixture.shutdown(grace: .zero)
            throw error
        }
        try await fixture.shutdown(grace: .zero)
    }

    private static let localPermissionModel = #"""
import http.server
import json
import sys

workdir = sys.argv[1]

class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/api/tags":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"models":[{"name":"fixture"}]}')
        else:
            self.send_error(404)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        tools = [tool["function"]["name"] for tool in request.get("tools", [])]
        shell = next((tool for tool in tools if tool in ("shell", "bash")), None)
        tool_returned = any(message["role"] == "tool" for message in request.get("messages", []))
        if shell and not tool_returned:
            args = {"command": "printf 'permission fixture' | cat > permission-fixture.txt",
                    "workdir": workdir, "description": "Write a disposable fixture"}
            delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "call_fixture",
                     "type": "function", "function": {"name": shell, "arguments": json.dumps(args)}}]}
            finish = "tool_calls"
        else:
            delta, finish = {"role": "assistant", "content": "Finished."}, "stop"

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for change, reason in [(delta, None), ({}, finish)]:
            chunk = {"id": "fixture", "object": "chat.completion.chunk", "created": 0, "model": "fixture",
                     "choices": [{"index": 0, "delta": change, "finish_reason": reason}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
print(server.server_port, flush=True)
server.serve_forever()
"""#

    private func livePermissionHelper() throws -> URL {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let override = ProcessInfo.processInfo.environment["AITVARAS_PROVIDER_HOOK_HELPER"].map { URL(fileURLWithPath: $0) }
        let candidate = try #require(([override].compactMap { $0 } + [
            sourceRoot.appendingPathComponent(".build/debug/aitvaras-mcp"),
            sourceRoot.appendingPathComponent(".build/out/Products/Debug/aitvaras-mcp")
        ]).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
        return candidate
    }

    private func composerCommand(backend: any AgentBackend, model: String, permissions: AgentChatPermissions,
                                 in directory: URL, command: String, allow: Bool = false,
                                 allowInterruption: Bool = false) async throws -> [AgentRequest] {
        let chatID = UUID()
        var configuration = AgentSessionConfiguration(directory: directory, model: model, permissions: permissions)
        configuration.gatewayChatID = chatID
        let native = try await backend.start(configuration)
        let log = LiveAuditLog()
        let run = AgentActionCoordinator(run: native, mode: permissions.mode, provenance: .init(chatID: chatID),
                                         permissions: permissions, audit: { await log.add($0) })
        var cards: [AgentRequest] = []
        do {
            try await run.send(.init(text: """
                Use the shell tool. Run this command exactly once:
                \(command)
                Then stop. Use the shell, not a file editing tool.
                """), willDeliver: {})
            for try await event in run.events {
                if case .request(let request) = event.kind, await run.pendingRequests().contains(request) {
                    cards.append(request)
                    try await run.respond(to: request, with: allow ? .allow(updatedInput: nil) : .deny)
                }
                if case .turnEnded(let outcome) = event.kind {
                    let diagnostic = event.failureReport.map { "\($0.category.type).\($0.category.errorCase)" } ?? "unknown category"
                    #expect(outcome == .completed || (allowInterruption && outcome == .interrupted),
                            "Outcome \(String(describing: outcome)); \(diagnostic)")
                    break
                }
            }
            try Task.checkCancellation()
            #expect(await log.count > 0)
        } catch {
            try? await run.shutdown()
            throw error
        }
        try await run.shutdown()
        return cards
    }

    @Test(arguments: providers) func signedOutProfileIsReportedAsSignedOut(provider: AgentProvider) async throws {
        let profile = try folder()
        defer { try? FileManager.default.removeItem(at: profile) }
        let key = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let backend = try await backend(provider, overrides: [key: profile.path])
        #expect(try await backend.status().authentication == .signedOut)
    }
}
