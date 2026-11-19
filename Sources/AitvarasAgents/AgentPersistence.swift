import Foundation

/// Mutable per-chat provider settings. Native identity is scoped by host/profile.
public struct AgentChatSession: Codable, Sendable, Equatable {
    public var id: UUID
    public var chatID: UUID
    public var provider: AgentProvider
    public var providerProfile: String = "default"
    public var host: String?
    public var profile: String?
    public var nativeID: String?
    public var cwd: String
    public var model: String
    public var effort: String?
    public var mode: AgentMode
    public var instructions: String
    public var additionalRootsJSON: String = "[]"
    public var forkOrigin: AgentForkOrigin?

    public init(id: UUID = UUID(), chatID: UUID, provider: AgentProvider, cwd: String,
                model: String, effort: String? = nil, providerProfile: String = "default", mode: AgentMode = .ask, instructions: String = "") {
        self.id = id; self.chatID = chatID; self.provider = provider; self.cwd = cwd
        self.model = model; self.effort = effort; self.mode = mode
        self.instructions = instructions; self.providerProfile = providerProfile
    }
    private enum CodingKeys: String, CodingKey {
        case providerProfile, id, chatID, provider, host, profile, nativeID, cwd, model, effort, mode, instructions, additionalRootsJSON, forkOrigin
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); chatID = try c.decode(UUID.self, forKey: .chatID)
        provider = try c.decode(AgentProvider.self, forKey: .provider)
        providerProfile = try c.decodeIfPresent(String.self, forKey: .providerProfile) ?? "default"
        host = try c.decodeIfPresent(String.self, forKey: .host); profile = try c.decodeIfPresent(String.self, forKey: .profile)
        nativeID = try c.decodeIfPresent(String.self, forKey: .nativeID)
        cwd = try c.decode(String.self, forKey: .cwd); model = try c.decode(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort); mode = try c.decode(AgentMode.self, forKey: .mode)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        additionalRootsJSON = try c.decodeIfPresent(String.self, forKey: .additionalRootsJSON) ?? "[]"
        forkOrigin = try c.decodeIfPresent(AgentForkOrigin.self, forKey: .forkOrigin)
    }
    public var choice: AgentProviderChoice { .init(provider: provider, profile: providerProfile) }
    public var sessionID: AgentSessionID? {
        get {
            guard let host, let profile, let nativeID else { return nil }
            return AgentSessionID(provider: provider, host: host, profile: profile, nativeID: nativeID)
        }
        set { host = newValue?.host; profile = newValue?.profile; nativeID = newValue?.nativeID }
    }
    /// Text-only Local is stateless; opencode keeps a durable native session.
    public var usesThreadContext: Bool { provider != .local || profile == OpencodeConfiguration.profile }

    public var configuration: AgentSessionConfiguration {
        .init(directory: URL(fileURLWithPath: cwd), resume: forkOrigin?.pending == true ? forkOrigin?.native : sessionID, model: model, effort: effort, mode: mode,
              instructions: instructions, additionalDirectories: (try? JSONDecoder().decode([String].self, from: Data(additionalRootsJSON.utf8)))?.map { URL(fileURLWithPath: $0) } ?? [])
            .forking(at: forkOrigin?.pending == true ? forkOrigin?.assistantMessageID : nil)
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

/// The cause is durable metadata, independent of a provider's injected prompt.
public enum AgentAutonomousReason: String, Codable, Sendable, Equatable {
    case wakeup, backgroundTask, monitor, scheduled, pullRequest, unknown
    public var markerText: String {
        switch self {
        case .wakeup, .scheduled: "Woke up: scheduled check"
        case .backgroundTask: "Background task finished"
        case .monitor: "Woke up: monitor update"
        case .pullRequest: "Pull request update"
        case .unknown: "Continued on its own"
        }
    }
    public var activityTitle: String {
        switch self {
        case .backgroundTask: "Background task finished"
        case .pullRequest: "Auto-fix: pull request update"
        default: "Chat woke up"
        }
    }
}

public enum AgentTurnOrigin: Sendable, Equatable, Codable {
    case user
    case autonomous(AgentAutonomousReason)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        if raw == "user" { self = .user }
        else if raw.hasPrefix("autonomous:"), let reason = AgentAutonomousReason(rawValue: String(raw.dropFirst(11))) {
            self = .autonomous(reason)
        } else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid turn origin") }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .user: try c.encode("user")
        case .autonomous(let reason): try c.encode("autonomous:" + reason.rawValue)
        }
    }
}

