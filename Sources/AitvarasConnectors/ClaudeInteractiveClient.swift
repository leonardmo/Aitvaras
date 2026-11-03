import AitvarasCore
import CryptoKit
import Darwin
import Foundation

public enum ClaudeAccountMode: String, Codable, CaseIterable, Sendable { case shared, separate }

public struct ClaudeInteractiveStatus: Sendable, Codable, Equatable {
    public let authenticated: Bool
    public let models: [CodexInteractiveModel]
    public let usageWindows: [CodexUsageWindow]?
    public let accountLabel: String?
    public let profileNamespace: String
    public init(authenticated: Bool, models: [CodexInteractiveModel], usageWindows: [CodexUsageWindow]? = nil,
                accountLabel: String? = nil, profileNamespace: String) {
        self.authenticated = authenticated; self.models = models; self.usageWindows = usageWindows
        self.accountLabel = accountLabel; self.profileNamespace = profileNamespace
    }
}

public struct ClaudeLoginGuidance: Sendable, Equatable {
    public let executable: String
    public let configDirectory: String
    public let arguments: [String]
    public let environment: [String: String]
    public init(executable: String, configDirectory: String, arguments: [String], environment: [String: String]) {
        self.executable = executable; self.configDirectory = configDirectory
        self.arguments = arguments; self.environment = environment
    }
}

public enum ClaudeInteractiveEvent: Sendable {
    case sessionCreated(String)
    /// Returning successfully must mean the app durably recorded the attempt.
    /// The bridge cannot supply the prompt to the SDK before this acknowledgement.
    case deliveryAttempt
    case turnStarted(String)
    case textDelta(String)
    /// Actual top-level SDK assistant message identity, separate from turn evidence.
    case assistantMessage(id: String, text: String)
    case providerFailure(code: String, messageID: String?)
    case completed(state: String, inputTokens: Int?, outputTokens: Int?)
    case projectFileAccess(tool: String, path: String, bytes: Int)
    case contextUsage(usedTokens: Int?, limitTokens: Int?)
}

public enum ClaudeInteractiveError: String, Error, LocalizedError, Sendable {
    case unavailable, disabled, busy, invalidRequest, unsupported, unsafeProfile, unsafeConfig, insecureCredentials
    case ownership, signInRequired, modelUnavailable, interruptedUnknown, timeout, tooLarge, malformed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The on-demand Claude connection is unavailable. Install the official Claude Code CLI and the optional pinned SDK first."
        case .disabled: "External integrations are disabled for this Aitvaras profile."
        case .busy: "A Claude operation is active, or a previous connection requires recovery."
        case .invalidRequest: "The Claude request or approved project folders are invalid or exceed a safety limit."
        case .unsupported: "Claude Code or the Agent SDK does not match the reviewed version. No conversation was sent."
        case .unsafeProfile: "Claude profile storage failed a safety check."
        case .unsafeConfig: "Claude configuration could not be safely isolated. No conversation was sent."
        case .insecureCredentials: "The official Claude profile contains a plaintext credential fallback. Restore macOS Keychain sign-in and remove the insecure fallback yourself before reconnecting. Aitvaras has not read or deleted it."
        case .ownership: "Only sessions created by this Aitvaras profile with the same Claude account can be continued. Imported native histories remain read-only."
        case .signInRequired: "Sign in through the official Claude Code CLI with a Claude subscription. API keys and alternate providers are not supported."
        case .modelUnavailable: "The selected Claude model or effort is unavailable. No alternative was selected."
        case .interruptedUnknown: "Claude stopped without a confirmed terminal result. Delivery or completion may be unknown; the prompt was not replayed."
        case .timeout: "The Claude operation exceeded its time limit."
        case .tooLarge: "Claude exceeded a bounded protocol or text limit."
        case .malformed: "Claude returned an unsupported protocol response."
        }
    }
}

