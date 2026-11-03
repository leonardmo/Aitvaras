import Foundation
import AitvarasCore
import AitvarasStore

/// Runs already-compiled workflows without involving an inference engine.
/// Phrase matching and schedule evaluation are deterministic and local.
public actor CommandRoutineExecutor {
    public struct Result: Sendable, Equatable {
        public var routineID: UUID
        public var title: String
        public var stepNames: [String]
        public var success: Bool
        public var spokenText: String
        public var wasScheduled: Bool
    }

    private let hub: ConnectorHub
    private let stores: Stores
    private let reporter: ActivityReporter?

    public init(hub: ConnectorHub, stores: Stores, reporter: ActivityReporter? = nil) {
        self.hub = hub
        self.stores = stores
        self.reporter = reporter
    }

    /// Nil means no exact active phrase matched and the normal agent may run.
    /// A matched failure is returned as a failure—never fall through and risk
    /// executing the same side effect a second time through the model.
    public func executeShortcut(
        matching phrase: String,
        channel: CommandObservation.Channel,
        at date: Date = .now,
        calendar: Calendar = .current
    ) async -> Result? {
        do {
            guard let routine = try stores.matchingPhraseRoutine(phrase) else { return nil }
            let result = await execute(routine, scheduled: false, at: date)
            if result.success {
                try stores.markCommandRoutineRun(routine.id, at: date)
                _ = try stores.observeCommand(
                    phrase: phrase, channel: channel, executionMode: .shortcut,
                    steps: routine.steps, at: date, calendar: calendar)
            }
            return result
        } catch {
            return Result(
                routineID: UUID(), title: "Shortcut", stepNames: [], success: false,
                spokenText: "The shortcut could not run: \(error.localizedDescription)",
                wasScheduled: false)
        }
    }

    /// Evaluate approved schedules. Suggested and paused routines are ignored.
    /// The ten-minute window tolerates launch/wake jitter without turning a
    /// stale morning action into a surprise hours later.
    public func runDueSchedules(
        at date: Date = .now,
        calendar: Calendar = .current
    ) async -> [Result] {
        guard ActivityExecution.permits(.routines, stores: stores, reporter: reporter, trigger: .automatic),
              !Task.isCancelled else { return [] }
        let routines: [CommandRoutine]
        do { routines = try stores.commandRoutines() }
        catch { return [] }
        let weekday = calendar.component(.weekday, from: date)
        let minute = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        let day = Self.dayKey(date, calendar: calendar)
        var results: [Result] = []

        for routine in routines where routine.triggerKindValue == .schedule
            && routine.statusValue == .active {
            guard !Task.isCancelled,
                  ActivityExecution.permits(.routines, stores: stores, reporter: reporter, trigger: .automatic) else { break }
            guard let scheduledMinute = routine.scheduleMinuteOfDay,
                  let mask = routine.scheduleWeekdayMask,
                  mask & (1 << (weekday - 1)) != 0,
                  minute >= scheduledMinute,
                  minute - scheduledMinute <= 10 else { continue }
            let slot = "\(routine.id.uuidString):\(day)"
            guard (try? stores.claimCommandRoutineRun(
                routine.id, slot: slot, at: date)) == true else { continue }
            let result = await ActivityTaskContext.$trigger.withValue(.automatic) {
                await ActivityTaskContext.$automaticFeature.withValue(.routines) {
                    await execute(routine, scheduled: true, at: date)
                }
            }
            results.append(result)
        }
        return results
    }

    private func execute(
        _ routine: CommandRoutine, scheduled: Bool, at date: Date
    ) async -> Result {
        let runID = reporter?.begin(ActivityRun(category: .automation,
            title: scheduled ? "Scheduled routine" : "Command shortcut",
            stage: "Running fixed steps", progressCompleted: 0, progressTotal: routine.steps.count,
            executionLocation: "Local", dataAccess: "Approved routine tools", dataDestination: "Configured connectors"))
        return await ActivityTaskContext.$runID.withValue(runID ?? ActivityTaskContext.runID) {
            let result = await executeSteps(routine, scheduled: scheduled, at: date, runID: runID)
            if let runID { reporter?.finish(id: runID,
                state: Task.isCancelled ? .cancelled : (result.success ? .succeeded : .failed),
                outcome: result.success ? "All steps completed" : "Stopped; completed steps are not repeated") }
            return result
        }
    }

    private func executeSteps(
        _ routine: CommandRoutine, scheduled: Bool, at date: Date, runID: UUID?
    ) async -> Result {
        let event = ActivityEvent(
            kind: scheduled ? .automationRun : .shortcutTaken,
            timestamp: date,
            connectorID: "routines",
            summary: scheduled
                ? "Scheduled routine started: \(routine.title)"
                : "Shortcut taken—no AI model: \(routine.title)",
            detailJSON: Self.auditJSON(routine))
        do {
            try Task.checkCancellation()
            try stores.record(event)
            for (index, step) in routine.steps.enumerated() {
                try Task.checkCancellation()
                if scheduled, !ActivityExecution.permits(.routines, stores: stores, reporter: reporter, trigger: .automatic) {
                    throw CancellationError()
                }
                if let runID { reporter?.update(id: runID, stage: "Running step \(index + 1)", progressCompleted: index) }
                _ = try await hub.executeCommandRoutineStep(step, causedBy: event.id)
            }
            try Task.checkCancellation()
            if let runID { reporter?.update(id: runID, progressCompleted: routine.steps.count) }
            return Result(
                routineID: routine.id,
                title: routine.title,
                stepNames: routine.steps.map(\.label),
                success: true,
                spokenText: scheduled
                    ? "Scheduled routine completed: \(routine.title)."
                    : "Shortcut used: \(routine.title).",
                wasScheduled: scheduled)
        } catch {
            if error is CancellationError || Task.isCancelled, let runID {
                reporter?.finish(id: runID, state: .cancelled,
                    outcome: "Routine cancelled; completed steps are not repeated")
            }
            _ = try? stores.record(ActivityEvent(
                kind: scheduled ? .automationRun : .shortcutTaken,
                timestamp: date,
                connectorID: "routines",
                summary: "\(scheduled ? "Scheduled routine" : "Shortcut") failed: \(routine.title)",
                detailJSON: Self.errorJSON(error.localizedDescription),
                causedBy: event.id))
            return Result(
                routineID: routine.id,
                title: routine.title,
                stepNames: routine.steps.map(\.label),
                success: false,
                spokenText: "The \(scheduled ? "scheduled routine" : "shortcut") failed: \(error.localizedDescription)",
                wasScheduled: scheduled)
        }
    }

    private static func auditJSON(_ routine: CommandRoutine) -> String? {
        let object: [String: Any] = [
            "routineID": routine.id.uuidString,
            "steps": routine.steps.map(\.namespacedToolName),
            "modelUsed": false
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0,
                      parts.month ?? 0, parts.day ?? 0)
    }

    private static func errorJSON(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["error": String(text.prefix(1_000))],
            options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
