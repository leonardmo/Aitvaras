import Foundation

/// One app-server connection per backend, with independent thread runs.
public actor CodexBackend: AgentBackend {
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

    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                profile: String = "default", overrides: [String: String] = [:]) {
        self.environment = ProviderEnvironment.make(inherited: environment, overrides: overrides)
        self.executable = ProviderLocator.executable(for: .codex, environment: self.environment,
            overrides: executable.map { [.codex: $0] } ?? [:])
        self.profile = profile
    }
    private func connection() async throws -> AgentWire {
        if let wire { return wire }
        if let connecting { return try await connecting.value }
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
        do { let result = try await task.value; wire = result; connecting = nil; return result }
        catch { connecting = nil; throw error }
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
    public func rateLimits() async throws -> [AgentRateLimitWindow] {
        let result = try await rpc("account/rateLimits/read")
        return codexRateLimits(result)
    }
    public func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun {
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
        return run
    }
    public func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    public func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }

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
        if method == "account/login/completed", loginInProgress, let loginID = parameters["loginId"]?.stringValue {
            if loginResults.count < 16 { loginResults[loginID] = parameters["success"]?.boolValue ?? false }
            return
        }
        if method == "account/rateLimits/updated", id == nil {
            for run in runs.values { await run.rateLimits(codexRateLimits(parameters)) }
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
        for run in current.values { await run.disconnected(error) }
    }
    /// Application-level disposal; shutting down one run leaves other threads alive.
    public func shutdown() async throws {
        let current = transport; wire = nil; transport = nil
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
