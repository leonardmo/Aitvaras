import Foundation

/// Risk classification for every tool a connector exposes.
/// AgentCore enforces the autonomy policy (D13) on these centrally;
/// connectors themselves never decide whether to ask the user.
public enum ActionRisk: String, Sendable, Codable, Equatable {
    /// Reading data. Always allowed.
    case read
    /// Easily reversible writes (create reminder, create calendar event).
    /// Executed immediately, logged.
    case reversibleWrite
    /// Outbound or hard-to-reverse actions (send, delete, modify foreign
    /// data, spend quota). Requires a user confirmation card.
    case confirmable
}

/// An event pushed by a connector into the agent loop
/// (new mail, Moodle deadline, homelab alert, …).
public struct ConnectorEvent: Sendable {
    public var connectorID: String
    /// Stable identifier of the causing artifact (e.g. Mail message-id).
    /// Becomes the root of the provenance chain (D13).
    public var sourceID: String
    public var title: String
    public var body: String
    public var occurredAt: Date

    public init(connectorID: String, sourceID: String, title: String, body: String, occurredAt: Date) {
        self.connectorID = connectorID
        self.sourceID = sourceID
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
    }
}

public enum ConnectorHealth: Sendable, Equatable {
    case ready
    /// Connector needs user action (e.g. Moodle session expired → re-login).
    case needsAuthentication(message: String)
    case error(message: String)
    case disabled
}

/// One integration (Mail, Calendar, Reminders, Moodle, Homelab, Telegram,
/// Delegate, …). New integrations implement this and register with the
/// ConnectorHub — nothing else in the app changes (D15).
public protocol Connector: Actor {
    var id: String { get }
    var displayName: String { get }

    /// Typed tools this connector exposes to the model.
    var tools: [ToolDefinition] { get }

    func health() async -> ConnectorHealth

    /// Execute a tool call. AgentCore has already applied the autonomy
    /// policy before this is invoked.
    func execute(toolName: String, argumentsJSON: String) async throws -> String

    /// Long-lived stream of pushed events; empty stream for pull-only connectors.
    func events() -> AsyncStream<ConnectorEvent>
}
