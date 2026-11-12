import Foundation
import Darwin

/// Injection boundary used by offline recordings. Credentials never cross it.
protocol OpencodeTransport: Actor {
    func open(projects: [URL], models: [AgentModel]) async throws
    func subscribe() async throws -> AsyncThrowingStream<JSONValue, Error>
    func request(_ path: String, method: String, body: JSONValue?) async throws -> JSONValue
    func close() async
}

actor OpencodeHTTPTransport: OpencodeTransport {
    private let executable: URL
    private let configuration: OpencodeConfiguration
    private let environment: [String: String]
    private var process: StreamingProcess?
    private var outputReader: Task<Void, Never>?
    private var eventReader: Task<Void, Never>?
    private var eventContinuation: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var generation = UUID()
    private var listening = false
    private var password: String?
    private var baseURL: URL?
    private var session: URLSession?
    private var closeTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Error>?

    init(executable: URL, environment: [String: String], configuration: OpencodeConfiguration) {
        self.executable = executable; self.environment = environment; self.configuration = configuration
    }
    /// HTTP-only injection seam; process stdout remains private to the transport.
    init(session: URLSession, password: String? = nil, port: UInt16) {
        executable = URL(fileURLWithPath: "/usr/bin/false")
        environment = [:]; configuration = .init(root: FileManager.default.temporaryDirectory.appendingPathComponent("opencode-http-test"))
        self.session = session; self.password = password
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }
    func open(projects: [URL], models: [AgentModel]) async throws {
        guard process == nil, closeTask == nil else { throw AgentFailure.invalidTransition }
        let generation = UUID(); self.generation = generation
        let fm = FileManager.default
        for directory in configuration.dataDirectories + [configuration.temporaryDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let recovery = Task { [file = configuration.serverPIDFile] in try await OpencodeServerPID.recover(file: file) }
        recoveryTask = recovery
        do { try await recovery.value; recoveryTask = nil }
        catch { recoveryTask = nil; throw error }
        guard generation == self.generation else { throw AgentFailure.offline }
        let configURL = configuration.dataDirectories[0].appendingPathComponent("opencode/opencode.json")
        try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(configuration.config(models: models).jsonString.utf8).write(to: configURL, options: .atomic)
        let sandboxURL = configuration.root.appendingPathComponent("sandbox.sb")
        try Data(configuration.sandbox(projects: projects).utf8).write(to: sandboxURL, options: .atomic)
        let port = try Self.freePort()
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let child = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
            arguments: ["-f", sandboxURL.path, executable.path, "serve", "--hostname", "127.0.0.1", "--port", String(port)],
            currentDirectory: projects.first, environment: configuration.environment(environment),
            terminationDelay: .seconds(2))
        process = child
        do {
            try child.start()
            try Data(String(child.processIdentifier).utf8).write(to: configuration.serverPIDFile, options: .atomic)
            outputReader = Task { [weak self] in
                do {
                    for try await line in child.lines { await self?.startupLine(line, generation: generation) }
                } catch { /* Never forward process text or errors containing it. */ }
                await self?.exited(generation: generation)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while password == nil || !listening {
                // Some builds emit startup banners on stderr. Read only in memory.
                for line in child.stderrText.split(separator: "\n") { startupLine(String(line)) }
                try Task.checkCancellation()
                guard generation == self.generation, child.isRunning, ContinuousClock.now < deadline else { throw AgentFailure.offline }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard generation == self.generation, child.isRunning else { throw AgentFailure.offline }
            session = localHTTPSession()
        } catch { await close(); throw (error as? AgentFailure) ?? .offline }
    }
    /// Startup stdout is consumed only here, never turned into AgentEvents,
    /// diagnostics, logger messages, activity events or persistence payloads.
    func startupLine(_ line: String) {
        if line.contains("server listening on ") { listening = true }
        guard password == nil, let range = line.range(of: "server password ") else { return }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { password = value }
    }
    private func startupLine(_ line: String, generation: UUID) {
        guard generation == self.generation else { return }; startupLine(line)
    }
    private func exited(generation: UUID) {
        guard generation == self.generation else { return }
        password = nil
        session?.invalidateAndCancel(); session = nil
        eventContinuation?.finish(throwing: AgentFailure.crashed(exitCode: nil))
    }
    private func authorized(_ path: String, method: String = "GET", body: JSONValue? = nil) throws -> URLRequest {
        guard let baseURL, let password, path.hasPrefix("api/"), !path.contains(".."),
              let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("/"))?.absoluteURL,
              url.host == "127.0.0.1", url.port == baseURL.port else { throw AgentFailure.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 30
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.jsonString.utf8)
        }
        return request
    }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        guard let session else { throw AgentFailure.offline }
        do {
            let request = try authorized(path, method: method, body: body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, response.url == request.url,
                  (200..<300).contains(http.statusCode), data.count <= 8 * 1_048_576 else { throw AgentFailure.offline }
            if data.isEmpty { return .null }
            guard let value = JSONValue.parse(String(decoding: data, as: UTF8.self)) else { throw AgentFailure.invalidRequest }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch { throw (error as? AgentFailure) ?? .offline }
    }
    func subscribe() async throws -> AsyncThrowingStream<JSONValue, Error> {
        guard let session, eventReader == nil else { throw AgentFailure.invalidTransition }
        var request = try authorized("api/event")
        request.timeoutInterval = 7 * 24 * 60 * 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request) }
        catch { throw AgentFailure.offline }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == request.url else { throw AgentFailure.offline }
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream(bufferingPolicy: .bufferingOldest(4096))
        eventContinuation = continuation
        eventReader = Task {
            do {
                // SSE framing is bounded even for a malicious/garbled local server.
                var line = Data(), frame = OpencodeSSEDecoder()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if byte == 10 {
                        guard let text = String(data: line, encoding: .utf8) else { throw AgentFailure.invalidRequest }
                        if let event = try frame.consume(text) {
                            guard case .enqueued = continuation.yield(event) else { throw AgentFailure.invalidTransition }
                        }
                        line.removeAll(keepingCapacity: true)
                    } else {
                        guard line.count < 1_048_576 else { throw AgentFailure.invalidRequest }
                        line.append(byte)
                    }
                }
                continuation.finish(throwing: AgentFailure.offline)
            } catch { continuation.finish(throwing: (error as? AgentFailure) ?? .offline) }
        }
        return stream
    }
    func close() async {
        if let closeTask { await closeTask.value; return }
        generation = UUID(); listening = false
        password = nil; baseURL = nil
        session?.invalidateAndCancel(); session = nil
        eventReader?.cancel(); eventReader = nil
        eventContinuation?.finish(); eventContinuation = nil
        outputReader?.cancel(); outputReader = nil
        let child = process; process = nil
        let recovery = recoveryTask
        let cleanup = Task { [file = configuration.serverPIDFile] in
            _ = try? await recovery?.value
            if let child {
                do {
                    try await child.shutdown(grace: .zero)
                    OpencodeServerPID.remove(file: file, matching: child.processIdentifier)
                } catch { /* Keep the PID file so startup can retry verified cleanup. */ }
            }
        }
        closeTask = cleanup
        await cleanup.value
        closeTask = nil
    }
    private static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentFailure.offline }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw AgentFailure.offline }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard status == 0 else { throw AgentFailure.offline }
        return UInt16(bigEndian: address.sin_port)
    }
}

