import Foundation
import GRDB
import AitvarasCore

/// A privacy-safe recap assembled from durable activity counts. It never
/// contains mail subjects, notification bodies, URLs, or model-generated
/// summaries, so untrusted external text cannot become a spoken prompt.
public struct WakeBriefing: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable, CaseIterable {
        case mail = "Mail"
        case systemNotifications = "System Notifications"
        case moodle = "Moodle"
    }

    public var sleepStartedAt: Date
    public var catchUpStartedAt: Date
    public var preparedAt: Date
    public var mailCount: Int
    public var notificationCount: Int
    public var deadlineCount: Int
    public var otherUpdateCount: Int
    public var heldMessageCount: Int
    public var newSuggestionCount: Int
    public var failedDeliveryCount: Int
    public var unavailableSources: [Source]
    public var limitedSources: [Source]

    public init(
        sleepStartedAt: Date,
        catchUpStartedAt: Date? = nil,
        preparedAt: Date,
        mailCount: Int = 0,
        notificationCount: Int = 0,
        deadlineCount: Int = 0,
        otherUpdateCount: Int = 0,
        heldMessageCount: Int = 0,
        newSuggestionCount: Int = 0,
        failedDeliveryCount: Int = 0,
        unavailableSources: [Source] = [],
        limitedSources: [Source] = []
    ) {
        self.sleepStartedAt = sleepStartedAt
        self.catchUpStartedAt = catchUpStartedAt ?? sleepStartedAt
        self.preparedAt = preparedAt
        self.mailCount = max(0, mailCount)
        self.notificationCount = max(0, notificationCount)
        self.deadlineCount = max(0, deadlineCount)
        self.otherUpdateCount = max(0, otherUpdateCount)
        self.heldMessageCount = max(0, heldMessageCount)
        self.newSuggestionCount = max(0, newSuggestionCount)
        self.failedDeliveryCount = max(0, failedDeliveryCount)
        self.unavailableSources = Array(Set(unavailableSources))
            .sorted { $0.rawValue < $1.rawValue }
        self.limitedSources = Array(Set(limitedSources))
            .sorted { $0.rawValue < $1.rawValue }
    }

    public var hasUpdates: Bool {
        mailCount > 0 || notificationCount > 0 || deadlineCount > 0
            || otherUpdateCount > 0 || heldMessageCount > 0
            || newSuggestionCount > 0 || failedDeliveryCount > 0
            || !unavailableSources.isEmpty || !limitedSources.isEmpty
    }

    public var spokenText: String {
        var details: [String] = []
        if mailCount > 0 {
            details.append(Self.counted(mailCount, singular: "email arrived", plural: "emails arrived"))
        }
        if notificationCount > 0 {
            details.append(Self.counted(
                notificationCount, singular: "notification arrived", plural: "notifications arrived"))
        }
        if deadlineCount > 0 {
            details.append(Self.counted(
                deadlineCount, singular: "new deadline surfaced", plural: "new deadlines surfaced"))
        }
        if otherUpdateCount > 0 {
            details.append(Self.counted(
                otherUpdateCount,
                singular: "connected-service update arrived",
                plural: "connected-service updates arrived"))
        }
        if heldMessageCount > 0 {
            details.append(Self.counted(
                heldMessageCount,
                singular: "message was held for sender review",
                plural: "messages were held for sender review"))
        }
        if newSuggestionCount > 0 {
            details.append(Self.counted(
                newSuggestionCount,
                singular: "action is waiting for your review",
                plural: "actions are waiting for your review"))
        }
        if failedDeliveryCount > 0 {
            details.append(Self.counted(
                failedDeliveryCount,
                singular: "phone delivery needs attention",
                plural: "phone deliveries need attention"))
        }
        if !unavailableSources.isEmpty {
            details.append("I could not refresh "
                + unavailableSources.map(\.rawValue).joined(separator: ", "))
        }
        if !limitedSources.isEmpty {
            details.append("I checked only the latest "
                + String(ConnectorEventStreams.maximumWakeCatchUpEvents)
                + " items for " + limitedSources.map(\.rawValue).joined(separator: ", "))
        }

        var opening = "Welcome back. You were away for \(Self.durationText(preparedAt.timeIntervalSince(sleepStartedAt)))."
        if catchUpStartedAt.timeIntervalSince(sleepStartedAt) > 1 {
            opening += " I checked the latest 7 days."
        }
        guard !details.isEmpty else {
            return opening + " Nothing new needs your attention."
        }
        return String((opening + " " + Self.sentenceList(details) + ".").prefix(600))
    }

    private static func counted(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }

    private static func sentenceList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return items[0] + ", and " + items[1]
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    private static func durationText(_ rawSeconds: TimeInterval) -> String {
        let seconds = max(0, rawSeconds)
        if seconds < 90 { return "a minute" }
        if seconds < 60 * 60 {
            return "\(max(2, Int((seconds / 60).rounded()))) minutes"
        }
        if seconds < 2 * 60 * 60 { return "about an hour" }
        if seconds < 24 * 60 * 60 {
            return "\(Int((seconds / 3600).rounded())) hours"
        }
        let days = max(1, Int((seconds / 86_400).rounded()))
        return "\(days) \(days == 1 ? "day" : "days")"
    }
}

