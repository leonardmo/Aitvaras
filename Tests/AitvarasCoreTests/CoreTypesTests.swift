import Testing
import Foundation
@testable import AitvarasCore
import AitvarasStore

@Test func voiceNewsRequestsUseTheHighQualityChatTier() {
    #expect(VoiceModelRouting.tier(for: "Open my news feed") == .chat)
    #expect(VoiceModelRouting.tier(for: "Was sind die heutigen Nachrichten?") == .chat)
    #expect(VoiceModelRouting.tier(for: "Create a reminder") == .voice)
}

@Test func wakeCatchUpBoundIsFiniteAndDisclosesTruncation() {
    let exact = Array(0..<ConnectorEventStreams.maximumWakeCatchUpEvents)
    let exactBatch = ConnectorEventStreams.boundedWakeCatchUp(exact)
    #expect(exactBatch.items == exact)
    #expect(!exactBatch.wasLimited)

    let flooded = Array(0..<(ConnectorEventStreams.maximumWakeCatchUpEvents + 25))
    let bounded = ConnectorEventStreams.boundedWakeCatchUp(flooded)
    #expect(bounded.items == exact)
    #expect(bounded.wasLimited)
}

@Test func activityEventProvenanceChain() {
    let mailArrived = ActivityEvent(
        kind: .eventReceived,
        connectorID: "mail",
        summary: "Mail from prof@example.edu",
        sourceID: "message-id-123"
    )
    let classified = ActivityEvent(
        kind: .classification,
        summary: "urgent, actionable",
        causedBy: mailArrived.id,
        sourceID: mailArrived.sourceID
    )
    #expect(classified.causedBy == mailArrived.id)
    #expect(classified.sourceID == "message-id-123")
}

@Test func activityEventRoundTripsThroughJSON() throws {
    let event = ActivityEvent(kind: .toolExecuted, connectorID: "calendar", summary: "Created event")
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(ActivityEvent.self, from: data)
    #expect(decoded == event)
}

@Test func actionRiskIsStableInSerializedForm() throws {
    // Risk levels are persisted in the activity log and tool definitions;
    // their raw values must not drift.
    #expect(ActionRisk.read.rawValue == "read")
    #expect(ActionRisk.reversibleWrite.rawValue == "reversibleWrite")
    #expect(ActionRisk.confirmable.rawValue == "confirmable")
}

@Test func connectorEventIntakeIsBoundedWithoutWeakeningDeduplication() {
    let sharedPrefix = String(repeating: "source", count: 300)
    let connector = String(repeating: "connector", count: 50)
    let first = ConnectorEvent(
        connectorID: connector,
        sourceID: sharedPrefix + "one",
        title: String(repeating: "t", count: 2_000),
        body: String(repeating: "b", count: 10_000),
        occurredAt: .now).boundedForIntake()
    let second = ConnectorEvent(
        connectorID: connector,
        sourceID: sharedPrefix + "two",
        title: "title", body: "body", occurredAt: .now).boundedForIntake()

    #expect(first.connectorID.count == ConnectorEvent.maximumConnectorIDCharacters)
    #expect(first.sourceID.count == ConnectorEvent.maximumSourceIDCharacters)
    #expect(first.title.count == ConnectorEvent.maximumTitleCharacters)
    #expect(first.body.count == ConnectorEvent.maximumBodyCharacters)
    #expect(first.sourceID != second.sourceID)
    #expect(first.sourceID.hasSuffix(
        StableIdentifier.short([sharedPrefix + "one"])))
}

@Test func persistentConversationRepairsStalePointerAtomically() throws {
    let stores = try inMemoryStores()
    let staleID = UUID()
    try stores.setValue(staleID.uuidString, forKey: "conversation.voice")

    let repairedID = try stores.persistentConversationID(
        forKey: "conversation.voice", title: "Voice")
    #expect(repairedID != staleID)
    #expect(try stores.persistentConversationID(
        forKey: "conversation.voice", title: "Voice") == repairedID)
    #expect(try stores.conversations().map(\.id) == [repairedID])
}

