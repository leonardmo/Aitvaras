import Foundation
import AitvarasAgents

/// Discovers tool names for a definition the user has approved testing. The
/// caller owns consent and audit. The probe never invokes a discovered tool.
public enum NativeMCPSetupProbe {
    public enum Failure: LocalizedError, Equatable, Sendable {
        case unsupportedTransport, executableUnavailable, missingCredential, authenticationRequired
        case invalidDefinition, invalidResponse, timedOut, cleanupFailed

        public var errorDescription: String? {
            switch self {
            case .unsupportedTransport: "Connection testing supports local commands and native HTTPS MCP endpoints."
            case .executableUnavailable: "The server command could not be started. Check the executable and working folder."
            case .missingCredential: "A credential needed for the connection test is missing or unusable."
            case .authenticationRequired: "The endpoint rejected the supplied credentials or needs sign-in."
            case .invalidDefinition: "The server definition cannot be tested with these settings."
            case .invalidResponse: "The server did not return a valid MCP tool list."
            case .timedOut: "The server took too long to return its tool list."
            case .cleanupFailed: "Aitvaras could not confirm that the test process stopped."
            }
        }
    }

    private static let maximumFrameBytes = 256 * 1024
    private static let maximumOutputBytes = 1024 * 1024
    private static let maximumTools = 256
    private static let reservedHeaders: Set<String> = [
        "accept", "connection", "cookie", "expect", "host", "keep-alive", "origin",
        "referer", "te", "trailer", "transfer-encoding", "upgrade", "user-agent"
    ]
    private static let ambientEnvironment: Set<String> = [
        "PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "SHELL"
    ]

    public static func test(server: AgentMCPServer, directory: URL, providerEnvironment: [String: String],
                            resolveSecret: AgentMCPRuntimeFile.SecretResolver) async throws -> [String] {
        try await test(server: server, directory: directory, providerEnvironment: providerEnvironment,
                       resolveSecret: resolveSecret, timeout: .seconds(12))
    }

