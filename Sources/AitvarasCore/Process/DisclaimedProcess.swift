import Foundation
import Synchronization

/// posix_spawn wrapper that sets the TCC "responsibility disclaim"
/// attribute: the spawned binary becomes its own responsible process, so
/// permission checks target the helper's identity instead of Aitvaras's.
/// Falls back to a plain spawn when the private symbol is unavailable.
public enum DisclaimedProcess {
    public struct Output: Sendable {
        public let exitCode: Int32
        /// Combined stdout and stderr, bounded to 1 MiB. Keeping both on the
        /// same pipe avoids a verbose helper blocking on an unread stderr
        /// pipe and gives callers useful installation/CLI diagnostics.
        public let stdout: String

        public init(exitCode: Int32, stdout: String) {
            self.exitCode = exitCode
            self.stdout = stdout
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let cancelled = Mutex(false)
        func cancel() { cancelled.withLock { $0 = true } }
        var isCancelled: Bool { cancelled.withLock { $0 } }
    }

    private typealias DisclaimFn = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>, Int32
    ) -> Int32

    public static func run(
        executable: String, arguments: [String], timeout: TimeInterval,
        environment: [String: String] = [:], inheritEnvironment: Bool = true
    ) async throws -> Output {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try runSync(
                            executable: executable, arguments: arguments,
                            timeout: timeout, environment: environment,
                            inheritEnvironment: inheritEnvironment,
                            cancellation: cancellation))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // The worker checks at least every 50ms, kills and reaps its own
            // pid, then resumes the cancelled task. Avoid killing here: the
            // child could exit and its pid be reused before this races in.
            cancellation.cancel()
        }
    }

    private static func runSync(
        executable: String, arguments: [String], timeout: TimeInterval,
        environment: [String: String],
        inheritEnvironment: Bool,
        cancellation: CancellationFlag
    ) throws -> Output {
        if cancellation.isCancelled { throw CancellationError() }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var stdoutPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create helper output pipe"])
        }
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Private but long-stable API (used by Chromium et al.).
        if let handle = dlopen(nil, RTLD_NOW) {
            defer { dlclose(handle) }
            if let symbol = dlsym(handle, "responsibility_spawnattrs_setdisclaim") {
                let disclaim = unsafeBitCast(symbol, to: DisclaimFn.self)
                _ = disclaim(&attributes, 1)
            }
        }

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var mergedEnvironment = inheritEnvironment
            ? ProcessInfo.processInfo.environment : [:]
        environment.forEach { mergedEnvironment[$0.key] = $0.value }
        let environmentStrings = mergedEnvironment
            .map { "\($0.key)=\($0.value)" }.sorted()
        let envp: [UnsafeMutablePointer<CChar>?] = environmentStrings
            .map { strdup($0) } + [nil]
        defer { envp.forEach { free($0) } }

        if cancellation.isCancelled {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw CancellationError()
        }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        close(stdoutPipe[1])
        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult),
                          userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed"])
        }

        // Nonblocking reads let timeout and cancellation work even when a
        // helper hangs silently. Excess output is drained but not retained.
        let originalFlags = fcntl(stdoutPipe[0], F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(stdoutPipe[0], F_SETFL, originalFlags | O_NONBLOCK)
        }
        var collected = Data()
        let captureLimit = 1_048_576
        let bufferSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let deadline = Date.now.addingTimeInterval(max(0, timeout))
        var status: Int32 = 0
        var reaped = false
        var reachedEOF = false
        var timedOut = false
        var wasCancelled = false

        while !reaped || !reachedEOF {
            if cancellation.isCancelled {
                if !reaped { _ = kill(pid, SIGKILL) }
                wasCancelled = true
                break
            }
            if !reachedEOF {
                while true {
                    let bytesRead = read(stdoutPipe[0], &buffer, bufferSize)
                    if bytesRead > 0 {
                        let remaining = captureLimit - collected.count
                        if remaining > 0 {
                            collected.append(contentsOf: buffer[0..<min(bytesRead, remaining)])
                        }
                        continue
                    }
                    if bytesRead == 0 { reachedEOF = true }
                    if bytesRead < 0, errno == EINTR { continue }
                    break
                }
            }

            if !reaped {
                let waitResult = waitpid(pid, &status, WNOHANG)
                if waitResult == pid { reaped = true }
            }
            if reaped && reachedEOF { break }
            if Date.now >= deadline {
                if !reaped { _ = kill(pid, SIGKILL) }
                timedOut = true
                break
            }

            if reachedEOF {
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                var descriptor = pollfd(
                    fd: stdoutPipe[0], events: Int16(POLLIN | POLLHUP), revents: 0)
                _ = poll(&descriptor, 1, 50)
            }
        }
        close(stdoutPipe[0])

        if !reaped { _ = waitpid(pid, &status, 0) }
        if wasCancelled { throw CancellationError() }
        if timedOut {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey:
                    "Helper exceeded the \(Int(timeout))-second timeout"])
        }
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Output(exitCode: exitCode, stdout: String(decoding: collected, as: UTF8.self))
    }
}