@Test func messageBatchRollsBackWholeTurnOnForeignKeyFailure() throws {
    let stores = try inMemoryStores()
    let conversationID = try stores.persistentConversationID(
        forKey: "conversation.voice", title: "Voice")
    let user = StoredMessage(
        conversationID: conversationID, role: "user", content: "Hello")
    let invalidAssistant = StoredMessage(
        conversationID: UUID(), role: "assistant", content: "Hi")

    #expect(throws: (any Error).self) {
        try stores.appendMessages([user, invalidAssistant])
    }
    #expect(try stores.messages(in: conversationID).isEmpty)
}

@Test func rotatingPersistentConversationPreservesOldChatAndMovesPointer() throws {
    let stores = try inMemoryStores()
    let oldID = try stores.persistentConversationID(
        forKey: "chat.conversationID", title: "Chat")
    try stores.appendMessage(StoredMessage(
        conversationID: oldID, role: "user", content: "Keep this"))

    let newID = try stores.rotatePersistentConversation(
        forKey: "chat.conversationID", title: "Chat")

    #expect(newID != oldID)
    #expect(try stores.persistentConversationID(
        forKey: "chat.conversationID", title: "Chat") == newID)
    #expect(try stores.messages(in: oldID).map(\.content) == ["Keep this"])
    #expect(try stores.messages(in: newID).isEmpty)
}

@Test func recentConversationQueriesKeepOnlyTheNewestRowsInDisplayOrder() throws {
    let stores = try inMemoryStores()
    let first = Conversation(title: "Voice")
    let second = Conversation(title: "Voice")
    try stores.saveConversation(first)
    try stores.saveConversation(second)
    for index in 0..<6 {
        try stores.appendMessage(StoredMessage(
            conversationID: index < 3 ? first.id : second.id,
            role: "user", content: "message-\(index)",
            createdAt: Date(timeIntervalSince1970: Double(index))))
    }

    #expect(try stores.messageCount(conversationTitle: "Voice") == 6)
    #expect(try stores.recentMessages(conversationTitle: "Voice", limit: 3)
        .map(\.content) == ["message-3", "message-4", "message-5"])
    #expect(try stores.messages(in: first.id, limit: 2)
        .map(\.content) == ["message-1", "message-2"])
    #expect(try stores.messages(in: first.id, limit: 0).isEmpty)
}

@Test func rotatingPersistentConversationRollsBackWhenPointerWriteFails() throws {
    let stores = try inMemoryStores()
    let oldID = try stores.persistentConversationID(
        forKey: "chat.conversationID", title: "Chat")
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_chat_pointer
            BEFORE UPDATE ON kv
            WHEN NEW.key = 'chat.conversationID'
            BEGIN
                SELECT RAISE(ABORT, 'injected pointer failure');
            END
            """)
    }

    #expect(throws: (any Error).self) {
        try stores.rotatePersistentConversation(
            forKey: "chat.conversationID", title: "Chat")
    }
    #expect(try stores.value(forKey: "chat.conversationID") == oldID.uuidString)
    #expect(try stores.conversations().map(\.id) == [oldID])
}

@Test func incomingEventDedupCommitsWithRootAndWatermark() throws {
    let stores = try inMemoryStores()
    let event = ActivityEvent(
        kind: .eventReceived,
        connectorID: "notifications",
        summary: "A message arrived",
        sourceID: "stable-item")
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_incoming_root
            BEFORE INSERT ON activityEvent
            BEGIN
                SELECT RAISE(ABORT, 'injected intake failure');
            END
            """)
    }

    #expect(throws: (any Error).self) {
        try stores.recordIncoming(
            event,
            seenConnectorID: "notifications",
            itemID: "stable-item",
            watermark: ("notifications.watermark", 42))
    }
    #expect(try stores.value(forKey: "notifications.watermark") == nil)
    #expect(try stores.recentActivity().isEmpty)

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: "DROP TRIGGER reject_incoming_root")
    }
    #expect(try stores.recordIncoming(
        event,
        seenConnectorID: "notifications",
        itemID: "stable-item",
        watermark: ("notifications.watermark", 42))?.id == event.id)
    #expect(try stores.recentActivity().count == 1)
    #expect(try stores.value(forKey: "notifications.watermark") == "42.0")

    // A replay is suppressed, but its later delivery timestamp may safely
    // move the watermark because the root was already durable.
    #expect(try stores.recordIncoming(
        event,
        seenConnectorID: "notifications",
        itemID: "stable-item",
        watermark: ("notifications.watermark", 43)) == nil)
    #expect(try stores.recentActivity().count == 1)
    #expect(try stores.value(forKey: "notifications.watermark") == "43.0")
}

