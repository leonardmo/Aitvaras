import Darwin
import Foundation

public enum AgentProcessError: Error, Sendable, Equatable {
    case alreadyStarted, notStarted, launchFailed, closed, writeFailed
    case inputLimit, outputLimit, invalidUTF8, cleanupUnconfirmed
}

/// One owned POSIX process group. A serial queue confines descriptors, framing,
/// writes and lifecycle state; no pipe I/O blocks a cooperative executor.
public final class StreamingProcess: @unchecked Sendable {
    static let maximumLineBytes = 1_048_576
    static let maximumQueuedLines = 64
    static let maximumPendingWriteBytes = 2 * 1_048_576
    static let maximumPendingWrites = 64
    static let stderrLimit = 16 * 1024

    private let executable: URL
    private let arguments: [String]
    private let directory: URL?
    private let environment: [String: String]
    private let keepEmptyLines: Bool
    private let io = DispatchQueue(label: "aitvaras.agent.process")
    private var pid: pid_t = 0
    private var started = false
    private var status: Int32?
    private var cleanupFailure: AgentProcessError?
    private var stopping = false
    private var groupCleaned = false
    private var input: Int32 = -1
    private var closeRequested = false
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var buffer = Data()
    private var scanned = 0
    private var stderrTail = Data()
    private var streamFinished = false
    private var writes: [PendingWrite] = []
    private var pendingWriteBytes = 0
    private struct PendingWrite {
        let data: Data
        var offset = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    public let lines: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation

