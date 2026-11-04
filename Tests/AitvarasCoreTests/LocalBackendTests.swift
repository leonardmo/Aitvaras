import Foundation
import Testing
import AitvarasAgents

@Suite struct LocalBackendTests {
    @Test func capabilitiesStreamTwoTurnsAndBarrierOrder() async throws {
        let calls = LocalCalls()
        let backend = LocalBackend { configuration, input in
            #expect(configuration.instructions == "project context")
            await calls.reply(input.text)
            return AsyncThrowingStream { $0.yield("local "); $0.yield(input.text); $0.finish() }
        }
        let status = await backend.status()
        #expect(status.authentication == .local)
        #expect(!status.capabilities.contains(.tools))
        #expect(!status.capabilities.contains(.approvals))
        #expect(!status.capabilities.contains(.plans))
        let run = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp"), model: "local", instructions: "project context"))
        #expect(await calls.events.isEmpty)
        let reader = Task { () throws -> [AgentEvent] in
            var events: [AgentEvent] = []
            for try await event in run.events {
                events.append(event)
                if case .turnEnded = event.kind { return events }
            }
            return events
        }
        let first = AgentInput(text: "first")
        try await run.send(first) { await calls.barrier() }
        let events = try await reader.value
        #expect(await calls.events == ["barrier", "first"])
        #expect(events.allSatisfy { $0.scope.runID == run.id && $0.scope.inputID == first.id })
        #expect(events.map(\.kind) == [.delivery(.acknowledged), .textDelta("local "), .textDelta("first"), .turnEnded(.completed)])
        let next = Task { () throws -> AgentTurnOutcome? in
            for try await event in run.events { if case .turnEnded(let value) = event.kind { return value } }
            return nil
        }
        try await run.send(.init(text: "second")) { await calls.barrier() }
        #expect(try await next.value == .completed)
        #expect(await calls.events == ["barrier", "first", "barrier", "second"])
        try await run.setMode(.plan) // Unsupported actions aren't offered by capabilities.
        try await run.shutdown()
    }

    @Test func barrierFailurePreventsInferenceAndEngineFailureIsTyped() async throws {
        let calls = LocalCalls()
        let backend = LocalBackend { _, input in
            await calls.reply(input.text)
            throw AgentFailure.offline
        }
        let run = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp"), model: "local"))
        await #expect(throws: AgentFailure.unknown) {
            try await run.send(.init(text: "must not infer")) { throw AgentFailure.unknown }
        }
        #expect(await calls.events.isEmpty)
        let reader = Task { () throws -> AgentTurnOutcome? in
            for try await event in run.events { if case .turnEnded(let value) = event.kind { return value } }
            return nil
        }
        try await run.send(.init(text: "engine down")) {}
        #expect(try await reader.value == .failed(.offline))
        try await run.shutdown()
    }

    @Test func stopRejectsLateDeltasAndShutdownRejectsNewInput() async throws {
        let holder = LocalStreamHolder()
        let backend = LocalBackend { _, _ in await holder.stream() }
        let run = try await backend.start(.init(directory: URL(fileURLWithPath: "/tmp"), model: "local"))
        let first = AgentInput(text: "hold")
        let reader = Task { () throws -> [AgentEvent.Kind] in
            var kinds: [AgentEvent.Kind] = []
            for try await event in run.events { kinds.append(event.kind) }
            return kinds
        }
        try await run.send(first) {}
        for _ in 0..<200 {
            if await holder.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await holder.started)
        await #expect(throws: AgentFailure.invalidTransition) { try await run.send(.init(text: "duplicate")) {} }
        try await run.interrupt()
        await holder.finish()
        try await run.shutdown()
        let kinds = try await reader.value
        #expect(kinds == [.delivery(.acknowledged), .turnEnded(.interrupted)])
        await #expect(throws: AgentFailure.invalidTransition) { try await run.send(.init(text: "after shutdown")) {} }
    }
}

private actor LocalCalls {
    var events: [String] = []
    func barrier() { events.append("barrier") }
    func reply(_ text: String) { events.append(text) }
}
private actor LocalStreamHolder {
    var started = false
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func stream() -> AsyncThrowingStream<String, Error> {
        started = true
        return AsyncThrowingStream { continuation = $0 }
    }
    func finish() { continuation?.yield("stale"); continuation?.finish() }
}
