import Foundation

/// One entry in Aitvaras's activity history (D13). Every side effect is
/// recorded with the chain of causes that led to it, so the UI can answer
/// "what happened, and because of what?" (e.g. event created ← suggestion
/// accepted ← mail classified urgent ← mail received).
public struct ActivityEvent: Sendable, Codable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case eventReceived      // connector pushed something (mail arrived, …)
        case classification     // model triage/routing verdict
        case toolExecuted       // a tool ran (with risk level + result)
        case suggestionOffered  // action card shown to the user
        case suggestionAccepted
        case suggestionRejected
        case confirmationDenied // user declined a confirmable action
        case notificationSent   // e.g. Telegram urgent push
        case delegationRun      // CLI agent task (D14)
        case voiceTurn          // spoken exchange (user utterance + reply)
        case conversationArchived   // chat summarized into an episode, facts flushed
        case consolidationRun   // nightly memory consolidation (K2) ran/failed
        case captureFinished    // capture session ended, summary produced (F12)
    }

    public var id: UUID
    public var kind: Kind
    public var timestamp: Date
    public var connectorID: String?
    public var summary: String
    /// Machine-readable detail (tool args, model verdict, result), JSON.
    public var detailJSON: String?
    /// Parent activity event; walking `causedBy` reaches the root cause.
    public var causedBy: UUID?
    /// Root artifact identifier (e.g. Mail message-id) for direct lookup.
    public var sourceID: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = .now,
        connectorID: String? = nil,
        summary: String,
        detailJSON: String? = nil,
        causedBy: UUID? = nil,
        sourceID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.connectorID = connectorID
        self.summary = summary
        self.detailJSON = detailJSON
        self.causedBy = causedBy
        self.sourceID = sourceID
    }
}
