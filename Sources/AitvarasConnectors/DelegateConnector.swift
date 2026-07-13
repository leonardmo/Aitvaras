import Foundation
import AitvarasCore

/// Delegation to CLI coding agents (D14): runs Claude Code (`claude -p …`)
/// or, as fallback, Codex CLI (`codex exec …`) headlessly on the user's
/// existing subscription logins. Always `confirmable` — delegated tasks
/// consume quota and can modify repositories, so D13 requires a card.
public actor DelegateConnector: Connector {
    public nonisolated let id = "delegate"
    public nonisolated let displayName = "Delegate (CLI agents)"

    /// 30 minutes — deep tasks are fine, runaway sessions are not.
    static let timeout: TimeInterval = 30 * 60
    static let outputLimit = 8000
    static let maxTurns = 40

    public init() {}

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "run_coding_task",
            description: "Delegate a coding or deep-research task to a CLI agent (Claude Code or Codex) running headlessly in a working directory. Takes minutes; consumes subscription quota; may modify files in the directory.",
            parametersJSON: """
            {"type":"object","properties":{"prompt":{"type":"string","description":"Complete, self-contained task description for the agent"},"workingDirectory":{"type":"string","description":"Absolute path of the directory (usually a repo) to work in"}},"required":["prompt","workingDirectory"]}
            """,
            risk: .confirmable
        )
    ]

    // MARK: - CLI discovery

    public enum AgentKind: String, Sendable {
        case claude
        case codex
    }

    public static func candidateBinaries() -> [(path: String, kind: AgentKind)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("/usr/local/bin/claude", .claude),
            ("/opt/homebrew/bin/claude", .claude),
            ("\(home)/.claude/local/claude", .claude),
            ("/usr/local/bin/codex", .codex),
            ("/opt/homebrew/bin/codex", .codex)
        ]
    }

    public static func findAgent() -> (path: String, kind: AgentKind)? {
        candidateBinaries().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func health() async -> ConnectorHealth {
        guard Self.findAgent() != nil else {
            return .error(message: "No CLI agent found. Install Claude Code (claude) or Codex CLI (codex) and log in once.")
        }
        return .ready
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == "run_coding_task" else {
            throw ConnectorError("Delegate connector has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        let prompt = try args.requiredString("prompt")
        let workingDirectory = try args.requiredString("workingDirectory")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConnectorError("Working directory does not exist: \(workingDirectory)")
        }
        guard let agent = Self.findAgent() else {
            throw ConnectorError("No CLI agent found — install Claude Code or Codex CLI.")
        }

        let arguments: [String]
        switch agent.kind {
        case .claude:
            arguments = ["-p", prompt, "--output-format", "json", "--max-turns", String(Self.maxTurns)]
        case .codex:
            arguments = ["exec", prompt]
        }

        let result = try await ProcessRunner.run(
            executable: agent.path,
            arguments: arguments,
            currentDirectory: workingDirectory,
            timeout: Self.timeout)

        if result.timedOut {
            throw ConnectorError("Delegated task exceeded the 30-minute limit and was terminated. Partial output:\n\(truncated(result.stdout, limit: 2000))")
        }
        guard result.exitCode == 0 else {
            throw ConnectorError("\(agent.kind.rawValue) exited with code \(result.exitCode): \(truncated(result.stderr.isEmpty ? result.stdout : result.stderr, limit: 1000))")
        }

        switch agent.kind {
        case .claude:
            return truncated(Self.extractClaudeResult(result.stdout), limit: Self.outputLimit)
        case .codex:
            return truncated(result.stdout, limit: Self.outputLimit)
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // pull-only connector
    }

    /// `claude -p --output-format json` prints one JSON object with the
    /// final answer in "result". Falls back to raw output on parse failure.
    static func extractClaudeResult(_ stdout: String) -> String {
        guard
            let data = stdout.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? String
        else {
            return stdout
        }
        return result
    }
}

// MARK: - Process execution

/// Runs an external process with a timeout, capturing stdout/stderr.
/// Foundation.Process and Pipe are not Sendable; the box confines them and
/// takes the @unchecked responsibility (terminate() is documented safe to
/// call from any thread).
enum ProcessRunner {
    struct Output: Sendable {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        private let lock = NSLock()
        private var _timedOut = false

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return _timedOut
        }

        func terminateForTimeout() {
            lock.lock()
            _timedOut = true
            lock.unlock()
            if process.isRunning { process.terminate() }
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        timeout: TimeInterval
    ) async throws -> Output {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        if let currentDirectory {
            box.process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        box.process.standardOutput = box.stdout
        box.process.standardError = box.stderr
        box.process.standardInput = FileHandle.nullDevice

        try box.process.run()

        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            box.terminateForTimeout()
        }

        // Drain pipes off the cooperative pool — readDataToEndOfFile blocks.
        let (outData, errData): (Data, Data) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let out = box.stdout.fileHandleForReading.readDataToEndOfFile()
                let err = box.stderr.fileHandleForReading.readDataToEndOfFile()
                box.process.waitUntilExit()
                cont.resume(returning: (out, err))
            }
        }
        watchdog.cancel()

        return Output(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: box.process.terminationStatus,
            timedOut: box.timedOut)
    }
}
