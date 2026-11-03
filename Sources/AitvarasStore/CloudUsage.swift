import Foundation
import GRDB

/// Local-only accounting for subscription-backed CLI work. This is an audit
/// ledger, not a provider bill: token and cost fields stay nil when a CLI does
/// not report them.
public struct CloudUsageRecord: Codable, Sendable, Equatable, Identifiable,
                                FetchableRecord, PersistableRecord {
    public static let databaseTableName = "cloudUsage"

    public var id: UUID
    public var timestamp: Date
    public var feature: String
    public var provider: String
    public var durationMilliseconds: Int
    public var inputCharacters: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reportedCostUSD: Double?
    public var succeeded: Bool
    public var dataCategoriesJSON: String
    public var policyVersion: String
    public var failureKind: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        feature: String,
        provider: String,
        durationMilliseconds: Int,
        inputCharacters: Int,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reportedCostUSD: Double? = nil,
        succeeded: Bool,
        dataCategories: [String],
        policyVersion: String,
        failureKind: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.feature = String(feature.prefix(80))
        self.provider = String(provider.prefix(40))
        self.durationMilliseconds = max(0, durationMilliseconds)
        self.inputCharacters = max(0, inputCharacters)
        self.inputTokens = inputTokens.map { max(0, $0) }
        self.outputTokens = outputTokens.map { max(0, $0) }
        self.reportedCostUSD = reportedCostUSD.map { max(0, $0) }
        self.succeeded = succeeded
        self.dataCategoriesJSON = Self.encodeCategories(dataCategories)
        self.policyVersion = String(policyVersion.prefix(40))
        self.failureKind = failureKind.map { String($0.prefix(120)) }
    }

    public var dataCategories: [String] {
        guard let data = dataCategoriesJSON.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values
    }

    private static func encodeCategories(_ values: [String]) -> String {
        let bounded = values.prefix(12).map { String($0.prefix(120)) }
        guard let data = try? JSONEncoder().encode(bounded) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CloudUsageSummary: Sendable, Equatable {
    public var callsToday: Int
    public var callsThisMonth: Int
    public var successfulCallsThisMonth: Int
    public var inputTokensThisMonth: Int?
    public var outputTokensThisMonth: Int?
    public var reportedCostUSDThisMonth: Double?
    public var lastUse: CloudUsageRecord?

    public static let empty = CloudUsageSummary(
        callsToday: 0,
        callsThisMonth: 0,
        successfulCallsThisMonth: 0,
        inputTokensThisMonth: nil,
        outputTokensThisMonth: nil,
        reportedCostUSDThisMonth: nil,
        lastUse: nil)
}

public struct CloudUsageBreakdown: Sendable, Equatable, Identifiable {
    public var feature: String
    public var calls: Int
    public var successfulCalls: Int
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reportedCostUSD: Double?
    public var lastUsedAt: Date

    public var id: String { feature }
}

public extension Stores {
    @discardableResult
    func recordCloudUsage(_ record: CloudUsageRecord) throws -> CloudUsageRecord {
        try db.queue.write { dbc in
            try record.insert(dbc)
            // Keep a useful year of small metadata without allowing an
            // unbounded telemetry table.
            try dbc.execute(
                sql: "DELETE FROM cloudUsage WHERE timestamp < ?",
                arguments: [Date.now.addingTimeInterval(-366 * 24 * 3600)])
        }
        return record
    }

    func recentCloudUsage(limit: Int = 20) throws -> [CloudUsageRecord] {
        try db.queue.read {
            try CloudUsageRecord
                .order(Column("timestamp").desc)
                .limit(min(max(limit, 0), 200))
                .fetchAll($0)
        }
    }

    func recentCloudUsage(feature: String, limit: Int = 12)
        throws -> [CloudUsageRecord] {
        try db.queue.read {
            try CloudUsageRecord
                .filter(Column("feature") == feature)
                .order(Column("timestamp").desc)
                .limit(min(max(limit, 0), 200))
                .fetchAll($0)
        }
    }

    func cloudUsageBreakdown(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> [CloudUsageBreakdown] {
        let month = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let records = try db.queue.read {
            try CloudUsageRecord
                .filter(Column("timestamp") >= month)
                .order(Column("timestamp").desc)
                .fetchAll($0)
        }
        return Dictionary(grouping: records, by: \.feature)
            .values.compactMap { group in
                guard let newest = group.first else { return nil }
                let tokenRecords = group.filter {
                    $0.inputTokens != nil || $0.outputTokens != nil
                }
                let costs = group.compactMap(\.reportedCostUSD)
                return CloudUsageBreakdown(
                    feature: newest.feature,
                    calls: group.count,
                    successfulCalls: group.filter(\.succeeded).count,
                    inputTokens: tokenRecords.isEmpty ? nil
                        : tokenRecords.compactMap(\.inputTokens).reduce(0, +),
                    outputTokens: tokenRecords.isEmpty ? nil
                        : tokenRecords.compactMap(\.outputTokens).reduce(0, +),
                    reportedCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                    lastUsedAt: newest.timestamp)
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func cloudUsageSummary(
        now: Date = .now,
        calendar: Calendar = .current
    ) throws -> CloudUsageSummary {
        let day = calendar.startOfDay(for: now)
        let month = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)) ?? day
        let records = try db.queue.read {
            try CloudUsageRecord
                .filter(Column("timestamp") >= month)
                .order(Column("timestamp").desc)
                .fetchAll($0)
        }
        let tokenRecords = records.filter {
            $0.inputTokens != nil || $0.outputTokens != nil
        }
        let costRecords = records.compactMap(\.reportedCostUSD)
        return CloudUsageSummary(
            callsToday: records.filter { $0.timestamp >= day }.count,
            callsThisMonth: records.count,
            successfulCallsThisMonth: records.filter(\.succeeded).count,
            inputTokensThisMonth: tokenRecords.isEmpty
                ? nil : tokenRecords.compactMap(\.inputTokens).reduce(0, +),
            outputTokensThisMonth: tokenRecords.isEmpty
                ? nil : tokenRecords.compactMap(\.outputTokens).reduce(0, +),
            reportedCostUSDThisMonth: costRecords.isEmpty
                ? nil : costRecords.reduce(0, +),
            lastUse: records.first)
    }
}
