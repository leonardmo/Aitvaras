import Foundation

public enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    case startup, chat, voice, capture, knowledge, memory, automation, connection, delivery, model, cloud, system
}

public enum ActivityTrigger: String, Codable, Sendable, CaseIterable {
    case manual, automatic, startup, recovery
}

public enum ActivityRunState: String, Codable, Sendable, CaseIterable {
    case queued, running, waiting, awaitingApproval, cancellationRequested
    case succeeded, failed, cancelled, interrupted, outcomeUnknown

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted, .outcomeUnknown: true
        default: false
        }
    }
}

/// Operational metadata only. Never put prompts, responses, tool arguments,
/// credentials, or private connector payloads in these display fields.
public struct ActivityRun: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var parentID: UUID?
    public var referenceID: String?
    public var category: ActivityCategory
    public var trigger: ActivityTrigger
    public var state: ActivityRunState
    public var title: String
    public var stage: String?
    public var progressCompleted: Int?
    public var progressTotal: Int?
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    public var provider: String?
    public var executionLocation: String?
    public var dataAccess: String?
    public var dataDestination: String?
    public var outcome: String?
    /// Reviewing a problem never retries work or rewrites its original outcome.
    public var acknowledgedAt: Date?

    public init(id: UUID = UUID(), parentID: UUID? = ActivityTaskContext.runID,
                referenceID: String? = nil, category: ActivityCategory,
                trigger: ActivityTrigger = ActivityTaskContext.trigger,
                state: ActivityRunState = .running, title: String, stage: String? = nil,
                progressCompleted: Int? = nil, progressTotal: Int? = nil,
                startedAt: Date = .now, updatedAt: Date? = nil, finishedAt: Date? = nil,
                provider: String? = nil, executionLocation: String? = nil,
                dataAccess: String? = nil, dataDestination: String? = nil, outcome: String? = nil,
                acknowledgedAt: Date? = nil) {
        self.id = id
        self.parentID = parentID
        self.referenceID = referenceID
        self.category = category
        self.trigger = trigger
        self.state = state
        self.title = title
        self.stage = stage
        self.progressCompleted = progressCompleted
        self.progressTotal = progressTotal
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.finishedAt = finishedAt ?? (state.isTerminal ? (updatedAt ?? startedAt) : nil)
        self.provider = provider
        self.executionLocation = executionLocation
        self.dataAccess = dataAccess
        self.dataDestination = dataDestination
        self.outcome = outcome
        self.acknowledgedAt = acknowledgedAt
    }
}

/// A stage transition, not a progress tick. Keeps the operation's explanation
/// readable after completion without copying any task content into telemetry.
public struct ActivityRunStep: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var runID: UUID
    public var timestamp: Date
    public var stage: String
    public var state: ActivityRunState

    public init(id: UUID = UUID(), runID: UUID, timestamp: Date = .now,
                stage: String, state: ActivityRunState) {
        self.id = id
        self.runID = runID
        self.timestamp = timestamp
        self.stage = stage
        self.state = state
    }
}

/// One durable row per service; idle checks update daily counters, not history.
public struct ServiceStatus: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var configured: Bool
    public var enabled: Bool
    public var paused: Bool
    public var stage: String?
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var nextOpportunity: Date?
    public var problem: String?
    public var counterDay: String?
    public var dailyChecks: Int
    public var dailySuccesses: Int

    public init(id: String, name: String, configured: Bool = false, enabled: Bool = false,
                paused: Bool = false, stage: String? = nil, lastAttempt: Date? = nil,
                lastSuccess: Date? = nil, nextOpportunity: Date? = nil, problem: String? = nil,
                counterDay: String? = nil, dailyChecks: Int = 0, dailySuccesses: Int = 0) {
        self.id = id
        self.name = name
        self.configured = configured
        self.enabled = enabled
        self.paused = paused
        self.stage = stage
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.nextOpportunity = nextOpportunity
        self.problem = problem
        self.counterDay = counterDay
        self.dailyChecks = dailyChecks
        self.dailySuccesses = dailySuccesses
    }
}

public enum BackgroundFeature: String, Codable, Sendable, CaseIterable {
    case mail, notifications, connectors, indexing, archiving, memory
    case routineReview, routines, delivery, focus
}

/// At most one metadata-only check summary per service and UTC day.
public struct ServiceCheckSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var serviceID: String
    public var name: String
    public var day: String
    public var checks: Int
    public var successes: Int
    public var lastAttempt: Date
    public var lastSuccess: Date?

    public init(id: String, serviceID: String, name: String, day: String,
                checks: Int, successes: Int, lastAttempt: Date, lastSuccess: Date? = nil) {
        self.id = id
        self.serviceID = serviceID
        self.name = name
        self.day = day
        self.checks = checks
        self.successes = successes
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
    }
}

/// New profiles and older installations both start closed until reviewed.
public struct BackgroundWorkPolicy: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var reviewed: Bool
    public var paused: Bool
    public var allowed: Set<BackgroundFeature>

    public init(version: Int = Self.currentVersion, reviewed: Bool = false,
                paused: Bool = false, allowed: Set<BackgroundFeature> = []) {
        self.version = version
        self.reviewed = reviewed
        self.paused = paused
        self.allowed = allowed
    }

    public func permits(_ feature: BackgroundFeature, trigger: ActivityTrigger = .automatic) -> Bool {
        trigger == .manual || (version == Self.currentVersion && reviewed && !paused && allowed.contains(feature))
    }
}

public enum ActivityTaskContext {
    @TaskLocal public static var runID: UUID?
    @TaskLocal public static var trigger: ActivityTrigger = .manual
    @TaskLocal public static var automaticFeature: BackgroundFeature?
}

public struct ActivityRunFilter: Sendable, Equatable {
    public var category: ActivityCategory?
    public var state: ActivityRunState?
    public var search: String
    public var since: Date?
    public var until: Date?

    public init(category: ActivityCategory? = nil, state: ActivityRunState? = nil,
                search: String = "", since: Date? = nil, until: Date? = nil) {
        self.category = category
        self.state = state
        self.search = search
        self.since = since
        self.until = until
    }
}
