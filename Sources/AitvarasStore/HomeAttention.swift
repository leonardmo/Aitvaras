import Foundation
import GRDB
import AitvarasCore
import AitvarasAgents

/// Complete persisted Home inputs, before any presentation cap. Ephemeral
/// agent approvals and monitoring incidents are added by the card projection.
public struct HomeAttentionSnapshot: Sendable, Equatable {
    public var suggestions: [Suggestion]
    public var unsavedCaptures: [ActivityRun]
    public var problems: ActivityAttentionSnapshot
    public var heldUpdates: [HeldNotification]
    public var showsAutomaticWorkPrompt: Bool

    public init(suggestions: [Suggestion] = [], unsavedCaptures: [ActivityRun] = [],
                problems: ActivityAttentionSnapshot = .init(), heldUpdates: [HeldNotification] = [],
                showsAutomaticWorkPrompt: Bool = false) {
        self.suggestions = suggestions
        self.unsavedCaptures = unsavedCaptures
        self.problems = problems
        self.heldUpdates = heldUpdates
        self.showsAutomaticWorkPrompt = showsAutomaticWorkPrompt
    }
}

public struct HomeMonitoringIncident: Sendable, Equatable {
    public let id: UUID
    public let message: String
    public init(id: UUID, message: String) { self.id = id; self.message = message }
}

public enum HomeAttentionRow: Sendable, Equatable, Identifiable {
    public enum ID: Sendable, Hashable {
        case approval(String), suggestion(UUID), capture(UUID), problem(ActivityAttentionGroup.ID)
        case monitoring(UUID), held(UUID), automaticWork
    }
    public enum Section: Sendable { case decisions, problems, notices }
    public enum Dismissal: Sendable, Equatable { case problem, unknownOutcome, heldUpdate, monitoring, later }

    case approval(AgentApprovalSuggestion)
    case suggestion(Suggestion)
    case unsavedCapture(ActivityRun)
    case problem(ActivityAttentionGroup)
    case monitoring(HomeMonitoringIncident)
    case heldUpdate(HeldNotification)
    case automaticWork

    public var id: ID {
        switch self {
        case .approval(let value): .approval(value.id)
        case .suggestion(let value): .suggestion(value.id)
        case .unsavedCapture(let value): .capture(value.id)
        case .problem(let value): .problem(value.id)
        case .monitoring(let value): .monitoring(value.id)
        case .heldUpdate(let value): .held(value.id)
        case .automaticWork: .automaticWork
        }
    }

    public var section: Section {
        switch self {
        case .approval, .suggestion, .unsavedCapture: .decisions
        case .problem, .monitoring: .problems
        case .heldUpdate, .automaticWork: .notices
        }
    }

    public var title: String {
        switch self {
        case .approval(let value): value.request.presentation.title
        case .suggestion(let value): value.title
        case .unsavedCapture(let value): value.title
        case .problem(let value): value.latestRun.title
        case .monitoring: "Activity monitoring unavailable"
        case .heldUpdate(let value): value.title
        case .automaticWork: "Review automatic work"
        }
    }

    /// Decisions and at-risk captures deliberately have no dismissal affordance.
    public var dismissal: Dismissal? {
        switch self {
        case .approval, .suggestion, .unsavedCapture: nil
        case .problem(let group): group.latestRun.state == .outcomeUnknown ? .unknownOutcome : .problem
        case .monitoring: .monitoring
        case .heldUpdate: .heldUpdate
        case .automaticWork: .later
        }
    }

    public var eligibleForDismissAll: Bool {
        switch dismissal {
        case .problem, .heldUpdate, .later: true
        default: false
        }
    }

    public var dismissalAccessibilityLabel: String? {
        guard let dismissal else { return nil }
        let kind: String
        switch dismissal {
        case .problem: kind = "problem"
        case .unknownOutcome: kind = "unknown outcome"
        case .heldUpdate: kind = "held update"
        case .monitoring: kind = "monitoring warning"
        case .later: return "Later: Review automatic work"
        }
        let shortTitle = String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
        return "Dismiss \(kind): \(shortTitle)"
    }

