import Foundation
import GRDB
import AitvarasAgents
import AitvarasCore

public enum GatewayServerApprovalMode: String, Sendable, Codable, CaseIterable {
    case ask, autoAllowReads, fullAuto

    public var label: String {
        switch self {
        case .ask: "Ask for everything"
        case .autoAllowReads: "Auto-allow reads"
        case .fullAuto: "Full auto"
        }
    }
}

private struct GatewayProjectServerApproval: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "gatewayProjectServerApproval"
    let projectID: UUID
    let accountID: UUID
    let mode: GatewayServerApprovalMode
}

public struct GatewayToolApprovalOverride: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "gatewayProjectToolOverride"
    let projectID: UUID
    let accountID: UUID
    public let toolRevision: String
    public let toolName: String
    public let risk: ActionRisk
    public var id: String { toolRevision }
}

public struct GatewayProjectApprovalSettings: Sendable, Equatable {
    /// A nil mode preserves the previous gateway behavior for a legacy account.
    public let mode: GatewayServerApprovalMode?
    public let toolOverrides: [GatewayToolApprovalOverride]
    public let toolGrants: [GatewayProjectToolGrant]
}

extension Stores {
    public func gatewayProjectApprovalSettings(projectID: UUID, accountID: UUID,
                                               legacyToolRevisions: Set<String> = []) throws -> GatewayProjectApprovalSettings {
        try db.queue.read { dbc in
            let account = try Self.gatewayApprovalAccount(accountID, projectID: projectID, in: dbc)
            let overrides = try GatewayToolApprovalOverride
                .filter(Column("projectID") == projectID && Column("accountID") == accountID)
                .order(Column("toolName"), Column("toolRevision")).fetchAll(dbc)
            let grants = try GatewayProjectToolGrant
                .filter(Column("projectID") == projectID && (Column("accountID") == accountID
                    || (Column("accountID") == nil && legacyToolRevisions.contains(Column("toolRevision")))))
                .order(Column("toolName"), Column("toolRevision")).fetchAll(dbc)
            return .init(mode: try Self.gatewayApprovalMode(projectID: projectID, account: account, in: dbc),
                         toolOverrides: overrides, toolGrants: grants)
        }
    }

    public func setGatewayServerApprovalMode(projectID: UUID, accountID: UUID,
                                             mode: GatewayServerApprovalMode) throws {
        try db.queue.write { dbc in
            let account = try Self.gatewayApprovalAccount(accountID, projectID: projectID, in: dbc)
            let previous = try Self.gatewayApprovalMode(projectID: projectID, account: account, in: dbc)
            guard previous != mode else { return }
            try GatewayProjectServerApproval(projectID: projectID, accountID: accountID, mode: mode).save(dbc)
            try Self.recordGatewaySetting("Change server approval mode", projectID: projectID,
                detail: ["accountID": .string(accountID.uuidString),
                         "previousMode": previous.map { .string($0.rawValue) } ?? .null,
                         "mode": .string(mode.rawValue)], in: dbc)
        }
    }

    public func setGatewayToolApprovalOverride(projectID: UUID, tool: MCPGatewayTool, risk: ActionRisk?) throws {
        guard let risk else { try revokeGatewayToolOverride(projectID: projectID, toolRevision: tool.revision); return }
        guard case .upstream(let server, let accountID, let fingerprint) = tool.origin,
              !GatewayUpstreamToolSafety.isForbidden(tool),
              GatewayUpstreamToolSafety.confirmationReason(tool) == nil
        else { throw AgentFailure.invalidRequest }
        try db.queue.write { dbc in
            let account = try Self.gatewayApprovalAccount(accountID, projectID: projectID, in: dbc)
            guard account.serverName == server, account.definitionFingerprint == fingerprint,
                  account.trusted == tool.trusted else { throw GatewayUpstreamError.definitionChanged }
            let rows = GatewayToolApprovalOverride.filter(Column("projectID") == projectID && Column("toolRevision") == tool.revision)
            guard try rows.fetchOne(dbc)?.risk != risk else { return }
            try GatewayToolApprovalOverride(projectID: projectID, accountID: accountID,
                toolRevision: tool.revision, toolName: tool.definition.name, risk: risk).save(dbc)
            try Self.recordGatewaySetting("Classify server tool", projectID: projectID,
                detail: ["accountID": .string(accountID.uuidString), "toolRevision": .string(tool.revision),
                         "classification": .string(risk.rawValue)], in: dbc)
        }
    }

    public func revokeGatewayToolOverride(projectID: UUID, toolRevision: String) throws {
        try db.queue.write { dbc in
            try Self.requireGatewayProject(projectID, in: dbc)
            let removed = try GatewayToolApprovalOverride.filter(Column("projectID") == projectID
                && Column("toolRevision") == toolRevision).deleteAll(dbc)
            if removed > 0 {
                try Self.recordGatewaySetting("Remove server tool classification", projectID: projectID,
                    detail: ["toolRevision": .string(toolRevision)], in: dbc)
            }
        }
    }

    public func revokeGatewayToolGrant(projectID: UUID, toolRevision: String) throws {
        try db.queue.write { dbc in
            try Self.requireGatewayProject(projectID, in: dbc)
            let removed = try GatewayProjectToolGrant.filter(Column("projectID") == projectID
                && Column("toolRevision") == toolRevision).deleteAll(dbc)
            if removed > 0 {
                try Self.recordGatewaySetting("Revoke server tool approval", projectID: projectID,
                    detail: ["toolRevision": .string(toolRevision)], in: dbc)
            }
        }
    }