    static func test(server: AgentMCPServer, directory: URL, providerEnvironment: [String: String],
                     resolveSecret: AgentMCPRuntimeFile.SecretResolver, timeout: Duration,
                     send: GatewayHTTP? = nil) async throws -> [String] {
        do { try server.validate() } catch { throw Failure.invalidDefinition }
        guard server.management == nil else { throw Failure.unsupportedTransport }
        try Task.checkCancellation()
        switch server.transport {
        case .stdio:
            guard let command = server.command, directory.isFileURL,
                  server.args.reduce(command.utf8.count, { $0 + $1.utf8.count }) <= 131_072 else { throw Failure.invalidDefinition }
            let resolved = try await resolve(server.env, lookup: resolveSecret)
            var ambient = providerEnvironment.filter { ambientEnvironment.contains($0.key) }
            ambient["PATH"] = [ambient["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"].compactMap { $0 }.joined(separator: ":")
            let environment = ProviderEnvironment.make(inherited: ambient.merging(resolved.values) { _, supplied in supplied })
            guard resolved.values.allSatisfy({ environment[$0.key] == $0.value }) else { throw Failure.invalidDefinition }
            guard let executable = locate(command, directory: directory, path: environment["PATH"]) else { throw Failure.executableUnavailable }
            return try await stdio(executable: executable, arguments: server.args, directory: directory,
                                   environment: environment, secrets: resolved.secrets, timeout: timeout)
        case .http:
            guard let rawURL = server.url, rawURL.lowercased().hasPrefix("https://") else { throw Failure.unsupportedTransport }
            let endpoint: URL
            do { endpoint = try GatewayOAuth.validated(URL(string: rawURL)) }
            catch { throw Failure.invalidDefinition }
            let names = server.headers.keys.map { $0.lowercased() }
            guard Set(names).count == names.count, names.allSatisfy({ name in
                !reservedHeaders.contains(name) && !name.hasPrefix("content-") && !name.hasPrefix("mcp-") && !name.hasPrefix("proxy-")
            }) else { throw Failure.invalidDefinition }
            let resolved = try await resolve(server.headers, lookup: resolveSecret)
            guard resolved.values.values.allSatisfy({ value in
                !value.utf8.contains { $0 < 32 || $0 == 127 }
            }) else { throw Failure.missingCredential }
            return try await withDeadline(timeout) {
                try await https(endpoint: endpoint, headers: resolved.values,
                                secrets: resolved.secrets, send: send ?? GatewayHTTPClient.make())
            }
        case .sse:
            throw Failure.unsupportedTransport
        }
    }

    private static func resolve(_ values: [String: AgentMCPValue], lookup: AgentMCPRuntimeFile.SecretResolver)
        async throws -> (values: [String: String], secrets: [String]) {
        var resolved: [String: String] = [:]
        var cache: [String: String] = [:]
        var bytes = 0
        for (name, value) in values {
            try Task.checkCancellation()
            let text: String
            switch value {
            case .literal(let literal): text = literal
            case .secretReference(let reference):
                if let prior = cache[reference] { text = prior }
                else {
                    let credential: String?
                    do { credential = try await lookup(reference) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw Failure.missingCredential }
                    try Task.checkCancellation()
                    guard let credential, !credential.isEmpty, credential.utf8.count <= 32_768,
                          !credential.contains("\0") else { throw Failure.missingCredential }
                    cache[reference] = credential
                    text = credential
                }
            }
            bytes += name.utf8.count + text.utf8.count
            guard bytes <= 131_072 else { throw Failure.invalidDefinition }
            resolved[name] = text
        }
        let secrets = Array(cache.values)
        let authorizationTokens = secrets.compactMap { value -> String? in
            let parts = value.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, ["bearer", "basic", "token"].contains(parts[0].lowercased()) else { return nil }
            return String(parts[1])
        }
        return (resolved, secrets + authorizationTokens)
    }

    private static func locate(_ command: String, directory: URL, path: String?) -> URL? {
        func executable(_ url: URL) -> Bool {
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
        }
        if command.contains("/") {
            let candidate = command.hasPrefix("/")
                ? URL(fileURLWithPath: command) : directory.appendingPathComponent(command)
            return executable(candidate) ? candidate : nil
        }
        return (path ?? "").split(separator: ":").lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(command)
        }.first(where: executable)
    }

