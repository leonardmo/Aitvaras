import Foundation

/// Composer identity is independent of running sessions. Failed durable
/// selection writes leave the visible selection and every draft untouched.
public struct ChatSelectionState: Sendable {
    public private(set) var chatID: UUID?
    public private(set) var provider: AgentProvider = .local
    private var drafts: [UUID: (text: String, version: UUID)] = [:]
    private var newDraft = ""
    public init() {}
    public var draft: String {
        get { if let chatID { drafts[chatID]?.text ?? "" } else { newDraft } }
        set { if let chatID { setDraft(newValue, chatID: chatID) } else { newDraft = newValue } }
    }
    public mutating func select(_ chatID: UUID?, provider: AgentProvider) {
        self.chatID = chatID; self.provider = provider
    }
    public mutating func select(_ chatID: UUID?, provider: AgentProvider,
                                persist: () throws -> Void) rethrows {
        try persist()
        select(chatID, provider: provider)
    }
    public mutating func setDraft(_ text: String, chatID: UUID) {
        drafts[chatID] = (text, UUID())
    }
    public func draftVersion(chatID: UUID) -> UUID? { drafts[chatID]?.version }

    @discardableResult
    public mutating func clearDraft(chatID: UUID, ifVersion version: UUID?) -> Bool {
        guard let draft = drafts[chatID], draft.version == version, !draft.text.isEmpty else { return false }
        setDraft("", chatID: chatID)
        return true
    }
}
