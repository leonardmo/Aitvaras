import Foundation

/// posix_spawn wrapper that sets the TCC "responsibility disclaim"
/// attribute: the spawned binary becomes its own responsible process, so
/// permission checks (Full Disk Access for notify-reader) target the
/// helper's identity instead of Aitvaras's (D21). Falls back to a plain
/// spawn when the private symbol is unavailable — the helper then simply
/// fails its permission check rather than widening Aitvaras's.
enum DisclaimedProcess {
    struct Output {
        let exitCode: Int32
        let stdout: String
    }

    private typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    static func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try runSync(
                        executable: executable, arguments: arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(executable: String, arguments: [String], timeout: TimeInterval) throws -> Output {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var stdoutPipe: [Int32] = [0, 0]
        pipe(&stdoutPipe)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // Private but long-stable API (used by Chromium et al.).
        if let handle = dlopen(nil, RTLD_NOW),
           let symbol = dlsym(handle, "responsibility_spawnattrs_setdisclaim") {
            let disclaim = unsafeBitCast(symbol, to: DisclaimFn.self)
            _ = disclaim(&attributes, 1)
        }

        let argv: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, environ)
        close(stdoutPipe[1])
        guard spawnResult == 0 else {
            close(stdoutPipe[0])
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(spawnResult),
                          userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed"])
        }

        // Read stdout fully (helper output is small), then reap.
        var collected = Data()
        let bufferSize = 1 << 16
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let bytesRead = read(stdoutPipe[0], &buffer, bufferSize)
            if bytesRead > 0 {
                collected.append(contentsOf: buffer[0..<bytesRead])
            } else {
                break
            }
            if Date() > deadline {
                kill(pid, SIGKILL)
                break
            }
        }
        close(stdoutPipe[0])

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Output(exitCode: exitCode, stdout: String(decoding: collected, as: UTF8.self))
    }
}
