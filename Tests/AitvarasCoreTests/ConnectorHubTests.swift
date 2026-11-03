import Foundation
import Testing
import AitvarasCore
import AitvarasStore
@testable import AitvarasAgent

private actor EventTestConnector: Connector {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let tools: [ToolDefinition] = []
    private let stream: AsyncStream<ConnectorEvent>
    private let continuation: AsyncStream<ConnectorEvent>.Continuation
    private let reportedHealth: ConnectorHealth

    init(id: String, health: ConnectorHealth = .ready) {
        self.id = id
        self.displayName = id
        self.reportedHealth = health
        (stream, continuation) = AsyncStream.makeStream(of: ConnectorEvent.self)
    }

    func health() async -> ConnectorHealth { reportedHealth }

    func execute(toolName: String, argumentsJSON: String) async throws -> String { "" }

    func events() -> AsyncStream<ConnectorEvent> { stream }

    func emit(sourceID: String) {
        continuation.yield(ConnectorEvent(
            connectorID: id,
            sourceID: sourceID,
            title: sourceID,
            body: "",
            occurredAt: .now))
    }
}

private actor EventRecorder {
    private var sourceIDs: [String] = []

    func append(_ sourceID: String) {
        sourceIDs.append(sourceID)
    }

    func waitForCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if sourceIDs.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func snapshot() -> [String] { sourceIDs }
}

private actor ActionTestConnector: Connector {
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let tools: [ToolDefinition]
    nonisolated let output: String
    private var calls = 0

    init(
        id: String = "action",
        toolName: String = "send",
        risk: ActionRisk = .confirmable,
        output: String = "sent"
    ) {
        self.id = id
        self.displayName = id
        self.output = output
        tools = [ToolDefinition(
            name: toolName,
            description: "Send something externally",
            parametersJSON: #"{"type":"object"}"#,
            risk: risk)]
    }

    func health() async -> ConnectorHealth { .ready }

    func execute(toolName: String, argumentsJSON: String) async throws -> String {
        calls += 1
        return output
    }

    func events() -> AsyncStream<ConnectorEvent> { AsyncStream { $0.finish() } }

    func callCount() -> Int { calls }
}