@Test func incomingEventCheckpointRollsBackWithRejectedRoot() throws {
    let stores = try inMemoryStores()
    let key = "trigger.test.status"
    try stores.setValue("running", forKey: key)
    let event = ActivityEvent(
        kind: .eventReceived, connectorID: "test", summary: "Stopped",
        sourceID: "test:status:stable")
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_checkpointed_root
            BEFORE INSERT ON activityEvent
            BEGIN
                SELECT RAISE(ABORT, 'injected intake failure');
            END
            """)
    }

    #expect(throws: (any Error).self) {
        try stores.recordIncoming(
            event, seenConnectorID: "test", itemID: "status:stable",
            settingValue: (key, "stopped"))
    }
    #expect(try stores.value(forKey: key) == "running")
    #expect(try stores.recentActivity().isEmpty)

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: "DROP TRIGGER reject_checkpointed_root")
    }
    #expect(try stores.recordIncoming(
        event, seenConnectorID: "test", itemID: "status:stable",
        settingValue: (key, "stopped"))?.id == event.id)
    #expect(try stores.value(forKey: key) == "stopped")
}

@Test func incomingEventRemainsReplayableWhenClassificationFails() throws {
    let stores = try inMemoryStores()
    let root = ActivityEvent(
        kind: .eventReceived, connectorID: "mail", summary: "New mail",
        sourceID: "mail:message-1")
    let classification = ActivityEvent(
        kind: .classification, connectorID: "mail", summary: "normal: New mail",
        causedBy: root.id, sourceID: root.sourceID)
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_incoming_classification
            BEFORE INSERT ON activityEvent
            WHEN NEW.kind = 'classification'
            BEGIN
                SELECT RAISE(ABORT, 'injected classification failure');
            END
            """)
    }

    #expect(throws: (any Error).self) {
        try stores.recordIncoming(
            root, recording: classification,
            seenConnectorID: "mail", itemID: "message-1")
    }
    #expect(try stores.recentActivity().isEmpty)
    #expect(try !stores.hasSeen(connectorID: "mail", itemID: "message-1"))

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: "DROP TRIGGER reject_incoming_classification")
    }
    #expect(try stores.recordIncoming(
        root, recording: classification,
        seenConnectorID: "mail", itemID: "message-1")?.id == root.id)
    #expect(try stores.recentActivity().count == 2)
    #expect(try stores.hasSeen(connectorID: "mail", itemID: "message-1"))
    #expect(try stores.recordIncoming(
        root, recording: classification,
        seenConnectorID: "mail", itemID: "message-1") == nil)
    #expect(try stores.recentActivity().count == 2)
}

