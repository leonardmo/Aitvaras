import Foundation

/// Read-only native history is evidence, not authority to run an agent.
public enum NativeSessionProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case codex, claude
    public var id: String { rawValue }
    public var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

/// A spawned subagent is not a fork of its parent's conversation history.
/// Missing kind on older imported records means unverified, not "fork".
public enum NativeParentRelationship: String, Codable, Sendable { case fork, spawn }

public struct NativeSessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var provider: NativeSessionProvider
    public var hostID: String
    public var externalID: String
    public var title: String
    public var directory: String?
    public var updatedAt: Date?
    public var parentExternalID: String?
    public var parentRelationship: NativeParentRelationship?
    public var archived: Bool?
    public var activity: String
    public var id: String { "\(provider.rawValue):\(hostID):\(externalID)" }
    public init(provider: NativeSessionProvider, hostID: String = "local", externalID: String,
                title: String, directory: String? = nil, updatedAt: Date? = nil,
                parentExternalID: String? = nil, parentRelationship: NativeParentRelationship? = nil,
                archived: Bool? = nil, activity: String = "Unknown") {
        self.provider = provider; self.hostID = hostID; self.externalID = externalID
        self.title = title; self.directory = directory; self.updatedAt = updatedAt
        self.parentExternalID = parentExternalID; self.archived = archived; self.activity = activity
        self.parentRelationship = parentRelationship
    }
}

public struct NativeTextMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var externalID: String
    public var role: Role
    public var text: String
    public var id: String { externalID }
    public init(externalID: String, role: Role, text: String) {
        self.externalID = externalID; self.role = role; self.text = text
    }
}

public struct NativeSessionPage: Codable, Sendable, Equatable {
    public var sessions: [NativeSessionSummary]
    public var nextCursor: String?
    public var coverage: String
    public init(sessions: [NativeSessionSummary], nextCursor: String? = nil, coverage: String) {
        self.sessions = sessions; self.nextCursor = nextCursor; self.coverage = coverage
    }
}

public struct NativeTranscriptPage: Codable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable { case older, newer }
    public var session: NativeSessionSummary
    public var messages: [NativeTextMessage]
    public var nextCursor: String?
    public var coverage: String
    public var direction: Direction
    public init(session: NativeSessionSummary, messages: [NativeTextMessage], nextCursor: String? = nil,
                coverage: String, direction: Direction = .older) {
        self.session = session; self.messages = messages; self.nextCursor = nextCursor; self.coverage = coverage
        self.direction = direction
    }
}

public struct NativeSessionCapability: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case ready, missingRuntime, missingSDK, unsupported, unavailable }
    public var provider: NativeSessionProvider
    public var state: State
    public var version: String?
    public var detail: String
    public init(provider: NativeSessionProvider, state: State, version: String? = nil, detail: String) {
        self.provider = provider; self.state = state; self.version = version; self.detail = detail
    }
}

public protocol NativeSessionReader: Sendable {
    var provider: NativeSessionProvider { get }
    func capabilities() async -> NativeSessionCapability
    func listSessions(cursor: String?, archived: Bool) async throws -> NativeSessionPage
    func readSession(id: String, directory: String?, cursor: String?) async throws -> NativeTranscriptPage
}
