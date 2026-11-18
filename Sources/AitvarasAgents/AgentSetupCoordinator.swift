import Foundation
import AitvarasCore

public struct AgentSetupProject: Sendable {
    public let directory: URL
    public let context: AgentMCPLaunchContext
    public init(directory: URL, context: AgentMCPLaunchContext) { self.directory = directory; self.context = context }
}

public enum AgentSetupEdit: Sendable {
    case approve(name: String, fingerprint: String), deny(name: String), revoke(name: String)
    case globalEnabled(name: String, enabled: Bool)
    case permissionSource(AgentPermissionSource), localMayUseMCP(Bool)
    case server(name: String, definition: AgentMCPServer?)
}

public protocol AgentSetupPersistence: Sendable {
    func agentSetupProject(projectID: UUID) throws -> AgentSetupProject
    func editAgentSetup(projectID: UUID, edit: AgentSetupEdit) throws
    func globalAgentMCPServers() throws -> [String: AgentMCPServer]
    func editGlobalAgentMCPServer(name: String, definition: AgentMCPServer?) throws
    func removeAgentMCPServer(projectID: UUID?, name: String, deleteUnusedSecret: @Sendable (String) throws -> Void) throws
}

public struct AgentMCPFieldDraft: Sendable, Identifiable {
    public var id = UUID()
    public var name = ""
    public var value = ""
    public var secret = true
    public init(name: String = "", value: String = "", secret: Bool = true) {
        self.name = name; self.value = value; self.secret = secret
    }
}

/// Form-only transient values; never Codable and never included in audit payloads.
public struct AgentMCPServerDraft: Sendable {
    public var name = ""
    public var transport: AgentMCPServer.Transport = .stdio
    public var command = ""
    public var arguments = ""
    public var url = ""
    public var fields: [AgentMCPFieldDraft] = []
    public init() {}

    func definition(references: [UUID: String]) throws -> AgentMCPServer {
        try AgentMCPConfiguration.validateName(name)
        guard fields.count <= 256, Set(fields.map(\.id)).count == fields.count else { throw AgentMCPError.invalidConfiguration }
        var values: [String: AgentMCPValue] = [:]
        for field in fields {
            guard !field.name.isEmpty, values[field.name] == nil else { throw AgentMCPError.invalidConfiguration }
            if transport != .stdio, field.value.contains(where: \.isNewline) { throw AgentMCPError.invalidConfiguration }
            if field.secret {
                guard let reference = references[field.id] else { throw AgentMCPError.secretUnavailable }
                values[field.name] = .secretReference(reference)
            } else { values[field.name] = .literal(field.value) }
        }
        let server: AgentMCPServer
        if transport == .stdio {
            // One argument per line preserves spaces without shell parsing.
            let args = arguments.isEmpty ? [] : arguments.components(separatedBy: "\n")
            server = .init(command: command, args: args, env: values)
        } else { server = .init(transport: transport, url: url, headers: values) }
        try server.validate()
        return server
    }
}

public struct AgentSetupServerRow: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable { case repository, project, global, user, account, plugin, provider }
    public enum Indicator: String, Sendable { case connected, needsSignIn, off, pendingApproval, approved, pending, failed, unknown }
    public let name: String
    public let source: Source
    public let indicator: Indicator
    public let transport: AgentMCPServer.Transport?
    public let fingerprint: String?
    public let canApprove: Bool
    public let canDeny: Bool
    public let canRemove: Bool
    public let isOffInProject: Bool
    public let signInUnavailable: String?
    public let detail: String?
    public var repositorySource: String? = nil
    public var isApproved = false
    public var id: String { source.rawValue + "." + name }
    public var sourceLabel: String {
        switch source {
        case .repository: "Repo · " + (repositorySource ?? ".mcp.json")
        case .project: "App · this project"
        case .global: "App · all projects"
        case .user: "User settings"
        case .account: "Account"
        case .plugin: "Plugin"
        case .provider: "Provider settings"
        }
    }
    public var canSignIn: Bool {
        signInUnavailable == nil && [.needsSignIn, .approved, .unknown, .failed].contains(indicator)
    }
}

