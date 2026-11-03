import AitvarasCore
import Foundation
import Darwin

public struct CodexInteractiveModel: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let efforts: [String]
    public init(id: String, displayName: String, efforts: [String]) {
        self.id = id; self.displayName = displayName; self.efforts = efforts
    }
}

public struct CodexUsageWindow: Sendable, Codable, Equatable {
    public let usedPercent: Double
    public let durationMinutes: Int?
    public let resetsAt: Date?
    public init(usedPercent: Double, durationMinutes: Int? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent; self.durationMinutes = durationMinutes; self.resetsAt = resetsAt
    }
    private enum CodingKeys: String, CodingKey { case usedPercent, durationMinutes, resetsAt }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        durationMinutes = try container.decodeIfPresent(Int.self, forKey: .durationMinutes)
        let seconds = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
        guard usedPercent.isFinite, (0...100).contains(usedPercent), durationMinutes.map({ $0 > 0 }) ?? true,
              seconds.map({ $0.isFinite && $0 > 0 && $0 <= 8_640_000_000_000 }) ?? true else { throw CodexInteractiveError.malformed }
        resetsAt = seconds.map { Date(timeIntervalSince1970: $0) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(resetsAt?.timeIntervalSince1970, forKey: .resetsAt)
    }
}

public struct CodexInteractiveStatus: Sendable, Codable, Equatable {
    public let authenticated: Bool
    public let models: [CodexInteractiveModel]
    public let usageSummary: String
    public let usageWindows: [CodexUsageWindow]?
    public init(authenticated: Bool, models: [CodexInteractiveModel], usageSummary: String, usageWindows: [CodexUsageWindow]? = nil) {
        self.authenticated = authenticated; self.models = models; self.usageSummary = usageSummary
        self.usageWindows = usageWindows
    }
}

public enum CodexInteractiveEvent: Sendable {
    case threadCreated(String)
    /// The prompt may leave once the app acknowledges this. Anything that
    /// fails before it was provably never delivered.
    case deliveryAttempt
    case turnStarted(String)
    case textDelta(String)
    case completed(state: String, inputTokens: Int?, outputTokens: Int?)
    case loginURL(String)
    case loginCompleted(Bool)
    case projectFileAccess(tool: String, path: String, bytes: Int)
    case contextUsage(usedTokens: Int?, limitTokens: Int?)
}

public enum CodexInteractiveError: Error, LocalizedError, Sendable {
    case unavailable, disabled, busy, invalidRequest, unsupported, unsafeProfile, unsafeConfig
    case ownership, signInRequired, modelUnavailable, interruptedUnknown, timeout, tooLarge, malformed
    case keychainUnavailable, signInFailed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The dedicated Codex connection stopped."
        case .disabled: "External integrations are disabled for this profile."
        case .busy: "A Codex operation is already active, or an earlier operation needs recovery."
        case .invalidRequest: "The Codex request or approved project folders are invalid or exceed a safety limit."
        case .unsupported: "This Codex installation does not match the reviewed isolated protocol."
        case .unsafeProfile: "Codex's local storage failed a compatibility check. The operation stopped; see the saved message status before trying again."
        case .unsafeConfig: "Codex configuration or requirements failed the isolation safety check."
        case .ownership: "Only sessions created by this Aitvaras profile can be continued."
        case .signInRequired: "Sign in with ChatGPT in this dedicated Aitvaras profile first."
        case .keychainUnavailable: "Browser sign-in finished, but macOS Keychain could not save the account. No plain-text credential fallback was used. Retry sign-in after checking Keychain access."
        case .signInFailed: "Codex sign-in was not completed. No conversation was sent."
        case .modelUnavailable: "The selected model or effort is unavailable. No alternative was selected."
        case .interruptedUnknown: "Codex stopped without a confirmed terminal event. The turn outcome is unknown."
        case .timeout: "Codex exceeded the operation time limit."
        case .tooLarge: "Codex exceeded the bounded text or protocol output limit."
        case .malformed: "Codex returned an unsupported protocol response."
        }
    }
}

