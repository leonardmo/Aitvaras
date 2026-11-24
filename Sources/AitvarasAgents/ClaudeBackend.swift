import Foundation
import AitvarasCore

public actor ClaudeBackend: AgentBackend {
    private let environment: [String: String]
    private let executable: URL?
    private let profile: String
    private let mcpPolicy: AgentMCPLaunchPolicy
    private let gateway: GatewayChatLaunch?
    private let probeDirectory: URL
    private var mcpLoginInProgress = false
    private struct LiveRun { weak var run: ClaudeRun?; let directory: URL; let projectID: UUID? }
    private var liveRuns: [UUID: LiveRun] = [:]
    public private(set) var mcpSetup: AgentMCPLaunchStatus?

    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                profile: String = "default", overrides: [String: String] = [:], mcpPolicy: AgentMCPLaunchPolicy = .default,
                probeDirectory: URL = FileManager.default.temporaryDirectory, gateway: GatewayChatLaunch? = nil) {
        self.environment = ProviderEnvironment.make(inherited: environment, overrides: overrides)
        self.executable = ProviderLocator.executable(for: .claude, environment: self.environment,
            overrides: executable.map { [.claude: $0] } ?? [:])
        self.profile = profile
        self.mcpPolicy = mcpPolicy
        self.gateway = gateway
        self.probeDirectory = probeDirectory
    }

    public func status() async throws -> AgentStatus {
        guard let executable else { return AgentStatus(installed: false, authentication: .signedOut, capabilities: []) }
        let output = try await OneShotProcess.run(executable: executable, arguments: ["auth", "status"],
            environment: environment, timeout: .seconds(15))
        guard !output.timedOut, let value = JSONValue.parse(output.stdout) else { throw AgentFailure.unknown }
        let authentication: AgentStatus.Authentication
        if value["loggedIn"]?.boolValue != true { authentication = .signedOut }
        else if value["apiKeySource"].map({ $0.stringValue != "none" }) ?? false || value["apiProvider"]?.stringValue != "firstParty" { authentication = .unsupported }
        else if value["authMethod"]?.stringValue == "claude.ai",
                ["pro", "max", "team", "enterprise"].contains((value["subscriptionType"]?.stringValue ?? "").lowercased().replacingOccurrences(of: "claude ", with: "")) {
            authentication = .subscription
        } else { authentication = .unsupported }
        return AgentStatus(installed: true, authentication: authentication, capabilities: subscriptionCapabilities,
                           accountID: authentication == .subscription ? Self.accountIdentity(value) : nil)
    }

    private static func accountIdentity(_ status: JSONValue) -> String? {
        if let account = status["accountUuid"]?.stringValue ?? status["accountId"]?.stringValue,
           !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return account
        }
        // Claude's subscription status commonly returns a member email and an
        // organization ID. Neither field on its own identifies this login.
        guard let email = status["email"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.contains("@"), email.utf8.count <= 320,
              let organization = status["orgId"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !organization.isEmpty, organization.utf8.count <= 512 else { return nil }
        return "claude-auth:" + StableIdentifier.digest([email, organization])
    }

    public func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        guard let executable else { throw AgentFailure.notInstalled }
        let process = StreamingProcess(executable: executable, arguments: ["auth", "login", "--claudeai"],
            currentDirectory: nil, environment: environment)
        try process.start()
        let timer = Task {
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            process.terminate()
        }
        // The CLI may print its URL to stderr and then wait for the browser.
        // Inspect only the bounded transient tail while the process is alive.
        let stderrURLs = Task {
            var seen = Set<URL>()
            while !Task.isCancelled {
                for url in Self.browserURLs(process.stderrText) where seen.insert(url).inserted {
                    await onBrowserURL(url)
                }
                if !process.isRunning { return }
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }
        defer { timer.cancel(); stderrURLs.cancel() }
        do {
            try await withTaskCancellationHandler {
                for try await line in process.lines {
                    for url in Self.browserURLs(line) { await onBrowserURL(url) }
                }
                await stderrURLs.value
                guard try await process.waitForExit() == 0 else { throw AgentFailure.authRequired }
            } onCancel: { process.terminate() }
        } catch { try? await process.shutdown(grace: .zero); throw error }
    }

    private static func browserURLs(_ text: String) -> [URL] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap {
            guard $0.hasPrefix("https://"), let url = URL(string: String($0)) else { return nil }
            return url
        }
    }

    public func models() async throws -> [AgentModel] {
        let run = try await makeRun(AgentSessionConfiguration(directory: probeDirectory, model: "default"))
        let models = await run.availableModels
        try await run.shutdown()
        return models
    }

    public func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun { try await makeRun(configuration) }
    public func commands(directory: URL) async throws -> [AgentCommand] {
        try await commands(directory: directory, projectID: nil)
    }
    public func commands(directory: URL, projectID: UUID?) async throws -> [AgentCommand] {
        try await commandCatalog(directory: directory, projectID: projectID).commands
    }
    public func commandCatalog(directory: URL, projectID: UUID?) async throws -> (commands: [AgentCommand], setup: AgentMCPLaunchStatus?) {
        // Starting a CLI only to list commands takes seconds, so the composer
        // popup reuses a running chat's catalog or a recent probe for the same
        // project and MCP setup revision.
        let revision = try mcpPolicy.snapshot(directory: directory, projectID: projectID).status.revision
        let key = CatalogKey(directory: directory, projectID: projectID, revision: revision)
        liveRuns = liveRuns.filter { $0.value.run != nil }
        for existing in liveRuns.values where existing.directory == directory && existing.projectID == projectID {
            if let run = existing.run, run.mcpSetup?.revision == revision, let commands = await run.availableCommands {
                catalogCache[key] = .init(commands: commands, setup: run.mcpSetup, date: .now)
                return (commands, run.mcpSetup)
            }
        }
        if let cached = catalogCache[key], Date.now.timeIntervalSince(cached.date) < Self.catalogLifetime {
            return (cached.commands, cached.setup)
        }
        let run = try await makeRun(.init(directory: directory, model: "default", projectID: projectID))
        let commands = await run.availableCommands
        try await run.shutdown()
        guard let commands else { throw AgentFailure.unsupported }
        catalogCache = catalogCache.filter { Date.now.timeIntervalSince($0.value.date) < Self.catalogLifetime }
        catalogCache[key] = .init(commands: commands, setup: run.mcpSetup, date: .now)
        return (commands, run.mcpSetup)
    }
    private struct CatalogKey: Hashable { let directory: URL; let projectID: UUID?; let revision: String }
    private struct CachedCatalog { let commands: [AgentCommand]; let setup: AgentMCPLaunchStatus?; let date: Date }
    private var catalogCache: [CatalogKey: CachedCatalog] = [:]
    static let catalogLifetime: TimeInterval = 120
    public func setup(directory: URL, projectID: UUID?) async throws -> AgentSetupSnapshot {
        liveRuns = liveRuns.filter { $0.value.run != nil }
        let revision = try mcpPolicy.snapshot(directory: directory, projectID: projectID).status.revision
        for existing in liveRuns.values where existing.directory == directory && existing.projectID == projectID {
            if let run = existing.run, run.mcpSetup?.revision == revision, await run.canRefreshSetup {
                return try await run.refreshSetup()
            }
        }
        let run = try await makeRun(.init(directory: directory, model: "default", projectID: projectID))
        do {
            let snapshot = try await run.refreshSetup()
            try await run.shutdown(); return snapshot
        } catch { try? await run.shutdown(); throw error }
    }
    public func signInMCP(name: String, directory: URL, timeout: Duration = .seconds(300),
                          onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        guard let executable else { throw AgentFailure.notInstalled }
        guard !mcpLoginInProgress else { throw AgentFailure.invalidTransition }
        mcpLoginInProgress = true
        defer { mcpLoginInProgress = false }
        try await AgentMCPLogin.run(executable: executable, name: name, directory: directory,
            environment: environment, timeout: timeout, onBrowserURL: onBrowserURL)
    }
    public func files(query: String, directory: URL) async throws -> [AgentFileMention] {
        let task = Task.detached { try AgentFileMention.localSearch(query: query, directory: directory) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func sideQuestion(configuration: AgentSessionConfiguration, question: String, timeout: Duration = .seconds(120)) async throws -> String {
        guard let executable, let session = configuration.resume, session.host == "local", session.profile == profile else { throw AgentConversationError.unavailable }
        let environment = environment
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                guard try await self.status().authentication == .subscription else { throw AgentFailure.authRequired }
                return try await ClaudeSideQuestion.run(executable: executable, environment: environment, configuration: configuration,
                    question: question, timeout: timeout)
            }
            group.addTask {
                try await Task.sleep(for: min(timeout, .seconds(120)))
                throw AgentConversationError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func makeRun(_ configuration: AgentSessionConfiguration) async throws -> ClaudeRun {
        guard let executable else { throw AgentFailure.notInstalled }
        let status = try await status()
        guard status.authentication == .subscription else {
            throw status.authentication == .signedOut ? AgentFailure.authRequired : AgentFailure.unsupported
        }
        if let resume = configuration.resume {
            guard resume.provider == .claude, resume.profile == profile, resume.host == "local" else { throw AgentFailure.invalidRequest }
        }
        if configuration.forkSession || configuration.resumeSessionAt != nil {
            guard configuration.forkSession, configuration.resume.flatMap({ UUID(uuidString: $0.nativeID) }) != nil,
                  configuration.resumeSessionAt.flatMap(UUID.init(uuidString:)) != nil else { throw AgentFailure.invalidRequest }
        }
        let snapshot = try mcpPolicy.snapshot(directory: configuration.directory, projectID: configuration.projectID)
        mcpSetup = snapshot.status
        let runID = UUID()
        let chatGateway = configuration.gatewayChatID.flatMap { _ in gateway }
        let fullAccess = configuration.permissions?.isFullAccess == true
        let file = try await mcpPolicy.runtimeFile(snapshot: snapshot, runID: runID, format: .claude,
                                                  gateway: chatGateway?.configuration, includeApprovedRepository: fullAccess)
        var launch = configuration
        do {
            try Task.checkCancellation()
            // Secret resolution can yield. Re-read once more before process startup.
            guard try mcpPolicy.snapshot(directory: configuration.directory, projectID: configuration.projectID).status.revision == snapshot.status.revision else {
                throw AgentFailure.invalidTransition
            }
        } catch { try? await file?.remove(); throw error }
        if let resume = configuration.resume, UUID(uuidString: resume.nativeID) != nil {
            do { launch.knownMessageIDs.formUnion(try historyReader.replayMessageIDs(session: resume)) }
            catch AgentNativeHistoryError.notFound { /* Durable transcript IDs remain available. */ }
            catch { try? await file?.remove(); throw error }
        }
        launch.settingsJSON = ClaudeRunPermissions.settings(snapshot.resolution.settingsJSON, permissions: configuration.permissions)
        launch.mcpConfigPath = file?.url
        launch.strictMCPConfig = fullAccess || snapshot.resolution.repositoryUnreadable
        launch.includeHookEvents = true
        let run = ClaudeRun(executable: executable, environment: environment, profile: profile, configuration: launch,
                            id: runID, accountID: status.accountID, runtimeFile: file, mcpSetup: snapshot.status, permissionSource: snapshot.permissionSource,
                            metadataReader: AgentProjectMetadataReader(projectDirectory: configuration.directory,
                                userDirectory: environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                                    ?? environment["HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent(".claude") },
                                environment: environment), validateProjectServers: { [mcpPolicy] report in
                                try await mcpPolicy.validateProjectServers(report, snapshot: snapshot, runID: runID)
                            })
        do {
            let register = configuration.gatewayChatID.flatMap { chatID in
                chatGateway?.register(client: .claude, chatID: chatID, projectID: configuration.projectID,
                                      permissions: configuration.permissions)
            }
            try await run.initialize(register: register)
            liveRuns = liveRuns.filter { $0.value.run != nil }
            liveRuns[runID] = .init(run: run, directory: configuration.directory, projectID: configuration.projectID)
            return run
        }
        catch { try? await run.shutdown(); throw error }
    }
    private var historyReader: ClaudeNativeHistory {
        let root = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".claude")
        return ClaudeNativeHistory(projectsDirectory: root.appendingPathComponent("projects"), profile: profile)
    }
    public func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> {
        try historyReader.list(folder: folder, cursor: cursor)
    }
    public func nativeSessions(folder: URL?, cursor: String?, archived: Bool) throws -> AgentPage<AgentSessionSummary> {
        try historyReader.list(folder: folder, cursor: cursor, archived: archived)
    }
    public func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> {
        try historyReader.history(session: session, cursor: cursor)
    }
}
