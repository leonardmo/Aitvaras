import Foundation

public enum AgentProvider: String, Codable, Sendable { case claude, codex, local }
public enum AgentMode: String, Codable, Sendable { case ask, acceptEdits, plan, auto }
public enum AgentCapability: String, Codable, Sendable {
    case thinking, tools, approvals, plans, questions, followups, history
}

/// Native IDs are meaningful only within their provider, host and profile.
public struct AgentSessionID: Hashable, Codable, Sendable {
    public let provider: AgentProvider
    public let host: String
    public let profile: String
    public let nativeID: String

    public init(provider: AgentProvider, host: String = "local", profile: String, nativeID: String) {
        self.provider = provider; self.host = host; self.profile = profile; self.nativeID = nativeID
    }
}

public struct AgentStatus: Sendable, Equatable {
    /// Unsupported includes API-key and third-party endpoint configurations.
    public enum Authentication: Sendable { case subscription, local, signedOut, unsupported }
    public let installed: Bool
    public let authentication: Authentication
    public let capabilities: Set<AgentCapability>

    public init(installed: Bool, authentication: Authentication, capabilities: Set<AgentCapability>) {
        self.installed = installed; self.authentication = authentication; self.capabilities = capabilities
    }

    public func require(_ capability: AgentCapability) throws {
        guard capabilities.contains(capability) else { throw AgentFailure.unsupported }
    }
}

public struct AgentModel: Sendable, Equatable {
    public let id: String
    public let name: String
    public let efforts: [String]
    public init(id: String, name: String, efforts: [String] = []) {
        self.id = id; self.name = name; self.efforts = efforts
    }
}

public struct AgentSessionConfiguration: Sendable {
    public let directory: URL
    public let resume: AgentSessionID?
    public let model: String
    public let effort: String?
    public let mode: AgentMode
    public let instructions: String

    public init(directory: URL, resume: AgentSessionID? = nil, model: String,
                effort: String? = nil, mode: AgentMode = .ask, instructions: String = "") {
        self.directory = directory; self.resume = resume; self.model = model
        self.effort = effort; self.mode = mode; self.instructions = instructions
    }
}

public struct AgentInput: Sendable, Equatable {
    /// Local durable message identity, retained across a provably safe retry.
    public let id: UUID
    public let text: String
    public init(id: UUID = UUID(), text: String) { self.id = id; self.text = text }
}

public struct AgentSessionSummary: Sendable, Equatable {
    public let id: AgentSessionID
    public let title: String
    public let directory: URL
    public init(id: AgentSessionID, title: String, directory: URL) {
        self.id = id; self.title = title; self.directory = directory
    }
}

public struct AgentPage<Element: Sendable>: Sendable {
    public let items: [Element]
    /// nil means complete; an unsuccessful read must throw, not claim completeness.
    public let nextCursor: String?
    public init(items: [Element], nextCursor: String? = nil) {
        self.items = items; self.nextCursor = nextCursor
    }
}

public protocol AgentBackend: Actor {
    /// Local authentication hint only; no prompt, browser or token refresh.
    func status() async throws -> AgentStatus
    /// Browser URLs are transient, never transcript or Activity content.
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws
    func models() async throws -> [AgentModel]
    /// Starts or resumes a session without sending a user message.
    func start(_ configuration: AgentSessionConfiguration) async throws -> any AgentRun
    func listSessions(folder: URL, cursor: String?) async throws -> AgentPage<AgentSessionSummary>
    func readHistory(session: AgentSessionID, cursor: String?) async throws -> AgentPage<AgentEvent>
}

public protocol AgentRun: Actor {
    /// One live connection generation. Reconnection must allocate a new ID.
    nonisolated var id: UUID { get }
    /// Subscribe before send. Losing events must fail the run, never drop silently.
    nonisolated var events: AsyncThrowingStream<AgentEvent, Error> { get }
    /// Await this durable journal barrier before the first write of this input.
    /// A successful pipe write is still deliveryUnknown, not provider acknowledgement.
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws
    /// Implementations reject wrong generations, resolved IDs and expired requests.
    func respond(to request: AgentRequest, with response: AgentResponse) async throws
    func setMode(_ mode: AgentMode) async throws
    func interrupt() async throws
    /// Releases this run's process and outstanding requests, independent of views.
    func shutdown() async throws
}
