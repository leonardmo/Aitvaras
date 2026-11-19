import Foundation

public enum AgentAutoContinueRowOption: Sendable {
    case enabled(Bool)
    case keepAwake(Bool)

    func applying(enabled: Bool, keepAwake: Bool) -> (enabled: Bool, keepAwake: Bool) {
        switch self {
        case .enabled(let value): (value, keepAwake)
        case .keepAwake(let value): (enabled, value)
        }
    }
}

/// The transcript projects the durable choice; a row never grants delivery itself.
public struct AgentAutoContinueRow: Sendable, Equatable {
    public let enabled: Bool
    public let keepAwake: Bool
    public let canToggle: Bool
    public let canChangeKeepAwake: Bool
    public let status: String?

    public init?(stop: AgentStoppedTurn, intent: AgentAutoContinue?, isCurrent: Bool, timeZone: TimeZone = .current) {
        guard stop.reason.kind == .quota else { return nil }
        let current = isCurrent && stop.canContinue && stop.provider != .local && stop.recoveryInputID == nil
        let scope = AgentUsageLimitScope(provider: stop.provider, providerProfile: stop.providerProfile,
                                         accountKey: intent?.scope.accountKey ?? stop.quotaContext?.accountKey)
        guard scope.hasKnownAccount else {
            enabled = false; keepAwake = false; canToggle = false; canChangeKeepAwake = false
            status = "Automatic continuation requires a verified provider account."
            return
        }
        let editable = intent.map { $0.state == .pending } ?? current
        let revocable = intent?.state == .claimed && intent?.delivery == .prepared
        canToggle = editable || revocable
        enabled = (intent?.enabled ?? current) && (canToggle || intent?.state == .claimed)
        keepAwake = intent?.keepAwake ?? false
        canChangeKeepAwake = enabled && editable
        if enabled, intent?.state != .claimed {
            if let reset = intent?.resetsAt ?? (intent == nil ? stop.reason.resetsAt : nil) {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = "HH:mm"
                status = "Waiting for usage reset · continues at " + formatter.string(from: reset)
            } else { status = "Checking when the limit resets…" }
        } else { status = nil }
    }
}