public enum AgentJournalState: String, Codable, Sendable { case running, completed, interrupted, failed }

public struct AgentJournalTurn: Codable, Sendable, Equatable {
    public var id: UUID
    public var chatID: UUID
    public var sessionID: UUID
    /// Follow-ups belong to an existing active input, never a second root turn.
    public var parentInputID: UUID?
    public var prompt: String?
    public var autonomousPrompt: String?
    public var origin: AgentTurnOrigin
    public var delivery: AgentDeliveryState
    public var state: AgentJournalState
    public var resendCount: Int
    public var partialOutput: String
    public var startedAt: Date
    public var endedAt: Date?
    public init(input: AgentInput, chatID: UUID, sessionID: UUID, parentInputID: UUID? = nil) {
        self.parentInputID = parentInputID; origin = .user
        id = input.id; prompt = input.text; self.chatID = chatID; self.sessionID = sessionID
        delivery = .prepared; state = .running; resendCount = 0; partialOutput = ""; startedAt = .now
    }
    public init(autonomousID: UUID, reason: AgentAutonomousReason, chatID: UUID, sessionID: UUID) {
        id = autonomousID; origin = .autonomous(reason); prompt = nil
        self.chatID = chatID; self.sessionID = sessionID; parentInputID = nil
        delivery = .prepared; state = .running; resendCount = 0; partialOutput = ""; startedAt = .now
    }
}

/// Synchronous calls commit before returning, including the willDeliver barrier.
/// The application injects its single store into its single manager.
public protocol AgentSessionPersistence: Sendable {
    func agentProjectID(chatID: UUID) throws -> UUID?
    func agentAlwaysAllowedTools(chatID: UUID) throws -> Set<String>
    func allowAgentTool(chatID: UUID, request: AgentRequest) throws
    func requireAgentChatAvailable(chatID: UUID) throws
    func renameAgentChat(chatID: UUID, title: String) throws
    func archiveAgentChat(chatID: UUID, archived: Bool) throws
    func agentSession(chatID: UUID, provider: AgentProvider) throws -> AgentChatSession?
    func agentSessions(chatID: UUID) throws -> [AgentChatSession]
    func saveAgentSession(_ session: AgentChatSession) throws
    func agentEntries(chatID: UUID) throws -> [AgentTranscriptEntry]
    @discardableResult func saveAgentEntry(_ entry: AgentTranscriptEntry) throws -> AgentTranscriptEntry
    func orderAgentEntries(chatID: UUID, ids: [UUID]) throws
    func prepareAgentTurn(_ turn: AgentJournalTurn) throws
    func prepareAgentTurn(_ turn: AgentJournalTurn, context: ChatContextProjection?) throws
    func quotaStops() throws -> [AgentQuotaStop]
    func prepareAutomaticTurn(_ turn: AgentJournalTurn, authorization: AgentAutoContinue) throws
    func beginAutomaticDelivery(id: UUID, authorization: AgentAutoContinue, now: Date) throws
    func automaticInput(id: UUID) throws -> AgentAutomaticInput?
    func bindAutomaticInput(id: UUID, messageID: String?, turnID: String?) throws
    func agentTurn(id: UUID) throws -> AgentJournalTurn?
    func latestAgentTurn(chatID: UUID) throws -> AgentJournalTurn?
    func advanceAgentDelivery(id: UUID, to state: AgentDeliveryState) throws
    func saveAgentPartial(id: UUID, text: String) throws
    func finishAgentTurn(id: UUID, state: AgentJournalState) throws
    @discardableResult func finishAgentTurn(id: UUID, state: AgentJournalState, stop: AgentStopReason?) throws -> AgentTranscriptEntry?
    func finishAgentTurn(id: UUID, state: AgentJournalState, stop: AgentStopReason?,
                         quotaContext: AgentStoppedTurn.QuotaContext?) throws -> AgentTranscriptEntry?
    func prepareAgentRecovery(_ turn: AgentJournalTurn, context: ChatContextProjection?, entry: AgentTranscriptEntry,
                              stoppedEntryID: UUID, action: AgentRecoveryAction, session: AgentChatSession) throws
    func claimAgentResend(id: UUID) throws -> AgentJournalTurn
    func recoverAgentTurns() throws
    func agentContext(session: AgentChatSession) throws -> ChatContextProjection?
    func agentHandover(turnID: UUID) throws -> ChatContextProjection?
}