/// One on-demand child per operation, never an idle background app-server.
/// The helper owns a detached app-server process group. This owner retains that
/// group ID too, so helper failure/cancellation cannot leave descendants behind.
public actor CodexInteractiveClient {
    public typealias EventHandler = @Sendable (CodexInteractiveEvent) async throws -> Void
    private let profileDirectory: URL
    private let nodePath: String?
    private let codexPath: String?
    private let helperPath: String?
    private var active: InteractiveProcess?
    private var projectReader: ProjectFileReader?
    private var preparing: ProjectFileReader.Preparation?

    public init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
        nodePath = CodexSessionReader.findNode()
        codexPath = DelegateConnector.findAgent(kind: .codex)?.path
        helperPath = Bundle.module.url(forResource: "codex-interactive", withExtension: "mjs")?.path
    }

    init(profileDirectory: URL, nodePath: String?, codexPath: String?, helperPath: String?) {
        self.profileDirectory = profileDirectory; self.nodePath = nodePath
        self.codexPath = codexPath; self.helperPath = helperPath
    }

    public func status() async throws -> CodexInteractiveStatus {
        guard let result = try await perform(Request(operation: "status"), onEvent: { _ in }) else {
            throw CodexInteractiveError.malformed
        }
        return result
    }

    public func login(onEvent: @escaping EventHandler) async throws {
        _ = try await perform(Request(operation: "login"), onEvent: onEvent)
    }

    public func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String,
                    projectRoots: [String] = [],
                    onEvent: @escaping EventHandler) async throws {
        guard sessionID.map(Self.validID) ?? true, context.utf8.count <= 65_536,
              prompt.utf8.count <= 65_536, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.isEmpty, model.utf8.count <= 256, (effort?.utf8.count ?? 0) <= 32,
              ![context, model, prompt, effort ?? ""].contains(where: { $0.contains("\0") }) else {
            throw CodexInteractiveError.invalidRequest
        }
        _ = try await perform(Request(operation: "run", sessionID: sessionID, context: context,
                                      model: model, effort: effort, prompt: prompt, projectRoots: projectRoots), onEvent: onEvent)
    }

    public func interrupt() async {
        preparing?.cancel()
        projectReader?.cancel()
        // Before a turn exists the helper cancels setup/login instead of sending.
        active?.send(Command(command: "interrupt"))
    }

    public func shutdown() async {
        preparing?.cancel()
        projectReader?.cancel()
        guard let running = active else { return }
        await running.stop()
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,127}\\z", options: .regularExpression) != nil
    }

    private struct Request: Encodable {
        var operation: String
        var sessionID: String? = nil
        var context: String? = nil
        var model: String? = nil
        var effort: String? = nil
        var prompt: String? = nil
        var projectRoots: [String] = []
        var executable: String? = nil
        var profileDirectory: String? = nil
    }
    private struct Command: Encodable { var command: String; var id: String? = nil }
    private struct ToolReply: Encodable { var command = "projectToolResult"; let id: String; let success: Bool; let text: String }
    private struct ToolArguments: Decodable { let root: Int; let path: String }
    private struct Frame: Decodable {
        var event: String
        var id: String?; var text: String?; var state: String?; var url: String?; var success: Bool?
        var inputTokens: Int?; var outputTokens: Int?; var code: String?; var pid: Int32?
        var result: CodexInteractiveStatus?
        var tool: String?; var arguments: ToolArguments?
        var usedTokens: Int?; var limitTokens: Int?
    }

    private func perform(_ input: Request, onEvent: @escaping EventHandler) async throws -> CodexInteractiveStatus? {
        try Task.checkCancellation()
        guard !AitvarasPaths.externalIntegrationsDisabled,
              ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] != "1" else { throw CodexInteractiveError.disabled }
        guard active == nil, preparing == nil else { throw CodexInteractiveError.busy }
        guard let nodePath, let codexPath, let helperPath else { throw CodexInteractiveError.unavailable }
        let preparation = ProjectFileReader.Preparation(roots: input.projectRoots)
        preparing = preparation
        let reader: ProjectFileReader
        do {
            reader = try await preparation.prepare()
            try preparation.ensureActive()
            preparing = nil
            try Task.checkCancellation()
        } catch {
            preparing = nil
            if Task.isCancelled { throw CancellationError() }
            if let denied = error as? ProjectFileReader.Denied {
                switch denied {
                case .cancelled: throw CodexInteractiveError.interruptedUnknown
                case .limit: throw CodexInteractiveError.timeout
                case .access: break
                }
            }
            throw CodexInteractiveError.invalidRequest
        }
        projectReader = reader
        defer { reader.cancel(); projectReader = nil }
        var request = input; request.executable = codexPath
        // Resolve OS aliases before the helper rejects symlinks within owned paths.
        request.profileDirectory = profileDirectory.resolvingSymlinksInPath().path
        let running = InteractiveProcess()
        active = running
        do {
            let frames = try running.start(node: nodePath, helper: helperPath, request: JSONEncoder().encode(request))
            let result = try await withTaskCancellationHandler {
                var result: CodexInteractiveStatus?, receivedResult = false
                for try await data in frames {
                    try Task.checkCancellation()
                    let frame: Frame
                    do { frame = try JSONDecoder().decode(Frame.self, from: data) }
                    catch { throw CodexInteractiveError.malformed }
                    switch frame.event {
                    case "contextUsage":
                        guard (frame.usedTokens ?? 0) >= 0, frame.limitTokens.map({ $0 > 0 }) ?? true else { throw CodexInteractiveError.malformed }
                        try await onEvent(.contextUsage(usedTokens: frame.usedTokens, limitTokens: frame.limitTokens))
                    case "projectToolRequest":
                        guard input.operation == "run", !input.projectRoots.isEmpty,
                              let id = frame.id, Self.validID(id), let tool = frame.tool,
                              ["aitvaras_project_list", "aitvaras_project_read"].contains(tool),
                              let args = frame.arguments else { throw CodexInteractiveError.malformed }
                        do {
                            let value = try await reader.executeAsync(tool: tool, root: args.root, path: args.path)
                            try Task.checkCancellation()
                            try await onEvent(.projectFileAccess(tool: tool, path: value.path, bytes: value.bytes))
                            try Task.checkCancellation()
                            try reader.ensureActive()
                            running.send(ToolReply(id: id, success: true, text: value.text))
                        } catch is ProjectFileReader.Denied {
                            running.send(ToolReply(id: id, success: false, text: "Project file access denied or limit reached."))
                        }
                    case "threadCreated":
                        guard let id = frame.id, Self.validID(id) else { throw CodexInteractiveError.malformed }
                        try await onEvent(.threadCreated(id))
                        try Task.checkCancellation()
                        // Throwing or cancelled persistence never crosses this send barrier.
                        running.send(Command(command: "ackThread", id: id))
                    case "deliveryAttempt":
                        guard let id = frame.id, id.hasPrefix("delivery:"),
                              Self.validID(String(id.dropFirst("delivery:".count))) else { throw CodexInteractiveError.malformed }
                        try await onEvent(.deliveryAttempt)
                        try Task.checkCancellation()
                        // Only a durably recorded attempt may release the prompt.
                        running.send(Command(command: "ackDelivery", id: id))
                    case "turnStarted":
                        guard let id = frame.id, Self.validID(id) else { throw CodexInteractiveError.malformed }
                        try await onEvent(.turnStarted(id))
                    case "textDelta":
                        guard let text = frame.text else { throw CodexInteractiveError.malformed }
                        try await onEvent(.textDelta(text))
                    case "completed":
                        guard let state = frame.state, ["completed", "failed", "interrupted"].contains(state),
                              (frame.inputTokens ?? 0) >= 0, (frame.outputTokens ?? 0) >= 0 else { throw CodexInteractiveError.malformed }
                        try await onEvent(.completed(state: state, inputTokens: frame.inputTokens, outputTokens: frame.outputTokens))
                    case "loginURL":
                        guard let value = frame.url, let url = URL(string: value), url.scheme == "https",
                              url.host == "auth.openai.com", url.user == nil, url.password == nil else { throw CodexInteractiveError.malformed }
                        try await onEvent(.loginURL(value))
                    case "loginCompleted":
                        guard let success = frame.success else { throw CodexInteractiveError.malformed }
                        try await onEvent(.loginCompleted(success))
                    case "result":
                        guard !receivedResult else { throw CodexInteractiveError.malformed }
                        receivedResult = true; result = frame.result
                    case "error": throw Self.error(frame.code)
                    default: throw CodexInteractiveError.malformed
                    }
                }
                guard receivedResult, running.successfulExit else { throw CodexInteractiveError.unavailable }
                return result
            } onCancel: { running.requestStop() }
            await running.stop(); active = nil
            return result
        } catch {
            await running.stop(); active = nil
            throw error
        }
    }

    private static func error(_ code: String?) -> CodexInteractiveError {
        switch code {
        case "invalidRequest": .invalidRequest
        case "unsafeProfile": .unsafeProfile
        case "unsafeConfig", "unsafeAuth", "serverRequest": .unsafeConfig
        case "ownership": .ownership
        case "busy": .busy
        case "unsupported": .unsupported
        case "signInRequired": .signInRequired
        case "keychainUnavailable": .keychainUnavailable
        case "signInFailed": .signInFailed
        case "modelUnavailable": .modelUnavailable
        case "cancelled": .interruptedUnknown
        case "timeout": .timeout
        case "tooLarge": .tooLarge
        case "malformed": .malformed
        default: .unavailable
        }
    }
}

