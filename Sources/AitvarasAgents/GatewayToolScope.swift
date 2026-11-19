import Foundation
import AitvarasCore

public enum GatewayToolScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case memory, knowledge, calendar, reminders, mail, goals, activity

    public var id: Self { self }
}

public enum GatewayToolScopeError: Error, Equatable, Sendable {
    case notGranted, invalidArguments, recordOutsideProject
}

/// The trusted adapter declares every record ID argument. Project queries
/// must use the project in the invocation context to filter their results.
public struct GatewayScopedTool: Sendable {
    public enum Access: Sendable {
        case projectQuery
        case records(idArguments: Set<String>)
    }

    public let definition: ToolDefinition
    public let scope: GatewayToolScope
    public let access: Access

    public init(definition: ToolDefinition, scope: GatewayToolScope, access: Access) {
        self.definition = definition
        self.scope = scope
        self.access = access
    }
}

public struct GatewayToolAccess: Sendable, Equatable {
    public let projectID: UUID
    public let scope: GatewayToolScope
}

/// Shared by catalog filtering and call dispatch. This is a data access gate.
/// A caller still needs to run the permitted action through the autonomy policy.
public struct GatewayToolScopeGate: Sendable {
    private let loadScopes: @Sendable (UUID) throws -> Set<GatewayToolScope>

    public init(loadScopes: @escaping @Sendable (UUID) throws -> Set<GatewayToolScope>) {
        self.loadScopes = loadScopes
    }

    public func listedTools(_ tools: [GatewayScopedTool], for launch: GatewayLaunchContext) throws -> [GatewayScopedTool] {
        guard let projectID = launch.projectID else { return [] }
        let scopes = try loadScopes(projectID)
        return tools.filter { scopes.contains($0.scope) }
    }

    /// Re-read grants at dispatch, including after a confirmation wait. An owner lookup
    /// comes from the trusted record adapter. Unknown or profile-wide records are denied.
    /// The adapter must also filter the actual read or write by the authorized project.
    public func execute<Result: Sendable>(_ tool: GatewayScopedTool, for launch: GatewayLaunchContext,
        arguments: JSONValue,
        recordOwner: @Sendable (GatewayToolScope, String) throws -> UUID? = { _, _ in nil },
        operation: @Sendable (GatewayToolAccess, JSONValue) async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard let projectID = launch.projectID, try loadScopes(projectID).contains(tool.scope) else {
            throw GatewayToolScopeError.notGranted
        }
        guard let fields = arguments.objectValue else { throw GatewayToolScopeError.invalidArguments }
        if case .records(let keys) = tool.access {
            guard !keys.isEmpty else { throw GatewayToolScopeError.invalidArguments }
            for key in keys.sorted() {
                guard let id = fields[key]?.stringValue, !id.isEmpty, id.utf8.count <= 512, !id.contains("\0") else {
                    throw GatewayToolScopeError.invalidArguments
                }
                guard try recordOwner(tool.scope, id) == projectID else {
                    throw GatewayToolScopeError.recordOutsideProject
                }
            }
            guard try loadScopes(projectID).contains(tool.scope) else { throw GatewayToolScopeError.notGranted }
        }
        try Task.checkCancellation()
        return try await operation(.init(projectID: projectID, scope: tool.scope), arguments)
    }
}
