import Foundation
import GRDB
import AitvarasCore

/// One fixed connector call in a learned workflow. Arguments are canonical
/// JSON so repeated model calls compare byte-for-byte across turns.
public struct CommandRoutineStep: Codable, Sendable, Equatable, Identifiable {
    public var connectorID: String
    public var toolName: String
    public var argumentsJSON: String
    public var risk: ActionRisk
    public var label: String

    public var id: String { "\(connectorID).\(toolName):\(argumentsJSON)" }
    public var namespacedToolName: String { "\(connectorID).\(toolName)" }

    public init(
        connectorID: String,
        toolName: String,
        argumentsJSON: String,
        risk: ActionRisk,
        label: String? = nil
    ) {
        self.connectorID = connectorID
        self.toolName = toolName
        self.argumentsJSON = Self.canonicalJSON(argumentsJSON) ?? argumentsJSON
        self.risk = risk
        self.label = label ?? toolName.replacingOccurrences(of: "_", with: " ")
    }

    public static func canonicalJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any],
              JSONSerialization.isValidJSONObject(object),
              let canonical = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
              canonical.count <= CommandRoutinePolicy.maximumArgumentsBytes
        else { return nil }
        return String(decoding: canonical, as: UTF8.self)
    }

    public var prettyArguments: String {
        guard argumentsJSON != "{}",
              let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return "No parameters" }
        return String(decoding: pretty, as: UTF8.self)
    }
}

public struct CommandObservation: Codable, Sendable, Equatable,
                                  Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commandObservation"

    public enum Channel: String, Codable, Sendable { case voice, typed }
    public enum ExecutionMode: String, Codable, Sendable { case agent, shortcut }

    public var id: UUID
    public var occurredAt: Date
    public var phrase: String
    public var normalizedPhrase: String
    public var channel: String
    public var executionMode: String
    public var stepsJSON: String
    public var workflowSignature: String

    public init(
        id: UUID = UUID(),
        occurredAt: Date = .now,
        phrase: String,
        channel: Channel,
        executionMode: ExecutionMode,
        steps: [CommandRoutineStep]
    ) throws {
        let normalized = CommandRoutinePolicy.normalize(phrase)
        guard CommandRoutinePolicy.isUsablePhrase(normalized),
              let stepsJSON = CommandRoutinePolicy.encodeSteps(steps)
        else { throw CommandRoutineError.invalidWorkflow }
        self.id = id
        self.occurredAt = occurredAt
        self.phrase = String(phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(CommandRoutinePolicy.maximumPhraseCharacters))
        self.normalizedPhrase = normalized
        self.channel = channel.rawValue
        self.executionMode = executionMode.rawValue
        self.stepsJSON = stepsJSON
        self.workflowSignature = CommandRoutinePolicy.workflowSignature(stepsJSON: stepsJSON)
    }

    public var channelValue: Channel { Channel(rawValue: channel) ?? .typed }
    public var executionModeValue: ExecutionMode {
        ExecutionMode(rawValue: executionMode) ?? .agent
    }
    public var steps: [CommandRoutineStep] {
        CommandRoutinePolicy.decodeSteps(stepsJSON) ?? []
    }
}