    public init(executable: URL, arguments: [String], currentDirectory: URL?,
                environment: [String: String]? = nil, keepEmptyLines: Bool = false) {
        self.executable = executable; self.arguments = arguments; directory = currentDirectory
        self.environment = environment ?? ProcessInfo.processInfo.environment
        self.keepEmptyLines = keepEmptyLines
        (lines, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumQueuedLines))
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.terminate() }
        }
    }

    public func start() throws {
        try io.sync {
            guard !started else { throw AgentProcessError.alreadyStarted }
            started = true
            do { try spawn() }
            catch {
                cleanupFailure = .launchFailed
                finishStream(.launchFailed)
                throw AgentProcessError.launchFailed
            }
        }
    }

    private func spawn() throws {
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              !([executable.path] + arguments + [directory?.path ?? ""]).contains(where: { $0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") })
        else { throw AgentProcessError.launchFailed }
        var descriptors: [Int32] = []
        defer { for fd in descriptors where fd >= 0 { Darwin.close(fd) } }
        for _ in 0..<3 {
            var pair = [Int32](repeating: -1, count: 2)
            guard Darwin.pipe(&pair) == 0 else { throw AgentProcessError.launchFailed }
            descriptors += pair
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AgentProcessError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AgentProcessError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ result: Int32) throws {
            guard result == 0 else { throw AgentProcessError.launchFailed }
        }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        for (source, target) in [(descriptors[0], STDIN_FILENO), (descriptors[3], STDOUT_FILENO), (descriptors[5], STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, source, target))
        }
        for fd in descriptors { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let directory { try check(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
        // Only parent ends are nonblocking. F_SETNOSIGPIPE avoids changing the
        // application's global signal disposition when a child closes stdin.
        for fd in [descriptors[1], descriptors[2], descriptors[4]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw AgentProcessError.launchFailed }
        }
        guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) != -1 else { throw AgentProcessError.launchFailed }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + env { free(pointer) } }
        let result = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, variables.baseAddress!)
            }
        }
        try check(result)
        input = descriptors[1]
        stdoutSource = reader(descriptors[2], stderr: false)
        stderrSource = reader(descriptors[4], stderr: true)
        // Dispatch sources own the read ends; this queue owns the write end.
        for index in [1, 2, 4] { descriptors[index] = -1 }
        let child = pid
        DispatchQueue.global(qos: .utility).async { [self] in
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &raw, 0) } while result == -1 && errno == EINTR
            let code = result == child ? ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)) : -1
            io.async { [self] in didExit(code) }
        }
    }

    private func reader(_ fd: Int32, stderr: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [weak self] in self?.read(fd, stderr: stderr) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        return source
    }

    private func read(_ fd: Int32, stderr: Bool) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Yield the queue under continuous output so writes/Stop cannot starve.
        for _ in 0..<32 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { return }
                fail(.closed); return
            }
            if count == 0 {
                if !stderr { flushTrailingLine() }
                closeReader(stderr: stderr)
                return
            }
            let data = Data(bytes.prefix(count))
            if stderr {
                stderrTail.append(data)
                if stderrTail.count > Self.stderrLimit { stderrTail.removeFirst(stderrTail.count - Self.stderrLimit) }
            } else {
                buffer.append(data)
                while let newline = buffer[buffer.index(buffer.startIndex, offsetBy: scanned)...].firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline); scanned = 0
                    guard emit(line) else { return }
                }
                scanned = buffer.count
                if buffer.count > Self.maximumLineBytes { fail(.outputLimit); return }
            }
        }
    }

    private func emit(_ data: Data) -> Bool {
        guard data.count <= Self.maximumLineBytes else { fail(.outputLimit); return false }
        guard let text = String(data: data, encoding: .utf8) else { fail(.invalidUTF8); return false }
        if text.isEmpty && !keepEmptyLines { return true }
        switch continuation.yield(text) {
        case .enqueued: return true
        case .dropped: fail(.outputLimit); return false
        case .terminated: stop(grace: .zero); return false
        @unknown default: fail(.outputLimit); return false
        }
    }

    private func flushTrailingLine() {
        if !buffer.isEmpty { _ = emit(buffer) }
        buffer.removeAll(); scanned = 0
        finishStream()
    }

    private func finishStream(_ error: AgentProcessError? = nil) {
        guard !streamFinished else { return }
        streamFinished = true
        continuation.finish(throwing: error)
    }

    private func closeReader(stderr: Bool) {
        if stderr { stderrSource?.cancel(); stderrSource = nil }
        else { stdoutSource?.cancel(); stdoutSource = nil }
    }

    private func fail(_ error: AgentProcessError) {
        finishStream(error)
        closeReader(stderr: false)
        stop(grace: .zero)
    }

    /// Returns only when the complete frame reached the pipe. This is not a
    /// provider acknowledgement; failures can follow a partially written frame.
    public func write(line: String) async throws {
        try Task.checkCancellation()
        guard !line.contains("\n"), !line.contains("\r") else { throw AgentProcessError.writeFailed }
        let byteCount = line.utf8.count + 1
        guard byteCount <= Self.maximumLineBytes else { throw AgentProcessError.inputLimit }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                // Admit synchronously before allocating the frame. An async
                // admission queue would itself retain unbounded pending inputs.
                io.sync {
                    guard started, input >= 0, !closeRequested, status == nil, !stopping else {
                        reply.resume(throwing: AgentProcessError.closed); return
                    }
                    guard writes.count < Self.maximumPendingWrites,
                          pendingWriteBytes + byteCount <= Self.maximumPendingWriteBytes else {
                        reply.resume(throwing: AgentProcessError.inputLimit); return
                    }
                    writes.append(PendingWrite(data: Data((line + "\n").utf8), continuation: reply))
                    pendingWriteBytes += byteCount
                    drainWrites()
                }
            }
        } onCancel: { self.terminate() }
    }

    private func drainWrites() {
        while !writes.isEmpty, input >= 0 {
            let count = writes[0].data.withUnsafeBytes { bytes in
                Darwin.write(input, bytes.baseAddress!.advanced(by: writes[0].offset), bytes.count - writes[0].offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    if writeSource == nil {
                        let source = DispatchSource.makeWriteSource(fileDescriptor: input, queue: io)
                        source.setEventHandler { [weak self] in self?.drainWrites() }
                        writeSource = source; source.resume()
                    }
                    return
                }
                closeInputNow(error: .writeFailed); return
            }
            guard count > 0 else { closeInputNow(error: .writeFailed); return }
            writes[0].offset += count; pendingWriteBytes -= count
            if writes[0].offset == writes[0].data.count { writes.removeFirst().continuation.resume() }
        }
        writeSource?.cancel(); writeSource = nil
        if closeRequested { closeInputNow() }
    }

    public func closeInput() {
        io.async { [self] in closeRequested = true; if writes.isEmpty { closeInputNow() } }
    }

    private func closeInputNow(error: AgentProcessError = .closed) {
        writeSource?.cancel(); writeSource = nil
        if input >= 0 { Darwin.close(input); input = -1 }
        let pending = writes; writes.removeAll(); pendingWriteBytes = 0
        for write in pending { write.continuation.resume(throwing: error) }
    }

    private func didExit(_ code: Int32) {
        status = code
        closeInputNow()
        // A grandchild can retain pipes even after the root exits normally.
        // It is still ours: signal only the isolated group, never process names.
        if kill(-pid, 0) == -1 && errno == ESRCH { groupCleaned = true }
        else { stop(grace: .zero) }
    }

    private func stop(grace: Duration) {
        guard started, pid > 0, !stopping else { return }
        stopping = true; closeRequested = true
        io.asyncAfter(deadline: .now() + grace.timeInterval) { [self] in
            guard !groupCleaned else { return }
            closeInputNow()
            _ = kill(-pid, SIGTERM)
            io.asyncAfter(deadline: .now() + 0.2) { [self] in
                guard !groupCleaned else { return }
                if kill(-pid, SIGKILL) == -1 && errno != ESRCH { cleanupFailure = .cleanupUnconfirmed }
                groupCleaned = true
            }
        }
        io.asyncAfter(deadline: .now() + grace.timeInterval + 1.2) { [self] in
            if status == nil || stdoutSource != nil || stderrSource != nil {
                cleanupFailure = .cleanupUnconfirmed
                finishStream(.cleanupUnconfirmed)
                closeReader(stderr: false); closeReader(stderr: true)
            }
        }
    }

    public func terminate() { io.async { [self] in stop(grace: .zero) } }
    public var isRunning: Bool { io.sync { started && pid > 0 && status == nil } }
    public var processIdentifier: Int32 { io.sync { pid } }
    /// Transient diagnostics only. Callers must not persist or log this text.
    public var stderrText: String { io.sync { String(decoding: stderrTail, as: UTF8.self) } }

    /// Polling is cancellation-aware; unlike a continuation inside a task-group
    /// race, it cannot prevent the timeout branch from cleaning up the process.
    public func waitForExit() async throws -> Int32 {
        while true {
            try Task.checkCancellation()
            if let result: Int32 = try io.sync(execute: {
                guard started else { throw AgentProcessError.notStarted }
                if let cleanupFailure { throw cleanupFailure }
                return groupCleaned && stdoutSource == nil && stderrSource == nil ? status : nil
            }) { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    public func shutdown(grace: Duration = .milliseconds(250)) async throws {
        closeInput()
        io.async { [self] in stop(grace: grace) }
        // Cleanup must finish even when its initiating task was cancelled.
        _ = try await Task.detached { try await self.waitForExit() }.value
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let value = components
        return max(0, Double(value.seconds) + Double(value.attoseconds) / 1e18)
    }
}

public enum OneShotProcess {
    static let maximumOutputBytes = 8 * 1_048_576
    public struct Output: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
        public let timedOut: Bool
    }

    public static func run(executable: URL, arguments: [String], currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           timeout: Duration = .seconds(120)) async throws -> Output {
        try Task.checkCancellation()
        let process = StreamingProcess(executable: executable, arguments: arguments,
            currentDirectory: currentDirectory, environment: environment, keepEmptyLines: true)
        try process.start(); process.closeInput()
        let timer = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) }
            catch { return false }
            try? await process.shutdown(grace: .zero)
            return true
        }
        defer { timer.cancel() }
        do {
            let output = try await withTaskCancellationHandler {
                var lines: [String] = [], bytes = 0
                for try await line in process.lines {
                    try Task.checkCancellation()
                    bytes += line.utf8.count + 1
                    guard bytes <= maximumOutputBytes else { throw AgentProcessError.outputLimit }
                    lines.append(line)
                }
                return lines.joined(separator: "\n")
            } onCancel: { process.terminate() }
            let status = try await process.waitForExit()
            timer.cancel()
            let timedOut = await timer.value
            return Output(stdout: output, stderr: process.stderrText, exitCode: status, timedOut: timedOut)
        } catch {
            try? await process.shutdown(grace: .zero)
            throw error
        }
    }
}
