import Foundation

/// Provider outcomes are never inferred from partial output or a stop request.
public enum WorkspaceFrontierTurnState: String, Codable, Sendable, CaseIterable {
    case prepared, running, cancellationRequested, completed, failed, cancelled, outcomeUnknown, interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .outcomeUnknown, .interrupted: true
        default: false
        }
    }

    /// Uncertain outcomes continue to block new delivery until reconciliation
    /// is supported. Startup recovery must never replay them automatically.
    public var blocksNewTurn: Bool {
        self != .completed && self != .failed && self != .cancelled
    }
}