public enum WakeBriefingPolicy {
    public static let minimumSleepDuration: TimeInterval = 5 * 60
    public static let maximumLookback: TimeInterval = 7 * 24 * 60 * 60

    public static func effectiveStart(sleepStartedAt: Date, wokeAt: Date) -> Date? {
        let duration = wokeAt.timeIntervalSince(sleepStartedAt)
        guard duration >= minimumSleepDuration else { return nil }
        return max(sleepStartedAt, wokeAt.addingTimeInterval(-maximumLookback))
    }
}

public struct WakeBriefingWindow: Sendable, Equatable {
    public var sleepStartedAt: Date
    public var catchUpStartedAt: Date

    public init(sleepStartedAt: Date, catchUpStartedAt: Date) {
        self.sleepStartedAt = sleepStartedAt
        self.catchUpStartedAt = catchUpStartedAt
    }
}

public enum WakeBriefingError: Error, LocalizedError, Sendable {
    case sleepBoundaryChanged

    public var errorDescription: String? {
        switch self {
        case .sleepBoundaryChanged:
            "The Mac went back to sleep before the wake briefing finished. The newer sleep period was preserved."
        }
    }
}

public extension Stores {
    static var wakeBriefingSleepStartedKey: String { "wakeBriefing.sleepStartedAt" }
    static var wakeBriefingLastPresentedKey: String { "wakeBriefing.lastPresentedAt" }

    func noteSystemSleep(at date: Date = .now) throws {
        try setValue(String(date.timeIntervalSince1970),
                     forKey: Self.wakeBriefingSleepStartedKey)
    }

    /// Return the durable sleep/catch-up window. A short-sleep boundary is
    /// consumed here so a later duplicate wake signal cannot age it into a
    /// briefing that no longer corresponds to a real sleep transition.
    func pendingWakeBriefingWindow(wokeAt: Date = .now) throws -> WakeBriefingWindow? {
        try db.queue.write { database in
            guard let raw = try String.fetchOne(
                database,
                sql: "SELECT value FROM kv WHERE key = ?",
                arguments: [Self.wakeBriefingSleepStartedKey]),
                  let timestamp = Double(raw) else { return nil }
            let sleepStartedAt = Date(timeIntervalSince1970: timestamp)
            guard let catchUpStartedAt = WakeBriefingPolicy.effectiveStart(
                sleepStartedAt: sleepStartedAt,
                wokeAt: wokeAt) else {
                try database.execute(
                    sql: "UPDATE kv SET value = '' WHERE key = ? AND value = ?",
                    arguments: [Self.wakeBriefingSleepStartedKey, raw])
                return nil
            }
            return WakeBriefingWindow(
                sleepStartedAt: sleepStartedAt,
                catchUpStartedAt: catchUpStartedAt)
        }
    }

