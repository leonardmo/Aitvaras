import Foundation
import AitvarasCore
import AitvarasStore

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
    static let healthCacheInterval: TimeInterval = 5 * 60

    private var cachedHealth: (value: ConnectorHealth, checkedAt: Date)?
    private let cloudService: CloudAgentService
    private let selectionOverride: CloudModelSelection?

    public init(
        stores: Stores? = nil,
        selectionOverride: CloudModelSelection? = nil,
        reporter: ActivityReporter? = nil
    ) {
        self.cloudService = CloudAgentService(stores: stores, reporter: reporter)
        self.selectionOverride = selectionOverride
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "run_coding_task",
            description: "Delegate a coding or deep-research task to the Claude Code or Codex provider selected in Settings. Runs headlessly in a working directory. Takes minutes, sends the task and files read there to that provider, consumes subscription quota, and may modify files in the directory.",
            parametersJSON: """
            {"type":"object","properties":{"prompt":{"type":"string","description":"Complete, self-contained task description for the agent"},"workingDirectory":{"type":"string","description":"Absolute path of the directory (usually a repo) to work in"}},"required":["prompt","workingDirectory"],"additionalProperties":false}
            """,
            risk: .confirmable
        )
    ]

    // MARK: - CLI discovery

    public enum AgentKind: String, Sendable, CaseIterable {
        case claude
        case codex

        public var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex CLI"
            }
        }

        public var loginCommand: String {
            switch self {
            case .claude: "claude auth login"
            case .codex: "codex login"
            }
        }
    }

    public struct Agent: Sendable, Equatable {
        public var path: String
        public var kind: AgentKind

        public init(path: String, kind: AgentKind) {
            self.path = path
            self.kind = kind
        }
    }

    public static func candidateBinaries() -> [Agent] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Agent(path: "/opt/homebrew/bin/claude", kind: .claude),
            Agent(path: "/usr/local/bin/claude", kind: .claude),
            Agent(path: "\(home)/.local/bin/claude", kind: .claude),
            Agent(path: "\(home)/.claude/local/claude", kind: .claude),
            Agent(
                path: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                kind: .codex),
            Agent(
                path: "/Applications/ChatGPT.app/Contents/Resources/codex",
                kind: .codex),
            Agent(path: "/opt/homebrew/bin/codex", kind: .codex),
            Agent(path: "/usr/local/bin/codex", kind: .codex),
            Agent(path: "\(home)/.local/bin/codex", kind: .codex)
        ]
    }

    public static func installedAgents(kind: AgentKind? = nil) -> [Agent] {
        var seen = Set<String>()
        return candidateBinaries().filter { candidate in
            (kind == nil || candidate.kind == kind)
                && seen.insert(URL(fileURLWithPath: candidate.path)
                    .standardizedFileURL.path).inserted
                && FileManager.default.isExecutableFile(atPath: candidate.path)
        }
    }

    public static func findAgent(kind: AgentKind? = nil) -> Agent? {
        installedAgents(kind: kind).first
    }

    public func health() async -> ConnectorHealth {
        let selection = selectionOverride
            ?? CloudAgentSettings.selection(for: .delegation)
        if selection == .local {
            return .error(
                message: "Cloud delegation is disabled in Models → Cloud agents.")
        }
        if let cachedHealth {
            let interval = cachedHealth.value == .ready
                ? Self.healthCacheInterval : 15
            if Date().timeIntervalSince(cachedHealth.checkedAt) < interval {
                return cachedHealth.value
            }
        }
        let agents = Self.installedAgents()
        let health: ConnectorHealth
        if agents.isEmpty {
            health = .error(
                message: "No CLI agent found. Install Claude Code or Codex CLI, then sign in once.")
        } else if await Self.firstAuthenticatedAgent(in: agents) != nil {
            health = .ready
        } else {
            let commands = agents.map(\.kind).uniqued()
                .map(\.loginCommand).joined(separator: " or ")
            health = .needsAuthentication(
                message: "CLI installed but signed out. Run \(commands) in Terminal.")
        }
        cachedHealth = (health, Date())
        return health
    }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard toolName == "run_coding_task" else {
            throw ConnectorError("Delegate connector has no tool named '\(toolName)'.")
        }
        let args = try ToolArgs(json: argumentsJSON)
        try args.requireOnly(["prompt", "workingDirectory"])
        let prompt = try args.requiredString("prompt")
        let workingDirectory = try args.requiredString("workingDirectory")
        guard !prompt.isEmpty, prompt.count <= 24_000 else {
            throw ConnectorError("Delegated task descriptions must be 1–24,000 characters.")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConnectorError("Working directory does not exist: \(workingDirectory)")
        }
        guard (workingDirectory as NSString).isAbsolutePath else {
            throw ConnectorError("The delegated working directory must be an absolute path.")
        }

        let selection = selectionOverride
            ?? CloudAgentSettings.selection(for: .delegation)
        let scopedPrompt = """
        Work only inside the current working directory. Do not inspect or \
        modify files outside it. Before changing repository files, read and \
        follow AGENTS.md and CLAUDE.md in the working directory when present.

        Delegated task:
        \(prompt)
        """
        let response = try await cloudService.run(.init(
            feature: .delegation,
            selection: selection,
            prompt: scopedPrompt,
            access: .workspaceWrite(workingDirectory),
            maxTurns: Self.maxTurns,
            timeout: Self.timeout))
        return truncated(response.text, limit: Self.outputLimit)
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }   // pull-only connector
    }

    /// `claude -p --output-format json` prints one JSON object with the
    /// final answer in "result". Falls back to raw output on parse failure.
    struct ClaudeEnvelope: Sendable, Equatable {
        var result: String
        var isError: Bool
        var permissionDenials: Int
        var inputTokens: Int?
        var outputTokens: Int?
        var reportedCostUSD: Double?
    }

    static func claudeEnvelope(_ stdout: String) throws -> ClaudeEnvelope {
        guard
            let data = stdout.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let result = root["result"] as? String
        else {
            throw ConnectorError("Claude Code returned an invalid JSON result.")
        }
        let usage = root["usage"] as? [String: Any]
        return ClaudeEnvelope(
            result: result,
            isError: root["is_error"] as? Bool ?? false,
            permissionDenials: (root["permission_denials"] as? [Any])?.count ?? 0,
            inputTokens: Self.intValue(
                usage?["input_tokens"] ?? usage?["inputTokens"]),
            outputTokens: Self.intValue(
                usage?["output_tokens"] ?? usage?["outputTokens"]),
            reportedCostUSD: Self.doubleValue(
                root["total_cost_usd"] ?? root["totalCostUSD"]))
    }

    static func extractClaudeResult(_ stdout: String) -> String {
        (try? claudeEnvelope(stdout).result) ?? stdout
    }

    static func delegationArguments(for kind: AgentKind) -> [String] {
        CloudAgentService.arguments(
            for: kind,
            request: .init(
                feature: .delegation,
                selection: kind == .claude ? .claude : .codex,
                prompt: "test",
                access: .workspaceWrite("/tmp"),
                maxTurns: maxTurns,
                timeout: timeout))
    }

    static func authenticationArguments(for kind: AgentKind) -> [String] {
        switch kind {
        case .claude: ["auth", "status"]
        case .codex: ["login", "status"]
        }
    }

    static func isAuthenticated(_ agent: Agent) async -> Bool {
        do {
            let result = try await ProcessRunner.run(
                executable: agent.path,
                arguments: authenticationArguments(for: agent.kind),
                currentDirectory: nil,
                timeout: 10,
                environment: sanitizedEnvironment())
            guard !result.timedOut, result.exitCode == 0 else { return false }
            switch agent.kind {
            case .claude:
                guard let data = result.stdout.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return false }
                return root["loggedIn"] as? Bool == true
            case .codex:
                return (result.stdout + result.stderr)
                    .localizedCaseInsensitiveContains("logged in")
            }
        } catch {
            return false
        }
    }

    static func firstAuthenticatedAgent(in agents: [Agent]) async -> Agent? {
        for agent in agents {
            if await isAuthenticated(agent) { return agent }
        }
        return nil
    }

    static func sanitizedEnvironment() -> [String: String] {
        [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            // Claude Code's macOS credential lookup uses the login name to
            // locate its Keychain item. Keep this non-secret identity field,
            // while still excluding inherited API tokens and connector env.
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Process execution

/// Runs an external process with a timeout, capturing stdout/stderr.
/// Foundation.Process and Pipe are not Sendable; the box confines them and
/// takes the @unchecked responsibility (terminate() is documented safe to
/// call from any thread).
public enum ProcessRunner {
    /// Keep draining beyond this point so the child cannot block, but do not
    /// let a noisy CLI grow the assistant process without bound.
    public static let captureLimit = 1_048_576

    public struct Output: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var timedOut: Bool
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        private let lock = NSLock()
        private var _timedOut = false
        private var terminationRequested = false

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return _timedOut
        }

        func terminateForTimeout() {
            lock.lock()
            _timedOut = true
            let shouldTerminate = !terminationRequested
            terminationRequested = true
            lock.unlock()
            if shouldTerminate, process.isRunning { process.terminate() }
        }

        func terminateForCancellation() {
            lock.lock()
            let shouldTerminate = !terminationRequested
            terminationRequested = true
            lock.unlock()
            if shouldTerminate, process.isRunning { process.terminate() }
        }

        func forceTerminateIfRunning() {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String?,
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        standardInput: Data? = nil
    ) async throws -> Output {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        if let currentDirectory {
            box.process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }
        if let environment { box.process.environment = environment }
        box.process.standardOutput = box.stdout
        box.process.standardError = box.stderr
        box.process.standardInput = standardInput == nil ? FileHandle.nullDevice : box.stdin

        try box.process.run()
        if let standardInput {
            // Feed prompts out-of-band so private task text is not exposed in
            // the process argument list. Keep this off the caller actor; a
            // child that reads slowly can temporarily fill the pipe.
            // Dedicated threads avoid root-queue starvation when several
            // blocking pipe readers and waitUntilExit are active together.
            // This was reproducible in serialized live CLI tests: the sole
            // utility worker entered waitUntilExit before stdin was written.
            Thread.detachNewThread {
                do {
                    try box.stdin.fileHandleForWriting.write(contentsOf: standardInput)
                    try box.stdin.fileHandleForWriting.close()
                } catch {
                    try? box.stdin.fileHandleForWriting.close()
                }
            }
        }

        return try await withTaskCancellationHandler {
            let watchdog = Task.detached {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                box.terminateForTimeout()
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                box.forceTerminateIfRunning()
            }

            // A child can block forever when either pipe fills. Drain stdout
            // and stderr concurrently, and reap the process on a third worker.
            async let outData = Self.readToEnd(
                box.stdout.fileHandleForReading, captureLimit: Self.captureLimit)
            async let errData = Self.readToEnd(
                box.stderr.fileHandleForReading, captureLimit: Self.captureLimit)
            async let finished: Void = Self.waitUntilExit(box.process)
            let (out, err, _) = await (outData, errData, finished)
            watchdog.cancel()
            try Task.checkCancellation()

            return Output(
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self),
                exitCode: box.process.terminationStatus,
                timedOut: box.timedOut)
        } onCancel: {
            box.terminateForCancellation()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                box.forceTerminateIfRunning()
            }
        }
    }

    private static func readToEnd(_ handle: FileHandle, captureLimit: Int) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                var captured = Data()
                while true {
                    let chunk = handle.readData(ofLength: 64 * 1024)
                    guard !chunk.isEmpty else { break }
                    let remaining = captureLimit - captured.count
                    if remaining > 0 {
                        captured.append(chunk.prefix(remaining))
                    }
                }
                continuation.resume(returning: captured)
            }
        }
    }

    private static func waitUntilExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