public struct CommandRoutine: Codable, Sendable, Equatable,
                             Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "commandRoutine"

    public enum TriggerKind: String, Codable, Sendable { case phrase, schedule }
    public enum Status: String, Codable, Sendable {
        case suggested, active, paused, dismissed
    }

    public var id: UUID
    public var title: String
    public var triggerKind: String
    /// JSON array. Phrase shortcuts match any alias exactly after normalization.
    public var phrasesJSON: String
    public var scheduleMinuteOfDay: Int?
    /// Calendar weekday bits: Sunday is bit 0, Saturday bit 6.
    public var scheduleWeekdayMask: Int?
    public var stepsJSON: String
    public var status: String
    public var evidenceCount: Int
    public var explanation: String
    public var dedupeKey: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastRunAt: Date?
    public var lastRunSlot: String?
    public var runCount: Int
    public var reviewProvider: String?
    public var reviewedAt: Date?
    public var reviewSummary: String?

    public init(
        id: UUID = UUID(),
        title: String,
        triggerKind: TriggerKind,
        phrases: [String] = [],
        scheduleMinuteOfDay: Int? = nil,
        scheduleWeekdayMask: Int? = nil,
        steps: [CommandRoutineStep],
        status: Status,
        evidenceCount: Int,
        explanation: String,
        dedupeKey: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastRunAt: Date? = nil,
        lastRunSlot: String? = nil,
        runCount: Int = 0,
        reviewProvider: String? = nil,
        reviewedAt: Date? = nil,
        reviewSummary: String? = nil
    ) throws {
        guard let stepsJSON = CommandRoutinePolicy.encodeSteps(steps),
              let phrasesJSON = CommandRoutinePolicy.encodePhrases(phrases),
              CommandRoutinePolicy.validTrigger(
                kind: triggerKind,
                phrases: CommandRoutinePolicy.decodePhrases(phrasesJSON),
                minute: scheduleMinuteOfDay,
                weekdayMask: scheduleWeekdayMask)
        else { throw CommandRoutineError.invalidWorkflow }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              cleanTitle.count <= CommandRoutinePolicy.maximumTitleCharacters,
              !dedupeKey.isEmpty else { throw CommandRoutineError.invalidWorkflow }
        self.id = id
        self.title = cleanTitle
        self.triggerKind = triggerKind.rawValue
        self.phrasesJSON = phrasesJSON
        self.scheduleMinuteOfDay = scheduleMinuteOfDay
        self.scheduleWeekdayMask = scheduleWeekdayMask
        self.stepsJSON = stepsJSON
        self.status = status.rawValue
        self.evidenceCount = max(0, evidenceCount)
        self.explanation = String(explanation.prefix(1_000))
        self.dedupeKey = dedupeKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastRunSlot = lastRunSlot
        self.runCount = max(0, runCount)
        self.reviewProvider = reviewProvider.map { String($0.prefix(40)) }
        self.reviewedAt = reviewedAt
        self.reviewSummary = reviewSummary.map { String($0.prefix(1_000)) }
    }

    public var triggerKindValue: TriggerKind {
        TriggerKind(rawValue: triggerKind) ?? .phrase
    }
    public var statusValue: Status { Status(rawValue: status) ?? .paused }
    public var phrases: [String] { CommandRoutinePolicy.decodePhrases(phrasesJSON) }
    public var steps: [CommandRoutineStep] {
        CommandRoutinePolicy.decodeSteps(stepsJSON) ?? []
    }
    public var isEditable: Bool { statusValue != .dismissed }
}

public enum CommandRoutineError: Error, LocalizedError, Sendable {
    case invalidWorkflow
    case routineNotFound
    case unsafeStep(String)
    case staleWorkflow(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkflow:
            "The routine is incomplete or contains invalid JSON."
        case .routineNotFound:
            "This routine no longer exists."
        case .unsafeStep(let name):
            "\(name) is not eligible for a no-model routine. Confirmable actions must still ask every time."
        case .staleWorkflow(let name):
            "\(name) changed or is no longer available. The routine was not run."
        }
    }
}

public enum CommandRoutinePolicy {
    public static let minimumShortcutEvidence = 3
    public static let maximumPhraseCharacters = 240
    public static let maximumTitleCharacters = 160
    public static let maximumSteps = 6
    public static let maximumArgumentsBytes = 16 * 1_024
    public static let observationRetention: TimeInterval = 90 * 24 * 3600
    public static let learningWindow: TimeInterval = 42 * 24 * 3600

    public static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : " "
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func isUsablePhrase(_ normalized: String) -> Bool {
        !normalized.isEmpty
            && normalized.count <= maximumPhraseCharacters
            && normalized.split(separator: " ").count <= 32
    }

    /// Learned paths are intentionally narrower than the normal autonomy
    /// policy: they must contain a reversible action and may never contain a
    /// confirmable action. Read-only questions still benefit from model prose
    /// and therefore are not turned into opaque shortcuts.
    public static func isEligibleWorkflow(_ steps: [CommandRoutineStep]) -> Bool {
        !steps.isEmpty && steps.count <= maximumSteps
            && steps.contains(where: { $0.risk == .reversibleWrite })
            && steps.allSatisfy { $0.risk == .read || $0.risk == .reversibleWrite }
            && encodeSteps(steps) != nil
    }

