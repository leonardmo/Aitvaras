import Foundation
import CryptoKit
import AitvarasCore

public struct AgentMCPLaunchContext: Sendable {
    public let projectID: UUID
    public var setup: AgentMCPProjectConfiguration
    public var globalServers: [String: AgentMCPServer]
    public var permissionSource: AgentPermissionSource
    public var alwaysAllowedTools: [String]
    public init(projectID: UUID, setup: AgentMCPProjectConfiguration = .init(),
                globalServers: [String: AgentMCPServer] = [:], permissionSource: AgentPermissionSource = .repo,
                alwaysAllowedTools: [String] = []) {
        self.projectID = projectID; self.setup = setup; self.globalServers = globalServers
        self.permissionSource = permissionSource; self.alwaysAllowedTools = alwaysAllowedTools
    }
}

/// Safe to expose to UI. Contains no definitions, credentials or runtime paths.
public struct AgentMCPLaunchStatus: Sendable, Equatable {
    public let revision: String
    public let repositoryUnreadable: Bool
    public let unsupportedRepositoryServers: [String]
    public var serverFingerprints: [String: String] = [:]
    public let unavailableForLocal: [String: AgentMCPResolution.LocalUnavailableReason]
    public var notice: String? {
        repositoryUnreadable ? "Project MCP configuration could not be read. Repo servers are disabled." : nil
    }
}

public struct AgentMCPLaunchSnapshot: Sendable {
    public let projectID: UUID
    public let resolution: AgentMCPResolution
    public let status: AgentMCPLaunchStatus
    public let permissionSource: AgentPermissionSource
}

/// Shared by the manager's reuse check and each backend's actual startup/probes.
/// Only the App/Store adapter knows persistence and the profile Keychain.
public struct AgentMCPLaunchPolicy: Sendable {
    public typealias Load = @Sendable (URL, UUID?) throws -> AgentMCPLaunchContext
    private let stateDirectory: URL
    private let load: Load
    private let audit: AgentActionCoordinator.Audit
    private let resolveSecret: AgentMCPRuntimeFile.SecretResolver
    public init(stateDirectory: URL = AitvarasPaths.stateDirectory, load: @escaping Load,
                audit: @escaping AgentActionCoordinator.Audit,
                resolveSecret: @escaping AgentMCPRuntimeFile.SecretResolver = { _ in nil }) {
        self.stateDirectory = stateDirectory; self.load = load; self.audit = audit; self.resolveSecret = resolveSecret
    }
    /// Standalone backends still disable unknown repo servers. App-added servers
    /// require the explicit persistence/audit adapter; no credentials are inherited.
    public static var `default`: Self {
        .init(load: { _, projectID in
            .init(projectID: projectID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        }, audit: { _ in throw AgentMCPError.auditFailed })
    }

    public func snapshot(directory: URL, projectID: UUID? = nil) throws -> AgentMCPLaunchSnapshot {
        let context = try load(directory, projectID)
        let resolution = try AgentMCPResolver.prepare(directory: directory, setup: context.setup, globalServers: context.globalServers)
        // Hash references/definitions, never resolved values. Include policy and
        // approval state even when a change currently produces the same server set.
        let value = JSONValue.object([
            "project": .string(context.projectID.uuidString), "directory": .string(directory.standardizedFileURL.path),
            "app": .object(try resolution.claudeServers.mapValues { .string(try $0.fingerprint()) }),
            "repo": .object(resolution.repositoryFingerprints.mapValues(JSONValue.string)),
            "unreadable": .bool(resolution.repositoryUnreadable),
            "disabled": .array(resolution.disabledProjectServers.map(JSONValue.string)),
            "approved": .object(context.setup.approvedServers.mapValues(JSONValue.string)),
            "denied": .array(context.setup.deniedServers.sorted().map(JSONValue.string)),
            "disabledGlobals": .array(context.setup.disabledGlobalServers.sorted().map(JSONValue.string)),
            "local": .bool(context.setup.localMayUseMCP), "permissionSource": .string(context.permissionSource.rawValue),
            "allowedTools": .array(context.alwaysAllowedTools.sorted().map(JSONValue.string))])
        let revision = SHA256.hash(data: Data(value.jsonString.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(projectID: context.projectID, resolution: resolution,
            status: .init(revision: revision, repositoryUnreadable: resolution.repositoryUnreadable,
                unsupportedRepositoryServers: resolution.repositoryEntries.filter { $0.value.server == nil || $0.value.conflicting }.keys.sorted(),
                serverFingerprints: try resolution.effectiveServers.mapValues { try $0.fingerprint() }.merging(
                    resolution.repositoryFingerprints.filter { resolution.effectiveServers[$0.key] != nil }) { _, repo in repo },
                unavailableForLocal: resolution.unavailableForLocal), permissionSource: context.permissionSource)
    }

    /// No raw server names/configuration enter the audit. A reported project
    /// server must belong to the exact approved launch snapshot, even if failed.
    public func validateProjectServers(_ report: JSONValue, snapshot: AgentMCPLaunchSnapshot, runID: UUID) async throws {
        let allowed = Set(snapshot.resolution.effectiveServers.keys).subtracting(snapshot.resolution.claudeServers.keys)
        let unexpected = (report["mcp_servers"]?.arrayValue ?? []).contains { server in
            guard server["source"]?.stringValue == "project" else { return false }
            guard let name = server["name"]?.stringValue,
                  (try? AgentMCPConfiguration.validateName(name)) != nil else { return true }
            return !allowed.contains(name)
        }
        guard unexpected else { return }
        try await audit(.init(kind: .confirmationDenied, connectorID: "agent.mcp",
            summary: "Unapproved project MCP server reported; run stopped", runID: runID))
        throw AgentFailure.unapprovedProjectMCP
    }

    public func runtimeFile(snapshot: AgentMCPLaunchSnapshot, runID: UUID,
                            format: AgentMCPRuntimeFile.Format, baseConfiguration: JSONValue? = nil,
                            gateway: GatewayCLIConfiguration? = nil) async throws -> AgentMCPRuntimeFile? {
        var servers = format == .claude ? snapshot.resolution.claudeServers : snapshot.resolution.localServers
        if let gateway {
            let name = GatewayCLIConfiguration.serverName
            guard format == .claude, servers[name] == nil, snapshot.resolution.repositoryEntries[name] == nil else {
                throw AgentMCPError.nameCollision
            }
            servers[name] = gateway.server
        }
        guard !servers.isEmpty else { return nil }
        return try await AgentMCPRuntimeFile.create(stateDirectory: stateDirectory, projectID: snapshot.projectID,
            runID: runID, servers: servers, format: format, baseConfiguration: baseConfiguration,
            audit: audit, resolveSecret: resolveSecret)
    }
}