    private static func stdio(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                              secrets: [String], timeout: Duration) async throws -> [String] {
        let process = StreamingProcess(executable: executable, arguments: arguments, currentDirectory: directory,
                                       environment: environment)
        do { try process.start() } catch { throw Failure.executableUnavailable }
        let outcome: Result<[String], any Error>
        do {
            outcome = .success(try await withDeadline(timeout) {
                var frames = process.lines.makeAsyncIterator()
                var frameCount = 0, outputBytes = 0
                func notify(_ method: String, id: JSONValue? = nil, params: JSONValue? = nil) async throws {
                    var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
                    message["id"] = id
                    message["params"] = params
                    try await process.write(line: JSONValue.object(message).jsonString)
                }
                func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
                    let id = JSONValue.string(UUID().uuidString)
                    try await notify(method, id: id, params: params)
                    while let line = try await frames.next() {
                        try Task.checkCancellation()
                        let frameBytes = line.utf8.count
                        frameCount += 1
                        outputBytes += frameBytes
                        guard frameBytes <= maximumFrameBytes, frameCount <= 128, outputBytes <= maximumOutputBytes,
                              let message = JSONValue.parse(line), message["jsonrpc"] == .string("2.0") else {
                            throw Failure.invalidResponse
                        }
                        if message["method"]?.stringValue != nil, message["id"] == nil { continue }
                        return try response(message, id: id)
                    }
                    try Task.checkCancellation()
                    throw Failure.invalidResponse
                }

                let initialized = try await request("initialize", params: GatewayRemoteSession.initialize)
                _ = try version(initialized, supported: GatewayRemoteSession.versions + ["2024-11-05"])
                try await notify("notifications/initialized")
                return try await catalog(secrets: secrets) { cursor in
                    try await request("tools/list", params: cursorParameters(cursor))
                }
            })
        } catch { outcome = .failure(error) }
        do { try await process.shutdown(grace: .zero) } catch { throw Failure.cleanupFailed }
        try Task.checkCancellation()
        return try outcome.get()
    }

    private static func https(endpoint: URL, headers: [String: String], secrets: [String], send: GatewayHTTP) async throws -> [String] {
        func perform(_ method: String, id: JSONValue?, params: JSONValue? = nil,
                     session: String? = nil, protocolVersion: String? = nil) async throws -> GatewayHTTPResponse {
            var request = GatewayOAuth.rpc(endpoint, method: method, id: id, params: params, authorization: nil,
                                          sessionID: session, version: protocolVersion)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            let result = try await send(request, id)
            if [401, 403].contains(result.status) { throw Failure.authenticationRequired }
            guard (200..<300).contains(result.status), result.body.count <= maximumFrameBytes else { throw Failure.invalidResponse }
            return result
        }

        let initID = JSONValue.string(UUID().uuidString)
        let initial = try await perform("initialize", id: initID, params: GatewayRemoteSession.initialize)
        let protocolVersion = try version(response(initial.json, id: initID), supported: GatewayRemoteSession.versions)
        let session = GatewayOAuth.credential(initial["mcp-session-id"].map(JSONValue.string), maximum: 1024)
        guard initial["mcp-session-id"] == nil || session != nil else { throw Failure.invalidResponse }
        _ = try await perform("notifications/initialized", id: nil, session: session, protocolVersion: protocolVersion)
        let names = try await catalog(secrets: secrets) { cursor in
            let id = JSONValue.string(UUID().uuidString)
            let result = try await perform("tools/list", id: id, params: cursorParameters(cursor),
                                           session: session, protocolVersion: protocolVersion)
            return try response(result.json, id: id)
        }
        return names
    }

    private static func response(_ message: JSONValue?, id: JSONValue) throws -> JSONValue {
        guard let message, message["jsonrpc"] == .string("2.0"), message["id"] == id,
              message["error"] == nil, let result = message["result"], case .object = result else {
            throw Failure.invalidResponse
        }
        return result
    }

    private static func version(_ result: JSONValue, supported: [String]) throws -> String {
        guard let version = result["protocolVersion"]?.stringValue, supported.contains(version),
              case .object? = result["capabilities"]?["tools"] else { throw Failure.invalidResponse }
        return version
    }

    private static func cursorParameters(_ cursor: String?) -> JSONValue? {
        cursor.map { .object(["cursor": .string($0)]) }
    }

    private static func catalog(secrets: [String], page: (String?) async throws -> JSONValue) async throws -> [String] {
        var cursor: String?, seenCursors = Set<String>(), names = Set<String>()
        for _ in 0..<16 {
            let response = try await page(cursor)
            guard let tools = response["tools"]?.arrayValue, names.count + tools.count <= maximumTools else { throw Failure.invalidResponse }
            for tool in tools {
                guard let name = tool["name"]?.stringValue, name.utf8.count <= 128,
                      (try? AgentMCPConfiguration.validateName(name)) != nil,
                      tool["inputSchema"]?["type"] == .string("object"),
                      !secrets.contains(where: { name.contains($0) }), names.insert(name).inserted else {
                    throw Failure.invalidResponse
                }
            }
            guard let next = response["nextCursor"], next != .null else { return names.sorted() }
            guard let value = next.stringValue, !value.isEmpty, value.utf8.count <= 1024,
                  seenCursors.insert(value).inserted else { throw Failure.invalidResponse }
            cursor = value
        }
        throw Failure.invalidResponse
    }

    private static func withDeadline(_ timeout: Duration, operation: @escaping @Sendable () async throws -> [String]) async throws -> [String] {
        do {
            return try await withThrowingTaskGroup(of: [String].self) { group in
                group.addTask(operation: operation)
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw Failure.timedOut
                }
                defer { group.cancelAll() }
                guard let names = try await group.next() else { throw Failure.invalidResponse }
                return names
            }
        } catch {
            try Task.checkCancellation()
            if let failure = error as? Failure { throw failure }
            throw Failure.invalidResponse
        }
    }
}
