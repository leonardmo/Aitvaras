import Foundation
import GRDB
import AitvarasAgents
import AitvarasCore

/// The UUID is app-owned. Provider account IDs and credentials are not part of this record.
public struct GatewayUpstreamAccount: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "gatewayUpstreamAccount"
    public let id: UUID
    public let serverName: String
    public let definitionProjectID: UUID?
    public let definitionFingerprint: String
    public let globallyAvailable: Bool
    public fileprivate(set) var isGlobalDefault: Bool
}

public struct GatewayUpstream: Sendable, Equatable {
    public let account: GatewayUpstreamAccount
    public let definition: AgentMCPServer
}

public enum GatewayUpstreamError: LocalizedError, Equatable, Sendable {
    case invalidServerName, definitionUnavailable, definitionChanged
    case invalidAccount, defaultAlreadySet, accountInUse

    public var errorDescription: String? {
        switch self {
        case .invalidServerName: "Choose an available gateway server name."
        case .definitionUnavailable: "The gateway server definition is unavailable."
        case .definitionChanged: "The gateway server definition changed. Register a fresh account binding."
        case .invalidAccount: "This account is unavailable for the selected server or project."
        case .defaultAlreadySet: "This server already has a default account."
        case .accountInUse: "Remove the project selections for this account before removing it."
        }
    }
}

private struct GatewayProjectUpstreamSelection: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "gatewayProjectUpstreamSelection"
    let projectID: UUID
    let serverName: String
    let accountID: UUID
}

extension Stores {
    public func gatewayUpstream(id: UUID) throws -> GatewayUpstream {
        try db.queue.read { dbc in
            guard let account = try GatewayUpstreamAccount.fetchOne(dbc, key: id) else { throw GatewayUpstreamError.invalidAccount }
            return try Self.resolveGatewayAccount(account, in: dbc)
        }
    }

    /// Management view for the account picker. It includes accounts that are
    /// eligible for explicit selection but are not part of a launch's catalog.
    public func gatewayUpstreamAccounts(projectID: UUID?) throws -> [GatewayUpstreamAccount] {
        try db.queue.read { dbc in
            var candidates = GatewayUpstreamAccount.filter(Column("definitionProjectID") == nil)
            if let projectID {
                try Self.requireGatewayProject(projectID, in: dbc)
                candidates = GatewayUpstreamAccount.filter(Column("definitionProjectID") == nil || Column("definitionProjectID") == projectID)
            }
            return try candidates.order(Column("serverName"), Column("id")).fetchAll(dbc)
        }
    }

    /// Attach an account to an explicitly managed D34 definition. Adding an account never
    /// promotes a native server, copies credentials, or implicitly replaces a default.
    public func registerGatewayUpstreamAccount(serverName: String, definitionProjectID: UUID? = nil,
        globallyAvailable: Bool, makeGlobalDefault: Bool = false) throws -> GatewayUpstreamAccount {
        try Self.validateGatewayServerName(serverName)
        guard !(globallyAvailable && definitionProjectID != nil), !makeGlobalDefault || globallyAvailable else {
            throw GatewayUpstreamError.invalidAccount
        }
        return try db.queue.write { dbc in
            let definition = try Self.gatewayDefinition(serverName, projectID: definitionProjectID, in: dbc)
            if makeGlobalDefault, try Self.gatewayDefault(serverName, in: dbc) != nil {
                throw GatewayUpstreamError.defaultAlreadySet
            }
            let account = GatewayUpstreamAccount(id: UUID(), serverName: serverName, definitionProjectID: definitionProjectID,
                definitionFingerprint: try definition.fingerprint(), globallyAvailable: globallyAvailable,
                isGlobalDefault: makeGlobalDefault)
            try account.insert(dbc)
            try Self.recordGatewaySetting("Register upstream account", projectID: definitionProjectID, in: dbc)
            return account
        }
    }

    public func setGatewayGlobalDefault(serverName: String, accountID: UUID?) throws {
        try Self.validateGatewayServerName(serverName)
        try db.queue.write { dbc in
            let account = try accountID.map { try Self.gatewayAccount($0, for: serverName, in: dbc) }
            if let account {
                guard account.globallyAvailable, account.definitionProjectID == nil else { throw GatewayUpstreamError.invalidAccount }
                _ = try Self.resolveGatewayAccount(account, in: dbc)
            }
            if var previous = try Self.gatewayDefault(serverName, in: dbc) {
                previous.isGlobalDefault = false
                try previous.update(dbc)
            }
            if var account {
                account.isGlobalDefault = true
                try account.update(dbc)
            }
            try Self.recordGatewaySetting("Select default upstream account", projectID: nil, in: dbc)
        }
    }

    /// A project can select a shared account explicitly. Accounts backed by a
    /// project definition are available only to the project that owns it.
    public func selectGatewayUpstreamAccount(projectID: UUID, serverName: String, accountID: UUID?) throws {
        try Self.validateGatewayServerName(serverName)
        try db.queue.write { dbc in
            try Self.requireGatewayProject(projectID, in: dbc)
            if let accountID {
                let account = try Self.gatewayAccount(accountID, for: serverName, in: dbc)
                guard account.definitionProjectID == nil || account.definitionProjectID == projectID else {
                    throw GatewayUpstreamError.invalidAccount
                }
                _ = try Self.resolveGatewayAccount(account, in: dbc)
                try GatewayProjectUpstreamSelection(projectID: projectID, serverName: serverName, accountID: accountID).save(dbc)
            } else {
                try GatewayProjectUpstreamSelection.filter(Column("projectID") == projectID && Column("serverName") == serverName).deleteAll(dbc)
            }
            try Self.recordGatewaySetting("Select project upstream account", projectID: projectID, in: dbc)
        }
    }