    public static func encodeSteps(_ steps: [CommandRoutineStep]) -> String? {
        guard !steps.isEmpty, steps.count <= maximumSteps,
              steps.allSatisfy({
                  !$0.connectorID.isEmpty && !$0.toolName.isEmpty
                      && canonicalJSONMatches($0.argumentsJSON)
              }),
              let encoded = try? JSONEncoder().encode(steps),
              let object = try? JSONSerialization.jsonObject(with: encoded),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
              data.count <= maximumSteps * maximumArgumentsBytes
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeSteps(_ raw: String) -> [CommandRoutineStep]? {
        guard let data = raw.data(using: .utf8),
              data.count <= maximumSteps * maximumArgumentsBytes,
              let steps = try? JSONDecoder().decode([CommandRoutineStep].self, from: data),
              !steps.isEmpty, steps.count <= maximumSteps else { return nil }
        return steps
    }

    public static func encodePhrases(_ phrases: [String]) -> String? {
        let cleaned = phrases.map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumPhraseCharacters))
        }.filter { isUsablePhrase(normalize($0)) }
        guard cleaned.count <= 12,
              let data = try? JSONEncoder().encode(Array(Set(cleaned)).sorted())
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodePhrases(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Array(values.prefix(12))
    }

    public static func workflowSignature(stepsJSON: String) -> String {
        StableIdentifier.digest([stepsJSON])
    }

    public static func validTrigger(
        kind: CommandRoutine.TriggerKind,
        phrases: [String],
        minute: Int?,
        weekdayMask: Int?
    ) -> Bool {
        switch kind {
        case .phrase:
            return !phrases.isEmpty && phrases.allSatisfy { isUsablePhrase(normalize($0)) }
                && minute == nil && weekdayMask == nil
        case .schedule:
            return phrases.isEmpty && (0..<1_440).contains(minute ?? -1)
                && (1...127).contains(weekdayMask ?? 0)
        }
    }

    private static func canonicalJSONMatches(_ raw: String) -> Bool {
        CommandRoutineStep.canonicalJSON(raw) == raw
    }
}

public struct CommandRoutineDiscovery: Sendable, Equatable {
    public var learnedShortcuts: [CommandRoutine]
    public var suggestedAutomations: [CommandRoutine]

    public static let none = CommandRoutineDiscovery(
        learnedShortcuts: [], suggestedAutomations: [])
}

