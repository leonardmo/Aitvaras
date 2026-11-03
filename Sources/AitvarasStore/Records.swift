import Foundation
import GRDB
import AitvarasCore

extension ActivityEvent: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "activityEvent" }

    public init(row: Row) throws {
        self.init(
            id: row["id"],
            kind: Kind(rawValue: row["kind"]) ?? .toolExecuted,
            timestamp: row["timestamp"],
            connectorID: row["connectorID"],
            summary: row["summary"],
            detailJSON: row["detailJSON"],
            causedBy: row["causedBy"],
            sourceID: row["sourceID"],
            runID: row["runID"]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["kind"] = kind.rawValue
        container["timestamp"] = timestamp
        container["connectorID"] = connectorID
        container["summary"] = summary
        container["detailJSON"] = detailJSON
        container["causedBy"] = causedBy
        container["sourceID"] = sourceID
        container["runID"] = runID
    }
}

/// A long-term memory about the user (D12).
public struct Memory: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var content: String
    public var category: String     // "preference" | "project" | "person" | "fact"
    public var archived: Bool

    public init(id: UUID = UUID(), createdAt: Date = .now, updatedAt: Date = .now,
                content: String, category: String, archived: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.content = content
        self.category = category
        self.archived = archived
    }
}

/// An atomic, typed, entity-tagged fact about the user (MASTERPLAN §9 L2 —
/// the D12 v2 memory layer). Bi-temporal: `validFrom`/`validTo` bound when
/// the fact is true in the world; a superseded fact is invalidated (validTo
/// set, supersededBy pointed at its replacement), never deleted, so history
/// stays queryable ("what did I use to…"). Embedded as fact text + entity
/// names ("fact-augmented keys") into the same sqlite-vec store as RAG.
public struct MemoryFact: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "memoryFact" }
    public static let maximumTextCharacters = 2_000
    public static let maximumEntitiesCharacters = 1_000
    public static let maximumEntityCount = 20

    /// What sort of fact this is (drives retrieval weighting and the
    /// sensitive-kind confirmation gate, O7).
    public enum Kind: String, Sendable, CaseIterable {
        case preference, biography, event, procedure, belief, rhythm
    }

    /// How Aitvaras learned it. `userStated`/`userAnswered` carry the highest
    /// authority in consolidation; `extracted`/`reflected` are model-drafted.
    public enum Source: String, Sendable {
        case userStated = "user_stated"
        case userAnswered = "user_answered"
        case extracted
        case reflected
    }

    public var id: UUID
    public var text: String
    /// Denormalized entity names, joined for embedding + keyword search
    /// (the structured links live in the memoryFactEntity join table).
    public var entitiesText: String
    public var kind: String
    public var importance: Int          // 1–10, LLM-rated at write time
    public var confidence: Double       // 0–1
    public var source: String
    public var createdAt: Date
    public var validFrom: Date
    public var validTo: Date?           // nil = currently valid
    public var supersededBy: UUID?      // the fact that replaced this one
    public var lastAccessed: Date       // recency decay is on access, not creation
    public var sourceEpisodesJSON: String?   // JSON array of ActivityEvent ids (provenance)
    public var embedding: Data?
    /// Sensitive pipeline-extracted facts (O7) are quarantined until the user
    /// approves them in the memory UI: excluded from prompt and recall.
    /// Explicit user statements (`userStated`/`userAnswered`) never quarantine.
    public var needsReview: Bool

    public init(id: UUID = UUID(), text: String, entitiesText: String = "",
                kind: Kind = .biography, importance: Int = 5, confidence: Double = 0.8,
                source: Source = .extracted, createdAt: Date = .now,
                validFrom: Date = .now, validTo: Date? = nil, supersededBy: UUID? = nil,
                lastAccessed: Date = .now, sourceEpisodesJSON: String? = nil,
                embedding: Data? = nil, needsReview: Bool = false) {
        self.id = id
        self.text = text
        self.entitiesText = entitiesText
        self.kind = kind.rawValue
        self.importance = max(1, min(10, importance))
        self.confidence = max(0, min(1, confidence))
        self.source = source.rawValue
        self.createdAt = createdAt
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.lastAccessed = lastAccessed
        self.sourceEpisodesJSON = sourceEpisodesJSON
        self.embedding = embedding
        self.needsReview = needsReview
    }

    public var kindValue: Kind { Kind(rawValue: kind) ?? .biography }
    public var sourceValue: Source { Source(rawValue: source) ?? .extracted }
    public var isCurrentlyValid: Bool { validTo == nil }

    /// Text used for embedding and FTS: the fact plus its entity names.
    public var searchText: String {
        entitiesText.isEmpty ? text : "\(text) [\(entitiesText)]"
    }

    public var embeddingVector: [Float]? {
        get {
            embedding.map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        set {
            embedding = newValue.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        }
    }
}

