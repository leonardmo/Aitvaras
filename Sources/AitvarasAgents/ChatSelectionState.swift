import Foundation

/// Composer identity is independent of running sessions. Failed durable
/// selection writes leave the visible selection and every draft untouched.
public struct ChatSelectionState: Sendable {
    public private(set) var chatID: UUID?
    public private(set) var provider: AgentProvider = .local
    private var drafts: [UUID: String] = [:]
    public init() {}
    public var draft: String {
        get { chatID.flatMap { drafts[$0] } ?? "" }
        set { if let chatID { drafts[chatID] = newValue } }
    }
    public mutating func select(_ chatID: UUID?, provider: AgentProvider) {
        self.chatID = chatID; self.provider = provider
    }
    public mutating func select(_ chatID: UUID?, provider: AgentProvider,
                                persist: () throws -> Void) rethrows {
        try persist()
        select(chatID, provider: provider)
    }
    public mutating func clearDraft(chatID: UUID, ifUnchanged text: String) {
        if drafts[chatID] == text { drafts[chatID] = "" }
    }
}
