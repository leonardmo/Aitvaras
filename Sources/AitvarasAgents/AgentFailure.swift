import Foundation

/// Fixed vocabulary only: raw CLI errors can contain credentials or personal data.
public enum AgentFailure: Error, Sendable, Equatable {
    case authRequired
    case quota(resetsAt: Date?)
    case offline
    case notInstalled
    case crashed(exitCode: Int32?)
    case unsupported
    case invalidRequest
    case invalidTransition
    case unknown
}

/// Delivery evidence is independent of turn outcome and token/cost counters.
public enum AgentDeliveryState: String, Codable, Sendable {
    case prepared, deliveryUnknown, acknowledged

    public var canAutomaticallyResend: Bool { self == .prepared }

    public func advancing(to next: Self) throws -> Self {
        guard next == self || (self == .prepared && next == .deliveryUnknown)
            || (self == .deliveryUnknown && next == .acknowledged) else {
            throw AgentFailure.invalidTransition
        }
        return next
    }
}

public enum AgentTurnOutcome: Sendable, Equatable {
    case completed, interrupted, failed(AgentFailure)
}