/// An owned, on-demand official SDK connection. Native transcript discovery is
/// deliberately separate; it never confers permission to resume a native session.
public actor ClaudeInteractiveClient {
    public typealias EventHandler = @Sendable (ClaudeInteractiveEvent) async throws -> Void
    public static let cliVersion = "2.1.300"
    private let accountMode: ClaudeAccountMode
    private let profileDirectory: URL
    private let configDirectory: String
    private let namespace: String
    private let nodePath: String?
    private let executablePath: String?
    private let helperPath: String?
    private var active: ClaudeInteractiveProcess?
    private var preparing: ProjectFileReader.Preparation?
    private var reader: ProjectFileReader?
    private var verifiedNamespace: String?

    public init(accountMode: ClaudeAccountMode, profileDirectory: URL) {
        self.accountMode = accountMode; self.profileDirectory = profileDirectory
        configDirectory = Self.configurationDirectory(accountMode: accountMode, profileDirectory: profileDirectory)
        namespace = Self.profileNamespace(accountMode: accountMode, profileDirectory: profileDirectory)
        nodePath = ClaudeSessionReader.findExecutable("node")
        executablePath = DelegateConnector.findAgent(kind: .claude)?.path
        helperPath = Bundle.module.url(forResource: "claude-interactive", withExtension: "mjs")?.path
    }

    init(accountMode: ClaudeAccountMode, profileDirectory: URL, nodePath: String?, executablePath: String?, helperPath: String?) {
        self.accountMode = accountMode; self.profileDirectory = profileDirectory
        configDirectory = Self.configurationDirectory(accountMode: accountMode, profileDirectory: profileDirectory)
        namespace = Self.profileNamespace(accountMode: accountMode, profileDirectory: profileDirectory)
        self.nodePath = nodePath; self.executablePath = executablePath; self.helperPath = helperPath
    }

    public nonisolated static func configurationDirectory(accountMode: ClaudeAccountMode, profileDirectory: URL) -> String {
        let url: URL
        if accountMode == .separate { url = profileDirectory.appendingPathComponent("claude-account", isDirectory: true) }
        else { url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true) }
        // Shared means the official default profile, never an inherited override.
        return canonicalClaudeDirectory(url).path
    }

    public nonisolated static func profileNamespace(accountMode: ClaudeAccountMode, profileDirectory: URL) -> String {
        let path = configurationDirectory(accountMode: accountMode, profileDirectory: profileDirectory)
        return SHA256.hash(data: Data("\(accountMode.rawValue)\n\(path)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func loginGuidance(accountMode: ClaudeAccountMode, profileDirectory: URL) -> ClaudeLoginGuidance? {
        guard let executable = DelegateConnector.findAgent(kind: .claude)?.path else { return nil }
        let config = configurationDirectory(accountMode: accountMode, profileDirectory: profileDirectory)
        return ClaudeLoginGuidance(executable: executable, configDirectory: config,
                                   arguments: ["auth", "login", "--claudeai"], environment: accountMode == .separate ? ["CLAUDE_CONFIG_DIR": config] : [:])
    }

    public func status() async throws -> ClaudeInteractiveStatus {
        guard let status = try await perform(Request(operation: "status"), onEvent: { _ in }).status else { throw ClaudeInteractiveError.malformed }
        verifiedNamespace = status.authenticated ? status.profileNamespace : nil
        return status
    }

    public func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String,
                    projectRoots: [String] = [], userMessageID: UUID? = nil, onEvent: @escaping EventHandler) async throws {
        guard sessionID.map({ UUID(uuidString: $0) != nil }) ?? true,
              context.utf8.count <= 65536, prompt.utf8.count <= 65536,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isEmpty, model.utf8.count <= 256,
              effort.map({ ["low", "medium", "high", "xhigh", "max"].contains($0) }) ?? true,
              ![context, model, prompt, effort ?? ""].contains(where: { $0.contains("\0") }) else { throw ClaudeInteractiveError.invalidRequest }
        if verifiedNamespace == nil { _ = try await status() }
        guard verifiedNamespace != nil else { throw ClaudeInteractiveError.signInRequired }
        _ = try await perform(Request(operation: "run", sessionID: sessionID, context: context, model: model,
                                      effort: effort, prompt: prompt, userMessageID: userMessageID?.uuidString,
                                      projectRoots: projectRoots), onEvent: onEvent)
    }

    /// Foreground, read-only observation of an already-owned native session.
    /// Account metadata is freshly verified; history never implies completion.
    public func readOwnedSession(sessionID: String, expectedProfileNamespace: String) async throws -> ClaudeOwnedHistorySnapshot {
        guard UUID(uuidString: sessionID) != nil, expectedProfileNamespace.count == 64,
              expectedProfileNamespace.allSatisfy({ $0.isHexDigit }) else { throw ClaudeInteractiveError.invalidRequest }
        guard let snapshot = try await perform(Request(operation: "history", sessionID: sessionID,
                                                        expectedNamespace: expectedProfileNamespace), onEvent: { _ in }).snapshot else {
            throw ClaudeInteractiveError.malformed
        }
        return snapshot
    }

    public func interrupt() async {
        preparing?.cancel(); reader?.cancel()
        active?.send(Command(command: "interrupt"))
    }
    public func shutdown() async {
        preparing?.cancel(); reader?.cancel()
        if let active { await active.stop() }
    }

    private struct Request: Encodable {
        var operation: String
        var sessionID: String?; var context: String?; var model: String?; var effort: String?; var prompt: String?
        var userMessageID: String?
        var projectRoots: [String] = []
        var projectRootCount = 0
        var accountMode: String?; var profileDirectory: String?; var configDirectory: String?; var profileNamespace: String?
        var expectedNamespace: String?
        var executable: String?; var home: String?
        var sdkDirectory = ClaudeSessionReader.sdkDirectory.path
    }
    private struct Command: Encodable { var command: String; var id: String? }
    private struct ToolReply: Encodable { var command = "projectToolResult"; var id: String; var success: Bool; var text: String }
    private struct Arguments: Decodable { var root: Int; var path: String }
    private struct Frame: Decodable {
        var event: String; var id: String?; var text: String?; var state: String?; var code: String?
        var inputTokens: Int?; var outputTokens: Int?; var result: ClaudeInteractiveStatus?
        var tool: String?; var arguments: Arguments?
        var usedTokens: Int?; var limitTokens: Int?
        var snapshot: ClaudeOwnedHistorySnapshot?; var role: String?; var append: Bool?
    }
    private struct Response { var status: ClaudeInteractiveStatus?; var snapshot: ClaudeOwnedHistorySnapshot? }

    private func perform(_ input: Request, onEvent: @escaping EventHandler) async throws -> Response {
        try Task.checkCancellation()
        guard !AitvarasPaths.externalIntegrationsDisabled, ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] != "1" else { throw ClaudeInteractiveError.disabled }
        guard active == nil, preparing == nil else { throw ClaudeInteractiveError.busy }
        guard let nodePath, let executablePath, let helperPath else { throw ClaudeInteractiveError.unavailable }
        let preparation = ProjectFileReader.Preparation(roots: input.projectRoots)
        preparing = preparation
        let project: ProjectFileReader
        do { project = try await preparation.prepare(); try preparation.ensureActive(); preparing = nil; try Task.checkCancellation() }
        catch { preparing = nil; if Task.isCancelled { throw CancellationError() }; throw ClaudeInteractiveError.invalidRequest }
        reader = project
        defer { project.cancel(); reader = nil }
        var request = input
        request.accountMode = accountMode.rawValue; request.profileDirectory = canonicalClaudeDirectory(profileDirectory).path
        request.configDirectory = configDirectory; request.profileNamespace = namespace
        request.expectedNamespace = input.expectedNamespace ?? verifiedNamespace
        request.executable = executablePath; request.home = FileManager.default.homeDirectoryForCurrentUser.path
        request.projectRootCount = input.projectRoots.count
        request.projectRoots = [] // Paths stay exclusively in the pinned native broker.
        let running = ClaudeInteractiveProcess(); active = running
        var deliveryAttempted = false, terminal = false, providerAcknowledged = false
        var sessionBound = input.sessionID != nil
        var lease: ClaudeOperationLease?
        defer { lease?.release() }
        do {
            lease = try ClaudeOperationLease(profileDirectory: profileDirectory, namespace: namespace)
            let frames = try running.start(node: nodePath, helper: helperPath, request: JSONEncoder().encode(request),
                                           outputLimit: input.operation == "history" ? 64 * 1024 * 1024 : 2 * 1024 * 1024,
                                           timeout: input.operation == "run" ? 900 : 43)
            let result = try await withTaskCancellationHandler {
                var result = Response(), receivedResult = false
                var historyRows: [(id: String, role: String, fragments: [String])] = []
                var historyIDs = Set<String>(), historyBytes = 0
                for try await data in frames {
                    try Task.checkCancellation()
                    let frame: Frame
                    do {
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
                        frame = try decoder.decode(Frame.self, from: data)
                    } catch { throw ClaudeInteractiveError.malformed }
                    switch frame.event {
                    case "sessionCreated":
                        guard input.operation == "run", !sessionBound, let id = frame.id, UUID(uuidString: id) != nil else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.sessionCreated(id)); try Task.checkCancellation()
                        sessionBound = true
                        running.send(Command(command: "ackSession", id: id))
                    case "deliveryAttempt":
                        guard input.operation == "run", sessionBound, !deliveryAttempted, let id = frame.id, UUID(uuidString: id) != nil else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.deliveryAttempt); try Task.checkCancellation()
                        deliveryAttempted = true
                        running.send(Command(command: "ackDelivery", id: id))
                    case "turnStarted":
                        guard deliveryAttempted, !providerAcknowledged, !terminal, let id = frame.id, UUID(uuidString: id) != nil else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.turnStarted(id))
                        providerAcknowledged = true
                    case "textDelta":
                        guard providerAcknowledged, !terminal, let text = frame.text else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.textDelta(text))
                    case "assistantMessage":
                        guard providerAcknowledged, !terminal, let id = frame.id, UUID(uuidString: id) != nil,
                              let text = frame.text, !text.isEmpty else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.assistantMessage(id: id, text: text))
                    case "completed":
                        guard providerAcknowledged, !terminal, let state = frame.state, ["completed", "failed"].contains(state),
                              (frame.inputTokens ?? 0) >= 0, (frame.outputTokens ?? 0) >= 0 else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.completed(state: state, inputTokens: frame.inputTokens, outputTokens: frame.outputTokens)); terminal = true
                    case "projectToolRequest":
                        guard deliveryAttempted, !terminal, let id = frame.id, UUID(uuidString: id) != nil,
                              let tool = frame.tool, let arguments = frame.arguments,
                              ["aitvaras_project_list", "aitvaras_project_read"].contains(tool) else { throw ClaudeInteractiveError.malformed }
                        do {
                            let value = try await project.executeAsync(tool: tool, root: arguments.root, path: arguments.path)
                            try Task.checkCancellation(); try project.ensureActive()
                            try await onEvent(.projectFileAccess(tool: tool, path: value.path, bytes: value.bytes))
                            try Task.checkCancellation(); try project.ensureActive()
                            running.send(ToolReply(id: id, success: true, text: value.text))
                        } catch is ProjectFileReader.Denied {
                            running.send(ToolReply(id: id, success: false, text: "Project file access denied or limit reached."))
                        }
                    case "providerFailure":
                        guard input.operation == "run", deliveryAttempted, providerAcknowledged, !terminal,
                              let code = frame.code, ["authenticationRequired", "usageLimit", "providerRejected"].contains(code) else { throw ClaudeInteractiveError.malformed }
                        guard frame.id.map({ UUID(uuidString: $0) != nil }) ?? true else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.providerFailure(code: code, messageID: frame.id))
                    case "contextUsage":
                        guard (frame.usedTokens ?? 0) >= 0, frame.limitTokens.map({ $0 > 0 }) ?? true else { throw ClaudeInteractiveError.malformed }
                        try await onEvent(.contextUsage(usedTokens: frame.usedTokens, limitTokens: frame.limitTokens))
                    case "result":
                        guard !receivedResult, input.operation == "status" || input.operation == "history" || terminal else { throw ClaudeInteractiveError.malformed }
                        if let status = frame.result {
                            guard status.profileNamespace.count == 64, status.profileNamespace.allSatisfy({ $0.isHexDigit }), status.models.count <= 100,
                                  status.models.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.displayName.utf8.count <= 256 }) else { throw ClaudeInteractiveError.malformed }
                        }
                        if input.operation == "history" {
                            guard let snapshot = result.snapshot else { throw ClaudeInteractiveError.malformed }
                            result.snapshot = ClaudeOwnedHistorySnapshot(sessionID: snapshot.sessionID, profileNamespace: snapshot.profileNamespace,
                                messages: historyRows.map { ClaudeOwnedHistoryMessage(id: $0.id, role: $0.role, text: $0.fragments.joined()) },
                                complete: true, observedAt: snapshot.observedAt)
                        }
                        receivedResult = true; result.status = frame.result
                    case "history":
                        guard input.operation == "history", result.snapshot == nil, let snapshot = frame.snapshot,
                              snapshot.sessionID == input.sessionID, snapshot.profileNamespace == input.expectedNamespace,
                              snapshot.complete, snapshot.messages.isEmpty, snapshot.observedAt.timeIntervalSince1970.isFinite else { throw ClaudeInteractiveError.malformed }
                        result.snapshot = snapshot
                    case "historyMessage":
                        guard input.operation == "history", !receivedResult, result.snapshot != nil,
                              let id = frame.id, UUID(uuidString: id) != nil, let role = frame.role, ["user", "assistant"].contains(role),
                              let text = frame.text, !text.isEmpty, let append = frame.append else { throw ClaudeInteractiveError.malformed }
                        historyBytes += text.utf8.count
                        guard historyBytes <= 10_000_000 else { throw ClaudeInteractiveError.tooLarge }
                        if append {
                            guard let last = historyRows.last, last.id == id, last.role == role else { throw ClaudeInteractiveError.malformed }
                            historyRows[historyRows.count - 1].fragments.append(text)
                        } else {
                            guard historyIDs.insert(id).inserted, historyIDs.count <= 5000 else { throw ClaudeInteractiveError.malformed }
                            historyRows.append((id: id, role: role, fragments: [text]))
                        }
                    case "error": throw ClaudeInteractiveError(rawValue: frame.code ?? "") ?? .unavailable
                    default: throw ClaudeInteractiveError.malformed
                    }
                }
                guard receivedResult, running.successfulExit else { throw ClaudeInteractiveError.unavailable }
                return result
            } onCancel: { running.requestStop(); Task { await running.stop() } }
            await running.stop(); active = nil
            return result
        } catch {
            await running.stop(); active = nil
            if deliveryAttempted && !terminal { throw ClaudeInteractiveError.interruptedUnknown }
            if running.didTimeOut { throw ClaudeInteractiveError.timeout }
            throw error
        }
    }
}

