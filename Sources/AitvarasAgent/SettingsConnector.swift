import AitvarasCore
import AitvarasAgents

/// Both local conversations and the gateway use the same typed tool contract.
/// Only the app's review surface owns the effects of applying a proposal.
public actor SettingsConnector: Connector {
    @TaskLocal public static var source: SettingsProposalSource?
    public typealias Execute = @Sendable (String, JSONValue, SettingsProposalSource) async throws -> String
    public nonisolated let id = "settings"
    public nonisolated let displayName = "Aitvaras settings"
    public nonisolated let tools = SettingsAgentTools.definitions
    private let handler: Execute

    public init(handler: @escaping Execute) { self.handler = handler }
    public func health() async -> ConnectorHealth { .ready }
    public func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        guard let arguments = JSONValue.parse(argumentsJSON) else { throw SettingsToolError.invalidArguments }
        return try await handler(toolName, arguments, Self.source ?? .init(channel: "local"))
    }
}
