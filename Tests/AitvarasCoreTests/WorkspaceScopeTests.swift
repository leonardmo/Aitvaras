import Foundation
import GRDB
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

private actor WorkspaceScopeEngine: InferenceEngine {
    nonisolated let identifier = "workspace-scope-fixture"
    private let emitsTool: Bool
    private var requests: [([ChatMessage], [ToolDefinition])] = []
    private var availabilityChecks = 0

    init(emitsTool: Bool = false) { self.emitsTool = emitsTool }
    func isAvailable(for tier: ModelTier) async -> Bool {
        availabilityChecks += 1
        return true
    }
    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        requests.append((messages, tools))
        return AsyncThrowingStream { continuation in
            if emitsTool {
                continuation.yield(.toolCall(ToolCall(
                    id: "fabricated", toolName: "scope_probe.read", argumentsJSON: "{}")))
                continuation.yield(.done(stopReason: .toolUse))
            } else {
                continuation.yield(.text("A scoped text answer."))
                continuation.yield(.done(stopReason: .endOfTurn))
            }
            continuation.finish()
        }
    }
    func snapshot() -> (messages: [ChatMessage], tools: [ToolDefinition], calls: Int, availabilityChecks: Int) {
        (requests.first?.0 ?? [], requests.first?.1 ?? [], requests.count, availabilityChecks)
    }
}

private actor WorkspaceScopeRetriever: ContextRetriever {
    private var calls = 0
    func retrieve(query: String, limit: Int) async throws -> [RetrievedChunk] {
        calls += 1
        return [RetrievedChunk(text: "OTHER_PROJECT_RETRIEVAL_CANARY", origin: "fixture", score: 1)]
    }
    func callCount() -> Int { calls }
}

private actor WorkspaceScopeConnector: Connector {
    nonisolated let id = "scope_probe"
    nonisolated let displayName = "Scope probe"
    private var catalogReads = 0
    private var executions = 0
    var tools: [ToolDefinition] {
        catalogReads += 1
        return [ToolDefinition(name: "read", description: "Synthetic scope probe",
                               parametersJSON: #"{"type":"object"}"#, risk: .read)]
    }
    func health() async -> ConnectorHealth { .ready }
    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        executions += 1
        return "CONNECTOR_CANARY"
    }
    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }
    func counts() -> (catalogReads: Int, executions: Int) { (catalogReads, executions) }
}

