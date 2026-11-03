import Foundation
import GRDB
import AitvarasCore

extension ActivityRun: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "activityRun" }
}

extension ServiceStatus: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "serviceStatus" }
}

extension ActivityRunStep: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "activityRunStep" }
}

extension ServiceCheckSummary: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "serviceCheckSummary" }
}

extension Notification.Name {
    public static let aitvarasMonitoringChanged = Notification.Name("aitvarasMonitoringChanged")
}

public enum ActivityMonitoringError: Error, Sendable {
    case runNotFound, nonterminalFinish, unsupportedPolicyVersion
}

extension Stores {
    public func activityRunSteps(runID: UUID) throws -> [ActivityRunStep] {
        try db.queue.read {
            try ActivityRunStep.filter(Column("runID") == runID)
                .order(Column("timestamp"), Column("rowid")).fetchAll($0)
        }
    }

    public func activityAttentionRuns(limit: Int = 100) throws -> [ActivityRun] {
        try db.queue.read { dbc in
            try ActivityRun.filter(["failed", "interrupted", "outcomeUnknown"].contains(Column("state")))
                .filter(Column("acknowledgedAt") == nil)
                .order(Column("updatedAt").desc)
                .limit(max(0, limit)).fetchAll(dbc)
        }
    }

    public func acknowledgeActivityRun(id: UUID) throws {
        try db.queue.write { dbc in
            try dbc.execute(sql: "UPDATE activityRun SET acknowledgedAt = ? WHERE id = ? AND state IN ('failed', 'interrupted', 'outcomeUnknown') AND acknowledgedAt IS NULL", arguments: [Date.now, id])
        }
        NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
    }

    public func serviceCheckSummaries(limit: Int = 50, offset: Int = 0,
                                      since: Date? = nil, until: Date? = nil) throws -> [ServiceCheckSummary] {
        guard limit > 0 else { return [] }
        return try db.queue.read { dbc in
            var query = ServiceCheckSummary.all()
            if let since { query = query.filter(Column("lastAttempt") >= since) }
            if let until { query = query.filter(Column("lastAttempt") <= until) }
            return try query.order(Column("day").desc, Column("serviceID"))
                .limit(limit, offset: max(0, offset)).fetchAll(dbc)
        }
    }

    public func activityChildRuns(parentID: UUID) throws -> [ActivityRun] {
        try db.queue.read {
            try ActivityRun.filter(Column("parentID") == parentID)
                .order(Column("startedAt"), Column("id")).fetchAll($0)
        }
    }

    public func activityEvents(runID: UUID) throws -> [ActivityEvent] {
        try db.queue.read {
            try ActivityEvent.filter(Column("runID") == runID)
                .order(Column("timestamp"), Column("id")).fetchAll($0)
        }
    }

    public func legacyActivity(limit: Int = 50, offset: Int = 0, search: String = "",
                               since: Date? = nil, until: Date? = nil) throws -> [ActivityEvent] {
        guard limit > 0 else { return [] }
        return try db.queue.read { dbc in
            var query = ActivityEvent.filter(Column("runID") == nil)
            if !search.isEmpty {
                query = query.filter(sql: "instr(lower(summary), lower(?)) > 0", arguments: [search])
            }
            if let since { query = query.filter(Column("timestamp") >= since) }
            if let until { query = query.filter(Column("timestamp") <= until) }
            return try query.order(Column("timestamp").desc, Column("id").desc)
                .limit(limit, offset: max(0, offset)).fetchAll(dbc)
        }
    }

    public func activityRun(id: UUID) throws -> ActivityRun? {
        try db.queue.read { try ActivityRun.fetchOne($0, key: id) }
    }

    /// Offset pagination is intentionally uncapped; filters apply before the
    /// page is selected, so older records are never hidden behind a UI limit.
    public func activityRuns(filter: ActivityRunFilter = ActivityRunFilter(),
                             limit: Int = 100, offset: Int = 0) throws -> [ActivityRun] {
        guard limit > 0 else { return [] }
        return try db.queue.read { dbc in
            var query = ActivityRun.all()
            if let category = filter.category { query = query.filter(Column("category") == category.rawValue) }
            if let state = filter.state { query = query.filter(Column("state") == state.rawValue) }
            if let since = filter.since { query = query.filter(Column("startedAt") >= since) }
            if let until = filter.until { query = query.filter(Column("startedAt") <= until) }
            if !filter.search.isEmpty {
                // instr treats %, _, and SQL syntax as literal search text.
                query = query.filter(sql: """
                    instr(lower(title || ' ' || coalesce(stage, '') || ' ' || coalesce(outcome, '') || ' ' || coalesce(provider, '')), lower(?)) > 0
                    """, arguments: [filter.search])
            }
            return try query.order(Column("startedAt").desc, Column("id").desc)
                .limit(limit, offset: max(0, offset)).fetchAll(dbc)
        }
    }

