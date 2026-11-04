import Foundation

/// A long-lived child process with line-oriented stdout, a writable stdin
/// and a bounded stderr tail. Foundation.Process and Pipe are not
/// Sendable; this box confines them behind a lock and takes the
/// @unchecked responsibility.
public final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = Data()
    private var inputClosed = false
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    /// Set by the termination handler; waiters resume once both pipes hit
    /// EOF too, so no trailing output is ever lost.
    private var terminationStatus: Int32?
    private var stdoutDone = false
    private var stderrDone = false
    private var exitStatus: Int32?
    private let linesContinuation: AsyncStream<String>.Continuation
    private let keepEmptyLines: Bool

    /// stdout, one element per line, finishing at EOF.
    public let lines: AsyncStream<String>

    static let stderrLimit = 16 * 1024
    /// A grandchild (e.g. a background shell) can hold the pipes open past
    /// the process's exit; after this grace the streams are closed anyway.
    static let pipeDrainGrace: Duration = .seconds(2)

    public init(executable: URL, arguments: [String], currentDirectory: URL?,
                environment: [String: String]? = nil, keepEmptyLines: Bool = false) {
        self.keepEmptyLines = keepEmptyLines
        (lines, linesContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// Writing to a child that just died must fail with EPIPE, not kill
    /// the app with SIGPIPE.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public func start() throws {
        _ = Self.ignoreSIGPIPE
        // Each handler runs serially on its own queue, so chunk order and
        // the EOF (empty chunk) that finishes the stream stay in sequence.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] proc in
            self?.didTerminate(proc.terminationStatus)
        }
        try process.run()
    }

    private func consumeStdout(_ chunk: Data) {
        lock.lock()
        guard !stdoutDone else { lock.unlock(); return }
        if chunk.isEmpty {
            // EOF: flush a trailing line without newline, then finish.
            let rest = buffer
            buffer.removeAll()
            stdoutDone = true
            lock.unlock()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            if !rest.isEmpty { linesContinuation.yield(String(decoding: rest, as: UTF8.self)) }
            linesContinuation.finish()
            completeIfDone()
            return
        }
        buffer.append(chunk)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines where keepEmptyLines || !line.isEmpty { linesContinuation.yield(line) }
    }

    private func consumeStderr(_ chunk: Data) {
        lock.lock()
        guard !stderrDone else { lock.unlock(); return }
        if chunk.isEmpty {
            stderrDone = true
            lock.unlock()
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            completeIfDone()
            return
        }
        stderrTail.append(chunk)
        if stderrTail.count > Self.stderrLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrLimit)
        }
        lock.unlock()
    }

    private func didTerminate(_ status: Int32) {
        lock.lock()
        terminationStatus = status
        lock.unlock()
        completeIfDone()
        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.pipeDrainGrace)
            self?.consumeStdout(Data())
            self?.consumeStderr(Data())
        }
    }

    private func completeIfDone() {
        lock.lock()
        guard exitStatus == nil, let status = terminationStatus, stdoutDone, stderrDone else {
            lock.unlock()
            return
        }
        exitStatus = status
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: status) }
    }

    /// Writes one line (a newline is appended). Silently ignored once
    /// stdin is closed or the process has exited.
    public func write(line: String) {
        lock.lock()
        let closed = inputClosed || terminationStatus != nil
        lock.unlock()
        guard !closed else { return }
        let data = Data((line + "\n").utf8)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func closeInput() {
        lock.lock()
        guard !inputClosed else { lock.unlock(); return }
        inputClosed = true
        lock.unlock()
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public var isRunning: Bool { process.isRunning }

    public var processIdentifier: Int32 { process.processIdentifier }

    public var stderrText: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    /// Resolves with the exit status (immediately if already exited).
    public func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let exitStatus {
                lock.unlock()
                cont.resume(returning: exitStatus)
            } else {
                exitWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    /// Closes stdin, then terminates if the process hasn't exited within
    /// `grace` — Claude Code keeps running after EOF while background
    /// work drains, which we don't want to wait on.
    public func shutdown(grace: Duration = .seconds(3)) async {
        closeInput()
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await self.waitForExit(); return true }
            group.addTask { try? await Task.sleep(for: grace); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !exited {
            terminate()
            _ = await waitForExit()
        }
    }
}

/// One-shot helper: run to completion with a timeout, collecting output.
public enum OneShotProcess {
    public struct Output: Sendable {
        public var stdout: String
        public var stderr: String
        public var exitCode: Int32
        public var timedOut: Bool
    }

    public static func run(executable: URL, arguments: [String], currentDirectory: URL? = nil,
                           environment: [String: String]? = nil,
                           timeout: Duration = .seconds(120)) async throws -> Output {
        let process = StreamingProcess(executable: executable, arguments: arguments,
                                       currentDirectory: currentDirectory, environment: environment,
                                       keepEmptyLines: true)
        try process.start()
        process.closeInput()
        let collector = Task {
            var lines: [String] = []
            for await line in process.lines { lines.append(line) }
            return lines.joined(separator: "\n")
        }
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await process.waitForExit(); return false }
            group.addTask { try? await Task.sleep(for: timeout); return true }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if timedOut { process.terminate() }
        let status = await process.waitForExit()
        let stdout = await collector.value
        return Output(stdout: stdout, stderr: process.stderrText, exitCode: status, timedOut: timedOut)
    }
}
