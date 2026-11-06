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
    public var additionalRootsJSON: String = "[]"

    public init(id: UUID = UUID(), chatID: UUID, provider: AgentProvider, cwd: String,
                model: String, effort: String? = nil, mode: AgentMode = .ask, instructions: String = "") {
        self.id = id; self.chatID = chatID; self.provider = provider; self.cwd = cwd
        self.model = model; self.effort = effort; self.mode = mode
        self.instructions = instructions
    }
    private enum CodingKeys: String, CodingKey {
        case id, chatID, provider, host, profile, nativeID, cwd, model, effort, mode, instructions, additionalRootsJSON
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); chatID = try c.decode(UUID.self, forKey: .chatID)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        host = try c.decodeIfPresent(String.self, forKey: .host); profile = try c.decodeIfPresent(String.self, forKey: .profile)
        nativeID = try c.decodeIfPresent(String.self, forKey: .nativeID)
        cwd = try c.decode(String.self, forKey: .cwd); model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort); mode = try c.decode(AgentMode.self, forKey: .mode)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        additionalRootsJSON = try c.decodeIfPresent(String.self, forKey: .additionalRootsJSON) ?? "[]"
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
              instructions: instructions, additionalDirectories: (try? JSONDecoder().decode([String].self, from: Data(additionalRootsJSON.utf8)))?.map { URL(fileURLWithPath: $0) } ?? [])
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
    /// Follow-ups belong to an existing active input, never a second root turn.
    public var parentInputID: UUID?
    public var prompt: String
    public var delivery: AgentDeliveryState
    public var state: AgentJournalState
    public var resendCount: Int
    public var partialOutput: String
    public var startedAt: Date
    public var endedAt: Date?
    public init(input: AgentInput, chatID: UUID, sessionID: UUID, parentInputID: UUID? = nil) {
        self.parentInputID = parentInputID
        id = input.id; prompt = input.text; self.chatID = chatID; self.sessionID = sessionID
        delivery = .prepared; state = .running; resendCount = 0; partialOutput = ""; startedAt = .now
    }
}

/// Synchronous calls commit before returning, including the willDeliver barrier.
/// The application injects its single store into its single manager.
public protocol AgentSessionPersistence: Sendable {
    func requireAgentChatAvailable(chatID: UUID) throws
    func renameAgentChat(chatID: UUID, title: String) throws
    func archiveAgentChat(chatID: UUID, archived: Bool) throws
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

public protocol AgentNativeSessionPersistence: Sendable {
    /// Atomically map metadata only; never writes legacy evidence or transcript.
    func discoverAgentNativeSessions(_ sessions: [AgentSessionSummary]) throws -> [UUID]
}

/// Publish only a fully read, internally consistent canonical branch.
public protocol AgentHistoryPersistence: Sendable {
    func reconcileAgentHistory(session: AgentChatSession, entries: [AgentTranscriptEntry]) throws
    func reconcileAgentHistories(_ histories: [(session: AgentChatSession, entries: [AgentTranscriptEntry])]) throws
}

extension AgentTranscriptEntry {
    public var isLegacyProjection: Bool {
        payloadJSON.flatMap(JSONValue.parse)?["legacyID"]?.stringValue != nil
    }

    /// Imported evidence keeps its original row IDs, separate from executable
    /// sessions and completed chat context. The group starts collapsed in Chat.
    public var importedMessages: [AgentTranscriptEntry] {
        guard kind == "importedHistory" else { return [] }
        return (payloadJSON.flatMap(JSONValue.parse)?["messages"]?.arrayValue ?? []).compactMap { message in
            guard let id = message["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let role = message["role"]?.stringValue, ["user", "assistant"].contains(role),
                  let text = message["text"]?.stringValue else { return nil }
            return .init(id: id, chatID: chatID, provider: provider, kind: role, text: text,
                payloadJSON: JSONValue.object(["legacyID": .string("import:\(id)"), "completed": .bool(false),
                    "revision": message["revision"] ?? .null, "externalID": message["externalID"] ?? .null]).jsonString)
        }
    }
}