@Test func heldNotificationAndAuditAreAtomicAndSurviveRouterRestart() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aitvaras-held-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("state.sqlite")
    let database = try AitvarasDatabase(url: databaseURL)
    let stores = Stores(db: database)
    let held = HeldNotification(title: "Build finished", body: "The private build passed.")
    let audit = ActivityEvent(
        kind: .notificationSent, connectorID: "focus", summary: "Held for break")
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_held_audit
            BEFORE INSERT ON activityEvent
            BEGIN
                SELECT RAISE(ABORT, 'injected held audit failure');
            END
            """)
    }

    #expect(throws: (any Error).self) {
        try stores.holdNotification(held, recording: audit)
    }
    #expect(try stores.heldNotifications().isEmpty)

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: "DROP TRIGGER reject_held_audit")
    }
    try stores.holdNotification(held, recording: audit)
    try database.queue.close()
    let restartedStores = Stores(db: try AitvarasDatabase(url: databaseURL))
    let restored = try restartedStores.heldNotifications()
    #expect(restored.count == 1)
    #expect(restored.first?.id == held.id)
    #expect(restored.first?.title == held.title)
    #expect(restored.first?.body == held.body)
    #expect(try restartedStores.recentActivity().map(\.id) == [audit.id])

    try restartedStores.clearHeldNotifications(ids: [held.id])
    #expect(try restartedStores.heldNotifications().isEmpty)
}

@Test func urgentPhoneOutboxIsDurableBackedOffAndAuditedAtomically() throws {
    let stores = try inMemoryStores()
    let root = ActivityEvent(kind: .eventReceived, summary: "Urgent event")
    try stores.record(root)
    let queued = ActivityEvent(
        kind: .notificationQueued, connectorID: "telegram",
        summary: "Queued", causedBy: root.id)
    let item = PhoneNotificationOutboxItem(
        text: "Urgent", causedBy: root.id, queueEventID: queued.id)

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_outbox_audit
            BEFORE INSERT ON activityEvent
            WHEN NEW.kind = 'notificationQueued'
            BEGIN
                SELECT RAISE(ABORT, 'injected queue audit failure');
            END
            """)
    }
    #expect(throws: (any Error).self) {
        try stores.enqueuePhoneNotification(item, recording: queued)
    }
    #expect(try stores.pendingPhoneNotificationCount() == 0)

    try stores.db.queue.write { dbc in
        try dbc.execute(sql: "DROP TRIGGER reject_outbox_audit")
    }
    try stores.enqueuePhoneNotification(item, recording: queued)
    #expect(try stores.duePhoneNotifications().map(\.id) == [item.id])

    let later = Date.now.addingTimeInterval(300)
    try stores.deferPhoneNotification(id: item.id, nextAttemptAt: later)
    #expect(try stores.duePhoneNotifications(at: Date.now).isEmpty)
    let deferred = try #require(try stores.duePhoneNotifications(at: later.addingTimeInterval(1)).first)
    #expect(deferred.attempts == 1)

    let sent = ActivityEvent(
        kind: .notificationSent, connectorID: "telegram",
        summary: "Delivered", causedBy: queued.id)
    try stores.finishPhoneNotification(id: item.id, recording: sent)
    #expect(try stores.pendingPhoneNotificationCount() == 0)
    #expect(try stores.provenance(of: sent.id).map(\.id) == [sent.id, queued.id, root.id])

    #expect(PhoneNotificationOutboxItem.retryDelay(afterAttempt: 1) == 60)
    #expect(PhoneNotificationOutboxItem.retryDelay(afterAttempt: 2) == 300)
    #expect(PhoneNotificationOutboxItem.retryDelay(afterAttempt: 3) == 900)
    #expect(PhoneNotificationOutboxItem.retryDelay(afterAttempt: 4) == 3600)
}

@Test func urgentPhoneOutboxDoesNotDisappearWhenCompletionAuditFails() throws {
    let stores = try inMemoryStores()
    let root = ActivityEvent(kind: .eventReceived, summary: "Urgent event")
    try stores.record(root)
    let queued = ActivityEvent(
        kind: .notificationQueued, summary: "Queued", causedBy: root.id)
    let item = PhoneNotificationOutboxItem(
        text: "Urgent", causedBy: root.id, queueEventID: queued.id)
    try stores.enqueuePhoneNotification(item, recording: queued)
    try stores.db.queue.write { dbc in
        try dbc.execute(sql: """
            CREATE TRIGGER reject_outbox_completion
            BEFORE INSERT ON activityEvent
            WHEN NEW.kind = 'notificationSent'
            BEGIN
                SELECT RAISE(ABORT, 'injected completion audit failure');
            END
            """)
    }

    let sent = ActivityEvent(
        kind: .notificationSent, summary: "Delivered", causedBy: queued.id)
    #expect(throws: (any Error).self) {
        try stores.finishPhoneNotification(id: item.id, recording: sent)
    }
    #expect(try stores.pendingPhoneNotificationCount() == 1)
    #expect(try stores.recentActivity().map(\.id).contains(queued.id))
    #expect(!((try stores.recentActivity()).map(\.id).contains(sent.id)))
}

@Test func processLocalPhoneGateBacksOffOnlyTheFailedItem() {
    let now = Date.now
    let first = PhoneNotificationOutboxItem(
        text: "first", causedBy: UUID(), queueEventID: UUID())
    let second = PhoneNotificationOutboxItem(
        text: "second", causedBy: UUID(), queueEventID: UUID())
    var gate = PhoneNotificationAttemptGate()
    gate.suppress(id: first.id, until: now.addingTimeInterval(60))

    #expect(gate.eligible([first, second], now: now).map(\.id) == [second.id])
    #expect(gate.eligible(
        [first, second], now: now.addingTimeInterval(61)).map(\.id) == [first.id, second.id])

    gate.suppress(id: second.id, until: now.addingTimeInterval(120))
    gate.clear(id: second.id)
    #expect(gate.eligible([second], now: now).map(\.id) == [second.id])
}