@Suite struct ConnectorHubTests {
    @Test func pendingConfirmationQueueHasADurableCeiling() async throws {
        let stores = try inMemoryStores()
        for index in 0..<Stores.maximumPendingSuggestions {
            try stores.saveSuggestion(Suggestion(
                title: "Pending \(index)", detail: "test",
                connectorID: "action", toolName: "send", argumentsJSON: "{}"))
        }
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector()
        await hub.register(connector)

        await #expect(throws: AitvarasStoreError.self) {
            try await hub.execute(
                call: ToolCall(
                    id: "overflow", toolName: "action.send", argumentsJSON: "{}"),
                causedBy: nil, sourceID: nil)
        }

        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().count == Stores.maximumPendingSuggestions)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func oversizedToolArgumentsAreRejectedBeforeStorageOrExecution() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(risk: .read)
        await hub.register(connector)
        let oversized = String(
            repeating: "x", count: ConnectorHub.maximumToolArgumentsBytes + 1)

        await #expect(throws: (any Error).self) {
            try await hub.execute(
                call: ToolCall(
                    id: "oversized", toolName: "action.send",
                    argumentsJSON: oversized),
                causedBy: nil, sourceID: nil)
        }

        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func connectorOutputIsBoundedBeforeReturningToModel() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(
            risk: .read,
            output: String(
                repeating: "z", count: ConnectorHub.maximumToolOutputCharacters + 1_000))
        await hub.register(connector)

        let result = try await hub.execute(
            call: ToolCall(id: "large", toolName: "action.send", argumentsJSON: "{}"),
            causedBy: nil, sourceID: nil)
        guard case .output(let output) = result else {
            Issue.record("Expected bounded connector output")
            return
        }

        #expect(output.hasSuffix("ask a narrower follow-up for more]"))
        #expect(output.count < ConnectorHub.maximumToolOutputCharacters + 100)
        #expect(await connector.callCount() == 1)
    }

    @Test func connectorEventQueueIsFiniteAndPreservesOldestOrder() async throws {
        let pair = ConnectorEventStreams.make(bufferingOldest: 2)
        func event(_ id: String) -> ConnectorEvent {
            ConnectorEvent(
                connectorID: "test", sourceID: id, title: id,
                body: "", occurredAt: .now)
        }

        _ = pair.continuation.yield(event("first"))
        _ = pair.continuation.yield(event("second"))
        let overflow = pair.continuation.yield(event("third"))
        pair.continuation.finish()

        if case .dropped(let dropped) = overflow {
            #expect(dropped.sourceID == "third")
        } else {
            Issue.record("The finite connector queue should drop the newest overflow item")
        }

        var iterator = pair.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let end = await iterator.next()
        #expect(first?.sourceID == "first")
        #expect(second?.sourceID == "second")
        #expect(end == nil)
    }

    @Test func healthSnapshotsIncludeConnectorFailures() async throws {
        let hub = ConnectorHub(stores: try inMemoryStores())
        await hub.register(EventTestConnector(id: "ready"))
        await hub.register(EventTestConnector(
            id: "broken", health: .error(message: "Polling failed")))

        let snapshots = await hub.healthSnapshots()

        #expect(snapshots.map(\.id) == ["broken", "ready"])
        #expect(snapshots.first?.health == .error(message: "Polling failed"))
    }

    @Test func mergedEventsTracksRegistrationsAndRemovalsLive() async throws {
        let hub = ConnectorHub(stores: try inMemoryStores())
        let events = await hub.mergedEvents()
        let recorder = EventRecorder()
        let reader = Task {
            for await event in events {
                await recorder.append(event.sourceID)
            }
        }
        defer { reader.cancel() }

        let old = EventTestConnector(id: "dynamic")
        await hub.register(old)
        await old.emit(sourceID: "old-before-removal")
        #expect(await recorder.waitForCount(1))

        await hub.unregister(id: "dynamic")
        await old.emit(sourceID: "old-after-removal")

        let replacement = EventTestConnector(id: "dynamic")
        await hub.register(replacement)
        await replacement.emit(sourceID: "new-after-registration")
        #expect(await recorder.waitForCount(2))

        #expect(await recorder.snapshot() == ["old-before-removal", "new-after-registration"])
    }

    @Test func suggestionOfferRollsBackWithoutAuditEvent() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        await hub.register(ActionTestConnector())
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_offer_audit
                BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'suggestionOffered'
                BEGIN
                    SELECT RAISE(ABORT, 'injected offer audit failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await hub.execute(
                call: ToolCall(id: "1", toolName: "action.send", argumentsJSON: "{}"),
                causedBy: nil, sourceID: nil)
        }
        #expect(try stores.pendingSuggestions().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func failedApprovalAuditPreventsExternalAction() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector()
        await hub.register(connector)
        let result = try await hub.execute(
            call: ToolCall(id: "1", toolName: "action.send", argumentsJSON: "{}"),
            causedBy: nil, sourceID: nil)
        guard case .awaitingConfirmation(let suggestion) = result else {
            Issue.record("Expected a confirmation card")
            return
        }
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_acceptance_audit
                BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'suggestionAccepted'
                BEGIN
                    SELECT RAISE(ABORT, 'injected acceptance audit failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await hub.executeSuggestion(suggestion)
        }
        #expect(await connector.callCount() == 0)
        #expect(try stores.suggestion(id: suggestion.id)?.status == "pending")
        #expect(try stores.pendingSuggestions().count == 1)
    }

    @Test func completedActionIsNotLeftPendingWhenFinalAuditFails() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector()
        await hub.register(connector)
        let result = try await hub.execute(
            call: ToolCall(id: "1", toolName: "action.send", argumentsJSON: "{}"),
            causedBy: nil, sourceID: nil)
        guard case .awaitingConfirmation(let suggestion) = result else {
            Issue.record("Expected a confirmation card")
            return
        }
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_completion_audit
                BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'toolExecuted'
                BEGIN
                    SELECT RAISE(ABORT, 'injected completion audit failure');
                END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await hub.executeSuggestion(suggestion)
        }
        #expect(await connector.callCount() == 1)
        #expect(try stores.suggestion(id: suggestion.id)?.status == "accepted")
        #expect(try stores.pendingSuggestions().isEmpty)
    }

    @Test func allowedActionAuditFailureReturnsNoRetryWarning() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(risk: .reversibleWrite)
        await hub.register(connector)
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_allowed_action_audit
                BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'toolExecuted'
                BEGIN
                    SELECT RAISE(ABORT, 'injected action audit failure');
                END
                """)
        }

        let result = try await hub.execute(
            call: ToolCall(id: "1", toolName: "action.send", argumentsJSON: "{}"),
            causedBy: nil, sourceID: nil)
        guard case .output(let output) = result else {
            Issue.record("Expected direct output")
            return
        }
        #expect(output.contains("sent"))
        #expect(output.contains("Do not retry"))
        #expect(await connector.callCount() == 1)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func externalContentCannotRunReversibleWritesWithoutApproval() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(
            id: "calendar", toolName: "create_event",
            risk: .reversibleWrite)
        await hub.register(connector)

        let result = try await hub.execute(
            call: ToolCall(
                id: "1", toolName: "calendar.create_event",
                argumentsJSON: "{}"),
            causedBy: UUID(), sourceID: "mail:untrusted-message")

        guard case .awaitingConfirmation(let suggestion) = result else {
            Issue.record("Expected external write to require confirmation")
            return
        }
        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().map(\.id) == [suggestion.id])

        _ = try await hub.executeSuggestion(suggestion)
        #expect(await connector.callCount() == 1)
    }

    @Test func externalProposalStillRequiresApprovalIfToolRiskIsMisdeclared() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(
            id: "calendar", toolName: "create_event", risk: .read)
        await hub.register(connector)

        let result = try await hub.execute(
            call: ToolCall(
                id: "1", toolName: "calendar.create_event",
                argumentsJSON: "{}"),
            causedBy: UUID(), sourceID: "mail:untrusted-message")

        guard case .awaitingConfirmation = result else {
            Issue.record("Expected external origin to override a bad risk label")
            return
        }
        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().count == 1)
    }

    @Test func externalContentCannotUseReadTools() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(risk: .read)
        await hub.register(connector)

        await #expect(throws: (any Error).self) {
            try await hub.execute(
                call: ToolCall(
                    id: "1", toolName: "action.send",
                    argumentsJSON: #"{"query":"secret in URL"}"#),
                causedBy: UUID(), sourceID: "mail:malicious-message")
        }

        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func externalContentCannotPutLinksInActionProposals() async throws {
        let stores = try inMemoryStores()
        let hub = ConnectorHub(stores: stores)
        let connector = ActionTestConnector(
            id: "reminders", toolName: "create_reminder",
            risk: .reversibleWrite)
        await hub.register(connector)

        await #expect(throws: (any Error).self) {
            try await hub.execute(
                call: ToolCall(
                    id: "1", toolName: "reminders.create_reminder",
                    argumentsJSON: #"{"title":"Visit https://evil.test now"}"#),
                causedBy: UUID(), sourceID: "mail:malicious-message")
        }

        #expect(await connector.callCount() == 0)
        #expect(try stores.pendingSuggestions().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }
}