    func pendingWakeBriefingStart(wokeAt: Date = .now) throws -> Date? {
        try pendingWakeBriefingWindow(wokeAt: wokeAt)?.catchUpStartedAt
    }

    func wakeBriefing(
        since: Date,
        sleepStartedAt: Date? = nil,
        preparedAt: Date = .now,
        unavailableSources: [WakeBriefing.Source] = [],
        limitedSources: [WakeBriefing.Source] = []
    ) throws -> WakeBriefing {
        try db.queue.read { database in
            let row = try Row.fetchOne(database, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN kind = ? AND connectorID = 'mail' THEN 1 ELSE 0 END), 0) AS mailCount,
                    COALESCE(SUM(CASE WHEN kind = ? AND connectorID = 'notifications' THEN 1 ELSE 0 END), 0) AS notificationCount,
                    COALESCE(SUM(CASE WHEN kind = ? AND connectorID = 'moodle' THEN 1 ELSE 0 END), 0) AS deadlineCount,
                    COALESCE(SUM(CASE WHEN kind = ? AND connectorID NOT IN ('mail', 'notifications', 'moodle') THEN 1 ELSE 0 END), 0) AS otherUpdateCount,
                    COALESCE(SUM(CASE WHEN kind = ? AND summary LIKE 'quarantined:%' THEN 1 ELSE 0 END), 0) AS heldMessageCount,
                    COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS newSuggestionCount,
                    COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS failedDeliveryCount
                FROM activityEvent
                WHERE timestamp >= ? AND timestamp <= ?
                """, arguments: [
                    ActivityEvent.Kind.eventReceived.rawValue,
                    ActivityEvent.Kind.eventReceived.rawValue,
                    ActivityEvent.Kind.eventReceived.rawValue,
                    ActivityEvent.Kind.eventReceived.rawValue,
                    ActivityEvent.Kind.classification.rawValue,
                    ActivityEvent.Kind.suggestionOffered.rawValue,
                    ActivityEvent.Kind.notificationFailed.rawValue,
                    since, preparedAt
                ])
            return WakeBriefing(
                sleepStartedAt: sleepStartedAt ?? since,
                catchUpStartedAt: since,
                preparedAt: preparedAt,
                mailCount: row?["mailCount"] ?? 0,
                notificationCount: row?["notificationCount"] ?? 0,
                deadlineCount: row?["deadlineCount"] ?? 0,
                otherUpdateCount: row?["otherUpdateCount"] ?? 0,
                heldMessageCount: row?["heldMessageCount"] ?? 0,
                newSuggestionCount: row?["newSuggestionCount"] ?? 0,
                failedDeliveryCount: row?["failedDeliveryCount"] ?? 0,
                unavailableSources: unavailableSources,
                limitedSources: limitedSources)
        }
    }

    /// Record the recap and consume its sleep boundary atomically. A duplicate
    /// wake notification therefore cannot produce the same briefing twice.
    @discardableResult
    func completeWakeBriefing(_ briefing: WakeBriefing) throws -> ActivityEvent {
        let detail = String(decoding: try JSONEncoder().encode(briefing), as: UTF8.self)
        let event = ActivityEvent(
            kind: .wakeBriefing,
            timestamp: briefing.preparedAt,
            connectorID: "system",
            summary: briefing.spokenText,
            detailJSON: detail)
        try db.queue.write { database in
            let expectedBoundary = String(briefing.sleepStartedAt.timeIntervalSince1970)
            let currentBoundary = try String.fetchOne(
                database,
                sql: "SELECT value FROM kv WHERE key = ?",
                arguments: [Self.wakeBriefingSleepStartedKey])
            guard currentBoundary == expectedBoundary else {
                throw WakeBriefingError.sleepBoundaryChanged
            }
            try event.insert(database)
            try database.execute(
                sql: "UPDATE kv SET value = '' WHERE key = ? AND value = ?",
                arguments: [Self.wakeBriefingSleepStartedKey, expectedBoundary])
            try database.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.wakeBriefingLastPresentedKey,
                            String(briefing.preparedAt.timeIntervalSince1970)])
        }
        return event
    }
}
