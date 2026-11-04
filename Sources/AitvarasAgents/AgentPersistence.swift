import Foundation

/// Mutable per-chat provider settings. Native identity is scoped by host/profile.
public struct AgentChatSession: Codable, Sendable, Equatable {
    public var id: UUID
    public var chatID: UUID
    public var provider: AgentProvider
    public var host: String?
    public var profile: String?
    public var nativeID: String?
    public var cwd: String
    public var model: String
    public var effort: String?
    public var mode: AgentMode
    public var instructions: String

    public init(id: UUID = UUID(), chatID: UUID, provider: AgentProvider, cwd: String,
                model: String, effort: String? = nil, mode: AgentMode = .ask, instructions: String = "") {
        self.id = id; self.chatID = chatID; self.provider = provider; self.cwd = cwd
        self.model = model; self.effort = effort; self.mode = mode
        self.instructions = instructions
    }
    public var sessionID: AgentSessionID? {
        get {
            guard let host, let profile, let nativeID else { return nil }
            return AgentSessionID(provider: provider, host: host, profile: profile, nativeID: nativeID)
        }
        set { host = newValue?.host; profile = newValue?.profile; nativeID = newValue?.nativeID }
    }
    public var configuration: AgentSessionConfiguration {
        .init(directory: URL(fileURLWithPath: cwd), resume: sessionID, model: model, effort: effort, mode: mode,
              instructions: instructions)
    }
}

/// Canonical display entries are independent of provider wire frames and journals.
public struct AgentTranscriptEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chatID: UUID
    public var provider: AgentProvider
    public var kind: String
    public var text: String
    public var payloadJSON: String?
    public var sessionID: UUID?
    public var nativeMessageID: String?
    public var position: Int
    public init(id: UUID = UUID(), chatID: UUID, provider: AgentProvider, kind: String,
                text: String = "", payloadJSON: String? = nil, sessionID: UUID? = nil,
                nativeMessageID: String? = nil, position: Int = 0) {
        self.id = id; self.chatID = chatID; self.provider = provider; self.kind = kind
        self.text = text; self.payloadJSON = payloadJSON; self.sessionID = sessionID
        self.nativeMessageID = nativeMessageID; self.position = position
    }
}

public enum AgentJournalState: String, Codable, Sendable { case running, completed, interrupted, failed }

public struct AgentJournalTurn: Codable, Sendable, Equatable {
    public var id: UUID
    public var chatID: UUID
    public var sessionID: UUID
    public var prompt: String
    public var delivery: AgentDeliveryState
    public var state: AgentJournalState
    public var resendCount: Int
    public var partialOutput: String
    public var startedAt: Date
    public var endedAt: Date?
    public init(input: AgentInput, chatID: UUID, sessionID: UUID) {
        id = input.id; prompt = input.text; self.chatID = chatID; self.sessionID = sessionID
        delivery = .prepared; state = .running; resendCount = 0; partialOutput = ""; startedAt = .now
    }
}

/// Synchronous calls commit before returning, including the willDeliver barrier.
/// The application injects its single store into its single manager.
public protocol AgentSessionPersistence: Sendable {
    func agentSession(chatID: UUID, provider: AgentProvider) throws -> AgentChatSession?
    func saveAgentSession(_ session: AgentChatSession) throws
    func agentEntries(chatID: UUID) throws -> [AgentTranscriptEntry]
    @discardableResult func saveAgentEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry
    func prepareAgentTurn(_ turn: AgentJournalTurn) throws
    func prepareAgentTurn(_ turn: AgentJournalTurn, context: ChatContextProjection?) throws
    func agentTurn(id: UUID) throws -> AgentJournalTurn?
    func latestAgentTurn(chatID: UUID) throws -> AgentJournalTurn?
    func advanceAgentDelivery(id: UUID, to state: AgentDeliveryState) throws
    func saveAgentPartial(id: UUID, text: String) throws
    func finishAgentTurn(id: UUID, state: AgentJournalState) throws
    func claimAgentResend(id: UUID) throws -> AgentJournalTurn
    func recoverAgentTurns() throws
    func agentContext(session: AgentChatSession) throws -> ChatContextProjection?
    func agentHandover(turnID: UUID) throws -> ChatContextProjection?
}
