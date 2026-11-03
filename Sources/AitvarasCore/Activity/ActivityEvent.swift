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
        case notificationQueued // durable phone delivery is waiting/retrying
        case notificationSent   // e.g. Telegram urgent push
        case notificationFailed // queued delivery expired or was abandoned
        case delegationRun      // CLI agent task (D14)
        case voiceTurn          // spoken exchange (user utterance + reply)
        case conversationArchived   // chat summarized into an episode, facts flushed
        case consolidationRun   // nightly memory consolidation (K2) ran/failed
        case captureFinished    // capture session ended, summary produced (F12)
        case wakeBriefing       // deterministic recap after the Mac wakes
        case shortcutLearned    // repeated fixed workflow compiled into an exact shortcut
        case shortcutTaken      // deterministic phrase fast path ran without a model
        case automationSuggested // a time pattern is waiting for explicit approval
        case automationApproved  // user activated a proposed routine
        case automationChanged   // user paused, dismissed, edited or deleted a routine
        case automationRun       // an approved scheduled routine ran
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
    /// Optional operational run; legacy events remain readable without one.
    public var runID: UUID?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: Date = .now,
        connectorID: String? = nil,
        summary: String,
        detailJSON: String? = nil,
        causedBy: UUID? = nil,
        sourceID: String? = nil,
        runID: UUID? = ActivityTaskContext.runID
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.connectorID = connectorID
        self.summary = summary
        self.detailJSON = detailJSON
        self.causedBy = causedBy
        self.sourceID = sourceID
        self.runID = runID
    }
}
