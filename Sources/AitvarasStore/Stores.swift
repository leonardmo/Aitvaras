import Foundation
import GRDB
import AitvarasCore

extension Notification.Name {
    public static let aitvarasCaptureRecordsChanged = Notification.Name("aitvarasCaptureRecordsChanged")
}

public enum AitvarasStoreError: Error, LocalizedError, Sendable {
    case factNotFound(UUID)
    case factAlreadySuperseded(UUID)
    case questionNotOpen(UUID)
    case invalidMemory(String)
    case invalidTrustedMessageSource(String)
    case pendingSuggestionLimitReached(Int)

    public var errorDescription: String? {
        switch self {
        case .factNotFound(let id):
            "Fact \(id.uuidString) no longer exists."
        case .factAlreadySuperseded(let id):
            "Fact \(id.uuidString) was already superseded. Refresh and edit its current replacement."
        case .questionNotOpen(let id):
            "Question \(id.uuidString) no longer exists or was already answered."
        case .invalidMemory(let reason):
            "Memory was not saved: \(reason)"
        case .invalidTrustedMessageSource(let reason):
            "Sender was not trusted: \(reason)"
        case .pendingSuggestionLimitReached(let limit):
            "There are already \(limit) actions waiting for review. Accept or dismiss some before adding more."
        }
    }
}

/// Typed access layer over AitvarasDatabase. One instance per app, shared.
public struct Stores: Sendable {
    public static let maximumPendingSuggestions = 100
    public let db: AitvarasDatabase

    public init(db: AitvarasDatabase) {
        self.db = db
    }

    // MARK: Activity log

    @discardableResult
    public func record(_ event: ActivityEvent) throws -> ActivityEvent {
        try db.queue.write { try event.insert($0) }
        return event
    }

    /// Commit an activity result and its scheduler watermark together. Used
    /// by background jobs so a run is never marked complete without its audit
    /// entry (or vice versa).
    @discardableResult
    public func record(_ event: ActivityEvent, settingValue value: String,
                       forKey key: String) throws -> ActivityEvent {
        try db.queue.write { dbc in
            try event.insert(dbc)
            try dbc.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
        }
        return event
    }

    /// Accept a polled connector event exactly once. The seen marker, root
    /// audit event, optional classification, and connector cursor share one
    /// transaction, so a failed intake remains replayable on the next poll.
    public func recordIncoming(
        _ event: ActivityEvent,
        recording relatedEvent: ActivityEvent? = nil,
        seenConnectorID: String,
        itemID: String,
        watermark: (key: String, value: Double)? = nil,
        settingValue checkpoint: (key: String, value: String)? = nil,
        observing observation: MessageSourceObservation? = nil
    ) throws -> ActivityEvent? {
        try db.queue.write { dbc in
            let existing = try Bool.fetchOne(
                dbc,
                sql: "SELECT 1 FROM seenItem WHERE connectorID = ? AND itemID = ?",
                arguments: [seenConnectorID, itemID]) ?? false

            if let watermark {
                let current = try String.fetchOne(
                    dbc, sql: "SELECT value FROM kv WHERE key = ?", arguments: [watermark.key])
                    .flatMap(Double.init) ?? -.greatestFiniteMagnitude
                if watermark.value > current {
                    try dbc.execute(
                        sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                        arguments: [watermark.key, String(watermark.value)])
                }
            }
            guard !existing else { return nil }

            try event.insert(dbc)
            if let relatedEvent {
                try relatedEvent.insert(dbc)
            }
            if let observation {
                try Self.upsertMessageSourceObservation(observation, in: dbc)
            }
            try dbc.execute(
                sql: "INSERT INTO seenItem(connectorID, itemID, seenAt) VALUES(?, ?, ?)",
                arguments: [seenConnectorID, itemID, Date.now])
            if let checkpoint {
                try dbc.execute(
                    sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [checkpoint.key, checkpoint.value])
            }
            return event
        }
    }

    // MARK: External message trust

    /// Approval changes routing only. The caller must continue treating all
    /// message text as untrusted data and keep external turns quarantined.
    public func isApprovedMessageSource(_ source: ExternalMessageSource) throws -> Bool {
        guard source.requiresSenderApproval else { return true }
        return try db.queue.read { dbc in
            func exists(
                kind: TrustedMessageSourceKind,
                value: String,
                applicationID: String = ""
            ) throws -> Bool {
                try Bool.fetchOne(
                    dbc,
                    sql: """
                        SELECT 1 FROM trustedMessageSource
                        WHERE kind = ? AND value = ? AND applicationID = ?
                        """,
                    arguments: [kind.rawValue, value, applicationID]) ?? false
            }

            switch source.kind {
            case .email:
                guard source.canApproveExactSender else { return false }
                if try exists(kind: .emailAddress, value: source.identity) { return true }
                guard let domain = source.domain else { return false }
                return try exists(kind: .emailDomain, value: domain)
            case .notification:
                guard source.canApproveExactSender else { return false }
                return try exists(
                    kind: .notificationSender,
                    value: source.identity,
                    applicationID: source.applicationID)
            case .configuredService:
                return true
            }
        }
    }

