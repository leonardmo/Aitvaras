import Foundation

/// One unresolved problem row. Only failed/interrupted keyed owners share a
/// row; an unknown outcome always keeps its own run identity.
public struct ActivityAttentionGroup: Sendable, Equatable, Identifiable {
    public enum ID: Sendable, Hashable {
        case job(String)
        case run(UUID)
    }

    public let id: ID
    /// Most recently updated member, then newest start and UUID for ties.
    public let latestRun: ActivityRun
    public let earlierRuns: [ActivityRun]

    public var runs: [ActivityRun] { [latestRun] + earlierRuns }
    public var runIDs: [UUID] { runs.map(\.id) }
    public var totalCount: Int { runs.reduce(0) { $0 + $1.occurrenceCount } }

    public init(id: ID, latestRun: ActivityRun, earlierRuns: [ActivityRun] = []) {
        self.id = id
        self.latestRun = latestRun
        self.earlierRuns = earlierRuns
    }
}

/// Complete database projection for the problem portion of attention. Home,
/// History and dismissal can use the same rows and exact member IDs. Approvals,
/// unsaved captures and notices retain their separate authoritative lifecycles.
public struct ActivityAttentionSnapshot: Sendable, Equatable {
    public let groups: [ActivityAttentionGroup]
    public var runIDs: [UUID] { groups.flatMap(\.runIDs) }
    /// Unknown outcomes require individual review, even when they have a key.
    public var bulkDismissibleRunIDs: [UUID] {
        groups.flatMap(\.runs)
            .filter { $0.state == .failed || $0.state == .interrupted }.map(\.id)
    }

    public init(groups: [ActivityAttentionGroup] = []) {
        self.groups = groups
    }
}