private actor WorkspaceArchiveGate: InferenceEngine {
    nonisolated let identifier = "workspace-archive-gate"
    private var continuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func isAvailable(for tier: ModelTier) async -> Bool { true }
    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        self.continuation = continuation
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return stream
    }
    func waitForInference() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func finish() {
        continuation?.yield(.text(#"{"summary":"PROJECT_EPISODE_CANARY","facts":[{"text":"PROJECT_FACT_CANARY","kind":"biography","entities":"ProjectCanary"}]}"#))
        continuation?.yield(.done(stopReason: .endOfTurn))
        continuation?.finish()
        continuation = nil
    }
}

@Suite struct WorkspaceScopeTests {
    @Test(arguments: [true, false])
    func projectTurnUsesOnlySuppliedTextAndNoSharedContext(withFact: Bool) async throws {
        let stores = try inMemoryStores()
        if withFact {
            try stores.saveFact(MemoryFact(text: "SHARED_FACT_CANARY", kind: .biography, source: .userStated))
        }
        try stores.saveMemory(Memory(content: "OLD_MEMORY_CANARY", category: "fact"))
        let engine = WorkspaceScopeEngine()
        let retriever = WorkspaceScopeRetriever()
        let connector = WorkspaceScopeConnector()
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        let loop = AgentLoop(router: EngineRouter(ranked: [engine]), hub: hub, stores: stores,
                             retriever: retriever, reporter: ActivityReporter(stores: stores))
        let project = try stores.createWorkspaceProject(title: "Scope example", instructions: "PROJECT_RULES")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Scope chat", purpose: "CHAT_PURPOSE")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local, .claude, .codex], expectedRevision: review.revision)
        let packet = try stores.workspaceContextPacket(chatID: chat.id)
        var finished = false
        for await update in await loop.run(
            history: [ChatMessage(role: .user, content: "THIS_CHAT_HISTORY"),
                      ChatMessage(role: .tool, content: "UNEXPECTED_TOOL_HISTORY_CANARY"),
                      ChatMessage(role: .system, content: "UNEXPECTED_SYSTEM_HISTORY_CANARY")],
            userMessage: "THIS_CHAT_REQUEST", projectTextContext: packet.promptText) {
            if case .finished = update { finished = true }
            if case .failed(let failure) = update { Issue.record("\(failure)") }
        }
        #expect(finished)
        let request = await engine.snapshot()
        let text = request.messages.map(\.content).joined(separator: "\n")
        #expect(request.calls == 1)
        #expect(request.tools.isEmpty)
        for expected in ["PROJECT_RULES", "CHAT_PURPOSE", "THIS_CHAT_HISTORY", "THIS_CHAT_REQUEST"] {
            #expect(text.contains(expected))
        }
        for excluded in ["SHARED_FACT_CANARY", "OLD_MEMORY_CANARY", "OTHER_PROJECT_RETRIEVAL_CANARY",
                         "UNEXPECTED_TOOL_HISTORY_CANARY", "UNEXPECTED_SYSTEM_HISTORY_CANARY"] {
            #expect(!text.contains(excluded))
        }
        #expect(await retriever.callCount() == 0)
        let counts = await connector.counts()
        #expect(counts.catalogReads == 0)
        #expect(counts.executions == 0)
        #expect(try stores.commandObservations().isEmpty)
        #expect(try stores.commandRoutines().isEmpty)
        let activity = try #require(try stores.activityRuns().first { $0.category == .chat })
        #expect(activity.dataAccess == "Selected project instructions and this chat only")
        #expect(activity.dataDestination == "On-device text response; no tools or shared recall")
    }

    @Test func scopedTurnDoesNotReadUnavailableSharedMemoryTables() async throws {
        let stores = try inMemoryStores()
        try await stores.db.queue.write { db in
            try db.execute(sql: "ALTER TABLE memoryFact RENAME TO unavailableMemoryFact")
            try db.execute(sql: "ALTER TABLE memory RENAME TO unavailableMemory")
        }
        let engine = WorkspaceScopeEngine()
        let loop = AgentLoop(router: EngineRouter(ranked: [engine]), hub: ConnectorHub(stores: stores),
                             stores: stores, retriever: nil)
        var finished = false
        for await update in await loop.run(history: [], userMessage: "Hello", projectTextContext: "") {
            if case .finished = update { finished = true }
            if case .failed(let failure) = update { Issue.record("\(failure)") }
        }
        #expect(finished)
        #expect(await engine.snapshot().calls == 1)
    }

    @Test func fabricatedProjectToolCallFailsBeforeCatalogOrExecution() async throws {
        let stores = try inMemoryStores()
        let engine = WorkspaceScopeEngine(emitsTool: true)
        let connector = WorkspaceScopeConnector()
        let hub = ConnectorHub(stores: stores)
        await hub.register(connector)
        let loop = AgentLoop(router: EngineRouter(ranked: [engine]), hub: hub, stores: stores, retriever: nil)
        var failure: String?
        for await update in await loop.run(history: [], userMessage: "Read something", projectTextContext: "") {
            switch update {
            case .failed(let value): failure = value
            case .toolStarted, .toolFinished, .confirmationRequested, .finished:
                Issue.record("Project tool request reached an action or success path")
            default: break
            }
        }
        #expect(failure?.contains("no action was taken") == true)
        let counts = await connector.counts()
        #expect(counts.catalogReads == 0)
        #expect(counts.executions == 0)
        #expect(await engine.snapshot().calls == 1)
        #expect(try stores.recentActivity().isEmpty)
        #expect(try stores.commandObservations().isEmpty)
    }

    @Test func projectInstructionsAreBoundedAndExplicitlyClipped() {
        let emptyPrompt = AgentLoop.projectSystemPrompt(context: "")
        let oversized = "START_CANARY" + String(repeating: "x", count: 20_000) + "OMITTED_TAIL_CANARY"
        let prompt = AgentLoop.projectSystemPrompt(context: oversized)
        #expect(prompt.count - emptyPrompt.count == AgentLoop.maximumProjectContextCharacters)
        #expect(prompt.contains("START_CANARY"))
        #expect(prompt.contains("clipped at the context limit"))
        #expect(!prompt.contains("OMITTED_TAIL_CANARY"))
        #expect(prompt.contains("no tools, file access, RAG retrieval, shared recall, hidden memory"))
    }

    @Test(arguments: [WorkspaceChatKind.primary, .temporary])
    func projectArchiveAndRetryRetainTranscriptWithoutModelWork(kind: WorkspaceChatKind) async throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic chat", kind: kind)
        try stores.appendMessage(StoredMessage(conversationID: chat.localConversationID,
            role: "user", content: String(repeating: "PROJECT_PRIVATE_CANARY ", count: 20)))
        try stores.setWorkspaceChatArchived(id: chat.id, archived: true)
        let before = try stores.messages(in: chat.localConversationID)
        let engine = WorkspaceScopeEngine()
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)
        let outcome = try await archiver.archiveStoredConversation(id: chat.localConversationID)
        #expect(!outcome.archived)
        #expect(outcome.factsSaved == 0)
        #expect(try await archiver.retryStoredConversations(excluding: [], maxAttempts: 1) == 0)
        let snapshot = await engine.snapshot()
        #expect(snapshot.calls == 0)
        #expect(snapshot.availabilityChecks == 0)
        #expect(try stores.messages(in: chat.localConversationID) == before)
        #expect(try stores.allFacts().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func failedWorkspaceScopeLookupNeverFallsThroughToArchiving() async throws {
        let stores = try inMemoryStores()
        let conversation = Conversation(title: "Synthetic chat")
        try stores.saveConversation(conversation)
        try stores.appendMessage(StoredMessage(conversationID: conversation.id,
            role: "user", content: String(repeating: "PRIVATE_CANARY ", count: 30)))
        try await stores.db.queue.write { db in
            try db.execute(sql: "ALTER TABLE workspaceChat RENAME TO unavailableWorkspaceChat")
        }
        let engine = WorkspaceScopeEngine()
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)
        do {
            _ = try await archiver.archiveStoredConversation(id: conversation.id)
            Issue.record("Failed scope lookup must throw")
        } catch { }
        do {
            _ = try await archiver.retryStoredConversations(excluding: [])
            Issue.record("Failed retry scope lookup must throw")
        } catch { }
        #expect(await engine.snapshot().availabilityChecks == 0)
        #expect(try stores.messages(in: conversation.id).count == 1)
        #expect(try stores.allFacts().isEmpty)
    }

    @Test(arguments: [true, false])
    func assignmentDuringArchiveInferenceDiscardsGlobalResults(retry: Bool) async throws {
        let stores = try inMemoryStores()
        let conversation = Conversation(title: "Synthetic legacy chat")
        try stores.saveConversation(conversation)
        try stores.appendMessage(StoredMessage(conversationID: conversation.id, role: "user",
            content: String(repeating: "PROJECT_PRIVATE_CANARY ", count: 20)))
        let before = try stores.messages(in: conversation.id)
        let fingerprint = ConversationArchiver.fingerprint(of: ConversationArchiver.transcript(from: before))
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let engine = WorkspaceArchiveGate()
        let archiver = ConversationArchiver(router: EngineRouter(ranked: [engine]), stores: stores)
        let task = Task {
            if retry {
                return try await archiver.retryStoredConversations(excluding: [], maxAttempts: 1) > 0
            }
            return try await archiver.archiveStoredConversation(id: conversation.id).archived
        }
        await engine.waitForInference()
        _ = try stores.createWorkspaceChat(projectID: project.id, title: "Now scoped",
                                           existingConversationID: conversation.id)
        await engine.finish()
        #expect(try await !task.value)
        #expect(try stores.messages(in: conversation.id) == before)
        #expect(try stores.allFacts().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
        #expect(try stores.entity(named: "ProjectCanary") == nil)
        #expect(try !stores.hasSeen(connectorID: "archiver", itemID: fingerprint))
    }

    @Test func archiveTransactionRejectsMappedConversationWithoutPartialWrites() throws {
        let stores = try inMemoryStores()
        let project = try stores.createWorkspaceProject(title: "Synthetic project")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Scoped chat")
        let event = ActivityEvent(kind: .conversationArchived, summary: "PROJECT_EPISODE_CANARY")
        let fact = MemoryFact(text: "PROJECT_FACT_CANARY", entitiesText: "ProjectCanary",
                              kind: .biography, source: .extracted)
        #expect(try !stores.archiveConversation(event, fingerprint: "synthetic-scope-fingerprint",
                                                facts: [fact], sourceConversationID: chat.localConversationID))
        #expect(try stores.allFacts().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
        #expect(try stores.entity(named: "ProjectCanary") == nil)
        #expect(try !stores.hasSeen(connectorID: "archiver", itemID: "synthetic-scope-fingerprint"))
    }
}