    @discardableResult
    public func trustMessageSource(
        kind: TrustedMessageSourceKind,
        value rawValue: String,
        applicationID rawApplicationID: String = "",
        label rawLabel: String? = nil
    ) throws -> TrustedMessageSource {
        let value: String
        let applicationID: String
        switch kind {
        case .emailAddress:
            guard let canonical = MessageTrustPolicy.canonicalEmailAddress(rawValue) else {
                throw AitvarasStoreError.invalidTrustedMessageSource(
                    "enter one complete email address.")
            }
            value = canonical
            applicationID = ""
        case .emailDomain:
            guard let canonical = MessageTrustPolicy.canonicalDomain(rawValue) else {
                throw AitvarasStoreError.invalidTrustedMessageSource(
                    "enter one ordinary domain such as example.org.")
            }
            guard !MessageTrustPolicy.isBroadMailboxDomain(canonical) else {
                throw AitvarasStoreError.invalidTrustedMessageSource(
                    "\(canonical) is a shared mailbox provider. Trust individual addresses instead.")
            }
            value = canonical
            applicationID = ""
        case .notificationSender:
            let normalized = MessageTrustPolicy.normalizedNotificationLabel(rawValue)
            let app = String(rawApplicationID.prefix(
                ExternalMessageSource.maximumApplicationIDCharacters))
            guard !normalized.isEmpty, !app.isEmpty else {
                throw AitvarasStoreError.invalidTrustedMessageSource(
                    "notification senders need an exact label and source app.")
            }
            value = normalized
            applicationID = app
        }

        let proposedLabel = MessageTrustPolicy.singleLine(rawLabel ?? rawValue)
        let label = String((proposedLabel.isEmpty ? value : proposedLabel).prefix(
            ExternalMessageSource.maximumDisplayNameCharacters))
        let record = TrustedMessageSource(
            kind: kind,
            value: value,
            applicationID: applicationID,
            label: label)

        return try db.queue.write { dbc in
            try dbc.execute(
                sql: """
                    INSERT INTO trustedMessageSource
                        (id, kind, value, applicationID, label, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(kind, value, applicationID)
                    DO UPDATE SET label = excluded.label
                    """,
                arguments: [record.id, kind.rawValue, value, applicationID,
                            label, record.createdAt])

            switch kind {
            case .emailAddress, .notificationSender:
                try dbc.execute(
                    sql: """
                        DELETE FROM messageSourceObservation
                        WHERE kind = ? AND value = ? AND applicationID = ?
                        """,
                    arguments: [kind.rawValue, value, applicationID])
            case .emailDomain:
                try dbc.execute(
                    sql: """
                        DELETE FROM messageSourceObservation
                        WHERE kind = ? AND domain = ?
                        """,
                    arguments: [TrustedMessageSourceKind.emailAddress.rawValue, value])
            }

            guard let stored = try TrustedMessageSource
                .filter(Column("kind") == kind.rawValue)
                .filter(Column("value") == value)
                .filter(Column("applicationID") == applicationID)
                .fetchOne(dbc) else {
                throw AitvarasStoreError.invalidTrustedMessageSource(
                    "the database did not return the saved rule.")
            }
            return stored
        }
    }

    public func trustedMessageSources() throws -> [TrustedMessageSource] {
        try db.queue.read {
            try TrustedMessageSource
                .order(Column("kind"), Column("label").collating(.localizedCaseInsensitiveCompare))
                .fetchAll($0)
        }
    }

    public func pendingMessageSourceObservations() throws -> [MessageSourceObservation] {
        try db.queue.read {
            try MessageSourceObservation
                .filter(Column("dismissedAt") == nil)
                .order(Column("lastSeenAt").desc)
                .fetchAll($0)
        }
    }

    public func pendingMessageSourceObservationCount() throws -> Int {
        try db.queue.read {
            try MessageSourceObservation
                .filter(Column("dismissedAt") == nil)
                .fetchCount($0)
        }
    }

    public func dismissMessageSourceObservation(_ id: UUID, at: Date = .now) throws {
        try db.queue.write {
            try $0.execute(
                sql: "UPDATE messageSourceObservation SET dismissedAt = ? WHERE id = ?",
                arguments: [at, id])
        }
    }

    public func removeTrustedMessageSource(_ id: UUID) throws {
        _ = try db.queue.write { try TrustedMessageSource.deleteOne($0, key: id) }
    }

    private static func upsertMessageSourceObservation(
        _ observation: MessageSourceObservation,
        in dbc: Database
    ) throws {
        try dbc.execute(
            sql: """
                INSERT INTO messageSourceObservation
                    (id, connectorID, kind, value, applicationID, displayName,
                     domain, canApproveExactSender, firstSeenAt, lastSeenAt,
                     messageCount, dismissedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(kind, value, applicationID) DO UPDATE SET
                    connectorID = excluded.connectorID,
                    displayName = excluded.displayName,
                    domain = excluded.domain,
                    canApproveExactSender = excluded.canApproveExactSender,
                    lastSeenAt = excluded.lastSeenAt,
                    messageCount = messageSourceObservation.messageCount + 1,
                    dismissedAt = NULL
                """,
            arguments: [
                observation.id, observation.connectorID, observation.kind.rawValue,
                observation.value, observation.applicationID, observation.displayName,
                observation.domain, observation.canApproveExactSender,
                observation.firstSeenAt, observation.lastSeenAt,
                observation.messageCount, observation.dismissedAt
            ])
    }

    public func recentActivity(limit: Int = 200) throws -> [ActivityEvent] {
        try db.queue.read {
            try ActivityEvent
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll($0)
        }
    }

    /// Episodes for the nightly consolidator: everything since its last run,
    /// oldest first, capped so one busy day can't blow up the prompt.
    public func activity(since: Date, limit: Int = 300) throws -> [ActivityEvent] {
        try db.queue.read {
            try ActivityEvent
                .filter(Column("timestamp") > since)
                .order(Column("timestamp"))
                .limit(limit)
                .fetchAll($0)
        }
    }

    /// Walk the provenance chain from an event back to its root cause.
    public func provenance(of eventID: UUID) throws -> [ActivityEvent] {
        try db.queue.read { dbc in
            var chain: [ActivityEvent] = []
            var current = try ActivityEvent.fetchOne(dbc, key: eventID)
            while let event = current {
                chain.append(event)
                current = try event.causedBy.flatMap { try ActivityEvent.fetchOne(dbc, key: $0) }
                if chain.count > 50 { break }   // cycle guard
            }
            return chain
        }
    }

    // MARK: Durable urgent-phone outbox

    public func enqueuePhoneNotification(
        _ item: PhoneNotificationOutboxItem, recording event: ActivityEvent
    ) throws {
        try db.queue.write { dbc in
            try event.insert(dbc)
            try item.insert(dbc)
        }
    }

