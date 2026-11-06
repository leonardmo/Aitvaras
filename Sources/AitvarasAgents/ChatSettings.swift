import Foundation

/// Provider choices are scoped to a chat session; changing them never sends.
public enum ChatSettings {
    public static func selecting(model: AgentModel, in session: AgentChatSession) -> AgentChatSession {
        var result = session
        result.model = model.id
        if !model.efforts.contains(result.effort ?? "") { result.effort = nil }
        if session.provider == .local { result.effort = nil; result.mode = .ask }
        return result
    }

    public static func contextFraction(_ usage: AgentUsage?) -> Double? {
        guard let used = usage?.contextTokens, let limit = usage?.contextLimit, used >= 0, limit > 0 else { return nil }
        return min(1, Double(used) / Double(limit))
    }
}

public enum ChatSidebarStatus: Sendable {
    case idle, running, needsYou, interrupted, failed
    public init(_ state: ChatState?) {
        if state?.pendingCards.isEmpty == false { self = .needsYou }
        else if state?.isRunning == true { self = .running }
        else if case .failed = state?.outcome { self = .failed }
        else if case .interrupted = state?.outcome { self = .interrupted }
        else { self = .idle }
    }
}
