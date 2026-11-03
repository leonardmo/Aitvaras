import Foundation
import GRDB

/// Local inference accounting. No prompt, response, tool argument or memory
/// content is stored—only counts and execution metadata.
public struct LocalModelUsageRecord: Codable, Sendable, Equatable, Identifiable,
                                     FetchableRecord, PersistableRecord {
    public static let databaseTableName = "localModelUsage"

    public var id: UUID
    public var timestamp: Date
    public var engine: String
    public var tier: String
    public var durationMilliseconds: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var isEstimated: Bool
    public var succeeded: Bool
    public var failureKind: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        engine: String,
        tier: String,
        durationMilliseconds: Int,
        inputTokens: Int,
        outputTokens: Int,
        isEstimated: Bool,
        succeeded: Bool,
        failureKind: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.engine = String(engine.prefix(160))
        self.tier = String(tier.prefix(40))
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.isEstimated = isEstimated
        self.succeeded = succeeded
        self.failureKind = failureKind.map { String($0.prefix(120)) }
    }

    public var tokenCredits: Int { inputTokens + outputTokens }
}

public struct LocalModelUsageSummary: Sendable, Equatable {
    public var callsToday: Int
    public var callsThisMonth: Int
    public var successfulCallsThisMonth: Int
    public var inputTokensThisMonth: Int
    public var outputTokensThisMonth: Int
    public var estimatedCallsThisMonth: Int
    public var lastUse: LocalModelUsageRecord?

    public static let empty = LocalModelUsageSummary(
        callsToday: 0,
        callsThisMonth: 0,
        successfulCallsThisMonth: 0,
        inputTokensThisMonth: 0,
        outputTokensThisMonth: 0,
        estimatedCallsThisMonth: 0,
        lastUse: nil)

    public var tokenCreditsThisMonth: Int {
        inputTokensThisMonth + outputTokensThisMonth
    }
}

public struct LocalModelUsageBreakdown: Sendable, Equatable, Identifiable {
    public var engine: String
    public var tier: String
    public var calls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCalls: Int
    public var lastUsedAt: Date

    public var id: String { "\(engine)|\(tier)" }
    public var tokenCredits: Int { inputTokens + outputTokens }
}

public extension Stores {
    @discardableResult
    func recordLocalModelUsage(
        _ record: LocalModelUsageRecord
    ) throws -> LocalModelUsageRecord {
        try db.queue.write { dbc in
            try record.insert(dbc)
            try dbc.execute(
                sql: "DELETE FROM localModelUsage WHERE timestamp < ?",
                arguments: [Date.now.addingTimeInterval(-366 * 24 * 3600)])
        }
        return record
    }

    func recentLocalModelUsage(limit: Int = 40)
        throws -> [LocalModelUsageRecord] {
        try db.queue.read {
            try LocalModelUsageRecord
                .order(Column("timestamp").desc)
                .limit(min(max(limit, 0), 500))
                .fetchAll($0)
        }
    }

    func localModelUsageSummary(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> LocalModelUsageSummary {
        let day = calendar.startOfDay(for: now)
        let month = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)) ?? day
        let records = try localModelUsageRecords(since: month)
        return LocalModelUsageSummary(
            callsToday: records.filter { $0.timestamp >= day }.count,
            callsThisMonth: records.count,
            successfulCallsThisMonth: records.filter(\.succeeded).count,
            inputTokensThisMonth: records.map(\.inputTokens).reduce(0, +),
            outputTokensThisMonth: records.map(\.outputTokens).reduce(0, +),
            estimatedCallsThisMonth: records.filter(\.isEstimated).count,
            lastUse: records.first)
    }

    func localModelUsageBreakdown(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> [LocalModelUsageBreakdown] {
        let month = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let records = try localModelUsageRecords(since: month)
        return Dictionary(grouping: records) { "\($0.engine)|\($0.tier)" }
            .values.compactMap { group in
                guard let newest = group.first else { return nil }
                return LocalModelUsageBreakdown(
                    engine: newest.engine,
                    tier: newest.tier,
                    calls: group.count,
                    inputTokens: group.map(\.inputTokens).reduce(0, +),
                    outputTokens: group.map(\.outputTokens).reduce(0, +),
                    estimatedCalls: group.filter(\.isEstimated).count,
                    lastUsedAt: newest.timestamp)
            }
            .sorted {
                if $0.tokenCredits == $1.tokenCredits {
                    return $0.lastUsedAt > $1.lastUsedAt
                }
                return $0.tokenCredits > $1.tokenCredits
            }
    }

    private func localModelUsageRecords(since date: Date)
        throws -> [LocalModelUsageRecord] {
        try db.queue.read {
            try LocalModelUsageRecord
                .filter(Column("timestamp") >= date)
                .order(Column("timestamp").desc)
                .fetchAll($0)
        }
    }
}
