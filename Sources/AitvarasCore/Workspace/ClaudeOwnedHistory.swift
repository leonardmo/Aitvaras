import Foundation

/// Text exposed by the official Claude Code history API, not proof of a
/// successful turn. IDs are provider message UUIDs, never text fingerprints.
public struct ClaudeOwnedHistoryMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let text: String

    public init(id: String, role: String, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}

/// A complete bounded observation of one already-owned session. The SDK does
/// not expose message creation times or completion states through this API.
public struct ClaudeOwnedHistorySnapshot: Codable, Sendable, Equatable {
    public let sessionID: String
    public let profileNamespace: String
    public let messages: [ClaudeOwnedHistoryMessage]
    public let complete: Bool
    public let observedAt: Date

    public init(sessionID: String, profileNamespace: String, messages: [ClaudeOwnedHistoryMessage],
                complete: Bool, observedAt: Date) {
        self.sessionID = sessionID; self.profileNamespace = profileNamespace
        self.messages = messages; self.complete = complete; self.observedAt = observedAt
    }
}