    public func clearGatewayServerApprovalRules(projectID: UUID, accountID: UUID,
                                                legacyToolRevisions: Set<String> = []) throws {
        try db.queue.write { dbc in
            _ = try Self.gatewayApprovalAccount(accountID, projectID: projectID, in: dbc)
            let overrides = try GatewayToolApprovalOverride
                .filter(Column("projectID") == projectID && Column("accountID") == accountID).deleteAll(dbc)
            let grants = try GatewayProjectToolGrant
                .filter(Column("projectID") == projectID && (Column("accountID") == accountID
                    || (Column("accountID") == nil && legacyToolRevisions.contains(Column("toolRevision"))))).deleteAll(dbc)
            if overrides + grants > 0 {
                try Self.recordGatewaySetting("Clear server tool rules", projectID: projectID,
                    detail: ["accountID": .string(accountID.uuidString)], in: dbc)
            }
        }
    }

    /// Called with the currently validated tool immediately before policy evaluation.
    public func gatewayToolApprovalRule(projectID: UUID?, tool: MCPGatewayTool)
        throws -> (mode: GatewayServerApprovalMode?, override: ActionRisk?, granted: Bool) {
        try db.queue.read { dbc in
            var mode: GatewayServerApprovalMode?
            if case .upstream(_, let accountID, _) = tool.origin,
               let account = try GatewayUpstreamAccount.fetchOne(dbc, key: accountID) {
                mode = try Self.gatewayApprovalMode(projectID: projectID, account: account, in: dbc)
            }
            guard let projectID else { return (mode, nil, false) }
            let match = Column("projectID") == projectID && Column("toolRevision") == tool.revision
            let override = try GatewayToolApprovalOverride.filter(match).fetchOne(dbc)?.risk
            let granted = try GatewayProjectToolGrant.filter(match).fetchCount(dbc) > 0
            return (mode, override, granted)
        }
    }

    /// A successful catalog confirms when the same named tool has a new revision.
    /// Empty catalogs during sign-in or temporary unavailability leave rules alone.
    public func expireChangedGatewayToolRules(projectID: UUID, tools: [MCPGatewayTool]) throws {
        guard let first = tools.first, case .upstream(_, let accountID, _) = first.origin,
              tools.allSatisfy({ $0.origin == first.origin }) else { return }
        let revisions = Dictionary(tools.map { ($0.definition.name, $0.revision) }, uniquingKeysWith: { _, latest in latest })
        let names = Dictionary(tools.map { ($0.revision, $0.definition.name) }, uniquingKeysWith: { _, latest in latest })
        let account = Column("projectID") == projectID && Column("accountID") == accountID

        func changedRules(in dbc: Database) throws -> (overrides: [GatewayToolApprovalOverride],
            grants: [GatewayProjectToolGrant], legacy: [GatewayProjectToolGrant]) {
            let overrides = try GatewayToolApprovalOverride.filter(account).fetchAll(dbc)
                .filter { rule in revisions[rule.toolName].map { $0 != rule.toolRevision } ?? false }
            let grants = try GatewayProjectToolGrant.filter(account).fetchAll(dbc)
                .filter { grant in grant.toolName.flatMap { revisions[$0] }.map { $0 != grant.toolRevision } ?? false }
            let legacy = try GatewayProjectToolGrant.filter(Column("projectID") == projectID && Column("accountID") == nil
                && Set(names.keys).contains(Column("toolRevision"))).fetchAll(dbc)
            return (overrides, grants, legacy)
        }

        let changes = try db.queue.read { try changedRules(in: $0) }
        guard !changes.overrides.isEmpty || !changes.grants.isEmpty || !changes.legacy.isEmpty else { return }
        try db.queue.write { dbc in
            try Self.requireGatewayProject(projectID, in: dbc)
            let changes = try changedRules(in: dbc)
            for row in changes.overrides { try row.delete(dbc) }
            for row in changes.grants { try row.delete(dbc) }
            // Older grants stored only a revision. An exact catalog match proves
            // the server and tool without changing what the grant authorizes.
            for row in changes.legacy {
                try GatewayProjectToolGrant(projectID: projectID, toolRevision: row.toolRevision,
                    accountID: accountID, toolName: names[row.toolRevision]).update(dbc)
            }
            if !changes.overrides.isEmpty || !changes.grants.isEmpty {
                try Self.recordGatewaySetting("Expire rules for changed tools", projectID: projectID,
                    detail: ["accountID": .string(accountID.uuidString)], in: dbc)
            }
        }
    }

    private static func gatewayApprovalMode(projectID: UUID?, account: GatewayUpstreamAccount,
                                            in dbc: Database) throws -> GatewayServerApprovalMode? {
        if let projectID, let rule = try GatewayProjectServerApproval
            .filter(Column("projectID") == projectID && Column("accountID") == account.id).fetchOne(dbc) {
            return rule.mode
        }
        return account.approvalDefaultsToAsk ? .ask : nil
    }

    private static func gatewayApprovalAccount(_ id: UUID, projectID: UUID, in dbc: Database) throws -> GatewayUpstreamAccount {
        try requireGatewayProject(projectID, in: dbc)
        guard let account = try GatewayUpstreamAccount.fetchOne(dbc, key: id),
              account.definitionProjectID == nil || account.definitionProjectID == projectID else {
            throw GatewayUpstreamError.invalidAccount
        }
        _ = try resolveGatewayAccount(account, in: dbc)
        return account
    }
}
