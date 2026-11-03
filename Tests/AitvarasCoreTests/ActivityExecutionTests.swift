import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent
@testable import AitvarasConnectors

private actor SimulatedProviderCalls {
    private var count = 0
    func next() -> Int { count += 1; return count }
    func total() -> Int { count }
}

private struct SimulatedProviderFailure: Error {}

private actor CancelledCompletionEngine: InferenceEngine {
    nonisolated let identifier = "synthetic-cancelled"
    func isAvailable(for tier: ModelTier) async -> Bool { true }
    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(#"{"digest":"Must not apply","operations":[{"op":"add","text":"Must not save"}],"insights":[],"questions":[]}"#))
            continuation.yield(.done(stopReason: .cancelled))
            continuation.finish()
        }
    }
}

private actor CancellingRoutineConnector: Connector {
    nonisolated let id = "synthetic"
    nonisolated let displayName = "Synthetic"
    nonisolated let tools = [ToolDefinition(name: "read", description: "Synthetic read",
        parametersJSON: #"{"type":"object"}"#, risk: .read)]
    private var count = 0
    func health() async -> ConnectorHealth { .ready }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        count += 1
        throw CancellationError()
    }
    func total() -> Int { count }
}

@Suite struct ActivityExecutionTests {
    private static let agents = [
        DelegateConnector.Agent(path: "/synthetic/claude", kind: .claude),
        DelegateConnector.Agent(path: "/synthetic/codex", kind: .codex)
    ]

    @Test func successfulProviderIsNotRepeatedWhenUsagePersistenceFails() async throws {
        let stores = try inMemoryStores()
        let calls = SimulatedProviderCalls()
        let reporter = ActivityReporter(stores: stores)
        let service = CloudAgentService(stores: stores, reporter: reporter,
            candidates: { _ in Self.agents }, execute: { agent, _, _ in
                _ = await calls.next()
                let active = try stores.currentActivityRuns()
                #expect(active.contains { $0.category == .cloud && $0.state == .running })
                return CloudAgentResponse(text: "private-result", provider: agent.kind, usage: .unavailable)
            }, recordUsage: { _ in throw SimulatedProviderFailure() })
        let response = try await service.run(.init(feature: .routineReview,
            selection: .automatic, prompt: "private-prompt"))
        #expect(response.text == "private-result")
        #expect(await calls.total() == 1)
        let runs = try stores.activityRuns()
        #expect(runs.count == 1)
        #expect(runs[0].state == .succeeded)
        #expect(runs[0].outcome?.contains("usage record could not be saved") == true)
        let metadata = String(decoding: try JSONEncoder().encode(runs), as: UTF8.self)
        #expect(!metadata.contains("private-prompt"))
        #expect(!metadata.contains("private-result"))
    }

    @Test func workspaceFailureNeverStartsFallbackProvider() async throws {
        let stores = try inMemoryStores()
        let calls = SimulatedProviderCalls()
        let service = CloudAgentService(stores: stores, reporter: ActivityReporter(stores: stores),
            candidates: { _ in Self.agents }, execute: { _, _, _ in
                _ = await calls.next()
                throw SimulatedProviderFailure()
            })
        do {
            _ = try await service.run(.init(feature: .delegation, selection: .automatic,
                prompt: "synthetic task", access: .workspaceWrite("/synthetic/workspace")))
            Issue.record("Expected uncertain delegated outcome")
        } catch {
            #expect(error.localizedDescription.contains("outcome is unknown"))
        }
        #expect(await calls.total() == 1)
        #expect(try stores.activityRuns().first?.state == .outcomeUnknown)
    }

    @Test func cancelledProviderNeverStartsFallback() async throws {
        let stores = try inMemoryStores()
        let calls = SimulatedProviderCalls()
        let service = CloudAgentService(stores: stores, reporter: ActivityReporter(stores: stores),
            candidates: { _ in Self.agents }, execute: { _, _, _ in
                _ = await calls.next()
                throw CancellationError()
            })
        do {
            _ = try await service.run(.init(feature: .nightlyMemory, selection: .automatic,
                prompt: "synthetic bounded task"))
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(await calls.total() == 1)
        #expect(try stores.activityRuns().first?.state == .cancelled)
    }

    @Test func safeReadOnlyFallbackHasSeparateAttemptLifecycles() async throws {
        let stores = try inMemoryStores()
        let calls = SimulatedProviderCalls()
        let service = CloudAgentService(stores: stores, reporter: ActivityReporter(stores: stores),
            candidates: { _ in Self.agents }, execute: { agent, _, _ in
                if await calls.next() == 1 { throw SimulatedProviderFailure() }
                return CloudAgentResponse(text: "ok", provider: agent.kind, usage: .unavailable)
            })
        _ = try await service.run(.init(feature: .routineReview, selection: .automatic, prompt: "synthetic task"))
        let runs = try stores.activityRuns()
        #expect(await calls.total() == 2)
        #expect(runs.count == 2)
        #expect(Set(runs.map(\.state)) == [.failed, .succeeded])
        #expect(runs.contains { $0.stage == "Fallback provider request" && $0.provider == "Codex CLI" })
    }

    @Test func cancelledConsolidationDoesNotFallbackOrApplyPartialPlan() async throws {
        let stores = try inMemoryStores()
        let now = Date.now
        try stores.record(ActivityEvent(kind: .conversationArchived,
            timestamp: now.addingTimeInterval(-60), connectorID: "memory", summary: "Synthetic episode"))
        let local = ScriptedEngine(identifier: "synthetic-local", responses: [])
        let consolidator = Consolidator(router: EngineRouter(ranked: [local]), stores: stores,
            preferredEngine: CancelledCompletionEngine(), reporter: ActivityReporter(stores: stores))
        let result = await consolidator.run(now: now)
        #expect(result.failed)
        #expect(await local.callCount() == 0)
        #expect(try stores.activeFacts().isEmpty)
        #expect(try await consolidator.lastSuccessfulRun() == nil)
        #expect(try stores.activityRuns().allSatisfy { $0.state == .cancelled })
    }

    @Test func cancelledChatNeverEmitsFinishedSuccess() async throws {
        let stores = try inMemoryStores()
        let loop = AgentLoop(router: EngineRouter(ranked: [CancelledCompletionEngine()]),
            hub: ConnectorHub(stores: stores), stores: stores, retriever: nil,
            reporter: ActivityReporter(stores: stores))
        var finished = false
        var failed = false
        for await update in await loop.run(history: [], userMessage: "Synthetic request") {
            if case .finished = update { finished = true }
            if case .failed = update { failed = true }
        }
        #expect(!finished && failed)
        #expect(try stores.activityRuns().first?.state == .cancelled)
    }

    @Test func automaticArchiveIsGatedButManualArchiveRemainsAvailable() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: [#"{"summary":"Synthetic conversation","facts":[]}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]),
            stores: stores, reporter: ActivityReporter(stores: stores))
        let transcript = [ChatMessage(role: .user, content: "One synthetic message"),
                          ChatMessage(role: .user, content: "Another synthetic message")]
        let blocked = await ActivityTaskContext.$trigger.withValue(.automatic) {
            await archiver.archive(transcript: transcript)
        }
        #expect(!blocked.archived)
        #expect(await engine.callCount() == 0)
        #expect(try stores.activityRuns().isEmpty)
        let manual = await archiver.archive(transcript: transcript)
        #expect(manual.archived)
        #expect(await engine.callCount() == 1)
    }

    @Test func cancelledRoutineStopsBeforeNextToolStep() async throws {
        let stores = try inMemoryStores()
        let connector = CancellingRoutineConnector()
        let reporter = ActivityReporter(stores: stores)
        let hub = ConnectorHub(stores: stores, reporter: reporter)
        await hub.register(connector)
        let step = CommandRoutineStep(connectorID: "synthetic", toolName: "read",
            argumentsJSON: "{}", risk: .read)
        let writeStep = CommandRoutineStep(connectorID: "synthetic", toolName: "write",
            argumentsJSON: "{}", risk: .reversibleWrite)
        let routine = try CommandRoutine(title: "Synthetic routine", triggerKind: .phrase,
            phrases: ["synthetic shortcut"], steps: [step, writeStep], status: .active,
            evidenceCount: 3, explanation: "Synthetic fixture", dedupeKey: "synthetic-cancel")
        try stores.saveCommandRoutine(routine)
        let executor = CommandRoutineExecutor(hub: hub, stores: stores, reporter: reporter)
        let result = await executor.executeShortcut(matching: "synthetic shortcut", channel: .typed)
        #expect(result?.success == false)
        #expect(await connector.total() == 1)
        #expect(try stores.activityRuns().allSatisfy { $0.state == .cancelled })
    }

    @Test func automaticCloudGatePreventsEvenProviderDiscovery() async throws {
        let stores = try inMemoryStores()
        let discoveries = SimulatedProviderCalls()
        let service = CloudAgentService(stores: stores,
            candidates: { _ in _ = await discoveries.next(); return Self.agents },
            execute: { agent, _, _ in
                Issue.record("Unapproved automatic work reached provider")
                return CloudAgentResponse(text: "unexpected", provider: agent.kind, usage: .unavailable)
            })
        await ActivityTaskContext.$trigger.withValue(.automatic) {
            do {
                _ = try await service.run(.init(feature: .routineReview, selection: .automatic,
                    prompt: "synthetic routine metadata"))
                Issue.record("Unapproved automatic review was accepted")
            } catch { }
        }
        #expect(await discoveries.total() == 0)
    }

    @Test func monitoringFailureSuspendsAutomaticArchiveEvenWithApprovedPolicy() async throws {
        let stores = try inMemoryStores()
        try stores.saveBackgroundWorkPolicy(.init(reviewed: true, allowed: [.archiving]))
        let reporter = ActivityReporter(stores: stores)
        // Deliberately invalid reporter operation creates its sticky, generic
        // failure without touching live storage or disabling manual work.
        reporter.finish(id: UUID(), state: .running)
        #expect(reporter.failureMessage != nil)
        let engine = ScriptedEngine(responses: [#"{"summary":"Synthetic archive","facts":[]}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]),
            stores: stores, reporter: reporter)
        let transcript = [ChatMessage(role: .user, content: "First synthetic turn"),
                          ChatMessage(role: .user, content: "Second synthetic turn")]
        let automatic = await ActivityTaskContext.$trigger.withValue(.automatic) {
            await archiver.archive(transcript: transcript)
        }
        #expect(!automatic.archived)
        #expect(await engine.callCount() == 0)
        #expect(await archiver.archive(transcript: transcript).archived)
    }

    @Test func failedCaptureChunkDoesNotProduceIncompleteSuccessfulSummary() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: ["First chunk", ScriptedEngine.throwMarker, "Must not run"])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]),
            stores: stores, reporter: ActivityReporter(stores: stores))
        let result = try await summarizer.summarize(String(repeating: "synthetic material ", count: 2_000))
        #expect(result == nil)
        #expect(await engine.callCount() == 2)
        #expect(try stores.activityRuns().first?.state == .failed)
    }
}
