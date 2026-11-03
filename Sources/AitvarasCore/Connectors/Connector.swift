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
public struct ConnectorCheckpoint: Sendable, Equatable {
    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct ConnectorEvent: Sendable {
    public static let maximumConnectorIDCharacters = 200
    public static let maximumSourceIDCharacters = 1_000
    public static let maximumTitleCharacters = 1_000
    public static let maximumBodyCharacters = 8_000

    public var connectorID: String
    /// Stable identifier of the causing artifact (e.g. Mail message-id).
    /// Becomes the root of the provenance chain (D13).
    public var sourceID: String
    public var title: String
    public var body: String
    public var occurredAt: Date
    /// Structured origin for external-content trust decisions. Event text is
    /// still untrusted even when this source has been approved by the user.
    public var externalMessageSource: ExternalMessageSource?
    /// Optional connector cursor that central intake commits with the event.
    /// Until that transaction succeeds the connector must emit the same
    /// stable sourceID again, making crash recovery lossless.
    public var checkpoint: ConnectorCheckpoint?

    public init(connectorID: String, sourceID: String, title: String, body: String,
                occurredAt: Date, checkpoint: ConnectorCheckpoint? = nil,
                externalMessageSource: ExternalMessageSource? = nil) {
        self.connectorID = connectorID
        self.sourceID = sourceID
        self.title = title
        self.body = body
        self.occurredAt = occurredAt
        self.checkpoint = checkpoint
        self.externalMessageSource = externalMessageSource
    }

    /// Normalize untrusted connector fields once at central intake. Long
    /// identifiers retain a digest suffix so replay deduplication does not
    /// collapse distinct items that happen to share a prefix.
    public func boundedForIntake() -> ConnectorEvent {
        ConnectorEvent(
            connectorID: Self.boundedIdentifier(
                connectorID, limit: Self.maximumConnectorIDCharacters),
            sourceID: Self.boundedIdentifier(
                sourceID, limit: Self.maximumSourceIDCharacters),
            title: String(title.prefix(Self.maximumTitleCharacters)),
            body: String(body.prefix(Self.maximumBodyCharacters)),
            occurredAt: occurredAt,
            checkpoint: checkpoint,
            externalMessageSource: externalMessageSource)
    }

    private static func boundedIdentifier(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let digest = "#" + StableIdentifier.short([value])
        return String(value.prefix(max(0, limit - digest.count))) + digest
    }
}

/// Connector events are replayable until central intake commits their stable
/// source id/checkpoint. A finite oldest-first queue therefore prevents a
/// stalled consumer from growing memory without sacrificing event order;
/// any newly dropped item will be emitted again by its poller.
public enum ConnectorEventStreams {
    public static let connectorCapacity = 256
    public static let mergedCapacity = 512
    /// A direct wake replay bypasses the finite AsyncStream buffer, so it has
    /// its own per-source ceiling to prevent a notification flood from
    /// monopolizing the assistant after wake.
    public static let maximumWakeCatchUpEvents = 200

    /// Keep the caller's relevance order and report truncation explicitly so
    /// the recap can disclose that its counts are partial.
    public static func boundedWakeCatchUp<Element>(
        _ orderedItems: [Element]
    ) -> (items: [Element], wasLimited: Bool) {
        let items = Array(orderedItems.prefix(maximumWakeCatchUpEvents))
        return (items, orderedItems.count > items.count)
    }

    public static func make(
        bufferingOldest capacity: Int = connectorCapacity
    ) -> (
        stream: AsyncStream<ConnectorEvent>,
        continuation: AsyncStream<ConnectorEvent>.Continuation
    ) {
        precondition(capacity > 0)
        return AsyncStream.makeStream(
            of: ConnectorEvent.self,
            bufferingPolicy: .bufferingOldest(capacity))
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