/// Join row linking a fact to an entity. Kept as a GRDB record (not raw SQL)
/// so its UUID columns encode exactly like the primary keys they reference.
struct FactEntityLink: Codable, Sendable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "memoryFactEntity" }
    var factID: UUID
    var entityID: UUID
}

/// A lightweight entity a fact can reference (person / place / course /
/// system …) with an LLM-maintained one-paragraph summary. No edges, no
/// graph traversal — the "graph-lite" shape (MASTERPLAN §9 L3).
public struct MemoryEntity: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "memoryEntity" }
    public static let maximumNameCharacters = 200

    public enum Kind: String, Sendable, CaseIterable {
        case person, place, course, system, org, other
    }

    public var id: UUID
    public var name: String
    public var kind: String
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind = .other,
                summary: String = "", createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.kind = kind.rawValue
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kindValue: Kind { Kind(rawValue: kind) ?? .other }
}

/// A question Aitvaras wants answered about the user (MASTERPLAN §11). Generated
/// by nightly reflection or live ambiguity capture; surfaced in short bounded
/// Q&A sessions; an answer becomes a `userAnswered` fact and retires it.
public struct CuriosityQuestion: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "curiosityQuestion" }
    public static let maximumTextCharacters = 1_000
    public static let maximumMotivationCharacters = 1_000

    public enum Status: String, Sendable {
        case open, answered, dismissed
    }

    public var id: UUID
    public var text: String
    public var motivation: String       // why Aitvaras wants to know (shown to the user)
    public var expectedValue: Int       // 1–10: how much answering would unblock
    public var status: String
    public var createdAt: Date
    public var answeredAt: Date?

    public init(id: UUID = UUID(), text: String, motivation: String = "",
                expectedValue: Int = 5, status: Status = .open,
                createdAt: Date = .now, answeredAt: Date? = nil) {
        self.id = id
        self.text = text
        self.motivation = motivation
        self.expectedValue = max(1, min(10, expectedValue))
        self.status = status.rawValue
        self.createdAt = createdAt
        self.answeredAt = answeredAt
    }

    public var statusValue: Status { Status(rawValue: status) ?? .open }
}

/// A capture session (F12): transcript + screen notes + summary. While a
/// session is live, a summary-pending version can also be checkpointed here
/// so an app or system failure does not erase a long transcript.
/// Deliberately contains NO media — raw audio/frames are transcribe-and-
/// discard by hard rule; text is all that ever persists.
public struct CaptureRecord: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "captureRecord" }

    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var title: String
    /// Human-readable scope, e.g. "Fenster: Zoom", "Ganzer Bildschirm", "Nur Audio".
    public var scope: String
    /// "none" | "mic" | "system" | "system+mic"
    public var audio: String
    /// The user confirmed all recorded people know and agree (O13).
    public var consentConfirmed: Bool
    public var transcript: String
    public var summary: String
    /// Set while summarization is incomplete or its result could not be
    /// persisted — transcript is still intact and can be retried later.
    public var summaryPending: Bool

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date = .now,
                title: String, scope: String, audio: String,
                consentConfirmed: Bool, transcript: String,
                summary: String = "", summaryPending: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.scope = scope
        self.audio = audio
        self.consentConfirmed = consentConfirmed
        self.transcript = transcript
        self.summary = summary
        self.summaryPending = summaryPending
    }
}

/// Durable outbox entry for an urgent phone push. The event itself is already
/// in the activity log; this small copy exists only until Telegram confirms
/// delivery (or the alert becomes too old to be useful).
public struct PhoneNotificationOutboxItem: Codable, Sendable, Identifiable, Equatable,
                                            FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "phoneNotificationOutbox" }

    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var attempts: Int
    public var nextAttemptAt: Date
    public var causedBy: UUID
    public var sourceID: String?
    public var queueEventID: UUID

    public init(id: UUID = UUID(), text: String, createdAt: Date = .now,
                attempts: Int = 0, nextAttemptAt: Date = .now,
                causedBy: UUID, sourceID: String? = nil, queueEventID: UUID) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.causedBy = causedBy
        self.sourceID = sourceID
        self.queueEventID = queueEventID
    }

    /// 1m, 5m, 15m, then hourly until the six-hour usefulness window ends.
    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: 60
        case 2: 5 * 60
        case 3: 15 * 60
        default: 60 * 60
        }
    }
}

/// Process-local duplicate/backoff guard layered under the durable outbox.
/// It matters only when SQLite cannot save a deferral after an external send;
/// normal retry state always comes from `phoneNotificationOutbox`.
public struct PhoneNotificationAttemptGate: Sendable {
    private var suppressedUntil: [UUID: Date] = [:]

    public init() {}

    public mutating func suppress(id: UUID, until: Date) {
        suppressedUntil[id] = until
    }

    public mutating func clear(id: UUID) {
        suppressedUntil[id] = nil
    }