    public func currentActivityRuns() throws -> [ActivityRun] {
        try db.queue.read {
            let terminal = ActivityRunState.allCases.filter(\.isTerminal).map(\.rawValue)
            return try ActivityRun.filter(!terminal.contains(Column("state")))
                .order(Column("startedAt").desc, Column("id").desc).fetchAll($0)
        }
    }

    public func serviceStatuses() throws -> [ServiceStatus] {
        try db.queue.read { try ServiceStatus.order(Column("name"), Column("id")).fetchAll($0) }
    }

    public func backgroundWorkPolicy() throws -> BackgroundWorkPolicy {
        try db.queue.read { dbc in
            guard let raw = try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?",
                                                arguments: ["backgroundWorkPolicy.v1"]) else {
                return BackgroundWorkPolicy()
            }
            let policy = try JSONDecoder().decode(BackgroundWorkPolicy.self, from: Data(raw.utf8))
            guard policy.version == BackgroundWorkPolicy.currentVersion else {
                throw ActivityMonitoringError.unsupportedPolicyVersion
            }
            return policy
        }
    }

    public func saveBackgroundWorkPolicy(_ policy: BackgroundWorkPolicy) throws {
        guard policy.version == BackgroundWorkPolicy.currentVersion else {
            throw ActivityMonitoringError.unsupportedPolicyVersion
        }
        let value = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
        try db.queue.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO kv(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: ["backgroundWorkPolicy.v1", value])
        }
        NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
    }
}

/// Synchronous, thread-safe, best-effort metadata reporting. A sticky failure
/// tells the coordinator to suspend automatic work; telemetry never throws
/// through a user's active task. Errors are generic to avoid leaking SQL or
/// private values through localized database diagnostics.
public final class ActivityReporter: @unchecked Sendable {
    public let stores: Stores
    private let lock = NSLock()
    private var storedFailure: String?

    public init(stores: Stores) { self.stores = stores }

    public var failureMessage: String? { lock.withLock { storedFailure } }

    private func perform(_ action: () throws -> Bool) {
        do {
            if try action() {
                NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
            }
        } catch {
            let firstFailure = lock.withLock {
                guard storedFailure == nil else { return false }
                storedFailure = "Activity monitoring could not be saved. Automatic work is suspended."
                return true
            }
            if firstFailure {
                NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
            }
        }
    }

    @discardableResult
    public func begin(_ run: ActivityRun) -> UUID {
        perform {
            try stores.db.queue.write { dbc in
                // Repeated reporting with the same stable ID is idempotent;
                // it must never reopen or overwrite an already finished run.
                guard try ActivityRun.fetchOne(dbc, key: run.id) == nil else { return false }
                try run.insert(dbc)
                try ActivityRunStep(runID: run.id, timestamp: run.startedAt,
                    stage: run.stage ?? run.title, state: run.state).insert(dbc)
                return true
            }
        }
        return run.id
    }

    /// Repeated background failures update one unresolved attention item,
    /// including across restarts. Reviewing it allows a later new incident.
    @discardableResult
    public func problem(title: String, outcome: String) -> UUID {
        var result = UUID()
        perform {
            try stores.db.queue.write { dbc in
                if var run = try ActivityRun.filter(Column("title") == title)
                    .filter(Column("category") == ActivityCategory.system.rawValue)
                    .filter(Column("state") == ActivityRunState.failed.rawValue)
                    .filter(Column("acknowledgedAt") == nil).fetchOne(dbc) {
                    result = run.id
                    run.updatedAt = .now
                    run.outcome = outcome
                    try run.update(dbc)
                } else {
                    let run = ActivityRun(id: result, parentID: nil, category: .system,
                        trigger: .automatic, state: .failed, title: title,
                        executionLocation: "This Mac", dataDestination: "Local activity history", outcome: outcome)
                    try run.insert(dbc)
                    try ActivityRunStep(runID: result, stage: outcome, state: .failed).insert(dbc)
                }
                return true
            }
        }
        return result
    }

    /// Nil patch arguments leave existing metadata intact. Use finish for
    /// terminal transitions; late updates cannot resurrect a completed run.
    public func update(id: UUID, stage: String? = nil, state: ActivityRunState? = nil,
                       progressCompleted: Int? = nil, progressTotal: Int? = nil,
                       provider: String? = nil, executionLocation: String? = nil,
                       dataAccess: String? = nil, dataDestination: String? = nil) {
        perform {
            try stores.db.queue.write { dbc in
                guard var run = try ActivityRun.fetchOne(dbc, key: id) else {
                    throw ActivityMonitoringError.runNotFound
                }
                guard !run.state.isTerminal else { return false }
                let previous = run
                if let stage { run.stage = stage }
                if let state { run.state = state }
                if let progressCompleted { run.progressCompleted = max(0, progressCompleted) }
                if let progressTotal { run.progressTotal = max(0, progressTotal) }
                if let provider { run.provider = provider }
                if let executionLocation { run.executionLocation = executionLocation }
                if let dataAccess { run.dataAccess = dataAccess }
                if let dataDestination { run.dataDestination = dataDestination }
                guard run != previous else { return false }
                let onlyProgressChanged = run.stage == previous.stage && run.state == previous.state
                    && run.provider == previous.provider && run.executionLocation == previous.executionLocation
                    && run.dataAccess == previous.dataAccess && run.dataDestination == previous.dataDestination
                    && run.progressTotal == previous.progressTotal
                if onlyProgressChanged, Date.now.timeIntervalSince(previous.updatedAt) < 0.2,
                   run.progressCompleted != run.progressTotal { return false }
                run.updatedAt = .now
                if run.state.isTerminal { run.finishedAt = run.updatedAt }
                try run.update(dbc)
                if run.stage != previous.stage || run.state != previous.state {
                    try ActivityRunStep(runID: id, timestamp: run.updatedAt,
                        stage: run.stage ?? run.title, state: run.state).insert(dbc)
                }
                return true
            }
        }
    }

