import Foundation
import CryptoKit

/// A durable scope contains only a one-way key, never the CLI account ID.
public struct AgentUsageLimitScope: Codable, Sendable, Equatable, Hashable {
    public let provider: AgentProvider
    public let providerProfile: String
    public let accountKey: String?
    public init(provider: AgentProvider, providerProfile: String = "default", accountID: String? = nil) {
        self.init(provider: provider, providerProfile: providerProfile,
                  accountKey: Self.deriveAccountKey(provider: provider, profile: providerProfile, accountID: accountID))
    }
    public init(provider: AgentProvider, providerProfile: String, accountKey: String?) {
        self.provider = provider; self.providerProfile = providerProfile; self.accountKey = accountKey
    }
    public static func deriveAccountKey(provider: AgentProvider, profile: String, accountID: String?) -> String? {
        guard let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let scope = JSONValue.array([.string(provider.rawValue), .string(profile), .string(accountID)])
        return SHA256.hash(data: Data(scope.jsonString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var hasKnownAccount: Bool {
        guard let accountKey else { return false }
        return accountKey.utf8.count == 64 && accountKey.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func matches(accountID: String?) -> Bool {
        guard hasKnownAccount, let observed = Self.deriveAccountKey(provider: provider, profile: providerProfile, accountID: accountID) else { return false }
        return accountKey == observed
    }
}

public enum AgentUsageResetSource: String, Codable, Sendable { case request, cached, poll, fallback }

/// One durable intent per stopped input, independent of transcript/UI lifetime.
public struct AgentAutoContinue: Codable, Sendable, Equatable, Identifiable {
    public static let prompt = AgentStoppedTurn.continuationText
    public enum State: String, Codable, Sendable { case pending, claimed, fired, cancelled, expired }
    public let id: UUID
    public let chatID: UUID
    public let failedInputID: UUID
    public let sessionID: UUID
    public let native: AgentSessionID
    public let scope: AgentUsageLimitScope
    public let createdAt: Date
    public let inputRevision: Int
    public var enabled: Bool
    public var keepAwake: Bool
    public var state: State = .pending
    public var version = 0
    public var windowID: String?
    public var resetsAt: Date?
    public var resetSource: AgentUsageResetSource
    public var nextCheckAt: Date
    public var nextPollAt: Date?
    public var fallbackStartedAt: Date
    /// Number of definitive quota-rejected continuation attempts.
    public var retryCount = 0
    public var continuationInputID: UUID?
    public var delivery: AgentDeliveryState = .prepared
    public var lastActivityID: UUID?
    public var updatedAt: Date

    public init(id: UUID = UUID(), chatID: UUID, failedInputID: UUID, sessionID: UUID,
                native: AgentSessionID, scope: AgentUsageLimitScope, createdAt: Date, inputRevision: Int,
                enabled: Bool = true, keepAwake: Bool = false, windowID: String? = nil,
                resetsAt: Date? = nil, resetSource: AgentUsageResetSource = .fallback,
                nextCheckAt: Date, nextPollAt: Date? = nil) {
        self.id = id; self.chatID = chatID; self.failedInputID = failedInputID; self.sessionID = sessionID
        self.native = native; self.scope = scope; self.createdAt = createdAt; self.inputRevision = inputRevision
        self.enabled = enabled; self.keepAwake = keepAwake; self.windowID = windowID; self.resetsAt = resetsAt
        self.resetSource = resetSource; self.nextCheckAt = nextCheckAt; self.nextPollAt = nextPollAt
        fallbackStartedAt = createdAt; updatedAt = createdAt
    }
}

public struct AgentUsageResetObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public let provider: AgentProvider
    public let providerProfile: String
    /// Empty means unavailable, so the SQL uniqueness key is never NULL.
    public let accountKey: String
    public let windowID: String
    public let resetsAt: Date
    public let observedAt: Date
    public var scope: AgentUsageLimitScope {
        .init(provider: provider, providerProfile: providerProfile, accountKey: accountKey.isEmpty ? nil : accountKey)
    }
    public init(id: UUID = UUID(), scope: AgentUsageLimitScope, windowID: String, resetsAt: Date, observedAt: Date) {
        self.id = id; provider = scope.provider; providerProfile = scope.providerProfile
        accountKey = scope.accountKey ?? ""; self.windowID = windowID; self.resetsAt = resetsAt; self.observedAt = observedAt
    }
}

/// Private delivery evidence, separate from the visible transcript.
public struct AgentAutomaticInput: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let intentID: UUID
    public let sessionID: UUID
    public let native: AgentSessionID
    public var nativeMessageID: String?
    public var nativeTurnID: String?
    /// Fixed vocabulary: completed, interrupted, quota, failed.
    public var outcome: String?
    public var resetsAt: Date?
    private enum CodingKeys: String, CodingKey { case id, intentID, sessionID, native, nativeMessageID, nativeTurnID }
    public init(id: UUID, intentID: UUID, sessionID: UUID, native: AgentSessionID) {
        self.id = id; self.intentID = intentID; self.sessionID = sessionID; self.native = native
        nativeMessageID = native.provider == .claude ? id.uuidString : nil
    }
}

/// Persisted only from a verified provider quota outcome; never reconstructed from text.
public struct AgentQuotaStop: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let chatID: UUID
    public let sessionID: UUID
    public let native: AgentSessionID
    public let providerProfile: String
    public let evidence: AgentUsageLimit
    public let accountKey: String?
    public let stoppedAt: Date
    public let inputRevision: Int
    public init(id: UUID, chatID: UUID, sessionID: UUID, native: AgentSessionID, providerProfile: String,
                evidence: AgentUsageLimit, stoppedAt: Date, inputRevision: Int, accountKey: String? = nil) {
        self.accountKey = accountKey
        self.id = id; self.chatID = chatID; self.sessionID = sessionID; self.native = native
        self.providerProfile = providerProfile; self.evidence = evidence; self.stoppedAt = stoppedAt; self.inputRevision = inputRevision
    }
}
