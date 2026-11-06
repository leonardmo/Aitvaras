import Foundation

/// Provider choices are scoped to a chat session; changing them never sends.
public enum ChatSettings {
    public static func newProvider(lastUsed: AgentProvider?, localAvailable: Bool,
                                   statuses: [AgentProvider: AgentStatus]) -> AgentProvider {
        if let lastUsed { return lastUsed }
        if localAvailable { return .local }
        return [AgentProvider.claude, .codex].first {
            statuses[$0]?.installed == true && statuses[$0]?.authentication == .subscription
        } ?? .local
    }

    public static func selecting(model: AgentModel, in session: AgentChatSession) -> AgentChatSession {
        var result = session
        result.model = model.id
        if !model.efforts.contains(result.effort ?? "") { result.effort = nil }
        if session.provider == .local { result.effort = nil; result.mode = .ask }
        return result
    }

    /// Catalogs are provider-scoped; validate every restored selection even
    /// when discovery is cached. Empty catalogs preserve a signed-out choice.
    public static func restoring(_ session: AgentChatSession, models: [AgentModel],
                                 automaticallySelect: Bool = true) -> AgentChatSession {
        if let model = models.first(where: { $0.id == session.model }) {
            return selecting(model: model, in: session)
        }
        guard automaticallySelect, let first = models.first else { return session }
        return selecting(model: first, in: session)
    }

    public static func contextFraction(_ usage: AgentUsage?) -> Double? {
        guard let used = usage?.contextTokens, let limit = usage?.contextLimit, used >= 0, limit > 0 else { return nil }
        return min(1, Double(used) / Double(limit))
    }
}

public enum ChatSidebarStatus: String, Sendable {
    case idle, running, needsYou, finishedUnseen, interrupted, failed
    public init(_ state: ChatState?, unseen: Bool = false) {
        if state?.pendingCards.isEmpty == false { self = .needsYou }
        else if state?.isRunning == true { self = .running }
        else if case .failed = state?.outcome { self = .failed }
        else if case .interrupted = state?.outcome { self = .interrupted }
        else if unseen { self = .finishedUnseen }
        else { self = .idle }
    }
}
