import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents

/// The profile's configured Knowledge source. IDs are the same identifiers
/// used by the index, so a project link covers future documents in the source.
public struct KnowledgeSourceConfiguration: Codable, Sendable, Equatable, Identifiable {
    public static let settingsKey = "rag.sources"
    public let id: String
    public let name: String
    public let path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

struct GatewayProjectKnowledgeSource: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "gatewayProjectKnowledgeSource"
    let projectID: UUID
    let sourceID: String
}

private struct GatewayActivityProject: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "gatewayActivityProject"
    let eventID: UUID
    let projectID: UUID
}

extension Stores {
    public func configuredKnowledgeSources() throws -> [KnowledgeSourceConfiguration] {
        try db.queue.read { try Self.configuredKnowledgeSources(in: $0) }
    }

    static func configuredKnowledgeSources(in dbc: Database) throws -> [KnowledgeSourceConfiguration] {
        guard let raw = try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?",
                                            arguments: [KnowledgeSourceConfiguration.settingsKey]) else { return [] }
        return try JSONDecoder().decode([KnowledgeSourceConfiguration].self, from: Data(raw.utf8))
    }

    public func gatewayKnowledgeSources(projectID: UUID) throws -> [KnowledgeSourceConfiguration] {
        try db.queue.read { dbc in
            try Self.requireGatewayScope(.knowledge, projectID: projectID, in: dbc)
            let ids = try Self.gatewayKnowledgeSourceIDs(projectID: projectID, in: dbc)
            guard !ids.isEmpty else { return [] }
            return try Self.configuredKnowledgeSources(in: dbc).filter { ids.contains($0.id) }
        }
    }

    static func gatewayKnowledgeSourceIDs(projectID: UUID, in dbc: Database) throws -> Set<String> {
        try Set(GatewayProjectKnowledgeSource.filter(Column("projectID") == projectID).fetchAll(dbc).map(\.sourceID))
    }

    public func gatewayRecordOwner(projectID: UUID, scope: GatewayToolScope, resourceID: String) throws -> UUID? {
        guard scope == .activity, let id = UUID(uuidString: resourceID) else { return nil }
        return try db.queue.read { dbc in
            try Self.requireGatewayScope(.activity, projectID: projectID, in: dbc)
            return try GatewayActivityProject.filter(Column("projectID") == projectID && Column("eventID") == id)
                .fetchOne(dbc)?.projectID
        }
    }

    public func recordGatewayActivity(_ event: ActivityEvent, projectID: UUID?) throws {
        try db.queue.write { dbc in
            try event.insert(dbc)
            if let projectID, try WorkspaceProject.fetchOne(dbc, key: projectID) != nil {
                try GatewayActivityProject(eventID: event.id, projectID: projectID).insert(dbc)
            }
        }
    }

    public func gatewayActivity(projectID: UUID, id: UUID? = nil) throws -> [ActivityEvent] {
        try db.queue.read { dbc in
            try Self.requireGatewayScope(.activity, projectID: projectID, in: dbc)
            let links = GatewayActivityProject.filter(Column("projectID") == projectID)
            if let id {
                guard try links.filter(Column("eventID") == id).fetchOne(dbc) != nil,
                      let event = try ActivityEvent.fetchOne(dbc, key: id) else { throw GatewayToolScopeError.recordOutsideProject }
                return [event]
            }
            let ids = try links.order(Column.rowID.desc).limit(20).fetchAll(dbc).map(\.eventID)
            return try ActivityEvent.filter(ids.contains(Column("id"))).order(Column("timestamp").desc).fetchAll(dbc)
        }
    }
}
