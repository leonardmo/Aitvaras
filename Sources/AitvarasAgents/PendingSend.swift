import Foundation

/// One bounded waiting message per application profile. URLs and credentials
/// are never persisted. Restoring this intent must never initiate login.
public struct PendingSend: Codable, Sendable, Equatable {
    public static let maximumBytes = 65_536
    public let inputID: UUID
    public let text: String
    public let session: AgentChatSession
    public let accountID: String?
    public let expiresAt: Date

    public init(inputID: UUID, text: String, session: AgentChatSession, accountID: String? = nil, now: Date = .now,
                hasAttachments: Bool = false) throws {
        guard session.provider != .local, (!text.isEmpty || hasAttachments), text.utf8.count <= Self.maximumBytes else {
            throw AgentFailure.invalidRequest
        }
        self.inputID = inputID; self.text = text; self.session = session; self.accountID = accountID
        expiresAt = now.addingTimeInterval(300)
    }

    public func permitsRetry(turn: AgentJournalTurn, session current: AgentChatSession, accountID currentAccountID: String? = nil, now: Date = .now) -> Bool {
        now < expiresAt && (session.nativeID == nil || accountID != nil)
            && (accountID == nil || accountID == currentAccountID) && current == session && turn.id == inputID && turn.chatID == session.chatID
            && turn.sessionID == session.id && turn.delivery == .prepared
            && turn.state != .running && turn.resendCount == 0
    }
}

public protocol PendingSendPersistence: Sendable {
    func pendingSend() throws -> PendingSend?
    func savePendingSend(_ pending: PendingSend?) throws
}