/// Deterministic pattern finder. No transcript is sent to an inference model.
public enum CommandRoutineLearner {
    public static func discover(
        observations: [CommandObservation],
        excludingDedupeKeys: Set<String> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CommandRoutineDiscovery {
        let recent = observations.filter {
            // SQLite date round-tripping can move a just-written timestamp by
            // a fraction of a millisecond. A one-second tolerance prevents the
            // newest sample from intermittently disappearing without admitting
            // genuinely future observations.
            now.timeIntervalSince($0.occurredAt) >= -1
                && now.timeIntervalSince($0.occurredAt) <= CommandRoutinePolicy.learningWindow
                && CommandRoutinePolicy.isEligibleWorkflow($0.steps)
        }
        var seen = excludingDedupeKeys
        var shortcuts: [CommandRoutine] = []
        var schedules: [CommandRoutine] = []

        for (phrase, group) in Dictionary(grouping: recent, by: \.normalizedPhrase) {
            let workflows = Dictionary(grouping: group, by: \.workflowSignature)
            guard workflows.count == 1,
                  let matching = workflows.values.first,
                  matching.count >= CommandRoutinePolicy.minimumShortcutEvidence,
                  let sample = matching.first else { continue }
            let key = "phrase:" + StableIdentifier.digest([phrase, sample.workflowSignature])
            guard seen.insert(key).inserted else { continue }
            let displayPhrase = matching
                .sorted { $0.occurredAt > $1.occurredAt }.first?.phrase ?? phrase
            if let routine = try? CommandRoutine(
                title: displayPhrase,
                triggerKind: .phrase,
                phrases: [displayPhrase],
                steps: sample.steps,
                status: .active,
                evidenceCount: matching.count,
                explanation: "Learned after \(matching.count) identical successful runs. Exact phrase only; no AI model is used.",
                dedupeKey: key,
                createdAt: now,
                updatedAt: now) {
                shortcuts.append(routine)
            }
        }

        for (signature, group) in Dictionary(grouping: recent, by: \.workflowSignature) {
            guard let sample = group.first,
                  let pattern = schedulePattern(for: group, calendar: calendar) else { continue }
            let key = "schedule:" + StableIdentifier.digest([
                signature, pattern.kindKey, String(pattern.weekdayMask)
            ])
            guard seen.insert(key).inserted else { continue }
            let title = sample.steps.last?.label.capitalized ?? "Repeated command"
            if let routine = try? CommandRoutine(
                title: title,
                triggerKind: .schedule,
                scheduleMinuteOfDay: pattern.minuteOfDay,
                scheduleWeekdayMask: pattern.weekdayMask,
                steps: sample.steps,
                status: .suggested,
                evidenceCount: pattern.evidenceCount,
                explanation: pattern.explanation,
                dedupeKey: key,
                createdAt: now,
                updatedAt: now) {
                schedules.append(routine)
            }
        }
        return CommandRoutineDiscovery(
            learnedShortcuts: shortcuts.sorted { $0.title < $1.title },
            suggestedAutomations: schedules.sorted { $0.title < $1.title })
    }

    private struct SchedulePattern {
        var minuteOfDay: Int
        var weekdayMask: Int
        var evidenceCount: Int
        var kindKey: String
        var explanation: String
    }

    private static func schedulePattern(
        for observations: [CommandObservation], calendar: Calendar
    ) -> SchedulePattern? {
        let unique = Dictionary(grouping: observations, by: {
            calendar.startOfDay(for: $0.occurredAt)
        }).compactMap { $0.value.max(by: { $0.occurredAt < $1.occurredAt }) }
        guard unique.count >= 3 else { return nil }

        let clustered = bestTimeCluster(unique, calendar: calendar, tolerance: 45)
        guard clustered.count >= 3,
              let first = clustered.map(\.occurredAt).min(),
              let last = clustered.map(\.occurredAt).max() else { return nil }
        let spanDays = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        let weekdays = Set(clustered.map { calendar.component(.weekday, from: $0.occurredAt) })
        let hasWeekend = weekdays.contains(1) || weekdays.contains(7)
        let center = circularCenterMinute(clustered.map {
            calendar.component(.hour, from: $0.occurredAt) * 60
                + calendar.component(.minute, from: $0.occurredAt)
        })

        if clustered.count >= 8, spanDays >= 9, hasWeekend,
           weekdays.contains(where: { (2...6).contains($0) }) {
            return SchedulePattern(
                minuteOfDay: center, weekdayMask: 127,
                evidenceCount: clustered.count, kindKey: "daily",
                explanation: "Suggested—not active—after \(clustered.count) similar runs on both weekdays and weekends around the same time.")
        }

        if clustered.count >= 7, spanDays >= 9, !hasWeekend,
           weekdays.count >= 4 {
            let mask = (2...6).reduce(0) { $0 | (1 << ($1 - 1)) }
            return SchedulePattern(
                minuteOfDay: center, weekdayMask: mask,
                evidenceCount: clustered.count, kindKey: "weekdays",
                explanation: "Suggested—not active—after \(clustered.count) weekday runs around the same time.")
        }

        let byWeekday = Dictionary(grouping: clustered) {
            calendar.component(.weekday, from: $0.occurredAt)
        }
        guard let best = byWeekday
            .filter({ $0.value.count >= 3 })
            .max(by: { $0.value.count < $1.value.count }),
              let weekdayFirst = best.value.map(\.occurredAt).min(),
              let weekdayLast = best.value.map(\.occurredAt).max(),
              (calendar.dateComponents(
                [.day], from: weekdayFirst, to: weekdayLast).day ?? 0) >= 14
        else { return nil }
        return SchedulePattern(
            minuteOfDay: circularCenterMinute(best.value.map {
                calendar.component(.hour, from: $0.occurredAt) * 60
                    + calendar.component(.minute, from: $0.occurredAt)
            }),
            weekdayMask: 1 << (best.key - 1),
            evidenceCount: best.value.count,
            kindKey: "weekly-\(best.key)",
            explanation: "Suggested—not active—after \(best.value.count) runs on the same weekday and at a similar time across at least three weeks.")
    }

    private static func bestTimeCluster(
        _ observations: [CommandObservation], calendar: Calendar, tolerance: Int
    ) -> [CommandObservation] {
        let minutes = observations.map {
            calendar.component(.hour, from: $0.occurredAt) * 60
                + calendar.component(.minute, from: $0.occurredAt)
        }
        var best: [CommandObservation] = []
        for anchor in minutes {
            let candidate = zip(observations, minutes).compactMap { item, minute in
                circularDistance(anchor, minute) <= tolerance ? item : nil
            }
            if candidate.count > best.count { best = candidate }
        }
        return best
    }

    private static func circularCenterMinute(_ minutes: [Int]) -> Int {
        guard !minutes.isEmpty else { return 0 }
        let radians = minutes.map { Double($0) / 1_440 * 2 * Double.pi }
        let x = radians.map(cos).reduce(0, +) / Double(radians.count)
        let y = radians.map(sin).reduce(0, +) / Double(radians.count)
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * Double.pi }
        return Int((angle / (2 * Double.pi) * 1_440).rounded()) % 1_440
    }