extension AgentSessionPersistence {
    public func finishAgentTurn(id: UUID, state: AgentJournalState, stop: AgentStopReason?,
                                quotaContext: AgentStoppedTurn.QuotaContext?) throws -> AgentTranscriptEntry? {
        try finishAgentTurn(id: id, state: state, stop: stop)
    }
    public func finishAgentTurn(id: UUID, state: AgentJournalState, stop: AgentStopReason?) throws -> AgentTranscriptEntry? {
        try finishAgentTurn(id: id, state: state); return nil
    }
    public func prepareAgentRecovery(_ turn: AgentJournalTurn, context: ChatContextProjection?, entry: AgentTranscriptEntry,
                                     stoppedEntryID: UUID, action: AgentRecoveryAction, session: AgentChatSession) throws {
        throw AgentFailure.unsupported
    }
    public func quotaStops() throws -> [AgentQuotaStop] { [] }
    public func prepareAutomaticTurn(_ turn: AgentJournalTurn, authorization: AgentAutoContinue) throws { throw AgentFailure.unsupported }
    public func beginAutomaticDelivery(id: UUID, authorization: AgentAutoContinue, now: Date) throws { throw AgentFailure.unsupported }
    public func automaticInput(id: UUID) throws -> AgentAutomaticInput? { nil }
    public func bindAutomaticInput(id: UUID, messageID: String?, turnID: String?) throws { throw AgentFailure.unsupported }

    public func agentSessions(chatID: UUID) throws -> [AgentChatSession] {
        try [AgentProvider.claude, .codex, .local].compactMap { try agentSession(chatID: chatID, provider: $0) }
    }
    public func orderAgentEntries(chatID: UUID, ids: [UUID]) throws { throw AgentFailure.unsupported }
    public func agentProjectID(chatID: UUID) throws -> UUID? { nil }
    public func agentAlwaysAllowedTools(chatID: UUID) throws -> Set<String> { [] }
    public func allowAgentTool(chatID: UUID, request: AgentRequest) throws { throw AgentFailure.unsupported }
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

/// Dormant storage seam; scheduling/dispatch is wired only after row controls exist.
public protocol AgentAutoContinuePersistence: Sendable {
    func validate(_ authorization: AgentAutoContinue) throws
    func hasValidSession(_ value: AgentAutoContinue) throws -> Bool
    func pending() throws -> [AgentAutoContinue]
    func continuation(id: UUID) throws -> AgentAutoContinue?
    func continuation(failedInputID: UUID) throws -> AgentAutoContinue?
    func inputRevision(chatID: UUID) throws -> Int
    @discardableResult func schedule(_ value: AgentAutoContinue, causedBy: UUID?) throws -> AgentAutoContinue
    @discardableResult func setOptions(id: UUID, enabled: Bool, keepAwake: Bool, now: Date) throws -> AgentAutoContinue
    @discardableResult func reschedule(id: UUID, version: Int, windowID: String?, resetsAt: Date?, source: AgentUsageResetSource,
                                      nextCheckAt: Date, nextPollAt: Date?, now: Date) throws -> AgentAutoContinue
    @discardableResult func claim(id: UUID, version: Int, inputID: UUID, now: Date) throws -> AgentAutoContinue
    @discardableResult func advanceDelivery(id: UUID, inputID: UUID, to: AgentDeliveryState, now: Date) throws -> AgentAutoContinue
    @discardableResult func retryAfterQuota(id: UUID, inputID: UUID, nextCheckAt: Date, now: Date) throws -> AgentAutoContinue
    @discardableResult func finish(id: UUID, state: AgentAutoContinue.State, now: Date) throws -> AgentAutoContinue
    func releasePrepared(id: UUID, inputID: UUID?, now: Date) throws
    func retryAutomatic(id: UUID, inputID: UUID, reset: AgentUsageResetResolution?, nextCheckAt: Date, nextPollAt: Date?, now: Date) throws
    func noteNewInput(chatID: UUID, now: Date) throws
    func observe(_ observation: AgentUsageResetObservation) throws
    func observations(scope: AgentUsageLimitScope) throws -> [AgentUsageResetObservation]
}
