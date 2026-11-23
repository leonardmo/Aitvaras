import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2)))
struct AgentFailureDiagnosticsTests {
    @Test(arguments: [AgentProvider.claude, .codex])
    func publicStartDoesNotThrowADiagnosticCarrier(provider: AgentProvider) async throws {
        let fixture = try BackendExecutableFixture(script: #"""
read()
print('x'*1100000,flush=True)
done()
"""#)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        do {
            let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
            try await run.shutdown()
            Issue.record("Expected startup to fail")
        } catch { #expect(error is AgentFailure); #expect(!(error is AgentFailureReport)) }
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func publicRunErrorsAreFailuresWhileEventsRetainCategories(provider: AgentProvider) async throws {
        let script = provider == .claude ? #"""
claude_init()
read()
print('x'*1100000,flush=True)
done()
"""# : #"""
codex_init()
start_thread()
read()
print('x'*1100000,flush=True)
done()
"""#
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let backend: any AgentBackend = provider == .claude
            ? ClaudeBackend(executable: fixture.executable, environment: fixture.environment)
            : CodexBackend(executable: fixture.executable, environment: fixture.environment)
        let run = try await backend.start(.init(directory: fixture.directory, model: "test"))
        do { try await run.send(.init(text: "Example"), willDeliver: {}) }
        catch { #expect(error is AgentFailure); #expect(!(error is AgentFailureReport)) }
        var reports: [AgentFailureReport] = []
        do {
            for try await event in run.events { if let report = event.failureReport { reports.append(report) } }
            Issue.record("A failed transport must terminate its stream with AgentFailure")
        } catch { #expect(error is AgentFailure); #expect(!(error is AgentFailureReport)) }
        #expect(reports.map(\.category.name) == ["AgentProcessError.outputLimit"])
        try await run.shutdown()
    }

    @Test func categoriesRetainOnlyTypesAndCases() throws {
        let samples: [(any Error, String)] = [
            (AgentStoreError.identityConflict, "AgentStoreError.identityConflict"),
            (AgentSessionManagerError.persistence, "AgentSessionManagerError.persistence"),
            (AgentNativeHistoryError.malformedHistory, "AgentNativeHistoryError.malformedHistory"),
            (AgentFailure.invalidTransition, "AgentFailure.invalidTransition"),
            (AgentFailure.quota(resetsAt: Date(timeIntervalSince1970: 1234)), "AgentFailure.quota"),
            (AgentFailure.crashed(exitCode: 19), "AgentFailure.crashed"),
            (AgentProcessError.writeFailed, "AgentProcessError.writeFailed"),
            (DiagnosticCanaryError.example, "DiagnosticCanaryError.failed"),
            (UncategorizedDiagnosticError.failed(DiagnosticCanaryError.prompt), "UncategorizedDiagnosticError.unknown")
        ]
        for (error, expected) in samples {
            let report = AgentFailureDiagnostics.capture(error)
            #expect(report.category.name == expected)
            #expect(AgentFailureDiagnostics.capture(report) == report)
            #expect(AgentFailureDiagnostics.failure(for: report) == report.failure)
            try expectNoCanaries([report.activity(chatID: UUID(), inputID: UUID())])
        }
        let error = NSError(domain: DiagnosticCanaryError.credential, code: 42,
            userInfo: [NSLocalizedDescriptionKey: DiagnosticCanaryError.path + DiagnosticCanaryError.prompt])
        try expectNoCanaries([AgentFailureDiagnostics.capture(error).activity(chatID: UUID(), inputID: UUID())])
        let invalid = Data(#"{"type":"/tmp/example-private","errorCase":"prompt with spaces"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SafeErrorCategory.self, from: invalid) }
    }

    @Test func localCaughtErrorReachesActivityWithOriginalCategoryOnce() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .local)
        let backend = LocalBackend { _, _ in throw DiagnosticCanaryError.example }
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = AgentInput(text: DiagnosticCanaryError.prompt)
        try await manager.send(chatID: chat.id, provider: .local, input: input)
        try await waitAgentCondition { try stores.recentActivity(limit: 20).contains { $0.kind == .agentFailure } }
        let events = try stores.recentActivity(limit: 20)
        let failures = events.filter { $0.kind == .agentFailure }
        #expect(failures.count == 1)
        #expect(failures.first?.runID == input.id)
        #expect(category(failures.first) == "DiagnosticCanaryError.failed")
        #expect(try await manager.state(chatID: chat.id).outcome == .failed(.unknown))
        try expectNoCanaries(events)
        try await manager.shutdown()
    }

    @Test func streamErrorSurvivesCoordinatorAndManagerWithoutDuplicateAudit() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .claude)
        let backend = DiagnosticBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = AgentInput(text: DiagnosticCanaryError.prompt)
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        await backend.run.fail(DiagnosticCanaryError.example)
        try await waitAgentCondition { try await !manager.state(chatID: chat.id).isRunning }
        let events = try stores.recentActivity(limit: 20)
        #expect(events.filter { $0.kind == .agentFailure }.count == 1)
        #expect(category(events.first { $0.kind == .agentFailure }) == "DiagnosticCanaryError.failed")
        #expect(events.first?.runID == input.id)
        try expectNoCanaries(events)
        try await manager.shutdown()
    }

    @Test(arguments: [AgentProvider.claude, .codex])
    func processErrorCategorySurvivesWireAndBackendMapping(provider: AgentProvider) async throws {
        let script = provider == .claude ? #"""
claude_init()
read()
print('x'*1100000,flush=True)
done()
"""# : #"""
codex_init()
start_thread()
request=read()
emit({'id':request['id'],'result':{'turn':{'id':'diagnostic-turn'}}})
print('x'*1100000,flush=True)
done()
"""#
        let fixture = try BackendExecutableFixture(script: script)
        defer { fixture.remove() }
        let (stores, chat, manager) = try followupManager(fixture, provider: provider)
        let input = AgentInput(text: DiagnosticCanaryError.prompt)
        do { try await manager.send(chatID: chat, provider: provider, input: input) }
        catch { #expect(error is AgentFailure); #expect(!(error is AgentFailureReport)) }
        try await waitAgentCondition {
            try stores.recentActivity(limit: 20).contains { category($0) == "AgentProcessError.outputLimit" }
        }
        // The coordinator records the failure before the manager handles the terminal event.
        try await waitAgentCondition { try await !manager.state(chatID: chat).isRunning }
        try expectNoCanaries(try stores.recentActivity(limit: 20))
        try await manager.shutdown()
    }

    @Test func persistenceCatchRecordsConcreteIdentityConflictAndKeepsUnknownOutcome() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .claude)
        let backend = DiagnosticBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = AgentInput(text: DiagnosticCanaryError.prompt)
        try await manager.send(chatID: chat.id, provider: .claude, input: input)
        // Simulate a changed durable row so the next manager save exercises
        // the real store identity guard rather than an invented error mapping.
        try await stores.db.queue.write { db in
            var entry = try #require(try AgentTranscriptEntry.fetchOne(db, key: input.id))
            entry.sessionID = nil
            try entry.update(db)
        }
        await backend.run.emit(.delivery(.acknowledged), input: input.id)
        try await waitAgentCondition {
            try stores.recentActivity(limit: 20).contains { category($0) == "AgentStoreError.identityConflict" }
        }
        #expect(try await manager.state(chatID: chat.id).outcome == .failed(.unknown))
        try expectNoCanaries(try stores.recentActivity(limit: 20))
        try await manager.shutdown()
    }

    @Test func approvalCatchRetainsCategoryAndAuditsOnlyMetadata() async throws {
        let stores = try inMemoryStores()
        let run = DiagnosticRun()
        let coordinator = AgentActionCoordinator(run: run, mode: .ask, provenance: .init(chatID: UUID()),
            audit: { _ = try stores.record($0) })
        let input = AgentInput(text: DiagnosticCanaryError.prompt)
        try await coordinator.send(input, willDeliver: {})
        let request = AgentRequest(id: .string("request"), scope: .init(runID: run.id,
            session: .init(provider: .claude, profile: "default", nativeID: "diagnostic-session"), inputID: input.id),
            kind: .permission(.init(name: "Write", input: .object(["file_path": .string(DiagnosticCanaryError.path)]))))
        await run.emit(.request(request), input: input.id)
        try await waitAgentCondition { await coordinator.pendingRequests().count == 1 }
        await #expect(throws: DiagnosticCanaryError.self) {
            try await coordinator.alwaysAllow(to: request) { throw DiagnosticCanaryError.example }
        }
        var reports: [AgentFailureReport] = []
        do {
            for try await event in coordinator.events {
                if let report = event.failureReport { reports.append(report) }
            }
            Issue.record("Expected the categorized stream failure")
        } catch {
            #expect(error as? AgentFailure == .unknown)
            #expect(!(error is AgentFailureReport))
        }
        #expect(reports.map(\.category.name) == ["DiagnosticCanaryError.failed"])
        #expect(reports.allSatisfy { $0.isAudited })
        let events = try stores.recentActivity(limit: 20)
        #expect(events.filter { $0.kind == .agentFailure }.count == 1)
        try expectNoCanaries(events)
        try await coordinator.shutdown()
    }

    @Test func preDeliveryCatchAndBrokenAuditDoNotLeakOrRecurse() async throws {
        let stores = try inMemoryStores()
        let (chat, _) = try agentStoreChat(stores, provider: .claude)
        let backend = DiagnosticBackend()
        let manager = try AgentSessionManager(persistence: stores, backend: { _ in backend }, audit: { _ = try stores.record($0) })
        let input = UUID()
        #expect(try await manager.reportSendFailure(chatID: chat.id, inputID: input, error: DiagnosticCanaryError.example) == .unknown)
        let events = try stores.recentActivity(limit: 20)
        #expect(events.count == 1)
        #expect(events.first?.runID == input)
        try expectNoCanaries(events)
        let sink = BrokenDiagnosticAudit()
        let report = AgentFailureDiagnostics.capture(DiagnosticCanaryError.example)
        let result = await report.recording(chatID: chat.id, inputID: input, audit: { try await sink.record($0) })
        #expect(await sink.calls == 1)
        #expect(result == report)
        #expect(!result.isAudited)
        try await manager.shutdown()
    }

    @Test func sharedTransportFailureRecordsEachAffectedInput() async throws {
        let stores = try inMemoryStores()
        let report = AgentFailureDiagnostics.capture(DiagnosticCanaryError.example)
        let inputs = [UUID(), UUID()]
        for input in inputs {
            let recorded = await report.recording(chatID: UUID(), inputID: input, audit: { _ = try stores.record($0) })
            #expect(recorded.isAudited)
        }
        let events = try stores.recentActivity(limit: 20)
        #expect(events.count == 2)
        #expect(Set(events.compactMap(\.runID)) == Set(inputs))
        #expect(events.allSatisfy { category($0) == "DiagnosticCanaryError.failed" })
        try expectNoCanaries(events)
    }
}

private func category(_ event: ActivityEvent?) -> String? {
    guard let payload = event?.detailJSON.flatMap(JSONValue.parse),
          let type = payload["errorType"]?.stringValue, let errorCase = payload["errorCase"]?.stringValue else { return nil }
    return type + "." + errorCase
}
private func expectNoCanaries(_ events: [ActivityEvent]) throws {
    let text = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    for canary in [DiagnosticCanaryError.path, DiagnosticCanaryError.prompt, DiagnosticCanaryError.credential] {
        #expect(!text.contains(canary))
    }
}
private enum DiagnosticCanaryError: Error, SafeErrorCategorizing {
    case failed(path: String, prompt: String, credential: String)
    static let path = "/tmp/example-private-canary"
    static let prompt = "EXAMPLE_PROMPT_CANARY"
    static let credential = "EXAMPLE_CREDENTIAL_CANARY"
    static var example: Self { .failed(path: path, prompt: prompt, credential: credential) }
    var safeErrorCategory: SafeErrorCategory { .init(type: "DiagnosticCanaryError", errorCase: "failed") }
}
private enum UncategorizedDiagnosticError: Error { case failed(String) }
private actor BrokenDiagnosticAudit {
    var calls = 0
    func record(_ event: ActivityEvent) throws { calls += 1; throw DiagnosticCanaryError.example }
}
private actor DiagnosticBackend: AgentBackend {
    let run = DiagnosticRun()
    func status() -> AgentStatus { .init(installed: true, authentication: .subscription, capabilities: []) }
    func models() -> [AgentModel] { [] }
    func signIn(onBrowserURL: @escaping @Sendable (URL) async -> Void) {}
    func start(_ configuration: AgentSessionConfiguration) -> any AgentRun { run }
    func listSessions(folder: URL, cursor: String?) throws -> AgentPage<AgentSessionSummary> { throw AgentFailure.unsupported }
    func readHistory(session: AgentSessionID, cursor: String?) throws -> AgentPage<AgentEvent> { throw AgentFailure.unsupported }
}
private actor DiagnosticRun: AgentRun {
    nonisolated let id = UUID()
    nonisolated let events: AsyncThrowingStream<AgentEvent, Error>
    private let continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    init() { (events, continuation) = AsyncThrowingStream.makeStream() }
    func send(_ input: AgentInput, willDeliver: @escaping @Sendable () async throws -> Void) async throws { try await willDeliver() }
    func respond(to request: AgentRequest, with response: AgentResponse) {}
    func setMode(_ mode: AgentMode) {}
    func interrupt() {}
    func shutdown() { continuation.finish() }
    func fail(_ error: any Error) { continuation.finish(throwing: error) }
    func emit(_ kind: AgentEvent.Kind, input: UUID) {
        let scope: AgentEventScope
        if case .request(let request) = kind { scope = request.scope }
        else { scope = .init(runID: id, inputID: input) }
        continuation.yield(.init(scope: scope, kind: kind))
    }
}
