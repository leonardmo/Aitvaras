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

    /// Fixed, safe composer copy; never display raw provider or filesystem errors.
    public static func sendMessage(for error: any Error, provider: AgentProvider) -> String {
        let name = provider.rawValue.capitalized
        if let failure = error as? Self {
            switch failure {
            case .authRequired: return "Sign in to \(name)"
            case .quota: return "Usage limit reached. Try again later."
            case .offline: return "You’re offline. Try again when connected."
            case .notInstalled: return "\(name) is not installed."
            case .crashed: return "\(name) stopped unexpectedly. Try again."
            case .unsupported: return "This provider configuration is unavailable."
            case .invalidRequest: return "This message or chat configuration is invalid."
            case .invalidTransition: return "The chat changed. Try sending again."
            case .unknown: break
            }
        }
        if let failure = error as? AgentSessionManagerError {
            switch failure {
            case .chatBusy: return "This chat is busy. Wait or stop it."
            case .chatUnavailable: return "This chat is unavailable. Restore it to continue."
            case .runningChatLimit: return "\(AgentSessionManager.maximumRunningChats) chats are running. Stop one or wait."
            case .shuttingDown: return "Chats are shutting down. Try again shortly."
            case .missingSession: return "The chat session is missing. Reopen the chat."
            case .staleRun: return "The chat session changed. Try again."
            case .persistence: return "The message could not be saved. Try again."
            }
        }
        if let failure = error as? AgentNativeHistoryError {
            switch failure {
            case .invalidCursor, .staleCursor: return "Chat history changed. Try again."
            case .malformedHistory: return "Chat history could not be read."
            case .incompleteHistory: return "Chat history is incomplete. Try again."
            case .notFound: return "The native chat session could not be found."
            case .tooLarge: return "Chat history is too large to load."
            case .identityConflict: return "Chat history has conflicting session identities."
            }
        }
        if let failure = error as? AgentGitError {
            switch failure {
            case .commandFailed: return "The project’s Git operation failed."
            case .invalidOutput: return "The project’s Git status could not be read."
            case .notRepository: return "The project’s Git repository is unavailable."
            case .ownershipConflict: return "The chat’s worktree ownership could not be verified."
            case .creationFailed: return "The chat’s worktree could not be prepared."
            case .staleChanges: return "Project files changed. Refresh and try again."
            case .busy: return "A project operation is running. Wait and try again."
            case .confirmationRequired: return "This project operation needs confirmation."
            case .emptyMessage: return "Enter a commit message."
            case .noChanges: return "There are no project changes to commit."
            }
        }
        if let failure = error as? AgentProcessError {
            switch failure {
            case .alreadyStarted: return "The provider is already starting. Wait and try again."
            case .notStarted: return "The provider has not started. Try again."
            case .launchFailed: return "\(name) could not start."
            case .closed: return "The provider connection closed. Try again."
            case .writeFailed: return "The message could not reach the provider."
            case .inputLimit: return "The message is too large. Shorten it and try again."
            case .outputLimit: return "The provider response exceeded its size limit."
            case .invalidUTF8: return "The provider returned unreadable text."
            case .cleanupUnconfirmed: return "Provider cleanup is still pending. Wait and try again."
            }
        }
        if let failure = error as? AgentAttachmentError {
            switch failure {
            case .missingFile: return "An attached file is unavailable. Attach it again."
            case .tooLarge: return "An attached file is too large."
            case .unsupportedType: return "This attachment type is unsupported."
            case .tooMany: return "There are too many attachments. Remove some and try again."
            }
        }
        if error is CancellationError { return "Sending was cancelled." }
        return "Message could not be sent."
    }
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