    public func finish(id: UUID, state: ActivityRunState, outcome: String? = nil) {
        perform {
            guard state.isTerminal else { throw ActivityMonitoringError.nonterminalFinish }
            return try stores.db.queue.write { dbc in
                guard var run = try ActivityRun.fetchOne(dbc, key: id) else {
                    throw ActivityMonitoringError.runNotFound
                }
                guard !run.state.isTerminal else { return false }
                run.state = state
                run.outcome = outcome
                run.updatedAt = .now
                run.finishedAt = run.updatedAt
                try run.update(dbc)
                try ActivityRunStep(runID: id, timestamp: run.updatedAt,
                    stage: outcome ?? run.stage ?? run.title, state: state).insert(dbc)
                return true
            }
        }
    }

    /// Configuration upserts retain check aggregates and attempt timestamps
    /// unless explicitly supplied, including when a caller uses fresh defaults.
    public func service(_ status: ServiceStatus) {
        perform {
            try stores.db.queue.write { dbc in
                var status = status
                if let previous = try ServiceStatus.fetchOne(dbc, key: status.id) {
                    status.lastAttempt = status.lastAttempt ?? previous.lastAttempt
                    status.lastSuccess = status.lastSuccess ?? previous.lastSuccess
                    status.counterDay = previous.counterDay
                    status.dailyChecks = previous.dailyChecks
                    status.dailySuccesses = previous.dailySuccesses
                    guard status != previous else { return false }
                }
                try status.save(dbc)
                return true
            }
        }
    }

    /// UTC day keys are stable across timezone changes. No run or audit row is
    /// emitted for a check with no useful work; only this summary is updated.
    public func serviceCheck(id: String, succeeded: Bool, at: Date = .now) {
        perform {
            try stores.db.queue.write { dbc in
                guard var status = try ServiceStatus.fetchOne(dbc, key: id) else { return false }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let parts = calendar.dateComponents([.year, .month, .day], from: at)
                let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                if status.counterDay != day {
                    status.counterDay = day
                    status.dailyChecks = 0
                    status.dailySuccesses = 0
                }
                status.dailyChecks += 1
                status.dailySuccesses += succeeded ? 1 : 0
                status.lastAttempt = at
                if succeeded { status.lastSuccess = at }
                let summaryID = "\(day):\(id)"
                var summary = try ServiceCheckSummary.fetchOne(dbc, key: summaryID)
                    ?? ServiceCheckSummary(id: summaryID, serviceID: id, name: status.name, day: day,
                                           checks: 0, successes: 0, lastAttempt: at)
                summary.name = status.name
                summary.checks += 1
                summary.successes += succeeded ? 1 : 0
                summary.lastAttempt = max(summary.lastAttempt, at)
                if succeeded { summary.lastSuccess = max(summary.lastSuccess ?? at, at) }
                try summary.save(dbc)
                try status.update(dbc)
                return true
            }
        }
    }

    /// Call once at startup before beginning new runs. This records the
    /// interruption, never replays work, and never claims external delivery
    /// failed when the previous process may have already performed it.
    public func recoverInterruptedRuns() {
        perform {
            try stores.db.queue.write { dbc in
                let terminal = ActivityRunState.allCases.filter(\.isTerminal).map(\.rawValue)
                let runs = try ActivityRun.filter(!terminal.contains(Column("state"))).fetchAll(dbc)
                for var run in runs {
                    let possiblyExternal = [.delivery, .cloud, .automation, .connection].contains(run.category)
                        && [.running, .cancellationRequested].contains(run.state)
                    run.state = possiblyExternal ? .outcomeUnknown : .interrupted
                    run.outcome = possiblyExternal
                        ? "The previous session ended before its result was recorded. The external outcome is unknown; nothing was replayed."
                        : "The previous session ended before this work completed. Nothing was replayed."
                    run.updatedAt = .now
                    run.finishedAt = run.updatedAt
                    try run.update(dbc)
                    try ActivityRunStep(runID: run.id, timestamp: run.updatedAt,
                        stage: run.outcome!, state: run.state).insert(dbc)
                }
                return !runs.isEmpty
            }
        }
    }
}
