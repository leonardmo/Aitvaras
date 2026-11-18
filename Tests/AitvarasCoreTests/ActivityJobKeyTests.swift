import Foundation
import Testing
import AitvarasCore
import AitvarasStore
import AitvarasRAG
@testable import AitvarasAgent
@testable import AitvarasConnectors

@Suite(.timeLimit(.minutes(2))) struct ActivityJobKeyTests {
    @Test func operationsAndSubjectsAreStableDistinctAndOpaque() {
        let first = UUID(), second = UUID()
        let operations: [(UUID) -> String] = [
            { ActivityJobKey.archiving(conversationID: $0, fingerprint: "example-fingerprint") },
            { ActivityJobKey.captureSummary(recordID: $0) },
            { ActivityJobKey.captureRefinement(archiveID: $0, modelID: "example-model", language: .english) },
            { ActivityJobKey.routineExecution(routineID: $0) },
            { ActivityJobKey.routineReview(routineIDs: [$0]) },
            { ActivityJobKey.queuedDelivery(itemID: $0) },
            { ActivityJobKey.problem(.routineExecution, subjectID: $0) }
        ]
        let keys = operations.map { $0(first) }
        #expect(Set(keys).count == operations.count)
        for operation in operations {
            #expect(operation(first) != operation(second))
            #expect(!operation(first).contains(first.uuidString))
            #expect(!operation(first).contains("example-model"))
            #expect(!operation(first).contains("example-fingerprint"))
        }
        #expect(ActivityJobKey.indexing(sourceIDs: ["source-a", "source-b"])
            == ActivityJobKey.indexing(sourceIDs: ["source-b", "source-a", "source-a"]))
        #expect(ActivityJobKey.indexing(sourceIDs: ["source-a"])
            != ActivityJobKey.indexing(sourceIDs: ["source-b"]))
        #expect(ActivityJobKey.indexing(sourceIDs: ["ab", "c"])
            != ActivityJobKey.indexing(sourceIDs: ["a", "bc"]))
        #expect(!ActivityJobKey.indexing(sourceIDs: ["example-source"]).contains("example-source"))
        #expect(ActivityJobKey.routineReview(routineIDs: [first, second])
            == ActivityJobKey.routineReview(routineIDs: [second, first, first]))
        #expect(ActivityJobKey.modelPreparation(modelID: "model-a")
            != ActivityJobKey.modelPreparation(modelID: "model-b"))
        #expect(ActivityJobKey.modelDownload(modelID: "model-a", repository: "example/model", revision: "v1")
            != ActivityJobKey.modelDownload(modelID: "model-a", repository: "example/model", revision: "v2"))
        #expect(!ActivityJobKey.modelDownload(modelID: "model-a", repository: "example/model", revision: "v1")
            .contains("example/model"))
        #expect(ActivityJobKey.captureRefinement(archiveID: first, modelID: "model-a", language: .english)
            != ActivityJobKey.captureRefinement(archiveID: first, modelID: "model-a", language: .german))
        #expect(ActivityJobKey.captureRefinement(archiveID: first, modelID: "model-a", language: .english)
            != ActivityJobKey.captureRefinement(archiveID: first, modelID: "model-b", language: .english))
        #expect(ActivityJobKey.speechAssets(language: .english) != ActivityJobKey.speechAssets(language: .german))
        #expect(Set([ActivityJobKey.startup, ActivityJobKey.captureAudioMaintenance,
            ActivityJobKey.voiceHelperCleanup, ActivityJobKey.consolidation, ActivityJobKey.voiceInstallation]).count == 5)
    }

    @Test func problemCodeAndSubjectCoalesceDespiteChangedDisplayText() throws {
        let stores = try inMemoryStores()
        let subject = UUID()
        let first = ActivityReporter(stores: stores).problem(code: .indexing, subjectID: subject,
            title: "Example problem", outcome: "First failure")
        let again = ActivityReporter(stores: stores).problem(code: .indexing, subjectID: subject,
            title: "Changed explanation", outcome: "Second failure")
        #expect(first == again)
        let run = try #require(try stores.activityRun(id: first))
        #expect(run.jobKey == ActivityJobKey.problem(.indexing, subjectID: subject))
        #expect(run.occurrenceCount == 2)
        #expect(run.outcome == "Second failure")
        let differentCode = ActivityReporter(stores: stores).problem(code: .incomingLookup, subjectID: subject,
            title: "Example problem", outcome: "Different operation")
        let differentSubject = ActivityReporter(stores: stores).problem(code: .indexing, subjectID: UUID(),
            title: "Example problem", outcome: "Different subject")
        #expect(Set([first, differentCode, differentSubject]).count == 3)
        try stores.acknowledgeActivityRun(id: first)
        let next = ActivityReporter(stores: stores).problem(code: .indexing, subjectID: subject,
            title: "Example problem", outcome: "New incident")
        #expect(next != first)
        #expect(try stores.activityRun(id: next)?.occurrenceCount == 1)
        #expect(try stores.activityRun(id: next)?.jobKey == run.jobKey)
        #expect(try stores.activityRuns().count == 4)
    }

    @Test func concurrentProblemReportsDoNotLoseOccurrences() async throws {
        let stores = try inMemoryStores()
        let ids = await withTaskGroup(of: UUID.self, returning: [UUID].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    ActivityReporter(stores: stores).problem(code: .indexing,
                        title: "Example problem", outcome: "Repeated failure")
                }
            }
            var results: [UUID] = []
            for await id in group { results.append(id) }
            return results
        }
        #expect(Set(ids).count == 1)
        #expect(try stores.activityRuns().first?.occurrenceCount == 12)
    }

    @Test func storedArchiveRetriesRetainTheirConversationAndFingerprintIdentity() async throws {
        let stores = try inMemoryStores()
        let first = try saveConversation(stores, marker: "first")
        let second = try saveConversation(stores, marker: "second")
        let engine = ScriptedEngine(responses: [ScriptedEngine.throwMarker,
            #"{"summary":"Example summary.","facts":[]}"#,
            #"{"summary":"Another summary.","facts":[]}"#])
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]),
            stores: stores, reporter: ActivityReporter(stores: stores))
        #expect(try await !archiver.archiveStoredConversation(id: first.id).archived)
        #expect(try await archiver.archiveStoredConversation(id: first.id).archived)
        #expect(try await archiver.archiveStoredConversation(id: second.id).archived)
        let runs = try stores.activityRuns()
        let attempts = runs.filter { $0.referenceID == first.id.uuidString }
        #expect(attempts.count == 2)
        #expect(Set(attempts.map(\.state)) == [.failed, .succeeded])
        let fingerprint = ConversationArchiver.fingerprint(of:
            ConversationArchiver.transcript(from: try stores.messages(in: first.id)))
        #expect(attempts.allSatisfy { $0.jobKey == ActivityJobKey.archiving(conversationID: first.id, fingerprint: fingerprint) })
        let other = try #require(runs.first { $0.referenceID == second.id.uuidString })
        #expect(other.jobKey != attempts.first?.jobKey)
    }

    @Test func captureSummaryRetriesUseTheRecordWhileModelHelpersStayUnkeyed() async throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let engine = ScriptedEngine(responses: [ScriptedEngine.throwMarker, "Example summary.", "Other summary."])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores, reporter: reporter)
        let first = CaptureRecord(startedAt: .now, title: "Example capture", scope: "Audio",
            audio: "mic", consentConfirmed: true, transcript: "Example transcript.", summaryPending: true)
        let second = CaptureRecord(startedAt: .now, title: "Example capture", scope: "Audio",
            audio: "mic", consentConfirmed: true, transcript: "Other transcript.", summaryPending: true)
        try stores.saveCaptureRecord(first)
        try stores.saveCaptureRecord(second)
        await #expect(throws: CaptureSummaryError.self) { try await summarizer.retrySummaryRecord(for: first.id) }
        _ = try await summarizer.retrySummaryRecord(for: first.id)
        _ = try await summarizer.retrySummaryRecord(for: second.id)
        let attempts = try stores.activityRuns().filter { $0.referenceID == first.id.uuidString }
        #expect(attempts.count == 2)
        #expect(Set(attempts.map(\.state)) == [.failed, .succeeded])
        #expect(attempts.allSatisfy { $0.jobKey == ActivityJobKey.captureSummary(recordID: first.id) })
        #expect(try stores.activityRuns().first { $0.referenceID == second.id.uuidString }?.jobKey
            == ActivityJobKey.captureSummary(recordID: second.id))

        let owner = reporter.begin(ActivityRun(referenceID: second.id.uuidString, category: .capture,
            title: "Example summary owner", jobKey: ActivityJobKey.captureSummary(recordID: second.id)))
        let helper = CaptureSummarizer(router: EngineRouter(ranked: [ScriptedEngine(responses: ["Helper result."])]),
            stores: stores, reporter: reporter)
        _ = try await ActivityTaskContext.$runID.withValue(owner) {
            try await helper.summarize("Example transcript.", recordID: second.id)
        }
        let child = try #require(try stores.activityChildRuns(parentID: owner).first)
        #expect(child.jobKey == nil)
        #expect(child.parentID == owner)
    }

    @Test func consolidationAndIndexingReportTheirOwnerKeys() async throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let consolidator = Consolidator(router: EngineRouter(ranked: []), stores: stores, reporter: reporter)
        _ = await consolidator.run()
        _ = await consolidator.run()
        let consolidations = try stores.activityRuns().filter { $0.category == .memory }
        #expect(consolidations.count == 2)
        #expect(consolidations.allSatisfy { $0.jobKey == ActivityJobKey.consolidation })

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("job-index-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Example\n\nExample content.".write(to: folder.appendingPathComponent("example.md"),
            atomically: true, encoding: .utf8)
        try stores.saveBackgroundWorkPolicy(BackgroundWorkPolicy(reviewed: true, allowed: [.indexing]))
        let source = IndexSource(id: "example-source", name: "Example", url: folder)
        let indexer = Indexer(stores: stores, embedder: JobKeyEmbedder(), reporter: reporter,
            jobSourceIDs: ["example-source", "other-configured-source"])
        try await ActivityTaskContext.$trigger.withValue(.automatic) {
            try await indexer.fullScan(sources: [source])
        }
        try "# Another example\n\nAdditional content.".write(to: folder.appendingPathComponent("another.md"),
            atomically: true, encoding: .utf8)
        try await ActivityTaskContext.$trigger.withValue(.automatic) {
            try await indexer.fullScan(sources: [source])
        }
        let scans = try stores.activityRuns().filter { $0.category == .knowledge }
        #expect(scans.count == 2)
        #expect(scans.allSatisfy { $0.jobKey == ActivityJobKey.indexing(sourceIDs: ["other-configured-source", "example-source"]) })
        let key = try #require(scans.first?.jobKey)
        #expect(!key.contains(folder.path))
    }

    @Test func routineExecutionAndReviewKeepDistinctOwnerKeysWithoutReparenting() async throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let connector = JobKeyConnector()
        let hub = ConnectorHub(stores: stores, reporter: reporter)
        await hub.register(connector)
        let step = CommandRoutineStep(connectorID: connector.id, toolName: "write", argumentsJSON: "{}", risk: .reversibleWrite)
        let routine = try CommandRoutine(title: "Example routine", triggerKind: .phrase,
            phrases: ["example command"], steps: [step], status: .active,
            evidenceCount: 3, explanation: "Example", dedupeKey: "fixture-routine")
        try stores.saveCommandRoutine(routine)
        let executor = CommandRoutineExecutor(hub: hub, stores: stores, reporter: reporter)
        for _ in 0..<2 {
            #expect(await executor.executeShortcut(matching: "example command", channel: .typed)?.success == true)
        }
        let executions = try stores.activityRuns().filter { $0.category == .automation }
        #expect(executions.count == 2)
        #expect(executions.allSatisfy { $0.jobKey == ActivityJobKey.routineExecution(routineID: routine.id) })
        #expect(try stores.activityRuns().filter { $0.category == .connection }.allSatisfy { $0.jobKey == nil })

        let parent = reporter.begin(ActivityRun(category: .system, title: "Existing review parent"))
        let service = CloudAgentService(stores: stores, reporter: reporter,
            candidates: { _ in [
                DelegateConnector.Agent(path: "/synthetic/claude", kind: .claude),
                DelegateConnector.Agent(path: "/synthetic/codex", kind: .codex)
            ] }, execute: { agent, request, _ in
                #expect(request.routineReviewIDs == [routine.id])
                let text = agent.kind == .claude ? "Invalid structured output" :
                    "{\"reviews\":[{\"id\":\"\(routine.id)\",\"title\":\"Example routine\",\"summary\":\"Example review.\"}]}"
                return CloudAgentResponse(text: text, provider: agent.kind, usage: .unavailable)
            })
        let reviewer = RoutineCloudReviewer(stores: stores, selectionProvider: { .automatic },
            reporter: reporter, service: service)
        try await ActivityTaskContext.$runID.withValue(parent) { try await reviewer.review([routine]) }
        let reviews = try stores.activityChildRuns(parentID: parent)
        #expect(reviews.count == 2)
        #expect(Set(reviews.map(\.state)) == [.failed, .succeeded])
        #expect(reviews.allSatisfy { $0.jobKey == ActivityJobKey.routineReview(routineIDs: [routine.id]) && $0.parentID == parent })
    }

    @Test func chatConfirmedActionsAndUnscopedArchiveStayUnkeyed() async throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let connector = JobKeyConnector()
        let hub = ConnectorHub(stores: stores, reporter: reporter)
        await hub.register(connector)
        let loop = AgentLoop(router: EngineRouter(ranked: [ScriptedEngine(responses: ["Example reply."])]),
            hub: hub, stores: stores, retriever: nil, reporter: reporter)
        for await _ in await loop.run(history: [], userMessage: "Example request.") { }
        let result = try await hub.execute(call: ToolCall(id: "example-action", toolName: "example.confirm",
            argumentsJSON: "{}"), causedBy: nil, sourceID: nil)
        guard case .awaitingConfirmation(let suggestion) = result else {
            Issue.record("Expected a confirmation decision")
            return
        }
        _ = try await hub.executeSuggestion(suggestion)
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [ScriptedEngine(responses: [
            #"{"summary":"Example archive.","facts":[]}"#
        ])]), stores: stores, reporter: reporter)
        #expect(await archiver.archive(transcript: [.init(role: .user, content: "Example first message."),
            .init(role: .user, content: "Example second message.")]).archived)
        let runs = try stores.activityRuns()
        #expect(runs.contains { $0.category == .chat })
        #expect(runs.contains { $0.id == suggestion.id && $0.state == .succeeded })
        #expect(runs.allSatisfy { $0.jobKey == nil })
    }

    private func saveConversation(_ stores: Stores, marker: String) throws -> Conversation {
        let conversation = Conversation(title: "Example conversation")
        try stores.saveConversation(conversation)
        for index in 0..<2 {
            try stores.appendMessage(StoredMessage(conversationID: conversation.id,
                role: "user", content: "Example \(marker) message \(index)."))
        }
        return conversation
    }
}

private actor JobKeyEmbedder: EmbeddingEngine {
    let identifier = "example-embedder"
    let dimensions = 2
    func embed(texts: [String]) async throws -> [[Float]] { texts.map { _ in [1, 0] } }
}

private actor JobKeyConnector: Connector {
    nonisolated let id = "example"
    nonisolated let displayName = "Example"
    nonisolated let tools = [
        ToolDefinition(name: "write", description: "Example reversible write", parametersJSON: "{}", risk: .reversibleWrite),
        ToolDefinition(name: "confirm", description: "Example confirmed action", parametersJSON: "{}", risk: .confirmable)
    ]
    func health() async -> ConnectorHealth { .ready }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
    func execute(toolName: String, argumentsJSON: String) async throws -> String { "Example result." }
}
