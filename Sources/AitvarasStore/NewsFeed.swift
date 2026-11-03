import Foundation
import GRDB

public enum NewsFeedStoreError: Error, LocalizedError, Sendable {
    case invalidTopic(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTopic(let reason): "News topic was not saved: \(reason)"
        }
    }
}

public enum NewsImportance: Int, CaseIterable, Codable, Sendable {
    case low = 1
    case normal = 3
    case high = 5

    public var displayName: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }
}

public enum NewsRefreshInterval: Int, CaseIterable, Codable, Sendable {
    case sixHours = 360
    case twelveHours = 720
    case daily = 1440
    case weekly = 10_080

    public var displayName: String {
        switch self {
        case .sixHours: "Every 6 hours"
        case .twelveHours: "Every 12 hours"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

public struct NewsTopic: Codable, Sendable, Identifiable, Equatable,
                         FetchableRecord, PersistableRecord {
    public static let databaseTableName = "newsTopic"
    public static let maximumNameCharacters = 100
    public static let maximumQueryCharacters = 300

    public var id: UUID
    public var name: String
    public var query: String
    public var importance: Int
    public var refreshIntervalMinutes: Int
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastFetchedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        query: String,
        importance: NewsImportance = .normal,
        refreshInterval: NewsRefreshInterval = .daily,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastFetchedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.query = query
        self.importance = importance.rawValue
        self.refreshIntervalMinutes = refreshInterval.rawValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastFetchedAt = lastFetchedAt
    }

    public var importanceValue: NewsImportance {
        if importance >= NewsImportance.high.rawValue { return .high }
        if importance <= NewsImportance.low.rawValue { return .low }
        return .normal
    }

    public var refreshIntervalValue: NewsRefreshInterval {
        NewsRefreshInterval(rawValue: refreshIntervalMinutes) ?? .daily
    }

    public var nextRefreshAt: Date? {
        lastFetchedAt?.addingTimeInterval(Double(refreshIntervalMinutes * 60))
    }

    public func isDue(at date: Date) -> Bool {
        guard isEnabled else { return false }
        guard let nextRefreshAt else { return true }
        return nextRefreshAt <= date
    }
}

public struct NewsArticle: Codable, Sendable, Identifiable, Equatable,
                           FetchableRecord, PersistableRecord {
    public static let databaseTableName = "newsArticle"
    public static let maximumTitleCharacters = 500
    public static let maximumSummaryCharacters = 2_000
    public static let maximumSourceCharacters = 200
    public static let maximumURLCharacters = 4_000

    public var id: UUID
    public var topicID: UUID
    public var title: String
    public var sourceName: String
    public var sourceDomain: String
    public var url: String
    public var summary: String
    public var imageURL: String?
    public var publishedAt: Date
    public var fetchedAt: Date
    public var qualityScore: Double
    public var corroborationCount: Int
    public var supportingSourcesJSON: String
    public var isRead: Bool

    public init(
        id: UUID,
        topicID: UUID,
        title: String,
        sourceName: String,
        sourceDomain: String,
        url: String,
        summary: String = "",
        imageURL: String? = nil,
        publishedAt: Date,
        fetchedAt: Date = .now,
        qualityScore: Double,
        corroborationCount: Int = 1,
        supportingSources: [String] = [],
        isRead: Bool = false
    ) {
        self.id = id
        self.topicID = topicID
        self.title = title
        self.sourceName = sourceName
        self.sourceDomain = sourceDomain
        self.url = url
        self.summary = summary
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.qualityScore = qualityScore
        self.corroborationCount = max(1, corroborationCount)
        self.supportingSourcesJSON = (try? String(
            data: JSONEncoder().encode(supportingSources), encoding: .utf8)) ?? "[]"
        self.isRead = isRead
    }

    public var supportingSources: [String] {
        guard let data = supportingSourcesJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// Source text is spoken as data, never passed through a model. Keeping
    /// the source attribution in the sentence makes the provenance audible.
    public var narrationText: String {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanSummary.isEmpty {
            return "From \(sourceName). \(title)."
        }
        return "From \(sourceName). \(title). \(cleanSummary)"
    }
}

public struct NewsMorningPreferences: Sendable, Equatable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int

    public init(isEnabled: Bool = true, hour: Int = 8, minute: Int = 0) {
        self.isEnabled = isEnabled
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }
}

/// Deterministic interpretation of the short answer to Aitvaras's pending
/// morning-news question. Unrelated speech continues through the normal agent.
public enum NewsMorningReplyIntent: Sendable, Equatable {
    case accept
    case decline
    case unrelated

    public static func classify(_ text: String) -> Self {
        let words = Set(text.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        let negative = ["no", "nope", "nein", "later", "später"]
        if !words.isDisjoint(with: negative)
            || (words.contains("not") && words.contains("now")) {
            return .decline
        }
        let positive = ["yes", "yeah", "sure", "okay", "ok", "please", "ja", "gerne"]
        return words.isDisjoint(with: positive) ? .unrelated : .accept
    }
}

/// One-time starter feeds. They are ordinary editable topics after install:
/// deleting or changing one is respected because the version marker prevents
/// Aitvaras from recreating it on every launch.
public enum DefaultNewsTopics {
    public static func topics(at date: Date = .now) -> [NewsTopic] {
        [
            NewsTopic(
                id: UUID(uuidString: "0F625268-5A57-4EA4-9E5F-55E074510B8D")!,
                name: "AI tools & workflows",
                query: "\"OpenAI Codex\" OR \"Claude Code\" OR \"GitHub Copilot\" OR \"Cursor AI\" OR \"Cline AI\" OR \"Aider AI\" OR \"coding agent\" OR \"agentic coding\" OR \"developer workflow\" OR \"Model Context Protocol\" OR \"agent skills\" OR \"AI companion\" OR \"AI model release\" OR \"applied AI\"",
                importance: .high,
                refreshInterval: .twelveHours,
                createdAt: date,
                updatedAt: date),
            NewsTopic(
                id: UUID(uuidString: "970726AF-2C50-48E2-A502-3A80E88BF86F")!,
                name: "International politics",
                query: "\"Ukraine war\" OR \"Israel Gaza\" OR \"Middle East conflict\" OR \"China Taiwan\" OR \"foreign policy\" OR \"economic sanctions\" OR \"NATO decision\" OR \"European Union decision\" OR \"United Nations resolution\" OR \"major election\" -stocks -markets -investors -consumer -deals -shares -Nikkei -selloff",
                importance: .high,
                refreshInterval: .twelveHours,
                createdAt: date,
                updatedAt: date),
            NewsTopic(
                id: UUID(uuidString: "A3B2CBA4-20E9-4B69-9B1C-BEC82FEC2D5E")!,
                name: "Germany",
                query: "\"German politics\" OR \"Germany government\" OR Bundestag OR Bundesrat OR Bundesregierung OR \"German economy\" OR \"German policy\" OR \"German election\" OR \"Germany energy\" OR \"Germany security\"",
                importance: .normal,
                refreshInterval: .daily,
                createdAt: date,
                updatedAt: date)
        ]
    }
}

public extension Stores {
    static let maximumNewsArticlesPerTopic = 250
    static let maximumNewsArticleAge: TimeInterval = 30 * 86_400
    private static let defaultNewsTopicsVersionKey = "news.defaults.version"
    private static let defaultNewsTopicsVersion = "1"

    /// Install this release's starter topics once without overwriting custom
    /// topics. The single old demo preset is removed as part of the requested
    /// transition from broad AI research to practical AI tools and workflows.
    @discardableResult
    func installDefaultNewsTopics(at date: Date = .now) throws -> Bool {
        try db.queue.write { database in
            let installed = try String.fetchOne(
                database,
                sql: "SELECT value FROM kv WHERE key = ?",
                arguments: [Self.defaultNewsTopicsVersionKey])
            guard installed != Self.defaultNewsTopicsVersion else { return false }

            try database.execute(
                sql: """
                    DELETE FROM newsTopic
                    WHERE name = ? COLLATE NOCASE AND query = ? COLLATE NOCASE
                    """,
                arguments: ["AI research", "artificial intelligence research"])

            for topic in DefaultNewsTopics.topics(at: date) {
                let alreadyExists = try Bool.fetchOne(
                    database,
                    sql: """
                        SELECT 1 FROM newsTopic
                        WHERE name = ? COLLATE NOCASE OR query = ? COLLATE NOCASE
                        """,
                    arguments: [topic.name, topic.query]) ?? false
                if !alreadyExists { try topic.insert(database) }
            }
            try database.execute(
                sql: """
                    INSERT INTO kv(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [Self.defaultNewsTopicsVersionKey, Self.defaultNewsTopicsVersion])
            return true
        }
    }

    func newsTopics() throws -> [NewsTopic] {
        try db.queue.read {
            try NewsTopic
                .order(Column("importance").desc, Column("name").collating(.localizedCaseInsensitiveCompare))
                .fetchAll($0)
        }
    }

    func newsTopic(id: UUID) throws -> NewsTopic? {
        try db.queue.read { try NewsTopic.fetchOne($0, key: id) }
    }

    @discardableResult
    func saveNewsTopic(_ proposed: NewsTopic, at date: Date = .now) throws -> NewsTopic {
        var topic = proposed
        topic.name = topic.name.trimmingCharacters(in: .whitespacesAndNewlines)
        topic.query = topic.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.name.isEmpty else {
            throw NewsFeedStoreError.invalidTopic("give it a name.")
        }
        guard !topic.query.isEmpty else {
            throw NewsFeedStoreError.invalidTopic("add search terms.")
        }
        guard topic.name.count <= NewsTopic.maximumNameCharacters else {
            throw NewsFeedStoreError.invalidTopic(
                "the name is longer than \(NewsTopic.maximumNameCharacters) characters.")
        }
        guard topic.query.count <= NewsTopic.maximumQueryCharacters else {
            throw NewsFeedStoreError.invalidTopic(
                "the search terms are longer than \(NewsTopic.maximumQueryCharacters) characters.")
        }
        guard (1...5).contains(topic.importance) else {
            throw NewsFeedStoreError.invalidTopic("importance must be between 1 and 5.")
        }
        guard NewsRefreshInterval(rawValue: topic.refreshIntervalMinutes) != nil else {
            throw NewsFeedStoreError.invalidTopic("choose a supported refresh interval.")
        }
        topic.updatedAt = date
        return try db.queue.write { database in
            if let existing = try NewsTopic.fetchOne(database, key: topic.id) {
                topic.createdAt = existing.createdAt
                // Changing what is searched should make the topic due now.
                if existing.query != topic.query
                    || existing.refreshIntervalMinutes != topic.refreshIntervalMinutes {
                    topic.lastFetchedAt = nil
                }
            }
            try topic.save(database)
            return topic
        }
    }

    func deleteNewsTopic(_ id: UUID) throws {
        _ = try db.queue.write { try NewsTopic.deleteOne($0, key: id) }
    }

    func dueNewsTopics(at date: Date = .now) throws -> [NewsTopic] {
        try newsTopics().filter { $0.isDue(at: date) }
    }

    func newsArticles(topicID: UUID? = nil, limit: Int = 100) throws -> [NewsArticle] {
        let boundedLimit = min(max(limit, 1), 500)
        return try db.queue.read { database in
            var request = NewsArticle
                .order(Column("qualityScore").desc, Column("publishedAt").desc)
            if let topicID {
                request = request.filter(Column("topicID") == topicID)
            }
            return try request.limit(boundedLimit).fetchAll(database)
        }
    }

    /// A refresh is one isolated transaction: article cache and topic cursor
    /// advance together. Existing read state survives a repeated URL.
    func replaceNewsArticles(
        _ articles: [NewsArticle],
        for topicID: UUID,
        fetchedAt: Date = .now
    ) throws {
        try db.queue.write { database in
            guard try NewsTopic.fetchOne(database, key: topicID) != nil else {
                throw NewsFeedStoreError.invalidTopic("it no longer exists.")
            }
            // Mark the old snapshot before inserting the new one. This makes
            // replacement exact even when a deterministic test (or two very
            // fast refreshes) uses the same fetchedAt timestamp twice.
            try database.execute(
                sql: "UPDATE newsArticle SET fetchedAt = ? WHERE topicID = ?",
                arguments: [fetchedAt.addingTimeInterval(-1), topicID])
            for proposed in articles {
                var article = proposed
                article.topicID = topicID
                article.fetchedAt = fetchedAt
                let existing = try NewsArticle
                    .filter(Column("topicID") == topicID)
                    .filter(Column("url") == article.url)
                    .fetchOne(database)
                    ?? NewsArticle.fetchOne(database, key: article.id)
                if let existing {
                    article.id = existing.id
                    article.isRead = existing.isRead
                }
                try article.save(database)
            }
            try database.execute(
                sql: "UPDATE newsTopic SET lastFetchedAt = ? WHERE id = ?",
                arguments: [fetchedAt, topicID])

            // The reader represents the latest curated snapshot, not an
            // inbox. Rows that were not accepted by this successful refresh
            // disappear immediately instead of lingering as stale/noisy news.
            try database.execute(
                sql: "DELETE FROM newsArticle WHERE topicID = ? AND fetchedAt < ?",
                arguments: [topicID, fetchedAt])

            let cutoff = fetchedAt.addingTimeInterval(-Self.maximumNewsArticleAge)
            try database.execute(
                sql: "DELETE FROM newsArticle WHERE topicID = ? AND publishedAt < ?",
                arguments: [topicID, cutoff])
            try database.execute(sql: """
                DELETE FROM newsArticle
                WHERE topicID = ? AND id NOT IN (
                    SELECT id FROM newsArticle WHERE topicID = ?
                    ORDER BY qualityScore DESC, publishedAt DESC LIMIT ?
                )
                """, arguments: [topicID, topicID, Self.maximumNewsArticlesPerTopic])
        }
    }

    func markNewsArticleRead(_ id: UUID, isRead: Bool = true) throws {
        try db.queue.write {
            try $0.execute(
                sql: "UPDATE newsArticle SET isRead = ? WHERE id = ?",
                arguments: [isRead, id])
        }
    }

    private static let newsMorningEnabledKey = "news.morning.enabled"
    private static let newsMorningHourKey = "news.morning.hour"
    private static let newsMorningMinuteKey = "news.morning.minute"
    private static let newsMorningLastOfferKey = "news.morning.lastOfferDay"

    func newsMorningPreferences() throws -> NewsMorningPreferences {
        NewsMorningPreferences(
            isEnabled: try value(forKey: Self.newsMorningEnabledKey) != "0",
            hour: try value(forKey: Self.newsMorningHourKey).flatMap(Int.init) ?? 8,
            minute: try value(forKey: Self.newsMorningMinuteKey).flatMap(Int.init) ?? 0)
    }

    func setNewsMorningPreferences(_ preferences: NewsMorningPreferences) throws {
        try setValues([
            Self.newsMorningEnabledKey: preferences.isEnabled ? "1" : "0",
            Self.newsMorningHourKey: String(preferences.hour),
            Self.newsMorningMinuteKey: String(preferences.minute)
        ])
    }

    /// Atomically claim today's single permitted proactive news moment.
    /// Launching late at night does not replay a stale morning interruption.
    func claimMorningNewsOffer(
        at date: Date = .now,
        calendar: Calendar = .current
    ) throws -> Bool {
        let preferences = try newsMorningPreferences()
        guard preferences.isEnabled, try !newsTopics().isEmpty else { return false }
        let start = calendar.date(
            bySettingHour: preferences.hour,
            minute: preferences.minute,
            second: 0,
            of: date) ?? date
        guard date >= start, date < start.addingTimeInterval(4 * 60 * 60) else {
            return false
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d",
                         components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return try db.queue.write { database in
            let previous = try String.fetchOne(
                database, sql: "SELECT value FROM kv WHERE key = ?",
                arguments: [Self.newsMorningLastOfferKey])
            guard previous != day else { return false }
            try database.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.newsMorningLastOfferKey, day])
            return true
        }
    }
}