    /// Identifiers contain only stable opaque identities, never display text.
    public var accessibilityIdentifier: String {
        let suffix: String
        switch id {
        case .approval(let id): suffix = "approval.\(StableIdentifier.digest([id]))"
        case .suggestion(let id): suffix = "suggestion.\(id.uuidString)"
        case .capture(let id): suffix = "capture.\(id.uuidString)"
        case .problem(.job(let key)): suffix = "problem.job.\(StableIdentifier.digest([key]))"
        case .problem(.run(let id)): suffix = "problem.run.\(id.uuidString)"
        case .monitoring(let id): suffix = "monitoring.\(id.uuidString)"
        case .held(let id): suffix = "held.\(id.uuidString)"
        case .automaticWork: suffix = "automaticWork"
        }
        return "home.attention.\(suffix)"
    }
}

/// One ordering and one cap across every kind. Groups count as one logical row,
/// regardless of member/occurrence count; bulk eligibility includes overflow.
public struct HomeAttentionCard: Sendable, Equatable {
    public static let rowLimit = 5
    public let rows: [HomeAttentionRow]
    public var visibleRows: [HomeAttentionRow] { Array(rows.prefix(Self.rowLimit)) }
    public var overflowCount: Int { max(0, rows.count - Self.rowLimit) }
    public var canDismissAll: Bool { rows.contains(where: \.eligibleForDismissAll) }

    public init(snapshot: HomeAttentionSnapshot = .init(), approvals: [AgentApprovalSuggestion] = [],
                monitoring: HomeMonitoringIncident? = nil) {
        // Only permission requests, shown with the full approval card as
        // before. Plans and question forms need the chat's context and stay
        // in Chat; a plan approval switches the session to execution.
        let approvals = approvals.filter {
            switch $0.request.kind {
            case .permission, .permissions: true
            default: false
            }
        }
        rows = approvals.map(HomeAttentionRow.approval)
            + snapshot.suggestions.map(HomeAttentionRow.suggestion)
            + snapshot.unsavedCaptures.map(HomeAttentionRow.unsavedCapture)
            + snapshot.problems.groups.map(HomeAttentionRow.problem)
            + (monitoring.map { [HomeAttentionRow.monitoring($0)] } ?? [])
            + snapshot.heldUpdates.map(HomeAttentionRow.heldUpdate)
            + (snapshot.showsAutomaticWorkPrompt ? [.automaticWork] : [])
    }
}

extension Stores {
    public func homeAttentionSnapshot() throws -> HomeAttentionSnapshot {
        let (snapshot, expired) = try db.queue.write { db in
            let now = heldNotificationClock()
            let expired = try Self.expireHeldNotifications(in: db, at: now)
            let snapshot = HomeAttentionSnapshot(
                suggestions: try Suggestion.filter(Column("status") == "pending")
                    .order(Column("createdAt").desc, Column("id")).fetchAll(db),
                unsavedCaptures: try ActivityRun.filter(Column("category") == ActivityCategory.capture.rawValue)
                    .filter(Column("state") == ActivityRunState.waiting.rawValue)
                    .order(Column("updatedAt").desc, Column("id")).fetchAll(db),
                problems: try Self.activityAttentionSnapshot(in: db),
                heldUpdates: try Self.activeHeldNotificationRequest(at: now)
                    .order(Column("createdAt"), Column("id")).fetchAll(db),
                showsAutomaticWorkPrompt: try !Self.attentionBackgroundPolicy(in: db).reviewed
                    && !Self.automaticWorkPromptDeferred(in: db))
            return (snapshot, expired)
        }
        Self.notifyHeldNotificationsChanged(if: expired > 0)
        return snapshot
    }
}
