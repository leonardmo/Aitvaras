import Foundation

/// One app-server connection per backend, with independent thread runs.
public actor CodexBackend: AgentBackend {
    public private(set) var availableSetup = AgentSetupSnapshot(provider: .codex)
    private var mcpEpoch = 0
    private var mcpUpdates: [String: (epoch: Int, server: AgentSetupServer)] = [:]
    private let executable: URL?
    private let environment: [String: String]
    private let profile: String
    private var wire: AgentWire?
    private var transport: AgentWire?
    private var generation = UUID()
    private var connecting: Task<AgentWire, Error>?
    private var runs: [String: CodexRun] = [:]
    private var loginResults: [String: Bool] = [:]
    private var loginInProgress = false
    private var mcpLogin: (name: String, generation: UUID)?
    private var mcpLoginResult: Bool?
    private var mcpLoginInProgress = false

    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                profile: String = "default", overrides: [String: String] = [:]) {
        self.environment = ProviderEnvironment.make(inherited: environment, overrides: overrides)
        self.executable = ProviderLocator.executable(for: .codex, environment: self.environment,
            overrides: executable.map { [.codex: $0] } ?? [:])
        self.profile = profile
    }
    private func connection() async throws -> AgentWire {
        if let wire { return wire }
        if let connecting {
            let generation = self.generation
            let result = try await connecting.value
            guard generation == self.generation else { throw AgentFailure.invalidTransition }
            wire = result; self.connecting = nil
            return result
        }
        guard let executable else { throw AgentFailure.notInstalled }
        let generation = UUID(); self.generation = generation
        let task = Task { [self] () throws -> AgentWire in
            let wire = AgentWire(process: StreamingProcess(executable: executable,
                arguments: ["app-server"],
                currentDirectory: nil, environment: environment), format: .codex)
            self.transport = wire
            do {
                try await wire.open(receive: { [weak self] value, id in await self?.receive(value, id: id, generation: generation) },
                    disconnected: { [weak self] error in await self?.disconnected(error, generation: generation) })
                _ = try await wire.request("initialize", .object([
                    "clientInfo": .object(["name": .string("aitvaras"), "title": .string("Aitvaras"), "version": .string("1")]),
                    "capabilities": .object(["experimentalApi": .bool(true)])]))
                try await wire.write(.object(["method": .string("initialized")]))
                return wire
            } catch { try? await wire.close(); throw error }
        }
        connecting = task
        do {
            let result = try await task.value
            guard self.generation == generation else { try? await result.close(); throw AgentFailure.invalidTransition }
            wire = result; connecting = nil; return result
        } catch {
            if self.generation == generation { connecting = nil }
            throw error
        }
    }
    public func status() async throws -> AgentStatus {
        guard executable != nil else { return AgentStatus(installed: false, authentication: .signedOut, capabilities: []) }
        let account = try await rpc("account/read", .object(["refreshToken": .bool(false)]))["account"]
        let authentication: AgentStatus.Authentication = account == nil || account == .null ? .signedOut
            : account?["type"]?.stringValue == "chatgpt" ? .subscription : .unsupported
        return AgentStatus(installed: true, authentication: authentication, capabilities: subscriptionCapabilities,
                           accountID: account?["chatgptAccountId"]?.stringValue ?? account?["id"]?.stringValue)
    }
    public func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        guard !loginInProgress else { throw AgentFailure.invalidTransition }
        loginInProgress = true; loginResults.removeAll()
        defer { loginInProgress = false; loginResults.removeAll() }
        let result = try await rpc("account/login/start", .object(["type": .string("chatgpt")]))
        guard let id = result["loginId"]?.stringValue, let rawURL = result["authUrl"]?.stringValue,
              let url = URL(string: rawURL), url.scheme == "https" || url.scheme == "http" else { throw AgentFailure.authRequired }
        do {
            await onBrowserURL(url)
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let success = loginResults[id] {
                    guard success else { throw AgentFailure.authRequired }
                    return
                }
                guard wire != nil else { throw AgentFailure.crashed(exitCode: nil) }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw AgentFailure.offline
        } catch {
            // Explicitly cancel the native login too; a late browser completion
            // must not leave an abandoned application login active.
            let wire = wire
            let cancellation = Task {
                _ = try? await wire?.request("account/login/cancel", .object(["loginId": .string(id)]), timeout: .seconds(2))
            }
            await cancellation.value
            throw error
        }
    }

    public func models() async throws -> [AgentModel] {
        var models: [AgentModel] = [], cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await rpc("model/list", .object(params))
            models += (result["data"]?.arrayValue ?? []).compactMap {
                guard let id = $0["model"]?.stringValue else { return nil }
                return AgentModel(id: id, name: $0["displayName"]?.stringValue ?? id,
                    efforts: ($0["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0["reasoningEffort"]?.stringValue })
            }
            let next = result["nextCursor"]?.stringValue
            guard next == nil || next != cursor else { throw AgentFailure.invalidRequest }
            cursor = next
        } while cursor != nil
        return models
    }

    public func signInMCP(name: String, directory: URL, timeout: Duration = .seconds(300),
                          onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        guard !mcpLoginInProgress else { throw AgentFailure.invalidTransition }
        mcpLoginInProgress = true
        defer { mcpLoginInProgress = false }
        // A dedicated login connection can be closed on cancellation without
        // interrupting the backend's existing chat threads.
        let login = CodexBackend(executable: executable, environment: environment, profile: profile)
        let deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(300)))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withTaskCancellationHandler {
                        try await login.performMCPLogin(name: name, timeout: timeout, onBrowserURL: onBrowserURL)
                    } onCancel: { Task { try? await login.shutdown() } }
                }
                group.addTask {
                    try await Task.sleep(for: min(timeout, .seconds(300)))
                    try? await login.shutdown()
                    throw ProviderSignInError.timedOut
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            try await login.shutdown()
        } catch {
            try? await login.shutdown()
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= deadline { throw ProviderSignInError.timedOut }
            throw error
        }
    }

    private func performMCPLogin(name: String, timeout: Duration,
                                 onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        try AgentMCPConfiguration.validateName(name)
        guard mcpLogin == nil else { throw AgentFailure.invalidTransition }
        let deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(300)))
        let connection = try await connection()
        guard mcpLogin == nil else { throw AgentFailure.invalidTransition }
        let generation = self.generation
        mcpLogin = (name, generation); mcpLoginResult = nil
        defer { mcpLogin = nil; mcpLoginResult = nil }
        do {
            let result = try await connection.request("mcpServer/oauth/login", .object(["name": .string(name),
                "timeoutSecs": .number(max(1, min(300, Double(timeout.components.seconds))))]),
                timeout: min(timeout, .seconds(300)), failOnTimeout: false)
            guard generation == self.generation, let raw = result["authorizationUrl"]?.stringValue,
                  let url = URL(string: raw) else { throw AgentFailure.authRequired }
            try ProviderSignIn.validate(url)
            try Task.checkCancellation()
            await onBrowserURL(url)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard generation == self.generation, wire === connection else { throw AgentFailure.offline }
                if let success = mcpLoginResult {
                    guard success else { throw AgentFailure.authRequired }
                    return
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw ProviderSignInError.timedOut
        } catch {
            // This protocol has no MCP OAuth cancel method. Dispose the owned
            // connection so an abandoned local login listener cannot survive.
            if generation == self.generation { try? await shutdown() }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    public func rateLimits() async throws -> [AgentRateLimitWindow] {
        let result = try await rpc("account/rateLimits/read")
        return codexRateLimits(result)
    }
    public func commands(directory: URL) async throws -> [AgentCommand] {
        return try AgentCommandCatalog.codex(await rpc("skills/list", .object([
            "cwds": .array([.string(directory.path)]), "forceReload": .bool(false)])), directory: directory)
    }
    public func files(query: String, directory: URL) async throws -> [AgentFileMention] {
        return try AgentFileMention.codex(await rpc("fuzzyFileSearch", .object([
            "query": .string(query), "roots": .array([.string(directory.path)])])), directory: directory)
    }
    public func setup(directory: URL, projectID: UUID?) async throws -> AgentSetupSnapshot {
        let connection = try await connection()
        let generation = self.generation, epoch = mcpEpoch
        var cursor: String?, cursors = Set<String>(), servers: [String: AgentSetupServer] = [:]
        repeat {
            var parameters: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { parameters["cursor"] = .string(cursor) }
            let result = try await connection.request("mcpServerStatus/list", .object(parameters), timeout: .seconds(10), failOnTimeout: false)
            guard generation == self.generation, wire === connection, let data = result["data"]?.arrayValue,
                  data.count <= 512 else { throw AgentFailure.invalidRequest }
            for raw in data {
                guard let name = AgentSetupSnapshot.name(raw["name"]), servers[name] == nil else { throw AgentFailure.invalidRequest }
                let auth = raw["authStatus"]?.stringValue
                let authentication = ["unsupported", "notLoggedIn", "bearerToken", "oAuth"].contains(auth) ? auth : nil
                let status = raw["status"]?.stringValue.map { AgentSetupServer.status($0) }
                    ?? (auth == "notLoggedIn" ? .needsAuth : mcpUpdates[name]?.server.status ?? .unknown)
                servers[name] = .init(name: name, status: status, source: "provider", authentication: authentication)
            }
            guard servers.count <= 512 else { throw AgentFailure.invalidRequest }
            if let next = result["nextCursor"], next != .null {
                guard let text = next.stringValue, !text.isEmpty, text.utf8.count <= 4096,
                      cursors.insert(text).inserted, cursors.count < 128 else { throw AgentFailure.invalidRequest }
                cursor = text
            } else { cursor = nil }
        } while cursor != nil
        for (name, update) in mcpUpdates where update.epoch > epoch {
            servers[name] = .init(name: name, status: update.server.status, source: "provider",
                                 authentication: servers[name]?.authentication)
        }
        var snapshot = AgentSetupSnapshot(provider: .codex)
        snapshot.serversAvailable = true; snapshot.servers = servers.values.sorted { $0.name < $1.name }
        availableSetup = snapshot
        for run in Array(runs.values) {
            guard generation == self.generation else { throw AgentFailure.invalidTransition }
            await run.setup(snapshot)
        }
        return snapshot
    }
    public func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun {
        guard !configuration.forkSession, configuration.resumeSessionAt == nil else { throw AgentFailure.unsupported }
        let authentication = try await status().authentication
        guard authentication == .subscription else {
            throw authentication == .signedOut ? AgentFailure.authRequired : AgentFailure.unsupported
        }
        var parameters: [String: JSONValue] = ["cwd": .string(configuration.directory.path),
            "approvalPolicy": .string(configuration.mode.codexApproval),
            "sandbox": .string(configuration.mode.codexSandbox)]
        if configuration.model != "default" { parameters["model"] = .string(configuration.model) }
        if !configuration.instructions.isEmpty { parameters["developerInstructions"] = .string(configuration.instructions) }
        let method: String
        if let resume = configuration.resume {
            guard resume.provider == .codex, resume.host == "local", resume.profile == profile,
                  runs[resume.nativeID] == nil else { throw AgentFailure.invalidRequest }
            parameters["threadId"] = .string(resume.nativeID); method = "thread/resume"
        } else { method = "thread/start" }
        let connection = try await connection()
        let result = try await connection.request(method, .object(parameters))
        guard wire === connection else { throw AgentFailure.invalidTransition }
        guard let nativeID = result["thread"]?["id"]?.stringValue, runs[nativeID] == nil else { throw AgentFailure.invalidRequest }
        if let provider = result["thread"]?["modelProvider"]?.stringValue, provider != "openai" { throw AgentFailure.unsupported }
        let session = AgentSessionID(provider: .codex, profile: profile, nativeID: nativeID)
        let run = CodexRun(backend: self, wire: connection, session: session, configuration: configuration)
        runs[nativeID] = run
        await run.started()
        if availableSetup.serversAvailable { await run.setup(availableSetup) }
        return run
    }
    func nativeSessionID(_ id: String) -> AgentSessionID { .init(provider: .codex, profile: profile, nativeID: id) }
    func validateNativeSession(_ session: AgentSessionID) throws {
        guard session.provider == .codex, session.profile == profile, session.host == "local", !session.nativeID.isEmpty else {
            throw AgentFailure.invalidRequest
        }
    }

    func rpc(_ method: String, _ parameters: JSONValue = .object([:])) async throws -> JSONValue {
        try await connection().request(method, parameters)
    }
    func reply(_ id: AgentRequestID, result: JSONValue?, error: Bool = false) async throws {
        guard let wire = transport else { throw AgentFailure.invalidTransition }
        try await wire.writeResponse(id: id, result: result, error: error)
    }
    func release(_ session: AgentSessionID, runID: UUID) {
        if runs[session.nativeID]?.id == runID { runs.removeValue(forKey: session.nativeID) }
    }
    private func receive(_ value: JSONValue, id: AgentRequestID?, generation: UUID) async {
        guard generation == self.generation else { return }
        guard let method = value["method"]?.stringValue else {
            if let id { try? await reply(id, result: nil, error: true) }
            return
        }
        let parameters = value["params"] ?? .null
        if method == "mcpServer/oauthLogin/completed", id == nil {
            if let login = mcpLogin, login.generation == generation,
               parameters["name"]?.stringValue == login.name, mcpLoginResult == nil {
                mcpLoginResult = parameters["success"]?.boolValue ?? false
            }
            return
        }
        if method == "account/login/completed", loginInProgress, let loginID = parameters["loginId"]?.stringValue {
            if loginResults.count < 16 { loginResults[loginID] = parameters["success"]?.boolValue ?? false }
            return
        }
        if method == "account/rateLimits/updated", id == nil {
            for run in runs.values { await run.rateLimits(codexRateLimits(parameters)) }
            return
        }
        if method == "mcpServer/startupStatus/updated", id == nil {
            guard let name = AgentSetupSnapshot.name(parameters["name"]),
                  let status = parameters["status"]?.stringValue, mcpUpdates.count < 512 || mcpUpdates[name] != nil else { return }
            let server = AgentSetupServer(name: name, status: AgentSetupServer.status(status), source: "provider",
                authentication: availableSetup.servers.first { $0.name == name }?.authentication)
            mcpEpoch += 1; mcpUpdates[name] = (mcpEpoch, server)
            availableSetup.serversAvailable = true
            availableSetup.servers.removeAll { $0.name == name }; availableSetup.servers.append(server)
            availableSetup.servers.sort { $0.name < $1.name }
            let snapshot = availableSetup
            for run in Array(runs.values) where generation == self.generation { await run.setup(snapshot) }
            return
        }
        guard let thread = parameters["threadId"]?.stringValue, let run = runs[thread] else {
            if let id { try? await reply(id, result: nil, error: true) }
            return
        }
        if method == "serverRequest/resolved" {
            if let id { await run.resolved(id) }; return
        }
        await run.receive(method, parameters: parameters, requestID: id)
    }
    private func disconnected(_ error: AgentFailure, generation: UUID) async {
        guard generation == self.generation else { return }
        let current = runs; runs.removeAll(); wire = nil; transport = nil
        availableSetup = .init(provider: .codex); mcpUpdates = [:]; mcpEpoch = 0
        for run in current.values { await run.disconnected(error) }
    }
    /// Application-level disposal; shutting down one run leaves other threads alive.
    public func shutdown() async throws {
        generation = UUID()
        availableSetup = .init(provider: .codex); mcpUpdates = [:]; mcpEpoch = 0
        let active = runs; runs.removeAll()
        let current = transport; wire = nil; transport = nil
        for run in active.values { await run.disconnected(.crashed(exitCode: nil)) }
        if let connecting { connecting.cancel(); _ = try? await connecting.value; self.connecting = nil }
        if let current { try await current.close() }
    }
}

extension AgentMode {
    var codexApproval: String { self == .ask ? "untrusted" : "on-request" }
    var codexSandbox: String { self == .plan ? "read-only" : "workspace-write" }
}

func codexRateLimits(_ value: JSONValue) -> [AgentRateLimitWindow] {
    let snapshots: [String: JSONValue]
    if let byID = value["rateLimitsByLimitId"]?.objectValue, !byID.isEmpty { snapshots = byID }
    else { snapshots = [value["rateLimits"]?["limitId"]?.stringValue ?? "codex": value["rateLimits"] ?? value] }
    return snapshots.sorted { $0.key < $1.key }.flatMap { key, snapshot in
        ["primary", "secondary"].compactMap { name in
            guard let window = snapshot[name], window != .null else { return nil }
            return AgentRateLimitWindow(id: key + "." + name,
                utilization: window["usedPercent"]?.doubleValue.map { min(1, max(0, $0 / 100)) },
                duration: window["windowDurationMins"]?.doubleValue.map { $0 * 60 }, resetsAt: window["resetsAt"]?.date)
        }
    }
}