    private static func circularDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 1_440 - direct)
    }
}

public extension Stores {
    func commandObservations(since: Date = .distantPast) throws -> [CommandObservation] {
        try db.queue.read {
            try CommandObservation
                .filter(Column("occurredAt") >= since)
                .order(Column("occurredAt"))
                .fetchAll($0)
        }
    }

    @discardableResult
    func observeCommand(
        phrase: String,
        channel: CommandObservation.Channel,
        executionMode: CommandObservation.ExecutionMode,
        steps: [CommandRoutineStep],
        at date: Date = .now,
        calendar: Calendar = .current
    ) throws -> CommandRoutineDiscovery {
        let observation = try CommandObservation(
            occurredAt: date, phrase: phrase, channel: channel,
            executionMode: executionMode, steps: steps)
        return try db.queue.write { dbc in
            try observation.insert(dbc)
            try dbc.execute(
                sql: "DELETE FROM commandObservation WHERE occurredAt < ?",
                arguments: [date.addingTimeInterval(-CommandRoutinePolicy.observationRetention)])
            return try Self.discoverRoutines(in: dbc, now: date, calendar: calendar)
        }
    }

    @discardableResult
    func refreshCommandRoutineSuggestions(
        now: Date = .now, calendar: Calendar = .current
    ) throws -> CommandRoutineDiscovery {
        try db.queue.write { try Self.discoverRoutines(in: $0, now: now, calendar: calendar) }
    }

    func commandRoutines(includeDismissed: Bool = false) throws -> [CommandRoutine] {
        try db.queue.read { dbc in
            var request = CommandRoutine.order(Column("updatedAt").desc)
            if !includeDismissed {
                request = request.filter(Column("status") != CommandRoutine.Status.dismissed.rawValue)
            }
            return try request.fetchAll(dbc)
        }
    }

    func matchingPhraseRoutine(_ phrase: String) throws -> CommandRoutine? {
        let normalized = CommandRoutinePolicy.normalize(phrase)
        guard CommandRoutinePolicy.isUsablePhrase(normalized) else { return nil }
        let matches = try commandRoutines().filter { routine in
            routine.triggerKindValue == .phrase && routine.statusValue == .active
                && routine.phrases.contains {
                    CommandRoutinePolicy.normalize($0) == normalized
                }
        }
        // Human edits may create overlapping aliases. Ambiguity must return to
        // the normal agent rather than choosing an arbitrary side effect.
        return matches.count == 1 ? matches[0] : nil
    }

    @discardableResult
    func saveCommandRoutine(_ routine: CommandRoutine) throws -> CommandRoutine {
        guard CommandRoutinePolicy.isEligibleWorkflow(routine.steps),
              CommandRoutinePolicy.validTrigger(
                kind: routine.triggerKindValue, phrases: routine.phrases,
                minute: routine.scheduleMinuteOfDay,
                weekdayMask: routine.scheduleWeekdayMask)
        else { throw CommandRoutineError.invalidWorkflow }
        var saved = routine
        saved.updatedAt = .now
        try db.queue.write { try saved.save($0) }
        return saved
    }