    public func removeGatewayUpstreamAccount(id: UUID) throws {
        try db.queue.write { dbc in
            guard let account = try GatewayUpstreamAccount.fetchOne(dbc, key: id) else { throw GatewayUpstreamError.invalidAccount }
            // Deleting a selected account must never switch a project to a different account.
            guard try GatewayProjectUpstreamSelection.filter(Column("accountID") == id).fetchCount(dbc) == 0 else {
                throw GatewayUpstreamError.accountInUse
            }
            try account.delete(dbc)
            try Self.recordGatewaySetting("Remove upstream account", projectID: account.definitionProjectID, in: dbc)
        }
    }

    /// Resolves against the launch's original project and the current account settings.
    /// D34's project opt-out blocks global accounts, including explicitly selected ones.
    public func gatewayUpstreams(for launch: GatewayLaunchContext) throws -> [GatewayUpstream] {
        try db.queue.read { dbc in
            var accounts = Dictionary(uniqueKeysWithValues: try GatewayUpstreamAccount
                .filter(Column("isGlobalDefault") == true).fetchAll(dbc).map { ($0.serverName, $0) })
            if let projectID = launch.projectID {
                try Self.requireGatewayProject(projectID, in: dbc)
                let setup = try WorkspaceAgentSetup.fetchOne(dbc, key: projectID) ?? .init(projectID: projectID)
                let disabled = Set(setup.disabledGlobalServers)
                accounts = accounts.filter { !disabled.contains($0.key) }
                for selection in try GatewayProjectUpstreamSelection.filter(Column("projectID") == projectID).fetchAll(dbc) {
                    let account = try Self.gatewayAccount(selection.accountID, for: selection.serverName, in: dbc)
                    guard account.definitionProjectID == nil || account.definitionProjectID == projectID else {
                        throw GatewayUpstreamError.invalidAccount
                    }
                    if !account.globallyAvailable || !disabled.contains(account.serverName) {
                        accounts[account.serverName] = account
                    }
                }
            }
            return try accounts.values.sorted { $0.serverName < $1.serverName }.map { try Self.resolveGatewayAccount($0, in: dbc) }
        }
    }

    private static func validateGatewayServerName(_ name: String) throws {
        try AgentMCPConfiguration.validateName(name)
        let letters = UInt8(ascii: "a")...UInt8(ascii: "z")
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        guard let first = name.utf8.first, letters.contains(first),
              name.utf8.allSatisfy({ letters.contains($0) || digits.contains($0) || $0 == UInt8(ascii: "_") }),
              !GatewayToolScope.allCases.contains(where: { $0.rawValue == name }), name != "aitvaras" else {
            throw GatewayUpstreamError.invalidServerName
        }
    }

    private static func gatewayDefault(_ name: String, in dbc: Database) throws -> GatewayUpstreamAccount? {
        try GatewayUpstreamAccount.filter(Column("serverName") == name && Column("isGlobalDefault") == true).fetchOne(dbc)
    }

    private static func gatewayAccount(_ id: UUID, for name: String, in dbc: Database) throws -> GatewayUpstreamAccount {
        guard let account = try GatewayUpstreamAccount.fetchOne(dbc, key: id), account.serverName == name else {
            throw GatewayUpstreamError.invalidAccount
        }
        return account
    }

    private static func gatewayDefinition(_ name: String, projectID: UUID?, in dbc: Database) throws -> AgentMCPServer {
        let definitions: [String: AgentMCPServer]
        if let projectID {
            try requireGatewayProject(projectID, in: dbc)
            let setup = try WorkspaceAgentSetup.fetchOne(dbc, key: projectID) ?? .init(projectID: projectID)
            definitions = try AgentMCPConfiguration.decodeServers(setup.extraServersJSON)
        } else {
            definitions = try globalAgentMCPServers(in: dbc)
        }
        guard let definition = definitions[name], definition.management == .gatewayOAuth else {
            throw GatewayUpstreamError.definitionUnavailable
        }
        return definition
    }

    private static func resolveGatewayAccount(_ account: GatewayUpstreamAccount, in dbc: Database) throws -> GatewayUpstream {
        let definition = try gatewayDefinition(account.serverName, projectID: account.definitionProjectID, in: dbc)
        guard try definition.fingerprint() == account.definitionFingerprint else { throw GatewayUpstreamError.definitionChanged }
        return .init(account: account, definition: definition)
    }

    static func requireGatewayProject(_ id: UUID, in dbc: Database) throws {
        guard try WorkspaceProject.fetchOne(dbc, key: id)?.isVisible == true else { throw WorkspaceStoreError.projectNotFound }
    }

    static func recordGatewaySetting(_ summary: String, projectID: UUID?, in dbc: Database) throws {
        let tool = ToolDefinition(name: "saveSettings", description: summary, parametersJSON: "{}", risk: .reversibleWrite)
        let connector = "agent.gateway"
        guard AutonomyPolicy().verdict(for: tool, connectorID: connector) == .allow else {
            throw AgentMCPError.invalidConfiguration
        }
        try ActivityEvent(kind: .toolExecuted, connectorID: connector, summary: summary,
            detailJSON: JSONValue.object(["projectID": projectID.map { .string($0.uuidString) } ?? .null,
                "risk": .string(tool.risk.rawValue)]).jsonString).insert(dbc)
    }
}