/// A persistent empty file carries only an OS lock, never PID state. No stale
/// file is deleted, and crashes release the lease without permitting replay.
/// Foundation preserves macOS firmlink aliases such as /var on some releases.
/// Resolve the existing prefix with POSIX realpath before the no-follow walk;
/// nonexistent suffix components remain subject to openat(O_NOFOLLOW).
private func canonicalClaudeDirectory(_ url: URL) -> URL {
    var prefix = url.standardizedFileURL, suffix: [String] = []
    while true {
        if let resolved = realpath(prefix.path, nil) {
            defer { free(resolved) }
            return suffix.reversed().reduce(URL(fileURLWithPath: String(cString: resolved), isDirectory: true)) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
        }
        guard prefix.path != "/" else { return url.standardizedFileURL }
        suffix.append(prefix.lastPathComponent)
        prefix.deleteLastPathComponent()
    }
}

final class ClaudeOperationLease {
    private var descriptor: Int32 = -1
    init(profileDirectory: URL, namespace: String) throws {
        guard namespace.count == 64, namespace.allSatisfy({ $0.isHexDigit }) else { throw ClaudeInteractiveError.unsafeProfile }
        let path = canonicalClaudeDirectory(profileDirectory).appendingPathComponent("claude-live/\(namespace)").path
        let parts = path.split(separator: "/").map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty, !path.contains("\0") else { throw ClaudeInteractiveError.unsafeProfile }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ClaudeInteractiveError.unsafeProfile }
        defer { close(directory) }
        for part in parts {
            if mkdirat(directory, part, 0o700) != 0 && errno != EEXIST { throw ClaudeInteractiveError.unsafeProfile }
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw ClaudeInteractiveError.unsafeProfile }
            close(directory); directory = next
        }
        var metadata = stat()
        guard fstat(directory, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o022 == 0 else { throw ClaudeInteractiveError.unsafeProfile }
        let fd = openat(directory, "operation.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ClaudeInteractiveError.unsafeProfile }
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0 else {
            close(fd); throw ClaudeInteractiveError.unsafeProfile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ClaudeInteractiveError.busy }
        descriptor = fd
    }
    func release() { guard descriptor >= 0 else { return }; _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    deinit { release() }
}

/// Process-group IDs are registered off-actor and removed immediately on child
/// exit. Stop signals only this operation's children; no global process matching.
private final class ClaudeInteractiveProcess: @unchecked Sendable {
    private struct Lifecycle: Decodable { var event: String; var pid: Int32? }
    private let process = Process(), input = Pipe(), output = Pipe(), lock = NSLock()
    private let terminated = DispatchSemaphore(value: 0)
    private var groups = Set<Int32>()
    private var launched = false, stopping = false
    private var exitStatus: Int32?
    private var timedOut = false
    private var stopTask: Task<Void, Never>?
    var successfulExit: Bool { lock.withLock { exitStatus == 0 } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func start(node: String, helper: String, request: Data, outputLimit: Int, timeout: TimeInterval) throws -> AsyncThrowingStream<Data, Error> {
        process.executableURL = URL(fileURLWithPath: node); process.arguments = [helper]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }; self.lock.withLock { self.exitStatus = process.terminationStatus }; self.terminated.signal()
        }
        try process.run(); lock.withLock { launched = true }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            let expired = self.lock.withLock {
                guard self.exitStatus == nil, !self.stopping else { return false }
                self.timedOut = true; return true
            }
            if expired { Task { await self.stop() } }
        }
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            DispatchQueue(label: "aitvaras.claude.text-pipe").async { [self] in
                var buffer = Data(), total = 0, scratch = [UInt8](repeating: 0, count: 16384)
                do {
                    while true {
                        let count = scratch.withUnsafeMutableBytes { Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                        if count < 0 { if errno == EINTR { continue }; throw ClaudeInteractiveError.unavailable }
                        if count == 0 { break }
                        buffer.append(contentsOf: scratch.prefix(count)); total += count
                        guard total <= outputLimit, buffer.count <= 262144 else { throw ClaudeInteractiveError.tooLarge }
                        while let end = buffer.firstIndex(of: 10) {
                            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                            let frame = try JSONDecoder().decode(Lifecycle.self, from: line)
                            if frame.event == "processGroup" || frame.event == "processGroupEnded" {
                                guard let pid = frame.pid, pid > 1 else { throw ClaudeInteractiveError.malformed }
                                lock.withLock { if frame.event == "processGroup" { _ = groups.insert(pid) } else { _ = groups.remove(pid) } }
                            } else if case .dropped = continuation.yield(line) { throw ClaudeInteractiveError.tooLarge }
                        }
                    }
                    guard buffer.isEmpty, terminated.wait(timeout: .now() + 2) == .success else { throw ClaudeInteractiveError.malformed }
                    continuation.finish()
                } catch { continuation.finish(throwing: (error as? ClaudeInteractiveError) ?? .malformed); requestStop() }
            }
        }
        var data = request; data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { requestStop(); throw ClaudeInteractiveError.unavailable }
        return stream
    }
    func send<T: Encodable>(_ command: T) {
        lock.withLock {
            guard !stopping, let encoded = try? JSONEncoder().encode(command) else { return }
            var data = encoded; data.append(10); try? input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func requestStop() {
        lock.withLock {
            guard !stopping else { return }; stopping = true
            try? input.fileHandleForWriting.close()
            if launched && process.isRunning { process.terminate() }
        }
    }
    func stop() async {
        let task = lock.withLock {
            if let stopTask { return stopTask }
            let task = Task.detached { [self] in
                requestStop()
                // Successful metadata calls already reached EOF and reaped their
                // child. Only genuinely live cleanup needs the bounded grace.
                for _ in 0..<36 {
                    if lock.withLock({ exitStatus != nil && groups.isEmpty }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                for pid in lock.withLock({ groups }) { _ = Darwin.kill(-pid, SIGKILL) }
                if lock.withLock({ launched }) && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                try? output.fileHandleForReading.close()
            }
            stopTask = task; return task
        }
        await task.value
    }
}