    func setCommandRoutineStatus(_ id: UUID, to status: CommandRoutine.Status) throws {
        try db.queue.write { dbc in
            guard var routine = try CommandRoutine.fetchOne(dbc, key: id) else {
                throw CommandRoutineError.routineNotFound
            }
            routine.status = status.rawValue
            routine.updatedAt = .now
            try routine.update(dbc)
            let kind: ActivityEvent.Kind = status == .active
                ? .automationApproved : .automationChanged
            try ActivityEvent(
                kind: kind,
                connectorID: "routines",
                summary: "\(status == .active ? "Activated" : status.rawValue.capitalized): \(routine.title)",
                detailJSON: Self.routineAuditJSON(routine)).insert(dbc)
        }
    }

    func deleteCommandRoutine(_ id: UUID) throws {
        try db.queue.write { dbc in
            guard let routine = try CommandRoutine.fetchOne(dbc, key: id) else { return }
            try routine.delete(dbc)
            try ActivityEvent(
                kind: .automationChanged,
                connectorID: "routines",
                summary: "Deleted routine: \(routine.title)").insert(dbc)
        }
    }

    /// Claims a schedule before side effects. A crash may skip one run but can
    /// never duplicate a write after restart, which is the safer trade-off.
    func claimCommandRoutineRun(_ id: UUID, slot: String, at date: Date = .now) throws -> Bool {
        try db.queue.write { dbc in
            guard var routine = try CommandRoutine.fetchOne(dbc, key: id),
                  routine.statusValue == .active,
                  routine.lastRunSlot != slot else { return false }
            routine.lastRunSlot = slot
            routine.lastRunAt = date
            routine.runCount += 1
            routine.updatedAt = date
            try routine.update(dbc)
            return true
        }
    }

    func markCommandRoutineRun(_ id: UUID, at date: Date = .now) throws {
        try db.queue.write { dbc in
            guard var routine = try CommandRoutine.fetchOne(dbc, key: id) else { return }
            routine.lastRunAt = date
            routine.runCount += 1
            routine.updatedAt = date
            try routine.update(dbc)
        }
    }

    /// Cloud review may improve only human-facing metadata. The fixed trigger,
    /// canonical arguments, risk labels, status and execution path remain
    /// deterministic and cannot be rewritten by a model.
    func applyCloudReview(
        to id: UUID,
        provider: String,
        title: String,
        summary: String,
        at date: Date = .now
    ) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedSummary = String(summary
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000))
        guard !cleanTitle.isEmpty,
              cleanTitle.count <= CommandRoutinePolicy.maximumTitleCharacters,
              !boundedSummary.isEmpty else { throw CommandRoutineError.invalidWorkflow }
        try db.queue.write { dbc in
            guard var routine = try CommandRoutine.fetchOne(dbc, key: id) else {
                throw CommandRoutineError.routineNotFound
            }
            routine.title = cleanTitle
            routine.reviewProvider = String(provider.prefix(40))
            routine.reviewedAt = date
            routine.reviewSummary = boundedSummary
            routine.explanation = boundedSummary
            routine.updatedAt = date
            try routine.update(dbc)
        }
    }

    private static func discoverRoutines(
        in dbc: Database, now: Date, calendar: Calendar
    ) throws -> CommandRoutineDiscovery {
        let since = now.addingTimeInterval(-CommandRoutinePolicy.learningWindow)
        let observations = try CommandObservation
            .filter(Column("occurredAt") >= since)
            .order(Column("occurredAt"))
            .fetchAll(dbc)
        let existing = try Set(String.fetchAll(
            dbc, sql: "SELECT dedupeKey FROM commandRoutine"))
        let discovery = CommandRoutineLearner.discover(
            observations: observations, excludingDedupeKeys: existing,
            now: now, calendar: calendar)
        for routine in discovery.learnedShortcuts + discovery.suggestedAutomations {
            try routine.insert(dbc)
            try ActivityEvent(
                kind: routine.statusValue == .active ? .shortcutLearned : .automationSuggested,
                connectorID: "routines",
                summary: routine.statusValue == .active
                    ? "Learned shortcut: \(routine.title)"
                    : "Automation suggestion: \(routine.title)",
                detailJSON: routineAuditJSON(routine)).insert(dbc)
        }
        return discovery
    }

    private static func routineAuditJSON(_ routine: CommandRoutine) -> String? {
        let object: [String: Any] = [
            "routineID": routine.id.uuidString,
            "trigger": routine.triggerKind,
            "steps": routine.steps.map(\.namespacedToolName),
            "evidence": routine.evidenceCount
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