    public func duePhoneNotifications(at date: Date = .now, limit: Int = 20) throws
        -> [PhoneNotificationOutboxItem] {
        try db.queue.read {
            try PhoneNotificationOutboxItem
                .filter(Column("nextAttemptAt") <= date)
                .order(Column("createdAt"))
                .limit(limit)
                .fetchAll($0)
        }
    }

    public func pendingPhoneNotificationCount() throws -> Int {
        try db.queue.read { try PhoneNotificationOutboxItem.fetchCount($0) }
    }

    public func deferPhoneNotification(id: UUID, nextAttemptAt: Date) throws {
        try db.queue.write { dbc in
            try dbc.execute(
                sql: "UPDATE phoneNotificationOutbox SET attempts = attempts + 1, nextAttemptAt = ? WHERE id = ?",
                arguments: [nextAttemptAt, id])
        }
    }

    /// Delivery success and its audit entry commit together. The same method
    /// records an expired/abandoned delivery with a failure event.
    public func finishPhoneNotification(id: UUID, recording event: ActivityEvent) throws {
        try db.queue.write { dbc in
            guard try PhoneNotificationOutboxItem.deleteOne(dbc, key: id) else { return }
            try event.insert(dbc)
        }
    }

    public func deleteAllPhoneNotifications() throws {
        _ = try db.queue.write { try PhoneNotificationOutboxItem.deleteAll($0) }
    }

    // MARK: Memories

    public func saveMemory(_ memory: Memory) throws {
        try db.queue.write { try memory.save($0) }
    }

    public func activeMemories() throws -> [Memory] {
        try db.queue.read {
            try Memory.filter(Column("archived") == false)
                .order(Column("updatedAt").desc)
                .fetchAll($0)
        }
    }

    // MARK: Knowledge — facts (D12 v2, MASTERPLAN §9)

    /// Upsert a fact, keep its FTS row and entity links in sync. Passing
    /// `entityIDs` replaces the fact's links (nil leaves them untouched).
    /// The FTS table keys on `factID` as text (self-consistent); the join
    /// table goes through a GRDB record so its UUID encoding matches the
    /// referenced primary keys (raw `.uuidString` SQL would break the FK).
    public func saveFact(_ fact: MemoryFact, entityIDs: [UUID]? = nil) throws {
        try db.queue.write { dbc in
            try Self.saveFact(fact, entityIDs: entityIDs, in: dbc)
        }
    }

    /// Resolve entity names and persist the fact as one unit. This prevents a
    /// rejected fact write from leaving orphaned People & Things rows behind.
    public func saveFact(_ fact: MemoryFact, entityNames: String?) throws {
        try db.queue.write { dbc in
            let entities = try Self.resolveEntities(names: entityNames, in: dbc)
            var stored = fact
            stored.entitiesText = entities.map(\.name).joined(separator: ", ")
            try Self.saveFact(stored, entityIDs: entities.map(\.id), in: dbc)
        }
    }