public struct AgentSetupState: Sendable, Equatable {
    public let projectID: UUID?
    public let provider: AgentProvider
    public var servers: [AgentSetupServerRow] = []
    public var snapshot: AgentSetupSnapshot?
    public var permissionSource: AgentPermissionSource = .repo
    public var localMayUseMCP = false
    public var notices: [String] = []
    public init(projectID: UUID?, provider: AgentProvider) { self.projectID = projectID; self.provider = provider }
}

/// Owns configuration mutations independently of view lifetime. Store and
/// profile Keychain adapters are injected by the app; Agents never imports Store.
public actor AgentSetupCoordinator {
    public struct Secrets: Sendable {
        public var set: @Sendable (String, String) throws -> Void
        public var delete: @Sendable (String) throws -> Void
        public init(set: @escaping @Sendable (String, String) throws -> Void,
                    delete: @escaping @Sendable (String) throws -> Void) { self.set = set; self.delete = delete }
    }
    private let persistence: any AgentSetupPersistence
    private let secrets: Secrets
    private let profileBackend: AgentSessionManager.ProfileBackendFactory?
    private let profileDirectory: @Sendable (String) throws -> URL?
    private let backends: [AgentProvider: any AgentBackend]
    private let audit: AgentActionCoordinator.Audit
    private let metadataUserDirectory: URL?
    private var snapshots: [String: (snapshot: AgentSetupSnapshot, revision: String)] = [:]
    private var generations: [String: UUID] = [:]
    private var saving = false
    private var closing = false
    private var logins: [UUID: Task<Void, Error>] = [:]
    private var probes: [UUID: Task<AgentSetupSnapshot, Error>] = [:]
    public init(persistence: any AgentSetupPersistence, secrets: Secrets,
                backends: [AgentProvider: any AgentBackend], metadataUserDirectory: URL? = nil,
                profileBackend: AgentSessionManager.ProfileBackendFactory? = nil,
                profileDirectory: @escaping @Sendable (String) throws -> URL? = { _ in nil },
                audit: @escaping AgentActionCoordinator.Audit) {
        self.profileBackend = profileBackend; self.profileDirectory = profileDirectory
        self.persistence = persistence; self.secrets = secrets; self.backends = backends; self.audit = audit
        self.metadataUserDirectory = metadataUserDirectory
    }

    private func scopedBackend(provider: AgentProvider, profile: String) throws -> any AgentBackend {
        let choice = AgentProviderChoice(provider: provider, profile: profile)
        if let profileBackend { return try profileBackend(choice) }
        guard choice.profile == "default", let backend = backends[provider] else { throw AgentFailure.notInstalled }
        return backend
    }
    private func location(projectID: UUID, directory: URL?) throws -> AgentSetupProject {
        let project = try persistence.agentSetupProject(projectID: projectID)
        return .init(directory: directory ?? project.directory, context: project.context)
    }
    private func key(projectID: UUID, directory: URL, provider: AgentProvider, profile: String = "default") -> String {
        projectID.uuidString + "." + directory.standardizedFileURL.path + "." + provider.rawValue + "." + (provider == .claude ? profile : "default")
    }
    private func revision(_ project: AgentSetupProject) throws -> String {
        try AgentMCPLaunchPolicy(load: { _, _ in project.context }, audit: { _ in throw AgentMCPError.auditFailed })
            .snapshot(directory: project.directory, projectID: project.context.projectID).status.revision
    }

    public func state(projectID: UUID?, directory: URL? = nil, provider: AgentProvider, profile: String = "default") async throws -> AgentSetupState {
        var state = AgentSetupState(projectID: projectID, provider: provider)
        guard let projectID else {
            let globals = try persistence.globalAgentMCPServers()
            state.servers = globals.keys.sorted().map { row(name: $0, source: .global, server: globals[$0], snapshot: nil, provider: provider) }
            return state
        }
        let project = try location(projectID: projectID, directory: directory), setup = project.context.setup
        let globals = project.context.globalServers
        let cached = snapshots[key(projectID: projectID, directory: project.directory, provider: provider, profile: profile)]
        let snapshot = provider == .codex || cached?.revision == (try? revision(project)) ? cached?.snapshot : nil
        state.snapshot = snapshot; state.permissionSource = project.context.permissionSource; state.localMayUseMCP = setup.localMayUseMCP
        if provider == .codex {
            state.servers = (snapshot?.servers ?? []).map { row(name: $0.name, source: .provider, server: nil, snapshot: $0, provider: provider) }
            return state
        }
        if state.snapshot == nil {
            var metadata = AgentSetupSnapshot(provider: provider)
            metadata.metadata = await AgentProjectMetadataReader(projectDirectory: project.directory,
                userDirectory: provider == .claude ? (try profileDirectory(profile) ?? metadataUserDirectory) : nil).read()
            state.snapshot = metadata
        }
        let inventory = AgentMCPResolver.repositoryInventory(directory: project.directory)
        if inventory.unreadable { state.notices.append("Project MCP configuration could not be read. Repo servers are disabled.") }
        for name in globals.keys.sorted() where setup.projectServers[name] == nil {
            state.servers.append(row(name: name, source: .global, server: globals[name],
                snapshot: snapshot?.servers.first { $0.name == name }, provider: provider,
                indicator: provider == .local && !setup.localMayUseMCP ? .off : nil, off: setup.disabledGlobalServers.contains(name)))
        }
        for name in setup.projectServers.keys.sorted() {
            state.servers.append(row(name: name, source: .project, server: setup.projectServers[name],
                snapshot: snapshot?.servers.first { $0.name == name }, provider: provider,
                indicator: provider == .local && !setup.localMayUseMCP ? .off : nil))
        }
        for (name, entry) in inventory.entries.sorted(by: { $0.key < $1.key }) {
            let approved = !inventory.unreadable && !entry.conflicting && entry.server != nil && !setup.deniedServers.contains(name) && setup.approvedServers[name] == entry.fingerprint
            let status: AgentSetupServerRow.Indicator? = entry.server == nil ? .failed : setup.deniedServers.contains(name) ? .off : !approved ? .pendingApproval : provider == .local && (!setup.localMayUseMCP || entry.hasAdditionalOptions) ? .off : nil
            state.servers.append(row(name: name, source: .repository, server: entry.server,
                snapshot: approved ? snapshot?.servers.first { $0.name == name } : nil, provider: provider,
                indicator: status, fingerprint: entry.fingerprint, supported: !inventory.unreadable && !entry.conflicting && entry.server != nil, approved: approved,
                off: setup.deniedServers.contains(name), detail: entry.unsupportedReason ?? (entry.hasAdditionalOptions && provider == .local ? "Local: additional repo options cannot be translated." : nil), repositorySource: entry.sourceFiles.joined(separator: ", ")))
        }
        let names = Set(state.servers.map(\.name))
        for server in snapshot?.servers ?? [] where !names.contains(server.name) {
            let source: AgentSetupServerRow.Source = server.source == "claudeai" ? .account : server.source == "plugin" ? .plugin : .user
            state.servers.append(row(name: server.name, source: source, server: nil, snapshot: server, provider: provider))
        }
        do { _ = try AgentMCPResolver.prepare(directory: project.directory, setup: setup, globalServers: globals) }
        catch AgentMCPError.nameCollision { state.notices.append("App and repo MCP server names conflict. Remove or rename the app-added server.") }
        catch { state.notices.append("Agent setup could not be resolved.") }
        state.notices += state.snapshot?.metadata.warnings ?? []
        return state
    }

    private func row(name: String, source: AgentSetupServerRow.Source, server: AgentMCPServer?, snapshot: AgentSetupServer?,
                     provider: AgentProvider, indicator: AgentSetupServerRow.Indicator? = nil, fingerprint: String? = nil,
                     supported: Bool = true, approved: Bool = false, off: Bool = false, detail: String? = nil, repositorySource: String? = nil) -> AgentSetupServerRow {
        let nativeStatus: AgentSetupServerRow.Indicator = switch snapshot?.status {
        case .connected: .connected; case .needsAuth: .needsSignIn; case .failed: .failed; case .pending: .pending; default: .unknown
        }
        let reported = approved && provider == .claude && nativeStatus == .unknown ? AgentSetupServerRow.Indicator.approved : nativeStatus
        let status = indicator ?? (off ? .off : reported)
        let signInReason: String?
        if source == .global || source == .project { signInReason = "Sign-in is unavailable for app-added servers in this phase." }
        else if provider == .local { signInReason = "Local: stdio servers only" }
        else if !supported || server?.transport == .stdio { signInReason = "OAuth sign-in is unavailable for this server." }
        else if source == .provider, ["unsupported", "bearerToken"].contains(snapshot?.authentication) { signInReason = "OAuth sign-in is unavailable for this server." }
        else if source == .plugin { signInReason = "Sign-in is unavailable for this server source." }
        else if status == .off || status == .pendingApproval { signInReason = "Approve this repo server before signing in." }
        else { signInReason = nil }
        let remoteLocal = provider == .local && server != nil && server?.transport != .stdio
        return .init(name: name, source: source, indicator: remoteLocal ? .off : status,
            transport: server?.transport, fingerprint: fingerprint, canApprove: source == .repository && supported && !approved,
            canDeny: source == .repository, canRemove: source == .global || source == .project,
            isOffInProject: off, signInUnavailable: signInReason,
            detail: remoteLocal ? "Local: stdio servers only" : detail ?? (status == .approved ? "Approved — starts with the next chat" : nil),
            repositorySource: repositorySource, isApproved: approved)
    }

    public func refresh(projectID: UUID, directory: URL? = nil, provider: AgentProvider, profile: String = "default") async throws -> AgentSetupState {
        guard !closing else { throw AgentFailure.invalidTransition }
        let project = try location(projectID: projectID, directory: directory)
        let backend = try scopedBackend(provider: provider, profile: profile)
        let key = key(projectID: projectID, directory: project.directory, provider: provider, profile: profile), token = UUID()
        let startedRevision = provider == .codex ? "codex" : try revision(project)
        generations[key] = token
        try await record("Check agent setup", projectID: projectID, risk: .read)
        try Task.checkCancellation()
        guard !closing else { throw AgentFailure.invalidTransition }
        let probe = Task { try await backend.setup(directory: project.directory, projectID: projectID) }
        probes[token] = probe
        defer { probes.removeValue(forKey: token) }
        let snapshot = try await withTaskCancellationHandler { try await probe.value } onCancel: { probe.cancel() }
        try Task.checkCancellation()
        guard generations[key] == token else { throw CancellationError() }
        if provider != .codex, try revision(location(projectID: projectID, directory: project.directory)) != startedRevision { throw CancellationError() }
        snapshots[key] = (snapshot, startedRevision)
        return try await state(projectID: projectID, directory: project.directory, provider: provider, profile: profile)
    }

    public func report(_ snapshot: AgentSetupSnapshot, projectID: UUID, directory: URL, revision reported: String? = nil, profile: String = "default") {
        guard let project = try? location(projectID: projectID, directory: directory) else { return }
        let current = snapshot.provider == .codex ? "codex" : (try? revision(project))
        guard let current, reported == nil || reported == current else { return }
        let key = key(projectID: projectID, directory: directory, provider: snapshot.provider, profile: profile)
        generations[key] = UUID(); snapshots[key] = (snapshot, current)
    }

    public func edit(projectID: UUID, directory: URL? = nil, edit: AgentSetupEdit) throws {
        try Task.checkCancellation()
        guard !saving, !closing else { throw AgentFailure.invalidTransition }
        if case .approve(let name, let fingerprint) = edit {
            let project = try location(projectID: projectID, directory: directory)
            let inventory = AgentMCPResolver.repositoryInventory(directory: project.directory)
            guard !inventory.unreadable, let entry = inventory.entries[name], entry.server != nil,
                  entry.fingerprint == fingerprint else { throw AgentMCPError.invalidApproval }
        }
        try persistence.editAgentSetup(projectID: projectID, edit: edit)
        snapshots = [:]; generations = [:]
    }

    public func saveServer(projectID: UUID?, directory: URL? = nil, draft: AgentMCPServerDraft) async throws {
        guard !saving, !closing else { throw AgentFailure.invalidTransition }
        saving = true
        defer { saving = false }
        var references: [UUID: String] = [:]
        for field in draft.fields where field.secret { references[field.id] = "agent.mcp." + UUID().uuidString }
        let definition = try draft.definition(references: references)
        // Reject collisions before writing any credential. Global/project name
        // shadowing is deliberate; app/repo collisions are never silently merged.
        try validateNewServer(projectID: projectID, directory: directory, name: draft.name)
        try await record("Save MCP server", projectID: projectID, risk: .reversibleWrite)
        try Task.checkCancellation()
        try validateNewServer(projectID: projectID, directory: directory, name: draft.name)
        var written: [String] = []
        do {
            for field in draft.fields where field.secret {
                let reference = references[field.id]!
                try AgentMCPValue.validateSecretReference(reference)
                try secrets.set(field.value, reference); written.append(reference)
            }
            if let projectID { try persistence.editAgentSetup(projectID: projectID, edit: .server(name: draft.name, definition: definition)) }
            else { try persistence.editGlobalAgentMCPServer(name: draft.name, definition: definition) }
        } catch {
            for key in written { try? secrets.delete(key) }
            throw AgentMCPError.invalidConfiguration
        }
        snapshots = [:]; generations = [:]
    }

    private func validateNewServer(projectID: UUID?, directory: URL?, name: String) throws {
        if let projectID {
            let project = try location(projectID: projectID, directory: directory)
            guard AgentMCPResolver.repositoryInventory(directory: project.directory).entries[name] == nil else { throw AgentMCPError.nameCollision }
            guard project.context.setup.projectServers[name] == nil else { throw AgentMCPError.invalidName }
        } else { guard try persistence.globalAgentMCPServers()[name] == nil else { throw AgentMCPError.invalidName } }
    }

    public func removeServer(projectID: UUID?, name: String) throws {
        try Task.checkCancellation()
        guard !saving, !closing else { throw AgentFailure.invalidTransition }
        try persistence.removeAgentMCPServer(projectID: projectID, name: name, deleteUnusedSecret: secrets.delete)
        snapshots = [:]; generations = [:]
    }

    public func signIn(projectID: UUID, directory: URL? = nil, provider: AgentProvider, profile: String = "default", rowID: String,
                       timeout: Duration = .seconds(300), onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws -> AgentSetupState {
        let current = try await state(projectID: projectID, directory: directory, provider: provider, profile: profile)
        guard !closing else { throw AgentFailure.invalidTransition }
        guard let row = current.servers.first(where: { $0.id == rowID }), row.canSignIn else { throw AgentFailure.unsupported }
        let backend = try scopedBackend(provider: provider, profile: profile)
        let project = try location(projectID: projectID, directory: directory)
        try await record("Sign in to MCP server", projectID: projectID, risk: .reversibleWrite)
        try Task.checkCancellation()
        let reread = try await state(projectID: projectID, directory: project.directory, provider: provider, profile: profile)
        guard let latest = reread.servers.first(where: { $0.id == rowID }), latest.canSignIn,
              latest.fingerprint == row.fingerprint else { throw AgentMCPError.invalidApproval }
        guard !closing else { throw AgentFailure.invalidTransition }
        let token = UUID()
        let login = Task {
            try await backend.signInMCP(name: row.name, directory: project.directory, timeout: timeout) { url in
                guard !Task.isCancelled, (try? ProviderSignIn.validate(url)) != nil else { return }
                await onBrowserURL(url)
            }
        }
        logins[token] = login
        defer { logins.removeValue(forKey: token) }
        do {
            try await withTaskCancellationHandler { try await login.value } onCancel: { login.cancel() }
            try Task.checkCancellation()
            try await record("MCP sign-in completed", projectID: projectID, risk: .read)
        } catch {
            try? await record(Task.isCancelled || error is CancellationError ? "MCP sign-in cancelled" : "MCP sign-in failed", projectID: projectID, risk: .read)
            throw error
        }
        return try await refresh(projectID: projectID, directory: project.directory, provider: provider, profile: profile)
    }

    /// App shutdown awaits process cleanup, even if the settings view is open.
    public func shutdown() async {
        closing = true
        defer { closing = false }
        let activeLogins = Array(logins.values), activeProbes = Array(probes.values)
        activeLogins.forEach { $0.cancel() }; activeProbes.forEach { $0.cancel() }
        for task in activeLogins { _ = try? await task.value }
        for task in activeProbes { _ = try? await task.value }
    }

    private func record(_ summary: String, projectID: UUID?, risk: ActionRisk) async throws {
        let tool = ToolDefinition(name: "setup", description: summary, parametersJSON: "{}", risk: risk)
        guard AutonomyPolicy().verdict(for: tool, connectorID: "agent.setup") == .allow else { throw AgentMCPError.auditFailed }
        try await audit(.init(kind: .toolExecuted, connectorID: "agent.setup", summary: summary,
            detailJSON: JSONValue.object(["projectID": projectID.map { .string($0.uuidString) } ?? .null,
                "risk": .string(risk.rawValue)]).jsonString))
    }
}
