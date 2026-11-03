import Darwin
import Foundation

public protocol ClaudeSubscriptionSigningIn: Sendable {
    func signIn(guidance: ClaudeLoginGuidance, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws
    func cancel() async
}

public enum ClaudeSubscriptionSignInError: String, Error, LocalizedError, Sendable {
    case busy, invalidGuidance, unavailable, loginFailed, verificationFailed, timeout, cancelled, outputLimit, requiresTerminal, stopUnconfirmed
    public var errorDescription: String? {
        switch self {
        case .busy: "Claude sign-in is already running."
        case .invalidGuidance: "The official Claude subscription sign-in could not be safely prepared."
        case .unavailable: "Claude Code could not be opened for sign-in."
        case .loginFailed: "Claude sign-in did not finish. Try again or use the Terminal fallback."
        case .verificationFailed: "The browser flow closed, but this profile is still signed out. Try again or use Terminal under Advanced."
        case .timeout: "Claude sign-in timed out. Try again when the browser is ready."
        case .cancelled: "Claude sign-in was cancelled."
        case .outputLimit: "Claude sign-in returned too much output and was stopped."
        case .requiresTerminal: "This sign-in needs a code entered in Terminal. Use the Terminal fallback."
        case .stopUnconfirmed: "Claude sign-in has not confirmed that it stopped. Do not start another sign-in yet."
        }
    }
}

/// Hosts only the official CLI's subscription authentication command. OAuth,
/// browser callbacks and credential storage remain the official CLI's job.
public actor ClaudeSubscriptionSignIn: ClaudeSubscriptionSigningIn {
    private let profileDirectory: URL
    private let homeDirectory: URL
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var active: ClaudeSignInProcess?

    public init(profileDirectory: URL) {
        self.profileDirectory = profileDirectory
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        timeout = 600; outputLimit = 262_144
    }

    // Test seam: still runs the exact official command arguments, but only a
    // generated synthetic executable. Production never accepts a custom home.
    init(profileDirectory: URL, homeDirectory: URL, timeout: TimeInterval = 600, outputLimit: Int = 262_144) {
        self.profileDirectory = profileDirectory; self.homeDirectory = homeDirectory
        self.timeout = timeout; self.outputLimit = outputLimit
    }

    public func signIn(guidance: ClaudeLoginGuidance, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        guard !Task.isCancelled else { throw ClaudeSubscriptionSignInError.cancelled }
        guard active == nil else { throw ClaudeSubscriptionSignInError.busy }
        guard guidance.arguments == ["auth", "login", "--claudeai"],
              guidance.executable.hasPrefix("/"), !guidance.executable.contains("\0"),
              FileManager.default.isExecutableFile(atPath: guidance.executable),
              guidance.environment.isEmpty || guidance.environment == ["CLAUDE_CONFIG_DIR": guidance.configDirectory],
              guidance.configDirectory.hasPrefix("/"), !guidance.configDirectory.contains("\0")
        else { throw ClaudeSubscriptionSignInError.invalidGuidance }

        let directory = profileDirectory.appendingPathComponent("claude-sign-in", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch { throw ClaudeSubscriptionSignInError.unavailable }
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ["HOME": homeDirectory.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "LANG": "en_US.UTF-8", "NO_COLOR": "1", "TERM": "dumb"]
        if let config = guidance.environment["CLAUDE_CONFIG_DIR"] { environment["CLAUDE_CONFIG_DIR"] = config }
        let worker = ClaudeSignInProcess()
        active = worker
        defer { if worker.didExit { active = nil } }
        try await withTaskCancellationHandler {
            do {
                let events = try worker.start(executable: guidance.executable, arguments: guidance.arguments,
                                              environment: environment, directory: directory,
                                              outputLimit: outputLimit, timeout: timeout)
                for try await event in events {
                    switch event {
                    case .browserURL(let url): await onBrowserURL(url)
                    }
                }
                await worker.stop()
                guard worker.didExit else { throw ClaudeSubscriptionSignInError.stopUnconfirmed }
                if Task.isCancelled || worker.wasCancelled { throw ClaudeSubscriptionSignInError.cancelled }
                if worker.didTimeOut { throw ClaudeSubscriptionSignInError.timeout }
                guard worker.successfulExit else { throw ClaudeSubscriptionSignInError.loginFailed }
            } catch {
                await worker.stop()
                guard worker.didExit else { throw ClaudeSubscriptionSignInError.stopUnconfirmed }
                if Task.isCancelled || worker.wasCancelled { throw ClaudeSubscriptionSignInError.cancelled }
                if worker.didTimeOut { throw ClaudeSubscriptionSignInError.timeout }
                throw (error as? ClaudeSubscriptionSignInError) ?? .unavailable
            }
        } onCancel: { worker.requestCancellation() }
    }

    public func cancel() async {
        guard let active else { return }
        active.requestCancellation()
        await active.stop()
    }
}

private enum ClaudeSignInEvent: Sendable { case browserURL(URL) }

/// Pipe bytes are transient and bounded. Never log them: authentication output
/// may contain state, authorization codes or other sensitive diagnostics.
private final class ClaudeSignInProcess: @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe(), lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var status: Int32?
    private var launched = false, cancelled = false, expired = false, stopping = false
    private var stopTask: Task<Void, Never>?
    var successfulExit: Bool { lock.withLock { status == 0 } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { expired } }
    var didExit: Bool { lock.withLock { status != nil || !launched } }

    func start(executable: String, arguments: [String], environment: [String: String], directory: URL,
               outputLimit: Int, timeout: TimeInterval) throws -> AsyncThrowingStream<ClaudeSignInEvent, Error> {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = environment; process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.withLock { self.status = process.terminationStatus }; self.exited.signal()
        }
        try lock.withLock {
            guard !cancelled else { throw ClaudeSubscriptionSignInError.cancelled }
            try process.run(); launched = true
        }
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let collector = ClaudeSignInOutput(limit: outputLimit)
            let group = DispatchGroup()
            for (pipe, isOutput) in [(output, true), (errors, false)] {
                group.enter()
                DispatchQueue(label: "aitvaras.claude.sign-in.pipe").async { [self] in
                    defer { group.leave() }
                    var scratch = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = scratch.withUnsafeMutableBytes { Darwin.read(pipe.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                        if count < 0 { if errno == EINTR { continue }; break }
                        if count == 0 { break }
                        do {
                            for event in try collector.consume(Data(scratch.prefix(count)), stdout: isOutput) {
                                if case .dropped = continuation.yield(event) { throw ClaudeSubscriptionSignInError.outputLimit }
                            }
                        } catch {
                            continuation.finish(throwing: error); requestStop(); return
                        }
                    }
                }
            }
            group.notify(queue: .global()) { [self] in
                guard exited.wait(timeout: .now() + 2) == .success else {
                    continuation.finish(throwing: ClaudeSubscriptionSignInError.loginFailed); requestStop(); return
                }
                continuation.finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let timedOut = self.lock.withLock {
                    guard self.status == nil, !self.stopping else { return false }
                    self.expired = true; return true
                }
                if timedOut { self.requestStop() }
            }
            continuation.onTermination = { [weak self] _ in self?.requestStop() }
        }
    }