    public mutating func clearAll() {
        suppressedUntil = [:]
    }

    public mutating func eligible(
        _ items: [PhoneNotificationOutboxItem],
        now: Date = .now
    ) -> [PhoneNotificationOutboxItem] {
        suppressedUntil = suppressedUntil.filter { $0.value > now }
        return items.filter { item in
            guard let until = suppressedUntil[item.id] else { return true }
            return until <= now
        }
    }
}

public struct Conversation: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StoredMessage: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var conversationID: UUID
    public var role: String
    public var content: String
    public var createdAt: Date
    public var metadataJSON: String?

    public init(id: UUID = UUID(), conversationID: UUID, role: String, content: String,
                createdAt: Date = .now, metadataJSON: String? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.metadataJSON = metadataJSON
    }
}

public struct RAGDocument: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var source: String
    public var path: String
    public var mtime: Double
    public var contentHash: String

    public init(id: UUID = UUID(), source: String, path: String, mtime: Double, contentHash: String) {
        self.id = id
        self.source = source
        self.path = path
        self.mtime = mtime
        self.contentHash = contentHash
    }
}

public struct RAGChunk: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var documentID: UUID
    public var ord: Int
    public var text: String
    public var context: String?
    public var embedding: Data?

    public init(id: UUID = UUID(), documentID: UUID, ord: Int, text: String,
                context: String? = nil, embedding: Data? = nil) {
        self.id = id
        self.documentID = documentID
        self.ord = ord
        self.text = text
        self.context = context
        self.embedding = embedding
    }

    public var embeddingVector: [Float]? {
        get {
            embedding.map { data in
                data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            }
        }
        set {
            embedding = newValue.map { v in v.withUnsafeBufferPointer { Data(buffer: $0) } }
        }
    }
}

/// A daily goal, set collaboratively in conversation; the focus coach
/// checks progress against these over the day.
public struct Goal: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var day: String          // "yyyy-MM-dd", local time
    public var text: String
    public var done: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), day: String, text: String, done: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.day = day
        self.text = text
        self.done = done
        self.createdAt = createdAt
    }

    public static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}

/// A non-urgent update deferred until the user's next focus break. Persisted
/// so restarting Aitvaras during a focus session cannot discard it.
public struct HeldNotification: Codable, Sendable, Identifiable, Equatable,
                                FetchableRecord, PersistableRecord {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }
}

/// A pending action card (D5/D13): Aitvaras proposes, the user accepts/rejects.
public struct Suggestion: Codable, Sendable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    public var id: UUID
    public var createdAt: Date
    public var title: String
    public var detail: String
    public var connectorID: String
    public var toolName: String
    public var argumentsJSON: String
    public var status: String   // pending | accepted | rejected | executed | failed
    public var causedBy: UUID?

    public init(id: UUID = UUID(), createdAt: Date = .now, title: String, detail: String,
                connectorID: String, toolName: String, argumentsJSON: String,
                status: String = "pending", causedBy: UUID? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.detail = detail
        self.connectorID = connectorID
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.status = status
        self.causedBy = causedBy
    }
}

/// A sender or exact domain the user has approved for assistant processing.
/// This is a routing preference, not proof of message authenticity.
public struct TrustedMessageSource: Codable, Sendable, Identifiable, Equatable,
                                    FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "trustedMessageSource" }

    public var id: UUID
    public var kind: TrustedMessageSourceKind
    public var value: String
    public var applicationID: String
    public var label: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: TrustedMessageSourceKind,
        value: String,
        applicationID: String = "",
        label: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.applicationID = applicationID
        self.label = label
        self.createdAt = createdAt
    }
}

/// Privacy-minimal review queue: only sender identity and counters are kept;
/// message subjects/bodies are not duplicated into the trust database.
public struct MessageSourceObservation: Codable, Sendable, Identifiable, Equatable,
                                        FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "messageSourceObservation" }

    public var id: UUID
    public var connectorID: String
    public var kind: TrustedMessageSourceKind
    public var value: String
    public var applicationID: String
    public var displayName: String
    public var domain: String?
    public var canApproveExactSender: Bool
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var messageCount: Int
    public var dismissedAt: Date?

    public init?(
        id: UUID = UUID(),
        connectorID: String,
        source: ExternalMessageSource,
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        messageCount: Int = 1,
        dismissedAt: Date? = nil
    ) {
        let kind: TrustedMessageSourceKind
        switch source.kind {
        case .email: kind = .emailAddress
        case .notification: kind = .notificationSender
        case .configuredService: return nil
        }
        self.id = id
        self.connectorID = connectorID
        self.kind = kind
        self.value = source.identity
        self.applicationID = source.applicationID
        self.displayName = source.displayName
        self.domain = source.domain
        self.canApproveExactSender = source.canApproveExactSender
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.messageCount = messageCount
        self.dismissedAt = dismissedAt
    }
}
