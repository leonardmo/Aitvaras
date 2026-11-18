import Foundation

/// A group selection captures exact member identities, rather than expanding
/// to include another failure that arrives while its sheet is open.
public struct ActivityRunDetailSelection: Sendable, Equatable, Identifiable {
    public let run: ActivityRun
    public let group: ActivityAttentionGroup?
    public var id: UUID { run.id }
    public var representedRuns: [ActivityRun] { group?.runs ?? [run] }
    public var runIDs: [UUID] { representedRuns.map(\.id) }

    public init(run: ActivityRun) { self.run = run; group = nil }
    public init(group: ActivityAttentionGroup) { self.run = group.latestRun; self.group = group }
}

public enum ActivityDetailDestination: Sendable, Equatable {
    case capture(UUID), workspaceChat(UUID), conversation(UUID)
    public var title: String {
        switch self {
        case .capture: "Open capture"
        case .workspaceChat, .conversation: "Open conversation"
        }
    }
}

/// The only operations with a safe, targeted retry path (D35): a failed capture
/// summary and a failed archive of one stored conversation. Everything else
/// has no Retry.
public enum ActivityRetryTarget: Sendable, Equatable {
    case captureSummary(recordID: UUID)
    case conversationArchive(conversationID: UUID, jobKey: String)

    public init?(run: ActivityRun) {
        guard run.state == .failed || run.state == .interrupted, run.acknowledgedAt == nil,
              let key = run.jobKey, let reference = run.referenceID.flatMap(UUID.init(uuidString:)) else { return nil }
        if run.category == .capture, key == ActivityJobKey.captureSummary(recordID: reference) {
            self = .captureSummary(recordID: reference)
        } else if run.category == .memory, ActivityJobKey.isArchiving(key) {
            self = .conversationArchive(conversationID: reference, jobKey: key)
        } else {
            return nil
        }
    }
}

/// Deterministic copy and action rules, independent of SwiftUI or a provider.
/// Destination existence and unresolved group membership come from the store;
/// the app supplies its existing operational Stop capability.
public struct ActivityRunDetailPresentation: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case retry(ActivityRetryTarget), open(ActivityDetailDestination), stop, dismiss(ActivityAttentionGroup)
    }
    public let run: ActivityRun
    public let actions: [Action]

    public init(run: ActivityRun, destination: ActivityDetailDestination? = nil,
                stopSupported: Bool = false, dismissalGroup: ActivityAttentionGroup? = nil,
                retrySupported: (ActivityRetryTarget) -> Bool = { _ in false }) {
        self.run = run
        var actions: [Action] = []
        if let target = ActivityRetryTarget(run: run), retrySupported(target) { actions.append(.retry(target)) }
        if let destination { actions.append(.open(destination)) }
        if stopSupported, !run.state.isTerminal, run.state != .cancellationRequested { actions.append(.stop) }
        if [.failed, .interrupted, .outcomeUnknown].contains(run.state),
           let group = dismissalGroup, !group.runs.isEmpty,
           group.runs.allSatisfy({ [.failed, .interrupted, .outcomeUnknown].contains($0.state) && $0.acknowledgedAt == nil }) {
            actions.append(.dismiss(group))
        }
        self.actions = actions
    }

    public var summary: String {
        switch run.state {
        case .queued: "This work is queued and has not started yet."
        case .running: "This work is in progress and its result has not been recorded yet."
        case .waiting where run.category == .capture:
            "This capture is waiting to be saved, so its data still needs your attention."
        case .waiting: "This work is waiting and has not finished yet."
        case .awaitingApproval: "This work is waiting for your decision and has not been approved."
        case .cancellationRequested: "A stop was requested and the operation has not confirmed that it ended yet."
        case .succeeded: "This work completed successfully and its recorded result is shown below."
        case .failed: "This work did not complete successfully; review the recorded result before deciding what to do next."
        case .interrupted: "This work was interrupted before a completed result was recorded."
        case .outcomeUnknown: "The result is unknown: an action may already have happened, so review it before trying again."
        case .cancelled: "This work stopped without a recorded successful result."
        }
    }
}
