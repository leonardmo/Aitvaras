import Foundation

public struct AgentQueuedMessage: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let provider: AgentProvider
    public let text: String
    public let attachmentKinds: [AgentAttachment.Kind]
    private let payload: String?

    init(input: AgentInput, session: AgentChatSession) {
        self.init(input: input, sessionID: session.id, provider: session.provider)
    }

    init(input: AgentInput, sessionID: UUID, provider: AgentProvider) {
        self.id = input.id
        self.sessionID = sessionID
        self.provider = provider
        self.text = input.text
        self.attachmentKinds = input.attachments.map(\.kind)
        self.payload = input.composerPayload()
    }

    public func restoredInput() throws -> AgentInput {
        try AgentInput.restoring(id: id, text: text, payload: payload)
    }
}

public struct AgentMessageQueue: Codable, Equatable, Sendable {
    public enum Pause: String, Codable, Sendable {
        case stopped, failed, quota, restarted, approval, delivery
    }

    public internal(set) var messages: [AgentQueuedMessage] = []
    public internal(set) var pause: Pause?
    public internal(set) var editingID: UUID?
    public internal(set) var dispatchingID: UUID?
    public init() {}
}

/// Local outbox storage. Accepted inputs retain their original identity so the
/// delivery journal can reconcile a crash between acceptance and queue removal.
public protocol AgentMessageQueuePersistence: Sendable {
    func messageQueue(chatID: UUID) throws -> AgentMessageQueue
    func saveMessageQueue(_ queue: AgentMessageQueue, chatID: UUID) throws
}