    func requestCancellation() { lock.withLock { cancelled = true }; requestStop() }
    private func requestStop() {
        let requested = lock.withLock {
            guard !stopping else { return false }; stopping = true
            try? input.fileHandleForWriting.close()
            if launched && status == nil && process.isRunning { process.terminate() }
            return true
        }
        if requested {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    if self.launched && self.status == nil && self.process.isRunning {
                        _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
                    }
                }
            }
        }
    }
    func stop() async {
        let task = lock.withLock {
            if let stopTask { return stopTask }
            let task = Task.detached { [self] in
                requestStop()
                for _ in 0..<40 {
                    if lock.withLock({ status != nil || !launched }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                lock.withLock {
                    if launched && status == nil && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                }
                // Wait for acknowledgement of actual process exit, never label a
                // mere signal request as a completed cancellation.
                for _ in 0..<40 {
                    if lock.withLock({ status != nil || !launched }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            }
            stopTask = task; return task
        }
        await task.value
    }
}

final class ClaudeSignInOutput: @unchecked Sendable {
    private let lock = NSLock(), limit: Int
    private var total = 0, buffers = [true: Data(), false: Data()], offered = Set<String>()
    init(limit: Int) { self.limit = limit }
    fileprivate func consume(_ data: Data, stdout: Bool) throws -> [ClaudeSignInEvent] {
        try lock.withLock {
            total += data.count
            guard total <= limit else { throw ClaudeSubscriptionSignInError.outputLimit }
            buffers[stdout, default: Data()].append(data)
            let text = String(decoding: buffers[stdout]!, as: UTF8.self)
            // The CLI prints its paste-code prompt during normal callback flows
            // too. Do not mistake that prompt for a failed browser login.
            guard stdout else { return [] }
            let urls = Self.browserURLs(in: text)
            return urls.filter { offered.insert($0.absoluteString).inserted }.map { .browserURL($0) }
        }
    }
    static func browserURLs(in text: String) -> [URL] {
        // Only complete whitespace-terminated URL tokens. Never open a partially
        // received query or accept suffix/userinfo/fragment tricks.
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let value = String(token)
            guard let range = text.range(of: value), range.upperBound < text.endIndex,
                  let parts = URLComponents(string: value), parts.scheme == "https", parts.host == "claude.ai",
                  parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
                  parts.path == "/oauth/authorize", let url = parts.url else { return nil }
            return url
        }
    }
}
