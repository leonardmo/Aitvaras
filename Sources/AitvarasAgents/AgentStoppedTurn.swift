import Foundation
import AitvarasCore

public enum AgentRecoveryAction: String, Codable, Sendable, CaseIterable {
    case continueTurn, retry, signIn, copyDetails
    public var label: String {
        switch self { case .continueTurn: "Continue"; case .retry: "Retry"; case .signIn: "Sign in"; case .copyDetails: "Copy details" }
    }
}

public struct AgentStopReason: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case connection, quota, signIn, internalError, interrupted }
    public let kind: Kind
    public let category: SafeErrorCategory
    public let resetsAt: Date?
    public init(kind: Kind, category: SafeErrorCategory, resetsAt: Date? = nil) {
        self.kind = kind; self.category = category; self.resetsAt = resetsAt
    }
    public static let interrupted = Self(kind: .interrupted, category: .init(type: "AgentTurnOutcome", errorCase: "interrupted"))
    public static let connectionClosed = Self(kind: .connection, category: .init(type: "AgentFailure", errorCase: "crashed"))
    public static func failure(_ failure: AgentFailure, category: SafeErrorCategory? = nil) -> Self {
        let category = category ?? failure.safeErrorCategory
        if ["AgentStoreError", "AgentSessionManagerError", "AgentNativeHistoryError", "DatabaseError"].contains(category.type) {
            return .init(kind: .internalError, category: category)
        }
        if category.type == "AgentProcessError" {
            return .init(kind: ["closed", "writeFailed", "launchFailed", "notStarted", "outputLimit", "invalidUTF8"].contains(category.errorCase)
                ? .connection : .internalError, category: category)
        }
        switch failure {
        case .authRequired: return .init(kind: .signIn, category: category)
        case .quota(let reset): return .init(kind: .quota, category: category, resetsAt: reset)
        case .offline, .crashed, .providerError: return .init(kind: .connection, category: category)
        default: return .init(kind: .internalError, category: category)
        }
    }
    public var outcome: AgentTurnOutcome {
        switch kind {
        case .interrupted: .interrupted
        case .connection: .failed(.offline)
        case .quota: .failed(.quota(resetsAt: resetsAt))
        case .signIn: .failed(.authRequired)
        case .internalError: .failed(.unknown)
        }
    }
}

/// Durable metadata only; original prompts stay in the input and its journal.
public struct AgentStoppedTurn: Codable, Sendable, Equatable {
    public static let continuationText = "Continue where you stopped."
    public let inputID: UUID
    public let attempt: Int
    public let provider: AgentProvider
    public let providerProfile: String
    public var choice: AgentProviderChoice { .init(provider: provider, profile: providerProfile) }
    public let nativeSession: AgentSessionID?
    public let delivery: AgentDeliveryState
    public let reason: AgentStopReason
    public var recoveryInputID: UUID?
    /// CLI-started turns have no user prompt, so Retry cannot apply.
    public var autonomous: Bool?

    /// Evidence used by the usage-reset scheduler. Failure and reset stay in reason.
    public struct QuotaContext: Codable, Sendable, Equatable {
        public let windowID: String?
        public let accountID: String?
        public let inputRevision: Int
        public let stoppedAt: Date
        public init(windowID: String?, accountID: String?, inputRevision: Int, stoppedAt: Date) {
            self.windowID = windowID; self.accountID = accountID
            self.inputRevision = inputRevision; self.stoppedAt = stoppedAt
        }
    }
    public var quotaContext: QuotaContext?

    public init(turn: AgentJournalTurn, session: AgentChatSession, reason: AgentStopReason) {
        inputID = turn.id; attempt = turn.resendCount; provider = session.provider; providerProfile = session.providerProfile
        nativeSession = session.sessionID; delivery = turn.delivery; self.reason = reason
        autonomous = turn.prompt == nil ? true : nil
    }
    public var actions: [AgentRecoveryAction] {
        if reason.kind == .internalError { return [.copyDetails] }
        guard recoveryInputID == nil else { return [] }
        if reason.kind == .signIn { return [.signIn] }
        if autonomous == true { return [.continueTurn] }
        return [delivery == .acknowledged ? .continueTurn : .retry]
    }
    public var canContinue: Bool {
        guard let nativeSession, nativeSession.host == "local", !nativeSession.nativeID.isEmpty,
              !nativeSession.profile.isEmpty else { return false }
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !nativeSession.nativeID.unicodeScalars.contains(where: invalid.contains)
    }
    public var icon: String {
        switch reason.kind {
        case .connection: "bolt.slash"
        case .quota: "clock"
        case .signIn: "person.crop.circle.badge.exclamationmark"
        case .internalError: "exclamationmark.triangle"
        case .interrupted: "pause.circle"
        }
    }
    public func label(timeZone: TimeZone = .current) -> String {
        switch reason.kind {
        case .connection: return "Connection lost"
        case .quota:
            guard let reset = reason.resetsAt else { return "Usage limit reached" }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone; formatter.dateFormat = "HH:mm"
            return "Usage limit reached · resets at " + formatter.string(from: reset)
        case .signIn: return "Sign in"
        case .internalError: return "Aitvaras error · " + reason.category.name
        case .interrupted: return "Stopped"
        }
    }
    public func payload() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}

extension AgentTranscriptEntry {
    public var stoppedTurn: AgentStoppedTurn? {
        guard kind == "stopped", let payloadJSON else { return nil }
        return try? JSONDecoder().decode(AgentStoppedTurn.self, from: Data(payloadJSON.utf8))
    }
}

extension ChatState {
    public func canRecover(_ entry: AgentTranscriptEntry) -> Bool {
        guard let stop = entry.stoppedTurn, let inputID else { return false }
        return entry.chatID == chatID && stop.inputID == inputID
    }
    public var currentStoppedTurn: AgentStoppedTurn? {
        entries.reversed().compactMap(\.stoppedTurn).first { $0.inputID == inputID }
    }
    public var showsComposerFailure: Bool {
        guard case .failed = outcome else { return false }
        // Nothing was sent by the user for a CLI-started turn.
        return currentStoppedTurn.map { $0.autonomous != true && $0.delivery == .prepared } ?? (delivery == nil || delivery == .prepared)
    }
}
