import Foundation
import AitvarasCore

/// A gateway call uses the existing profile connector. Recheck its grant
/// after entering the connector actor and after any permission prompt.
public protocol GatewayProfileConnector: Connector {
    func executeGatewayTool(toolName: String, argumentsJSON: String, projectID: UUID,
                            authorize: @Sendable () throws -> Void) async throws -> String
}

extension GatewayProfileConnector {
    public func executeGatewayTool(toolName: String, argumentsJSON: String, projectID: UUID,
                                   authorize: @Sendable () throws -> Void) async throws -> String {
        try Task.checkCancellation()
        try authorize()
        return try await execute(toolName: toolName, argumentsJSON: argumentsJSON)
    }
}