/// The PID is lifecycle metadata, never authority to signal an arbitrary process.
/// Revalidate native argv and group ownership before each stale-group signal.
enum OpencodeServerPID {
    static func isServer(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && (arguments[0] as NSString).lastPathComponent == "opencode"
            && arguments[1] == "serve"
    }
    static func arguments(for pid: Int32) -> [String]? {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&query, 3, nil, &count, nil, 0) == 0, count > 4, count <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctl(&query, 3, &bytes, &count, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return nil }
        // KERN_PROCARGS2: argc, executable path, padding NULs, argv, environment.
        var offset = MemoryLayout<Int32>.size
        while offset < count, bytes[offset] != 0 { offset += 1 }
        while offset < count, bytes[offset] == 0 { offset += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < count, bytes[offset] != 0 { offset += 1 }
            guard offset < count, let value = String(bytes: bytes[start..<offset], encoding: .utf8) else { return nil }
            result.append(value); offset += 1
        }
        return result
    }
    static func recover(file: URL,
                        inspect: @Sendable (Int32) -> [String]? = { arguments(for: $0) },
                        group: @Sendable (Int32) -> Int32 = { getpgid($0) },
                        signal: @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }) async throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              let argv = inspect(pid), isServer(argv), group(pid) == pid else { return }
        guard signal(-pid, SIGTERM) == 0 || errno == ESRCH else { throw AgentFailure.offline }
        // Cleanup survives cancellation of the startup task.
        await Task.detached { try? await Task.sleep(for: .seconds(2)) }.value
        let remainingGroup = group(pid)
        let leaderExited = remainingGroup == -1 && errno == ESRCH
        if leaderExited || (remainingGroup == pid && inspect(pid).map(isServer) == true) {
            guard signal(-pid, SIGKILL) == 0 || errno == ESRCH else { throw AgentFailure.offline }
        }
        remove(file: file, matching: pid)
    }
    static func remove(file: URL, matching pid: Int32) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text == String(pid) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}

struct OpencodeSSEDecoder {
    private var data = ""
    mutating func consume(_ raw: String) throws -> JSONValue? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            defer { data = "" }
            guard let value = JSONValue.parse(data) else { throw AgentFailure.invalidRequest }
            return value
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }
            guard data.utf8.count + value.utf8.count < 1_048_576 else { throw AgentFailure.invalidRequest }
            if !data.isEmpty { data += "\n" }; data += value
        }
        return nil
    }
}