/// All cross-thread state is protected by a lock; pipe reads run on a dedicated
/// queue, not the main actor or a cooperative executor. Stream buffering is bounded.
private final class InteractiveProcess: @unchecked Sendable {
    private struct LifecycleFrame: Decodable { var event: String; var pid: Int32? }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var groups = Set<Int32>()
    private var stopping = false
    private var launched = false
    private var exitStatus: Int32?
    private let terminationSignal = DispatchSemaphore(value: 0)
    private var stopTask: Task<Void, Never>?

    var successfulExit: Bool { lock.withLock { exitStatus == 0 } }
    func register(group: Int32) { lock.withLock { _ = groups.insert(group) } }
    func deregister(group: Int32) { lock.withLock { _ = groups.remove(group) } }

    func start(node: String, helper: String, request: Data) throws -> AsyncThrowingStream<Data, Error> {
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [helper]
        // No inherited HOME, native CODEX_HOME, provider endpoint, API key,
        // proxy, NODE_OPTIONS, DYLD injection or shell startup environment.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.withLock { self.exitStatus = process.terminationStatus }
            self.terminationSignal.signal()
        }
        try process.run(); lock.withLock { launched = true }
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(256)) { continuation in
            DispatchQueue(label: "aitvaras.codex.text-pipe").async { [self] in
                var buffer = Data(), total = 0
                do {
                    var scratch = [UInt8](repeating: 0, count: 16_384)
                    while true {
                        // Foundation's length-based pipe read may wait to fill
                        // the buffer. That deadlocks a small threadCreated frame
                        // against the helper's durable-binding acknowledgement.
                        let count = scratch.withUnsafeMutableBytes {
                            Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                        }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw CodexInteractiveError.unavailable
                        }
                        if count == 0 { break }
                        let data = Data(scratch.prefix(count))
                        total += data.count; buffer.append(data)
                        guard total <= 2 * 1024 * 1024, buffer.count <= 2 * 1024 * 1024 else { throw CodexInteractiveError.tooLarge }
                        while let end = buffer.firstIndex(of: 10) {
                            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                            // Lifecycle bookkeeping must not wait for a UI/database
                            // callback; otherwise a reaped PID could become stale.
                            let lifecycle = try JSONDecoder().decode(LifecycleFrame.self, from: line)
                            if lifecycle.event == "processGroup" || lifecycle.event == "processGroupEnded" {
                                guard let pid = lifecycle.pid, pid > 1 else { throw CodexInteractiveError.malformed }
                                if lifecycle.event == "processGroup" { register(group: pid) }
                                else { deregister(group: pid) }
                                continue
                            }
                            if case .dropped = continuation.yield(line) { throw CodexInteractiveError.tooLarge }
                        }
                    }
                    guard buffer.isEmpty else { throw CodexInteractiveError.malformed }
                    // Foundation waitUntilExit can wait indefinitely even after
                    // a child has died. EOF plus a bounded termination latch is
                    // sufficient; no cooperative executor is blocked here.
                    guard terminationSignal.wait(timeout: .now() + 2) == .success else { throw CodexInteractiveError.unavailable }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: (error as? CodexInteractiveError) ?? .malformed)
                    requestStop()
                }
            }
        }
        do { var line = request; line.append(10); try input.fileHandleForWriting.write(contentsOf: line) }
        catch { requestStop(); throw CodexInteractiveError.unavailable }
        return stream
    }

    func send<T: Encodable>(_ command: T) {
        lock.withLock {
            guard !stopping, let encoded = try? JSONEncoder().encode(command) else { return }
            var data = encoded; data.append(10)
            try? input.fileHandleForWriting.write(contentsOf: data)
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
        let task: Task<Void, Never> = lock.withLock {
            if let stopTask { return stopTask }
            let task = Task.detached { [self] in
                requestStop()
                try? await Task.sleep(for: .milliseconds(500))
                let owned = lock.withLock { groups }
                for group in owned { _ = Darwin.kill(-group, SIGKILL) }
                if lock.withLock({ launched }) && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                // Process reaps via its termination handler; never wait without
                // a bound during cancellation or failed-launch cleanup.
                try? output.fileHandleForReading.close()
            }
            stopTask = task; return task
        }
        await task.value
    }
}
