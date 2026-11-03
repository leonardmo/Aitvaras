import AitvarasCore
import Foundation
import Darwin

/// Reachability is not proof that Codex desktop uses this endpoint. The reviewed
/// initialize response provides no stable runtime identity or desktop attestation.
public struct CodexSharedRuntimeDescriptor: Sendable, Codable, Equatable {
    public let connected: Bool
    public let transport: String
    public let projectListAvailable: Bool
    public let runtimeIdentity: String
    public let desktopAttachmentVerified: Bool
    public let continuationSupported: Bool
}

public enum CodexSharedRuntimeError: Error, LocalizedError, Sendable, Equatable {
    case disabled, busy, invalidEndpoint, unavailable, unsupported, rejected
    case timeout, tooLarge, malformed, serverRequest

    public var errorDescription: String? {
        switch self {
        case .disabled: "External integrations are disabled for this profile."
        case .busy: "A shared Codex endpoint check is already running."
        case .invalidEndpoint: "Enter an explicit ws:// endpoint using 127.0.0.1 or [::1] and a port. Credentials, queries, fragments and hostnames are not accepted."
        case .unavailable: "The configured shared Codex endpoint is unavailable. No runtime was started."
        case .unsupported: "The configured endpoint does not support the required read-only project check."
        case .rejected: "The shared Codex endpoint rejected the read-only check."
        case .timeout: "The shared Codex endpoint check timed out."
        case .tooLarge: "The shared Codex endpoint exceeded the bounded protocol limit."
        case .malformed: "The shared Codex endpoint returned an unsupported response."
        case .serverRequest: "The shared Codex endpoint requested an action. Nothing was approved or executed."
        }
    }
}

/// Separate from the owned isolated-session client. Attaches only to a supplied
/// loopback WebSocket; it cannot authenticate, resume, send turns or mutate native
/// projects. It never discovers endpoints, starts Codex or changes native config.
public actor CodexSharedRuntimeClient {
    private let nodePath: String?
    private let helperPath: String?
    private let timeout: TimeInterval
    private var active: SharedRuntimeProbeProcess?

    public init() {
        nodePath = CodexSessionReader.findNode()
        helperPath = Bundle.module.url(forResource: "codex-shared-runtime", withExtension: "mjs")?.path
        timeout = 8
    }

    init(nodePath: String?, helperPath: String?, timeout: TimeInterval = 8) {
        self.nodePath = nodePath; self.helperPath = helperPath; self.timeout = timeout
    }

    /// Literal loopback IPs only. Validate the original string before a URL
    /// parser can normalize an alternative IP spelling or a redirected path.
    public nonisolated static func validateEndpoint(_ endpoint: String) throws -> URL {
        let pattern = #"^ws://(127\.0\.0\.1|\[::1\]):([1-9][0-9]{0,4})(/[^\s\\?#%]*)?\z"#
        guard endpoint.utf8.count <= 2048,
              endpoint.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: endpoint, range: NSRange(endpoint.startIndex..., in: endpoint)),
              let portRange = Range(match.range(at: 2), in: endpoint),
              let port = Int(endpoint[portRange]), (1...65535).contains(port),
              let url = URL(string: endpoint), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "ws", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw CodexSharedRuntimeError.invalidEndpoint }
        return url
    }

    public func probe(endpoint: String) async throws -> CodexSharedRuntimeDescriptor {
        try Task.checkCancellation()
        _ = try Self.validateEndpoint(endpoint)
        guard !AitvarasPaths.externalIntegrationsDisabled,
              ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] != "1" else { throw CodexSharedRuntimeError.disabled }
        guard active == nil else { throw CodexSharedRuntimeError.busy }
        guard let nodePath, let helperPath else { throw CodexSharedRuntimeError.unavailable }
        let running = SharedRuntimeProbeProcess()
        active = running
        defer { active = nil }
        let request = try JSONEncoder().encode(Request(operation: "probe", endpoint: endpoint))
        let data = try await withTaskCancellationHandler {
            try await running.run(node: nodePath, helper: helperPath, request: request, timeout: timeout)
        } onCancel: { running.cancel() }
        try Task.checkCancellation()
        let frame: Frame
        do { frame = try JSONDecoder().decode(Frame.self, from: data) }
        catch { throw CodexSharedRuntimeError.malformed }
        if let error = frame.error { throw Self.error(error) }
        guard let result = frame.result, result.connected,
              result.transport == "explicitLoopbackWebSocket", result.projectListAvailable,
              result.runtimeIdentity == "unknown", !result.desktopAttachmentVerified,
              !result.continuationSupported else { throw CodexSharedRuntimeError.malformed }
        return result
    }

    public func cancel() { active?.cancel() }

    private struct Request: Encodable { let operation: String; let endpoint: String }
    private struct Frame: Decodable { let result: CodexSharedRuntimeDescriptor?; let error: String? }
    private static func error(_ code: String) -> CodexSharedRuntimeError {
        switch code {
        case "invalidEndpoint", "invalidRequest": .invalidEndpoint
        case "unsupported": .unsupported
        case "rejected": .rejected
        case "timeout": .timeout
        case "tooLarge": .tooLarge
        case "malformed": .malformed
        case "serverRequest": .serverRequest
        default: .unavailable
        }
    }
}

/// Only the small Node transport helper is owned here, never a native server.
/// The parent wall-clock deadline also covers a faulty helper. Completion and
/// cancellation never wait indefinitely for Foundation's process exit handling.
private final class SharedRuntimeProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process(), input = Pipe(), output = Pipe()
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false, launched = false
    private var exitStatus: Int32?
    private let exitSignal = DispatchSemaphore(value: 0)

    func run(node: String, helper: String, request: Data, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [helper]
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "NO_COLOR": "1"]
            process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.lock.withLock { self.exitStatus = process.terminationStatus }
                self.exitSignal.signal()
            }
            do { try process.run(); launched = true }
            catch { lock.unlock(); finish(.failure(CodexSharedRuntimeError.unavailable)); return }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(max(timeout, 0.01), 8)) { [weak self] in
                self?.finish(.failure(CodexSharedRuntimeError.timeout))
            }
            DispatchQueue(label: "aitvaras.codex.shared-probe").async { [self] in
                defer { try? output.fileHandleForReading.close() }
                do {
                    try input.fileHandleForWriting.write(contentsOf: request)
                    try input.fileHandleForWriting.close()
                    var captured = Data(), scratch = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = scratch.withUnsafeMutableBytes {
                            Darwin.read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                        }
                        if count < 0 {
                            if errno == EINTR { continue }
                            throw CodexSharedRuntimeError.unavailable
                        }
                        if count == 0 { break }
                        guard captured.count + count <= 16_384 else { throw CodexSharedRuntimeError.tooLarge }
                        captured.append(contentsOf: scratch.prefix(count))
                    }
                    guard exitSignal.wait(timeout: .now() + 1) == .success else { throw CodexSharedRuntimeError.unavailable }
                    let status = lock.withLock { exitStatus }
                    // A structured helper failure is decoded by the caller;
                    // successful data must also have a confirmed clean exit.
                    guard status == 0 || (try? JSONDecoder().decode(Failure.self, from: captured)) != nil else {
                        throw CodexSharedRuntimeError.unavailable
                    }
                    finish(.success(captured))
                } catch { finish(.failure(error)) }
            }
        }
    }

    private struct Failure: Decodable { let error: String }
    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Data, Error>) {
        let value: CheckedContinuation<Data, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let value = continuation; continuation = nil
            if launched && process.isRunning { process.terminate() }
            return value
        }
        value?.resume(with: result)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [self] in
            lock.withLock {
                if launched && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