    /// Currently-valid, user-visible facts (validTo IS NULL, not quarantined),
    /// strongest first. The always-in-context profile layer and recall
    /// candidate set.
    public func activeFacts(limit: Int? = nil) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            var q = MemoryFact.filter(Column("validTo") == nil)
                .filter(Column("needsReview") == false)
                .order(Column("importance").desc, Column("lastAccessed").desc)
            if let limit { q = q.limit(limit) }
            return try q.fetchAll(dbc)
        }
    }

    /// Quarantined sensitive facts (O7) awaiting user approval in the memory UI.
    public func factsNeedingReview() throws -> [MemoryFact] {
        try db.queue.read {
            try MemoryFact.filter(Column("needsReview") == true)
                .order(Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    /// User approved (or edited) a quarantined fact — release it into use.
    public func approveFact(_ id: UUID) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { return }
            fact.needsReview = false
            try fact.update(dbc)
        }
    }

    public func fact(id: UUID) throws -> MemoryFact? {
        try db.queue.read { try MemoryFact.fetchOne($0, key: id) }
    }

    public func allFacts(includeSuperseded: Bool = true) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            let q = includeSuperseded ? MemoryFact.all() : MemoryFact.filter(Column("validTo") == nil)
            return try q.order(Column("createdAt").desc).fetchAll(dbc)
        }
    }

    /// Invalidate `oldID` as of `at`, pointing it at the fact that replaced it.
    /// The old fact is kept (queryable history), never deleted (MASTERPLAN §8).
    public func supersedeFact(_ oldID: UUID, by newID: UUID?, at: Date = .now) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: oldID) else { return }
            fact.validTo = at
            fact.supersededBy = newID
            try fact.update(dbc)
        }
    }

    /// Insert a corrected fact and supersede its current predecessor in one
    /// transaction. When entity ids are omitted, the predecessor's links are
    /// copied so a UI text correction does not silently disappear from its
    /// People & Things pages.
    public func replaceFact(_ oldID: UUID, with replacement: MemoryFact,
                            entityIDs: [UUID]? = nil, at: Date = .now) throws {
        try db.queue.write { dbc in
            try Self.replaceFact(oldID, with: replacement, entityIDs: entityIDs,
                                 at: at, in: dbc)
        }
    }

    /// Resolve replacement entities inside the correction transaction. Unlike
    /// the id-based overload, nil names explicitly means no entity links.
    public func replaceFact(_ oldID: UUID, with replacement: MemoryFact,
                            entityNames: String?, at: Date = .now) throws {
        try db.queue.write { dbc in
            let entities = try Self.resolveEntities(names: entityNames, in: dbc)
            var stored = replacement
            stored.entitiesText = entities.map(\.name).joined(separator: ", ")
            try Self.replaceFact(oldID, with: stored, entityIDs: entities.map(\.id),
                                 at: at, in: dbc)
        }
    }

    /// Hard-delete a fact — user action only (never automatic).
    public func deleteFact(_ id: UUID) throws {
        try db.queue.write { dbc in
            try dbc.execute(sql: "DELETE FROM factFTS WHERE factID = ?", arguments: [id.uuidString])
            _ = try MemoryFact.deleteOne(dbc, key: id)   // cascades join rows
        }
    }

    /// Bump recency on retrieved facts (decay is on access, not creation).
    public func touchFacts(ids: [UUID], at: Date = .now) throws {
        guard !ids.isEmpty else { return }
        try db.queue.write { dbc in
            for id in ids {
                guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { continue }
                fact.lastAccessed = at
                try fact.update(dbc)
            }
        }
    }

    /// Keyword arm of hybrid recall: BM25 over the fact FTS index.
    public func factKeywordSearch(_ query: String, limit: Int) throws -> [(factID: UUID, score: Double)] {
        let match = Self.ftsQuery(query)
        guard !match.isEmpty else { return [] }
        return try db.queue.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT factID, bm25(factFTS) AS score FROM factFTS
                WHERE factFTS MATCH ? ORDER BY score LIMIT ?
                """, arguments: [match, limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["factID"]) else { return nil }
                return (id, row["score"] as Double? ?? 0)
            }
        }
    }

    /// Facts carrying an embedding, for the vector arm (brute-force cosine —
    /// fine at personal scale, D11). `activeOnly` also excludes quarantined facts.
    public func factsWithEmbeddings(activeOnly: Bool = true) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            var q = MemoryFact.filter(Column("embedding") != nil)
            if activeOnly {
                q = q.filter(Column("validTo") == nil).filter(Column("needsReview") == false)
            }
            return try q.fetchAll(dbc)
        }
    }

    /// Facts saved while the embedder was down (embedding IS NULL) — the
    /// backfill set for `Indexer.embedMissingFacts()`.
    public func factsMissingEmbedding(limit: Int = 500) throws -> [MemoryFact] {
        try db.queue.read {
            try MemoryFact.filter(Column("embedding") == nil).limit(limit).fetchAll($0)
        }
    }

    public func saveFactEmbedding(_ id: UUID, vector: [Float]) throws {
        try db.queue.write { dbc in
            guard var fact = try MemoryFact.fetchOne(dbc, key: id) else { return }
            fact.embeddingVector = vector
            try fact.update(dbc)
        }
    }

    public func facts(ids: [UUID]) throws -> [MemoryFact] {
        try db.queue.read { try MemoryFact.filter(ids.contains(Column("id"))).fetchAll($0) }
    }

    public func factStats() throws -> (total: Int, active: Int, embedded: Int) {
        try db.queue.read { dbc in
            let total = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact") ?? 0
            let active = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact WHERE validTo IS NULL") ?? 0
            let embedded = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM memoryFact WHERE embedding IS NOT NULL") ?? 0
            return (total, active, embedded)
        }
    }

    // MARK: Knowledge — entities

    public func saveEntity(_ entity: MemoryEntity) throws {
        try db.queue.write { try entity.save($0) }
    }

    public func entities() throws -> [MemoryEntity] {
        try db.queue.read { try MemoryEntity.order(Column("name")).fetchAll($0) }
    }

    public func entity(named name: String) throws -> MemoryEntity? {
        try db.queue.read {
            try MemoryEntity.fetchOne(
                $0, sql: "SELECT * FROM memoryEntity WHERE LOWER(name) = LOWER(?) LIMIT 1",
                arguments: [name])
        }
    }

    /// Resolve a comma-separated name list to entities, creating missing ones.
    /// Shared by the memory connector, archiver and consolidator so entity
    /// identity stays case-insensitively unique.
    public func upsertEntities(names: String?) throws -> [MemoryEntity] {
        try db.queue.write { try Self.resolveEntities(names: names, in: $0) }
    }

    public func facts(forEntity entityID: UUID, includeSuperseded: Bool = false) throws -> [MemoryFact] {
        try db.queue.read { dbc in
            let ids = try FactEntityLink.filter(Column("entityID") == entityID)
                .fetchAll(dbc).map(\.factID)
            guard !ids.isEmpty else { return [] }
            var q = MemoryFact.filter(ids.contains(Column("id")))
            if !includeSuperseded { q = q.filter(Column("validTo") == nil) }
            return try q.order(Column("importance").desc).fetchAll(dbc)
        }
    }

    // MARK: Capture sessions (F12)

    public func saveCaptureRecord(_ record: CaptureRecord) throws {
        try db.queue.write { try record.save($0) }
        NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue)
    }

    /// Update a finished capture and append its activity entry atomically.
    /// The caller may already have saved a raw pending transcript; if either
    /// final write fails, that recoverable pending version remains unchanged.
    public func saveCaptureRecord(_ record: CaptureRecord,
                                  recording event: ActivityEvent) throws {
        try db.queue.write { dbc in
            try record.save(dbc)
            try event.insert(dbc)
        }
        NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue)
    }

    public func captureRecords(limit: Int = 50) throws -> [CaptureRecord] {
        try db.queue.read {
            try CaptureRecord.order(Column("startedAt").desc).limit(limit).fetchAll($0)
        }
    }

    /// A summary retry must never resurrect a capture deleted during inference.
    public func updateCaptureRecordIfPresent(_ record: CaptureRecord, recording event: ActivityEvent) throws -> Bool {
        let updated = try db.queue.write { dbc in
            guard try CaptureRecord.exists(dbc, key: record.id) else { return false }
            try record.update(dbc)
            try event.insert(dbc)
            return true
        }
        if updated { NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue) }
        return updated
    }

    public func captureRecord(id: UUID) throws -> CaptureRecord? {
        try db.queue.read { try CaptureRecord.fetchOne($0, key: id) }
    }

    public func deleteCaptureRecord(_ id: UUID) throws {
        let deleted = try db.queue.write { try CaptureRecord.deleteOne($0, key: id) }
        if deleted { NotificationCenter.default.post(name: .aitvarasCaptureRecordsChanged, object: db.queue) }
    }

    // MARK: Knowledge — curiosity queue (MASTERPLAN §11)

    public func saveQuestion(_ question: CuriosityQuestion) throws {
        try Self.validate(question)
        try db.queue.write { try question.save($0) }
    }

    public func openQuestions(limit: Int? = nil) throws -> [CuriosityQuestion] {
        try db.queue.read { dbc in
            var q = CuriosityQuestion.filter(Column("status") == "open")
                .order(Column("expectedValue").desc, Column("createdAt"))
            if let limit { q = q.limit(limit) }
            return try q.fetchAll(dbc)
        }
    }

    public func setQuestionStatus(_ id: UUID, to status: CuriosityQuestion.Status, at: Date = .now) throws {
        try db.queue.write { dbc in
            guard var question = try CuriosityQuestion.fetchOne(dbc, key: id) else { return }
            question.status = status.rawValue
            question.answeredAt = status == .answered ? at : nil
            try question.update(dbc)
        }
    }

    /// Store an answer fact and retire its curiosity question atomically, so
    /// a failed second write cannot leave an open question that creates the
    /// same answer again on retry.
    public func saveAnswer(_ fact: MemoryFact, entityIDs: [UUID],
                           forQuestion questionID: UUID, at: Date = .now) throws {
        try db.queue.write { dbc in
            try Self.saveAnswer(fact, entityIDs: entityIDs, forQuestion: questionID,
                                at: at, in: dbc)
        }
    }

    /// Resolve answer entities in the same transaction that retires the
    /// question, so every durable result succeeds or none of it does.
    public func saveAnswer(_ fact: MemoryFact, entityNames: String?,
                           forQuestion questionID: UUID, at: Date = .now) throws {
        try db.queue.write { dbc in
            let entities = try Self.resolveEntities(names: entityNames, in: dbc)
            var stored = fact
            stored.entitiesText = entities.map(\.name).joined(separator: ", ")
            try Self.saveAnswer(stored, entityIDs: entities.map(\.id),
                                forQuestion: questionID, at: at, in: dbc)
        }
    }

    private static func saveFact(_ fact: MemoryFact, entityIDs: [UUID]?,
                                 in dbc: Database) throws {
        try validate(fact)
        try fact.save(dbc)
        try dbc.execute(sql: "DELETE FROM factFTS WHERE factID = ?",
                        arguments: [fact.id.uuidString])
        try dbc.execute(sql: "INSERT INTO factFTS(factID, text) VALUES(?, ?)",
                        arguments: [fact.id.uuidString, fact.searchText])
        if let entityIDs {
            try FactEntityLink.filter(Column("factID") == fact.id).deleteAll(dbc)
            for entityID in Set(entityIDs) {
                try FactEntityLink(factID: fact.id, entityID: entityID).insert(dbc)
            }
        }
    }

    private static func replaceFact(_ oldID: UUID, with replacement: MemoryFact,
                                    entityIDs: [UUID]?, at: Date,
                                    in dbc: Database) throws {
        guard var old = try MemoryFact.fetchOne(dbc, key: oldID) else {
            throw AitvarasStoreError.factNotFound(oldID)
        }
        guard old.isCurrentlyValid else {
            throw AitvarasStoreError.factAlreadySuperseded(oldID)
        }

        try Self.saveFact(replacement, entityIDs: entityIDs, in: dbc)
        if entityIDs == nil {
            let copied = try FactEntityLink
                .filter(Column("factID") == oldID)
                .fetchAll(dbc)
                .map(\.entityID)
            for entityID in Set(copied) {
                try FactEntityLink(factID: replacement.id, entityID: entityID).insert(dbc)
            }
        }

        old.validTo = at
        old.supersededBy = replacement.id
        try old.update(dbc)
    }

    private static func saveAnswer(_ fact: MemoryFact, entityIDs: [UUID],
                                   forQuestion questionID: UUID, at: Date,
                                   in dbc: Database) throws {
        guard var question = try CuriosityQuestion.fetchOne(dbc, key: questionID),
              question.statusValue == .open else {
            throw AitvarasStoreError.questionNotOpen(questionID)
        }

        try Self.saveFact(fact, entityIDs: entityIDs, in: dbc)
        question.status = CuriosityQuestion.Status.answered.rawValue
        question.answeredAt = at
        try question.update(dbc)
    }

    private static func resolveEntities(names: String?, in dbc: Database) throws -> [MemoryEntity] {
        guard let names else { return [] }
        guard names.count <= MemoryFact.maximumEntitiesCharacters else {
            throw AitvarasStoreError.invalidMemory(
                "the People & Things field is longer than \(MemoryFact.maximumEntitiesCharacters.formatted()) characters.")
        }
        let parsedNames = names.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parsedNames.count <= MemoryFact.maximumEntityCount else {
            throw AitvarasStoreError.invalidMemory(
                "a fact can reference at most \(MemoryFact.maximumEntityCount) People & Things entries.")
        }
        guard parsedNames.allSatisfy({ $0.count <= MemoryEntity.maximumNameCharacters }) else {
            throw AitvarasStoreError.invalidMemory(
                "a People & Things name is longer than \(MemoryEntity.maximumNameCharacters) characters.")
        }
        var result: [MemoryEntity] = []
        var resolvedIDs: Set<UUID> = []
        for name in parsedNames {
            let entity: MemoryEntity
            if let existing = try MemoryEntity.fetchOne(
                dbc, sql: "SELECT * FROM memoryEntity WHERE LOWER(name) = LOWER(?) LIMIT 1",
                arguments: [name]) {
                entity = existing
            } else {
                entity = MemoryEntity(name: name)
                try entity.insert(dbc)
            }
            if resolvedIDs.insert(entity.id).inserted {
                result.append(entity)
            }
        }
        return result
    }

    private static func validate(_ fact: MemoryFact) throws {
        guard !fact.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AitvarasStoreError.invalidMemory("a fact cannot be empty.")
        }
        guard fact.text.count <= MemoryFact.maximumTextCharacters else {
            throw AitvarasStoreError.invalidMemory(
                "a fact is longer than \(MemoryFact.maximumTextCharacters.formatted()) characters.")
        }
        guard fact.entitiesText.count <= MemoryFact.maximumEntitiesCharacters else {
            throw AitvarasStoreError.invalidMemory(
                "the People & Things field is longer than \(MemoryFact.maximumEntitiesCharacters.formatted()) characters.")
        }
        let names = fact.entitiesText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard names.count <= MemoryFact.maximumEntityCount else {
            throw AitvarasStoreError.invalidMemory(
                "a fact can reference at most \(MemoryFact.maximumEntityCount) People & Things entries.")
        }
        guard names.allSatisfy({ $0.count <= MemoryEntity.maximumNameCharacters }) else {
            throw AitvarasStoreError.invalidMemory(
                "a People & Things name is longer than \(MemoryEntity.maximumNameCharacters) characters.")
        }
    }

    private static func validate(_ question: CuriosityQuestion) throws {
        guard !question.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AitvarasStoreError.invalidMemory("a curiosity question cannot be empty.")
        }
        guard question.text.count <= CuriosityQuestion.maximumTextCharacters else {
            throw AitvarasStoreError.invalidMemory(
                "a curiosity question is longer than \(CuriosityQuestion.maximumTextCharacters.formatted()) characters.")
        }
        guard question.motivation.count <= CuriosityQuestion.maximumMotivationCharacters else {
            throw AitvarasStoreError.invalidMemory(
                "a question explanation is longer than \(CuriosityQuestion.maximumMotivationCharacters.formatted()) characters.")
        }
    }

    // MARK: Key-value settings (non-secret; secrets go to KeychainStore)

    public func setValue(_ value: String, forKey key: String) throws {
        try db.queue.write {
            try $0.execute(sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, value])
        }
    }

    public func setValues(_ values: [String: String]) throws {
        guard !values.isEmpty else { return }
        try db.queue.write { dbc in
            for (key, value) in values {
                try dbc.execute(
                    sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value])
            }
        }
    }

    public func value(forKey key: String) throws -> String? {
        try db.queue.read {
            try String.fetchOne($0, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    // MARK: Conversations

    public func saveConversation(_ c: Conversation) throws {
        try db.queue.write { try c.save($0) }
    }

    /// Resolve a long-lived named conversation and its kv pointer in one
    /// transaction. Stale/corrupt pointers are replaced instead of causing
    /// every subsequent message insert to fail its foreign key.
    public func persistentConversationID(forKey key: String, title: String) throws -> UUID {
        try db.queue.write { dbc in
            if let raw = try String.fetchOne(
                dbc, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]),
               let id = UUID(uuidString: raw),
               try Conversation.fetchOne(dbc, key: id) != nil {
                return id
            }

            let conversation = Conversation(title: title)
            try conversation.insert(dbc)
            try dbc.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, conversation.id.uuidString])
            return conversation.id
        }
    }

    /// Start a fresh named conversation and move its durable pointer as one
    /// unit. If the pointer write fails, the new empty conversation is rolled
    /// back and callers can safely keep displaying the old one.
    public func rotatePersistentConversation(forKey key: String, title: String) throws -> UUID {
        try db.queue.write { dbc in
            let conversation = Conversation(title: title)
            try conversation.insert(dbc)
            try dbc.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, conversation.id.uuidString])
            return conversation.id
        }
    }

    public func conversations() throws -> [Conversation] {
        try db.queue.read {
            try Conversation.order(Column("updatedAt").desc).fetchAll($0)
        }
    }

    public func conversation(id: UUID) throws -> Conversation? {
        try db.queue.read { try Conversation.fetchOne($0, key: id) }
    }

    public func appendMessage(_ m: StoredMessage) throws {
        try db.queue.write { dbc in
            try m.insert(dbc)
            let now = Date.now
            try dbc.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?",
                            arguments: [now, m.conversationID])
            try dbc.execute(sql: """
                UPDATE workspaceChat SET lastActivityAt = ?
                WHERE localConversationID = ? AND lastActivityAt < ?
                """, arguments: [now, m.conversationID, now])
        }
    }

    /// Append a logical exchange as one unit. A missing conversation or any
    /// other failed message rolls the whole turn back, avoiding half a voice
    /// exchange in History.
    public func appendMessages(_ messages: [StoredMessage]) throws {
        guard !messages.isEmpty else { return }
        try db.queue.write { dbc in
            for message in messages {
                try message.insert(dbc)
            }
            let now = Date.now
            for conversationID in Set(messages.map(\.conversationID)) {
                try dbc.execute(sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?",
                                arguments: [now, conversationID])
                try dbc.execute(sql: """
                    UPDATE workspaceChat SET lastActivityAt = ?
                    WHERE localConversationID = ? AND lastActivityAt < ?
                    """, arguments: [now, conversationID, now])
            }
        }
    }

    public func messages(in conversationID: UUID, limit: Int? = nil) throws -> [StoredMessage] {
        try db.queue.read {
            let base = StoredMessage.filter(Column("conversationID") == conversationID)
            guard let limit else {
                return try base.order(Column("createdAt"), Column("id")).fetchAll($0)
            }
            guard limit > 0 else { return [] }
            return try Array(base
                .order(Column("createdAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll($0)
                .reversed())
        }
    }

    public func messageCount(in conversationID: UUID) throws -> Int {
        try db.queue.read {
            try StoredMessage.filter(Column("conversationID") == conversationID)
                .fetchCount($0)
        }
    }

    /// Recent messages across rotated sessions with the same title, used by
    /// bounded history surfaces. Archiving still reads each full transcript.
    public func recentMessages(conversationTitle title: String, limit: Int) throws
        -> [StoredMessage] {
        guard limit > 0 else { return [] }
        return try db.queue.read { dbc in
            let rows = try StoredMessage.fetchAll(dbc, sql: """
                SELECT storedMessage.* FROM storedMessage
                JOIN conversation ON conversation.id = storedMessage.conversationID
                WHERE conversation.title = ?
                ORDER BY storedMessage.createdAt DESC, storedMessage.id DESC
                LIMIT ?
                """, arguments: [title, limit])
            return Array(rows.reversed())
        }
    }

    public func messageCount(conversationTitle title: String) throws -> Int {
        try db.queue.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM storedMessage
                JOIN conversation ON conversation.id = storedMessage.conversationID
                WHERE conversation.title = ?
                """, arguments: [title]) ?? 0
        }
    }

    public func deleteConversation(_ id: UUID) throws {
        _ = try db.queue.write { try Conversation.deleteOne($0, key: id) }
    }

    // MARK: Seen items (dedup for mail/moodle polling)

    /// Returns true if the item was newly marked (i.e. not seen before).
    public func markSeen(connectorID: String, itemID: String) throws -> Bool {
        try db.queue.write { dbc in
            let existing = try Bool.fetchOne(
                dbc,
                sql: "SELECT 1 FROM seenItem WHERE connectorID = ? AND itemID = ?",
                arguments: [connectorID, itemID]) ?? false
            if existing { return false }
            try dbc.execute(sql: "INSERT INTO seenItem(connectorID, itemID, seenAt) VALUES(?, ?, ?)",
                            arguments: [connectorID, itemID, Date.now])
            return true
        }
    }

    public func hasSeen(connectorID: String, itemID: String) throws -> Bool {
        try db.queue.read { dbc in
            try Bool.fetchOne(
                dbc,
                sql: "SELECT 1 FROM seenItem WHERE connectorID = ? AND itemID = ?",
                arguments: [connectorID, itemID]) ?? false
        }
    }

    /// Persist every durable result of conversation archiving as one unit.
    /// The dedup fingerprint is deliberately written last: if the episode,
    /// any entity, fact, FTS row, or link fails, SQLite rolls everything back
    /// and the transcript remains eligible for a later retry.
    @discardableResult
    public func archiveConversation(_ event: ActivityEvent, fingerprint: String,
                                    facts: [MemoryFact], sourceConversationID: UUID? = nil) throws -> Bool {
        try db.queue.write { dbc in
            // Serialize scope validation with the archive write and workspace
            // assignment. A chat moved during inference must not leak its
            // episode or facts into shared memory (nor consume its fingerprint).
            if let sourceConversationID {
                guard try Conversation.fetchOne(dbc, key: sourceConversationID) != nil,
                      try WorkspaceChat.filter(Column("localConversationID") == sourceConversationID)
                        .fetchOne(dbc) == nil else { return false }
            }
            let existing = try Bool.fetchOne(
                dbc,
                sql: "SELECT 1 FROM seenItem WHERE connectorID = ? AND itemID = ?",
                arguments: ["archiver", fingerprint]) ?? false
            guard !existing else { return false }

            try event.insert(dbc)
            for fact in facts {
                try Self.validate(fact)
                let entityIDs = Set(try Self.resolveEntities(
                    names: fact.entitiesText, in: dbc).map(\.id))

                try fact.insert(dbc)
                try dbc.execute(
                    sql: "INSERT INTO factFTS(factID, text) VALUES(?, ?)",
                    arguments: [fact.id.uuidString, fact.searchText])
                for entityID in entityIDs {
                    try FactEntityLink(factID: fact.id, entityID: entityID).insert(dbc)
                }
            }
            try dbc.execute(
                sql: "INSERT INTO seenItem(connectorID, itemID, seenAt) VALUES(?, ?, ?)",
                arguments: ["archiver", fingerprint, Date.now])
            return true
        }
    }

    // MARK: Held focus notifications

    /// Queue a focus update with its audit event as one durable operation.
    public func holdNotification(_ notification: HeldNotification,
                                 recording event: ActivityEvent) throws {
        try db.queue.write { dbc in
            try notification.insert(dbc)
            try event.insert(dbc)
        }
    }

    public func heldNotifications() throws -> [HeldNotification] {
        try db.queue.read {
            try HeldNotification.order(Column("createdAt")).fetchAll($0)
        }
    }

    /// A briefing is allowed to clear only the exact rows it displayed. New
    /// updates that arrive while the briefing is composed remain queued.
    public func clearHeldNotifications(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        _ = try db.queue.write {
            try HeldNotification.filter(ids.contains(Column("id"))).deleteAll($0)
        }
    }

    // MARK: Goals

    public func goals(day: String) throws -> [Goal] {
        try db.queue.read {
            try Goal.filter(Column("day") == day).order(Column("createdAt")).fetchAll($0)
        }
    }

    public func saveGoal(_ goal: Goal) throws {
        try db.queue.write { try goal.save($0) }
    }

    @discardableResult
    public func setGoalDone(_ id: UUID, done: Bool) throws -> Bool {
        try db.queue.write { dbc in
            guard var goal = try Goal.fetchOne(dbc, key: id) else { return false }
            goal.done = done
            try goal.update(dbc)
            return true
        }
    }

    @discardableResult
    public func deleteGoal(_ id: UUID) throws -> Bool {
        try db.queue.write { try Goal.deleteOne($0, key: id) }
    }

    // MARK: Suggestions

    public func saveSuggestion(_ s: Suggestion) throws {
        try db.queue.write { try s.save($0) }
    }

    /// Store a confirmation card and the matching audit event together.
    public func offerSuggestion(_ suggestion: Suggestion, recording event: ActivityEvent) throws {
        try db.queue.write { dbc in
            let pending = try Suggestion.filter(Column("status") == "pending")
                .fetchCount(dbc)
            guard pending < Self.maximumPendingSuggestions else {
                throw AitvarasStoreError.pendingSuggestionLimitReached(
                    Self.maximumPendingSuggestions)
            }
            try suggestion.insert(dbc)
            try event.insert(dbc)
        }
    }

    public func pendingSuggestions() throws -> [Suggestion] {
        try db.queue.read {
            try Suggestion.filter(Column("status") == "pending")
                .order(Column("createdAt").desc)
                .fetchAll($0)
        }
    }

    public func updateSuggestionStatus(_ id: UUID, to status: String) throws {
        try db.queue.write {
            try $0.execute(sql: "UPDATE suggestion SET status = ? WHERE id = ?", arguments: [status, id])
        }
    }

    public func suggestion(id: UUID) throws -> Suggestion? {
        try db.queue.read { try Suggestion.fetchOne($0, key: id) }
    }

    /// Compare-and-set a suggestion state and append its audit event in one
    /// transaction. A false result means another click or task already moved
    /// the card, so callers must not execute its side effect again.
    @discardableResult
    public func transitionSuggestion(_ id: UUID, from expectedStatus: String,
                                     to status: String, recording event: ActivityEvent) throws -> Bool {
        try db.queue.write { dbc in
            guard var suggestion = try Suggestion.fetchOne(dbc, key: id),
                  suggestion.status == expectedStatus else { return false }
            suggestion.status = status
            try suggestion.update(dbc)
            try event.insert(dbc)
            return true
        }
    }

    // MARK: RAG

    public func upsertDocument(_ doc: RAGDocument, chunks: [RAGChunk]) throws {
        try db.queue.write { dbc in
            // Replace any previous version of this path entirely.
            if let old = try RAGDocument.filter(Column("path") == doc.path).fetchOne(dbc) {
                let oldChunkIDs = try UUID.fetchAll(
                    dbc, sql: "SELECT id FROM ragChunk WHERE documentID = ?", arguments: [old.id])
                for cid in oldChunkIDs {
                    try dbc.execute(
                        sql: "DELETE FROM ragFTS WHERE chunkID = ?", arguments: [cid.uuidString])
                }
                try old.delete(dbc)   // cascades to chunks
            }
            try doc.insert(dbc)
            for chunk in chunks {
                try chunk.insert(dbc)
                try dbc.execute(sql: "INSERT INTO ragFTS(chunkID, text) VALUES(?, ?)",
                                arguments: [chunk.id.uuidString, chunk.text])
            }
        }
    }

    public func removeDocument(path: String) throws {
        try db.queue.write { dbc in
            guard let doc = try RAGDocument.filter(Column("path") == path).fetchOne(dbc) else { return }
            let chunkIDs = try UUID.fetchAll(
                dbc, sql: "SELECT id FROM ragChunk WHERE documentID = ?", arguments: [doc.id])
            for cid in chunkIDs {
                try dbc.execute(
                    sql: "DELETE FROM ragFTS WHERE chunkID = ?", arguments: [cid.uuidString])
            }
            try doc.delete(dbc)
        }
    }

    /// Persist a source-list change and remove every indexed artifact for the
    /// deleted source in one transaction. A failure leaves both the old
    /// configuration and its searchable content intact, so the UI never
    /// claims a half-completed removal.
    public func setValue(_ value: String, forKey key: String,
                         removingRAGDocumentsFrom source: String) throws {
        try db.queue.write { dbc in
            try dbc.execute(
                sql: "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key, value])
            let chunkIDs = try UUID.fetchAll(dbc, sql: """
                SELECT ragChunk.id
                FROM ragChunk
                JOIN ragDocument ON ragDocument.id = ragChunk.documentID
                WHERE ragDocument.source = ?
                """, arguments: [source])
            for chunkID in chunkIDs {
                try dbc.execute(
                    sql: "DELETE FROM ragFTS WHERE chunkID = ?", arguments: [chunkID.uuidString])
            }
            try dbc.execute(sql: "DELETE FROM ragDocument WHERE source = ?", arguments: [source])
        }
    }

    public func document(path: String) throws -> RAGDocument? {
        try db.queue.read { try RAGDocument.filter(Column("path") == path).fetchOne($0) }
    }

    public func allDocuments(source: String? = nil) throws -> [RAGDocument] {
        try db.queue.read {
            var q = RAGDocument.all()
            if let source { q = q.filter(Column("source") == source) }
            return try q.fetchAll($0)
        }
    }

    /// Keyword arm of hybrid retrieval: BM25 over FTS5.
    public func keywordSearch(_ query: String, limit: Int) throws -> [(chunkID: UUID, score: Double)] {
        try db.queue.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT chunkID, bm25(ragFTS) AS score FROM ragFTS
                WHERE ragFTS MATCH ? ORDER BY score LIMIT ?
                """, arguments: [Self.ftsQuery(query), limit])
            return rows.compactMap { row in
                guard let id = UUID(uuidString: row["chunkID"]) else { return nil }
                return (id, row["score"] as Double? ?? 0)
            }
        }
    }

    /// All chunks with embeddings, for the vector arm (brute-force cosine —
    /// fine for personal corpus sizes; see D11).
    public func chunksWithEmbeddings() throws -> [RAGChunk] {
        try db.queue.read {
            try RAGChunk.filter(Column("embedding") != nil).fetchAll($0)
        }
    }

    public func chunks(ids: [UUID]) throws -> [RAGChunk] {
        try db.queue.read { try RAGChunk.filter(ids.contains(Column("id"))).fetchAll($0) }
    }

    public func chunkStats() throws -> (documents: Int, chunks: Int, embedded: Int) {
        try db.queue.read { dbc in
            let d = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragDocument") ?? 0
            let c = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragChunk") ?? 0
            let e = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM ragChunk WHERE embedding IS NOT NULL") ?? 0
            return (d, c, e)
        }
    }

    /// FTS5 treats many characters as syntax; quote each term.
    static func ftsQuery(_ raw: String) -> String {
        raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }
}
