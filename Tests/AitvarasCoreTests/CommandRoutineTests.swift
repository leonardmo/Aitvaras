import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

private actor RoutineSwitchConnector: Connector {
    nonisolated let id = "switches"
    nonisolated let displayName = "Test switches"
    nonisolated let tools: [ToolDefinition]
    private var executions = 0

    init(risk: ActionRisk = .reversibleWrite) {
        tools = [ToolDefinition(
            name: "set_off", description: "Turn one test switch off",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}"#,
            risk: risk)]
    }

    func health() async -> ConnectorHealth { .ready }
    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        executions += 1
        return "off"
    }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
    func count() -> Int { executions }
}

private actor FixedRoutineEngine: InferenceEngine {
    nonisolated let identifier = "fixed-routine"

    func isAvailable(for tier: ModelTier) async -> Bool { true }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        let afterTool = messages.last?.role == .tool
        return AsyncThrowingStream { continuation in
            if afterTool {
                continuation.yield(.text("Done."))
                continuation.yield(.done(stopReason: .endOfTurn))
            } else {
                continuation.yield(.toolCall(ToolCall(
                    id: UUID().uuidString,
                    toolName: "switches.set_off",
                    argumentsJSON: #"{"id":"desk"}"#)))
                continuation.yield(.done(stopReason: .toolUse))
            }
            continuation.finish()
        }
    }
}

@Suite struct CommandRoutineTests {
    private let step = CommandRoutineStep(
        connectorID: "switches", toolName: "set_off",
        argumentsJSON: #"{"id":"desk"}"#,
        risk: .reversibleWrite,
        label: "Desk light off")

    @Test func phraseNormalizationIsConservativeAndExact() {
        #expect(CommandRoutinePolicy.normalize("  STÓP, Licht aus! ") == "stop licht aus")
        #expect(CommandRoutinePolicy.normalize("Licht bitte aus") !=
                CommandRoutinePolicy.normalize("Licht aus"))
        #expect(CommandRoutineStep.canonicalJSON(#"["not", "an", "object"]"#) == nil)
    }

    @Test func thirdIdenticalSuccessfulPathCreatesAnActiveShortcut() throws {
        let stores = try inMemoryStores()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CommandRoutinePolicy.isEligibleWorkflow([step]))
        let direct = try (0..<3).map { index in
            try CommandObservation(
                occurredAt: start.addingTimeInterval(Double(index) * 60),
                phrase: "stop licht aus", channel: .voice,
                executionMode: .agent, steps: [step])
        }
        #expect(CommandRoutineLearner.discover(
            observations: direct, now: start.addingTimeInterval(120))
            .learnedShortcuts.count == 1)
        for index in 0..<2 {
            let discovery = try stores.observeCommand(
                phrase: index == 0 ? "Stop, Licht aus" : "STOP LICHT AUS!",
                channel: .voice, executionMode: .agent, steps: [step],
                at: start.addingTimeInterval(Double(index) * 60))
            #expect(discovery.learnedShortcuts.isEmpty)
        }
        let third = try stores.observeCommand(
            phrase: "stop licht aus", channel: .voice, executionMode: .agent,
            steps: [step], at: start.addingTimeInterval(120))

        let fetched = try stores.commandObservations()
        #expect(fetched.count == 3)
        #expect(fetched.allSatisfy {
            CommandRoutinePolicy.isEligibleWorkflow($0.steps)
        })
        #expect(Set(fetched.map(\.normalizedPhrase)).count == 1)
        #expect(Set(fetched.map(\.workflowSignature)).count == 1)
        #expect(fetched.allSatisfy {
            start.addingTimeInterval(120).timeIntervalSince($0.occurredAt)
                <= CommandRoutinePolicy.learningWindow
        })
        #expect(CommandRoutineLearner.discover(
            observations: fetched, now: start.addingTimeInterval(120))
            .learnedShortcuts.count == 1)
        #expect(third.learnedShortcuts.count == 1)
        let shortcut = try #require(try stores.matchingPhraseRoutine("Stóp—Licht aus."))
        #expect(shortcut.statusValue == .active)
        #expect(shortcut.steps == [step])
        #expect(shortcut.evidenceCount == 3)
        #expect(try stores.recentActivity().contains { $0.kind == .shortcutLearned })
    }

    @Test func ambiguousPhraseAndUnsafePathsNeverCompile() throws {
        let stores = try inMemoryStores()
        let alternate = CommandRoutineStep(
            connectorID: "switches", toolName: "set_off",
            argumentsJSON: #"{"id":"hall"}"#, risk: .reversibleWrite)
        let base = Date(timeIntervalSince1970: 1_800_100_000)
        for index in 0..<3 {
            _ = try stores.observeCommand(
                phrase: "lights out", channel: .typed, executionMode: .agent,
                steps: [index == 1 ? alternate : step],
                at: base.addingTimeInterval(Double(index)))
        }
        #expect(try stores.matchingPhraseRoutine("lights out") == nil)

        let confirmable = CommandRoutineStep(
            connectorID: "danger", toolName: "delete",
            argumentsJSON: "{}", risk: .confirmable)
        for index in 0..<4 {
            _ = try stores.observeCommand(
                phrase: "delete everything", channel: .voice,
                executionMode: .agent, steps: [confirmable],
                at: base.addingTimeInterval(Double(100 + index)))
        }
        #expect(try stores.matchingPhraseRoutine("delete everything") == nil)

        let read = CommandRoutineStep(
            connectorID: "weather", toolName: "read",
            argumentsJSON: "{}", risk: .read)
        for index in 0..<4 {
            _ = try stores.observeCommand(
                phrase: "weather", channel: .voice,
                executionMode: .agent, steps: [read],
                at: base.addingTimeInterval(Double(200 + index)))
        }
        #expect(try stores.matchingPhraseRoutine("weather") == nil)

        let first = try CommandRoutine(
            title: "First", triggerKind: .phrase, phrases: ["same phrase"],
            steps: [step], status: .active, evidenceCount: 3,
            explanation: "test", dedupeKey: "manual:first")
        let second = try CommandRoutine(
            title: "Second", triggerKind: .phrase, phrases: ["same phrase"],
            steps: [alternate], status: .active, evidenceCount: 3,
            explanation: "test", dedupeKey: "manual:second")
        try stores.saveCommandRoutine(first)
        try stores.saveCommandRoutine(second)
        #expect(try stores.matchingPhraseRoutine("Same phrase!") == nil)
    }

    @Test func recurringWeeklyTimeCreatesOnlyAnInertSuggestion() throws {
        let stores = try inMemoryStores()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = [6, 13, 20].map { day in
            calendar.date(from: DateComponents(
                year: 2027, month: 1, day: day, hour: 22, minute: 15))!
        }
        for (index, date) in dates.enumerated() {
            _ = try stores.observeCommand(
                phrase: "variant \(index)", channel: .voice,
                executionMode: .agent, steps: [step], at: date,
                calendar: calendar)
        }

        let routines = try stores.commandRoutines()
        let schedule = try #require(routines.first { $0.triggerKindValue == .schedule })
        #expect(schedule.statusValue == .suggested)
        #expect(schedule.evidenceCount == 3)
        #expect(schedule.scheduleMinuteOfDay == 22 * 60 + 15)
        #expect(try stores.recentActivity().contains { $0.kind == .automationSuggested })

        try stores.setCommandRoutineStatus(schedule.id, to: .dismissed)
        let later = dates.last!.addingTimeInterval(7 * 24 * 3600)
        _ = try stores.observeCommand(
            phrase: "another variant", channel: .voice,
            executionMode: .agent, steps: [step], at: later,
            calendar: calendar)
        #expect(try stores.commandRoutines(includeDismissed: true)
            .filter { $0.triggerKindValue == .schedule }.count == 1)
    }

    @Test func dailyAndWeekdayPatternsRequireBroadRepeatedEvidence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(
            year: 2027, month: 3, day: 1, hour: 8, minute: 0))!

        let daily = try (0..<10).map { offset in
            try CommandObservation(
                occurredAt: calendar.date(byAdding: .day, value: offset, to: start)!,
                phrase: "daily variant \(offset)", channel: .voice,
                executionMode: .agent, steps: [step])
        }
        let dailyRoutine = try #require(CommandRoutineLearner.discover(
            observations: daily,
            now: calendar.date(byAdding: .day, value: 10, to: start)!,
            calendar: calendar).suggestedAutomations.first)
        #expect(dailyRoutine.scheduleWeekdayMask == 127)
        #expect(dailyRoutine.statusValue == .suggested)

        var weekdayDates: [Date] = []
        for offset in 0..<14 {
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            if (2...6).contains(calendar.component(.weekday, from: date)) {
                weekdayDates.append(date)
            }
            if weekdayDates.count == 8 { break }
        }
        let weekdays = try weekdayDates.enumerated().map { index, date in
            try CommandObservation(
                occurredAt: date.addingTimeInterval(Double(index % 3) * 60),
                phrase: "weekday variant \(index)", channel: .typed,
                executionMode: .agent, steps: [step])
        }
        let weekdayRoutine = try #require(CommandRoutineLearner.discover(
            observations: weekdays,
            now: weekdayDates.last!.addingTimeInterval(5 * 60),
            calendar: calendar).suggestedAutomations.first)
        let mondayToFriday = (2...6).reduce(0) { $0 | (1 << ($1 - 1)) }
        #expect(weekdayRoutine.scheduleWeekdayMask == mondayToFriday)
        #expect(weekdayRoutine.statusValue == .suggested)
    }

    @Test(arguments: [CommandObservation.Channel.typed, .voice])
    func executorUsesExactShortcutWithoutAnEngineAndKeepsProvenance(channel: CommandObservation.Channel) async throws {
        let stores = try inMemoryStores()
        let connector = RoutineSwitchConnector()
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        let routine = try CommandRoutine(
            title: "Desk off", triggerKind: .phrase,
            phrases: ["Stop, Licht aus"], steps: [step], status: .active,
            evidenceCount: 3, explanation: "test", dedupeKey: "manual:test")
        try stores.saveCommandRoutine(routine)
        let executor = CommandRoutineExecutor(hub: hub, stores: stores)

        #expect(await executor.executeShortcut(
            matching: "different words", channel: channel) == nil)
        let result = try #require(await executor.executeShortcut(
            matching: "STOP—LICHT AUS!", channel: channel))
        #expect(result.success)
        #expect(result.spokenText.contains("Shortcut used"))
        #expect(await connector.count() == 1)

        let activity = try stores.recentActivity()
        let root = try #require(activity.first { $0.kind == .shortcutTaken })
        let child = try #require(activity.first {
            $0.kind == .toolExecuted && $0.causedBy == root.id
        })
        #expect(try stores.provenance(of: child.id).map(\.id) == [child.id, root.id])
    }

    @Test func changedToolRiskFailsClosedWithoutExecutingOrFallingThrough() async throws {
        let stores = try inMemoryStores()
        let connector = RoutineSwitchConnector(risk: .confirmable)
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        let routine = try CommandRoutine(
            title: "Desk off", triggerKind: .phrase,
            phrases: ["Stop, Licht aus"], steps: [step], status: .active,
            evidenceCount: 3, explanation: "test", dedupeKey: "manual:stale-risk")
        try stores.saveCommandRoutine(routine)

        let result = try #require(await CommandRoutineExecutor(hub: hub, stores: stores)
            .executeShortcut(matching: "Stop, Licht aus", channel: .voice))

        #expect(!result.success)
        #expect(result.spokenText.contains("changed"))
        #expect(await connector.count() == 0)
    }

    @Test func suggestedScheduleCannotRunAndApprovedScheduleRunsOncePerSlot() async throws {
        let stores = try inMemoryStores()
        try stores.saveBackgroundWorkPolicy(.init(reviewed: true, allowed: [.routines]))
        let connector = RoutineSwitchConnector()
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2027, month: 2, day: 1, hour: 8, minute: 30))!
        let mask = 1 << (calendar.component(.weekday, from: now) - 1)
        let routine = try CommandRoutine(
            title: "Desk off", triggerKind: .schedule,
            scheduleMinuteOfDay: 8 * 60 + 30, scheduleWeekdayMask: mask,
            steps: [step], status: .suggested, evidenceCount: 4,
            explanation: "test", dedupeKey: "schedule:test")
        try stores.saveCommandRoutine(routine)
        let executor = CommandRoutineExecutor(hub: hub, stores: stores)

        #expect(await executor.runDueSchedules(at: now, calendar: calendar).isEmpty)
        #expect(await connector.count() == 0)
        try stores.setCommandRoutineStatus(routine.id, to: .active)
        #expect(await executor.runDueSchedules(at: now, calendar: calendar).count == 1)
        #expect(await executor.runDueSchedules(
            at: now.addingTimeInterval(60), calendar: calendar).isEmpty)
        #expect(await connector.count() == 1)
    }

    @Test func normalAgentTurnsFeedTheLearner() async throws {
        let stores = try inMemoryStores()
        let connector = RoutineSwitchConnector()
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        let loop = AgentLoop(
            router: EngineRouter(ranked: [FixedRoutineEngine()]),
            hub: hub, stores: stores, retriever: nil)

        for _ in 0..<3 {
            let stream = await loop.run(
                history: [], userMessage: "Stop, Licht aus", voiceMode: true,
                tier: .voice)
            for await _ in stream {}
        }
        #expect(await connector.count() == 3)
        let observations = try stores.commandObservations()
        #expect(observations.count == 3)
        #expect(Set(observations.map(\.workflowSignature)).count == 1)
        #expect(try stores.matchingPhraseRoutine("stop licht aus") != nil)
    }
}
