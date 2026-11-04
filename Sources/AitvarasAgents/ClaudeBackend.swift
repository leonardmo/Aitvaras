import Foundation

public actor ClaudeBackend: AgentBackend {
    private let environment: [String: String]
    private let executable: URL?
    private let profile: String

    public init(executable: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                profile: String = "default") {
        self.environment = ProviderEnvironment.make(inherited: environment)
        self.executable = ProviderLocator.executable(for: .claude, environment: self.environment,
            overrides: executable.map { [.claude: $0] } ?? [:])
        self.profile = profile
    }

    public func status() async throws -> AgentStatus {
        guard let executable else { return AgentStatus(installed: false, authentication: .signedOut, capabilities: []) }
        let output = try await OneShotProcess.run(executable: executable, arguments: ["auth", "status"],
            environment: environment, timeout: .seconds(15))
        guard !output.timedOut, let value = JSONValue.parse(output.stdout) else { throw AgentFailure.unknown }
        let authentication: AgentStatus.Authentication
        if value["loggedIn"]?.boolValue != true { authentication = .signedOut }
        else if value["apiKeySource"]?.stringValue != "none" || value["apiProvider"]?.stringValue != "firstParty" { authentication = .unsupported }
        else if value["authMethod"]?.stringValue == "claude.ai",
                ["pro", "max", "team", "enterprise"].contains((value["subscriptionType"]?.stringValue ?? "").lowercased().replacingOccurrences(of: "claude ", with: "")) {
            authentication = .subscription
        } else { authentication = .unsupported }
        return AgentStatus(installed: true, authentication: authentication, capabilities: subscriptionCapabilities)
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
        let run = try await makeRun(AgentSessionConfiguration(directory: FileManager.default.temporaryDirectory, model: "default"))
        let models = await run.availableModels
        try await run.shutdown()
        return models
    }

    public func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun { try await makeRun(configuration) }
    private func makeRun(_ configuration: AgentSessionConfiguration) async throws -> ClaudeRun {
        guard let executable else { throw AgentFailure.notInstalled }
        let status = try await status()
        guard status.authentication == .subscription else {
            throw status.authentication == .signedOut ? AgentFailure.authRequired : AgentFailure.unsupported
        }
        if let resume = configuration.resume {
            guard resume.provider == .claude, resume.profile == profile, resume.host == "local" else { throw AgentFailure.invalidRequest }
        }
        let run = ClaudeRun(executable: executable, environment: environment, profile: profile, configuration: configuration)
        do { try await run.initialize(); return run }
        catch { try? await run.shutdown(); throw error }
    }
    public func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    public func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
