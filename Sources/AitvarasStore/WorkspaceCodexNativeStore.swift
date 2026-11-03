import Foundation
import GRDB
import AitvarasCore

public enum WorkspaceCodexNativeError: Error, LocalizedError, Sendable, Equatable {
    case invalidValue, incompleteSnapshot, identityMismatch, staleRevision, reviewRequired
    case linkNotFound, operationNotFound, busyNativeThread, unresolvedOperation, invalidTransition

    public var errorDescription: String? {
        switch self {
        case .invalidValue: "The native observation or operation contains an invalid value."
        case .incompleteSnapshot: "A complete native transcript refresh is required."
        case .identityMismatch: "The native thread, project, host or profile does not match the reviewed relationship."
        case .staleRevision: "The native relationship or observation changed. Reload before continuing."
        case .reviewRequired: "Review this native relationship and its exact effective configuration first."
        case .linkNotFound: "This native relationship no longer exists."
        case .operationNotFound: "This native operation no longer exists."
        case .busyNativeThread: "The native chat is active or its current state is unknown."
        case .unresolvedOperation: "A previous native operation has an unresolved outcome. It will not be replayed."
        case .invalidTransition: "The saved native operation does not permit this state change."
        }
    }
}

public enum WorkspaceCodexNativeThreadState: String, Codable, Sendable {
    case idle, active, notLoaded, systemError, unknown
    public init(nativeValue: String) { self = Self(rawValue: nativeValue) ?? .unknown }
}

public enum WorkspaceCodexNativeTurnState: String, Codable, Sendable {
    case inProgress, completed, interrupted, failed, unknown
    public init(nativeValue: String) { self = Self(rawValue: nativeValue) ?? .unknown }
}

public struct WorkspaceCodexNativeProjection: Sendable, Equatable {
    public let chatLinkID: UUID
    public let revision: Int
    public let snapshot: CodexNativeThreadSnapshot
    public let observedAt: Date
    public var threadState: WorkspaceCodexNativeThreadState { .init(nativeValue: snapshot.status) }
}

/// The current native-ID keyed projection, not an imported or synthetic message.
/// Unknown and partial native states remain explicit; raw variants are retained.
public struct WorkspaceCodexNativeItem: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCodexNativeItem"
    public let chatLinkID: UUID
    public let nativeTurnID: String
    public let nativeItemID: String
    public let turnOrder: Int
    public let itemOrder: Int
    public let kind: String
    public let role: String?
    public let text: String
    public let turnState: WorkspaceCodexNativeTurnState
    public let itemState: WorkspaceCodexNativeTurnState
    public let rawJSON: String
    public let timestamp: Date
    public let firstObservedAt: Date
    public var id: String { "native:\(chatLinkID):\(nativeTurnID.utf8.count):\(nativeTurnID):\(nativeItemID)" }
}

public struct WorkspaceCodexNativeObservation: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let chatLinkID: UUID
    public let hostID: String
    public let profileNamespace: String
    public let nativeThreadID: String
    public let projectionRevision: Int
    public let snapshot: CodexNativeThreadSnapshot
    public let observedAt: Date
}

public enum WorkspaceCodexNativeOperationKind: String, Codable, Sendable {
    case send, rename, archive, restore, move
}

public enum WorkspaceCodexNativeOperationState: String, Codable, Sendable {
    case requested, prepared, deliveryUnknown, acknowledged, completed, failed, interrupted, cancelled
    public var isTerminal: Bool { [.completed, .failed, .interrupted, .cancelled].contains(self) }
}

/// Local durable input is intentionally separate from Activity metadata. Neither
/// this row nor a connection failure authorizes replaying an operation.
public struct WorkspaceCodexNativeOperation: Codable, Sendable, Equatable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCodexNativeOperation"
    public let id: UUID
    public let chatLinkID: UUID
    public let projectID: UUID
    public let chatID: UUID
    public let hostID: String
    public let profileNamespace: String
    public let nativeThreadID: String
    public let kind: WorkspaceCodexNativeOperationKind
    public let state: WorkspaceCodexNativeOperationState
    public let projectRevision: Int
    public let chatRevision: Int
    public let projectionRevision: Int
    public let effectiveConfigurationFingerprint: String?
    public let userMessage: String?
    public let requestedValue: String?
    public let nativeTurnID: String?
    public let cancellationRequestedAt: Date?
    public let failureCode: String?
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let endedAt: Date?
}

public struct WorkspaceCodexNativeOperationEvent: Codable, Sendable, Equatable, FetchableRecord, TableRecord {
    public static let databaseTableName = "workspaceCodexNativeOperationEvent"
    public let operationID: UUID
    public let revision: Int
    public let state: WorkspaceCodexNativeOperationState
    public let timestamp: Date
}

extension Stores {
    public func workspaceCodexNativeProjection(chatLinkID: UUID) throws -> WorkspaceCodexNativeProjection? {
        try db.queue.read { try Self.nativeProjection(chatLinkID: chatLinkID, in: $0) }
    }

    public func workspaceCodexNativeItems(chatID: UUID, completedOnly: Bool = false) throws -> [WorkspaceCodexNativeItem] {
        try db.queue.read { dbc in
            try WorkspaceCodexNativeItem.fetchAll(dbc, sql: """
                SELECT i.* FROM workspaceCodexNativeItem i JOIN workspaceCodexChatLink c ON c.id = i.chatLinkID
                WHERE c.chatID = ? AND (? = 0 OR (i.turnState = 'completed' AND i.itemState = 'completed'))
                ORDER BY i.turnOrder, i.itemOrder, i.nativeTurnID, i.nativeItemID
                """, arguments: [chatID, completedOnly ? 1 : 0])
        }
    }

    /// A complete refresh is one transaction. Missing native items disappear
    /// only from the current projection; immutable historical evidence remains.
    /// nil expectedProjectionRevision means the caller observed no projection.
    @discardableResult
    public func replaceWorkspaceCodexNativeProjection(chatLinkID: UUID, snapshot: CodexNativeThreadSnapshot,
        expectedProjectRevision: Int, expectedChatRevision: Int, expectedProjectionRevision: Int?,
        now: Date = .now) throws -> WorkspaceCodexNativeProjection {
        try Self.validateNativeSnapshot(snapshot)
        let turnOrder = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0.order) })
        let orderedItems = snapshot.items.sorted {
            let lhs = (turnOrder[$0.turnID]!, $0.order, $0.id)
            let rhs = (turnOrder[$1.turnID]!, $1.order, $1.id)
            return lhs < rhs
        }
        let snapshot = CodexNativeThreadSnapshot(id: snapshot.id, name: snapshot.name, projectID: snapshot.projectID,
            cwd: snapshot.cwd, status: snapshot.status, raw: snapshot.raw, turns: snapshot.turns.sorted { $0.order < $1.order },
            items: orderedItems, complete: snapshot.complete, observedAt: snapshot.observedAt)
        return try db.queue.write { dbc in
            let (link, project) = try Self.nativeLinks(chatLinkID: chatLinkID,
                projectRevision: expectedProjectRevision, chatRevision: expectedChatRevision, in: dbc)
            let approved: NativeProjectSnapshot = try Self.nativeDecode(project["approvedSnapshotJSON"])
            guard snapshot.id == link.externalID, snapshot.projectID == approved.identity.externalID,
                  Self.nativeNormalizedPath(snapshot.cwd) == Self.nativeNormalizedPath(link.workingDirectory) else {
                throw WorkspaceCodexNativeError.identityMismatch
            }
            let old = try Self.nativeProjection(chatLinkID: chatLinkID, in: dbc)
            guard old?.revision == expectedProjectionRevision else { throw WorkspaceCodexNativeError.staleRevision }
            let revision = (old?.revision ?? 0) + 1
            let json = try Self.nativeJSON(snapshot)
            let previous = try WorkspaceCodexNativeItem.filter(Column("chatLinkID") == chatLinkID).fetchAll(dbc)
            let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            try dbc.execute(sql: """
                INSERT INTO workspaceCodexNativeProjection(chatLinkID, revision, snapshotJSON, observedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(chatLinkID) DO UPDATE SET revision = excluded.revision,
                    snapshotJSON = excluded.snapshotJSON, observedAt = excluded.observedAt
                """, arguments: [chatLinkID, revision, json, now])
            try dbc.execute(sql: """
                INSERT INTO workspaceCodexNativeObservation
                    (id, chatLinkID, hostID, profileNamespace, nativeThreadID, projectionRevision, snapshotJSON, observedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID(), chatLinkID, link.hostID, link.profileNamespace, link.externalID, revision, json, now])
            try dbc.execute(sql: "DELETE FROM workspaceCodexNativeItem WHERE chatLinkID = ?", arguments: [chatLinkID])
            let turns = Dictionary(uniqueKeysWithValues: snapshot.turns.map { ($0.id, $0) })
            for item in snapshot.items {
                let turn = turns[item.turnID]!
                let key = "native:\(chatLinkID):\(item.turnID.utf8.count):\(item.turnID):\(item.id)"
                let previousItem = previousByID[key]
                let firstObserved = previousItem?.firstObservedAt ?? now
                let turnState = WorkspaceCodexNativeTurnState(nativeValue: turn.status)
                let nativeItem = item.raw["item"] ?? item.raw
                let itemState = nativeItem["status"]?.stringValue.map(WorkspaceCodexNativeTurnState.init(nativeValue:)) ?? turnState
                let (role, text) = Self.nativeMessage(item)
                let timestamp = Self.nativeTimestamp(item.raw) ?? Self.nativeTimestamp(turn.raw) ?? previousItem?.timestamp ?? firstObserved
                try dbc.execute(sql: """
                    INSERT INTO workspaceCodexNativeItem
                        (chatLinkID, nativeTurnID, nativeItemID, turnOrder, itemOrder, kind, role, text,
                         turnState, itemState, rawJSON, timestamp, firstObservedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [chatLinkID, item.turnID, item.id, turn.order, item.order, item.kind, role, text,
                        turnState.rawValue, itemState.rawValue, try Self.nativeJSON(item.raw), timestamp, firstObserved])
            }
            // Reconcile only an immutable, explicitly acknowledged native turn ID.
            // Never guess delivery by matching user text or fabricate native IDs.
            let operations = try WorkspaceCodexNativeOperation.filter(Column("chatLinkID") == chatLinkID)
                .filter(["acknowledged", "deliveryUnknown"].contains(Column("state"))).fetchAll(dbc)
            for operation in operations {
                guard let turnID = operation.nativeTurnID, let turn = turns[turnID] else { continue }
                let state: WorkspaceCodexNativeOperationState?
                switch WorkspaceCodexNativeTurnState(nativeValue: turn.status) {
                case .completed: state = .completed
                case .failed: state = .failed
                case .interrupted: state = .interrupted
                case .inProgress: state = operation.state == .deliveryUnknown ? .acknowledged : nil
                case .unknown: state = nil
                }
                if let state { _ = try Self.nativeTransition(operation, to: state, in: dbc, now: now) }
            }
            return .init(chatLinkID: chatLinkID, revision: revision, snapshot: snapshot, observedAt: now)
        }
    }

    public func workspaceCodexNativeObservations(chatLinkID: UUID, limit: Int = 100) throws -> [WorkspaceCodexNativeObservation] {
        guard limit > 0 else { return [] }
        return try db.queue.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT * FROM workspaceCodexNativeObservation WHERE chatLinkID = ?
                ORDER BY projectionRevision DESC LIMIT ?
                """, arguments: [chatLinkID, min(limit, 1000)]).map { row in
                    try .init(id: row["id"], chatLinkID: row["chatLinkID"], hostID: row["hostID"],
                        profileNamespace: row["profileNamespace"], nativeThreadID: row["nativeThreadID"],
                        projectionRevision: row["projectionRevision"], snapshot: Self.nativeDecode(row["snapshotJSON"]),
                        observedAt: row["observedAt"])
                }
        }
    }

    /// Persist explicit intent before preparing transport. Project membership is
    /// not an execution grant, and the isolated owned-session registry is unused.
    public func requestWorkspaceCodexNativeOperation(chatLinkID: UUID, kind: WorkspaceCodexNativeOperationKind,
        userMessage: String? = nil, requestedValue: String? = nil, expectedProjectRevision: Int,
        expectedChatRevision: Int, expectedProjectionRevision: Int, effectiveConfigurationFingerprint: String? = nil,
        now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        if kind == .send {
            guard let userMessage, !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  userMessage.count <= 200_000, !userMessage.contains("\0"), requestedValue == nil else {
                throw WorkspaceCodexNativeError.invalidValue
            }
            guard let effectiveConfigurationFingerprint else { throw WorkspaceCodexNativeError.reviewRequired }
            try Self.nativeIdentifier(effectiveConfigurationFingerprint, limit: 4096)
        } else {
            guard userMessage == nil, effectiveConfigurationFingerprint == nil else { throw WorkspaceCodexNativeError.invalidValue }
            if [.rename, .move].contains(kind) {
                guard let requestedValue else { throw WorkspaceCodexNativeError.invalidValue }
                try Self.nativeIdentifier(requestedValue, limit: 4096)
            } else if requestedValue != nil { throw WorkspaceCodexNativeError.invalidValue }
        }
        return try db.queue.write { dbc in
            let (link, _) = try Self.nativeReadyLink(chatLinkID: chatLinkID, projectRevision: expectedProjectRevision,
                chatRevision: expectedChatRevision, projectionRevision: expectedProjectionRevision,
                kind: kind, fingerprint: effectiveConfigurationFingerprint, in: dbc)
            guard try !Bool.fetchOne(dbc, sql: """
                SELECT EXISTS(SELECT 1 FROM workspaceCodexNativeOperation WHERE hostID = ? AND profileNamespace = ? AND nativeThreadID = ?
                    AND state NOT IN ('completed','failed','interrupted','cancelled'))
                """, arguments: [link.hostID, link.profileNamespace, link.externalID])! else { throw WorkspaceCodexNativeError.unresolvedOperation }
            let id = UUID()
            try dbc.execute(sql: """
                INSERT INTO workspaceCodexNativeOperation
                    (id, chatLinkID, projectID, chatID, hostID, profileNamespace, nativeThreadID, kind, state,
                     projectRevision, chatRevision, projectionRevision, effectiveConfigurationFingerprint,
                     userMessage, requestedValue, revision, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'requested', ?, ?, ?, ?, ?, ?, 1, ?, ?)
                """, arguments: [id, chatLinkID, link.projectID, link.chatID, link.hostID, link.profileNamespace,
                    link.externalID, kind.rawValue, expectedProjectRevision, expectedChatRevision, expectedProjectionRevision,
                    effectiveConfigurationFingerprint, userMessage, requestedValue, now, now])
            try Self.nativeOperationEvent(id: id, revision: 1, state: .requested, now: now, in: dbc)
            return try Self.nativeOperation(id: id, in: dbc)
        }
    }

    @discardableResult
    public func prepareWorkspaceCodexNativeOperation(id: UUID, expectedRevision: Int,
        now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        try db.queue.write { dbc in
            let old = try Self.nativeOperation(id: id, expectedRevision: expectedRevision, in: dbc)
            guard old.state == .requested else { throw WorkspaceCodexNativeError.invalidTransition }
            try Self.nativeRevalidateOperation(old, in: dbc)
            return try Self.nativeTransition(old, to: .prepared, in: dbc, now: now)
        }
    }

    /// This commit MUST succeed before invoking transport, once only. A transport,
    /// monitoring or persistence failure after this point must never resend input.
    @discardableResult
    public func beginWorkspaceCodexNativeDelivery(id: UUID, expectedRevision: Int,
        now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        try db.queue.write { dbc in
            let old = try Self.nativeOperation(id: id, expectedRevision: expectedRevision, in: dbc)
            guard old.state == .prepared else { throw WorkspaceCodexNativeError.invalidTransition }
            try Self.nativeRevalidateOperation(old, in: dbc)
            return try Self.nativeTransition(old, to: .deliveryUnknown, in: dbc, now: now)
        }
    }

    /// Bind only native response evidence. A bound turn ID can never be reassigned.
    @discardableResult
    public func acknowledgeWorkspaceCodexNativeOperation(id: UUID, nativeTurnID: String? = nil,
        expectedRevision: Int, now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        if let nativeTurnID { try Self.nativeIdentifier(nativeTurnID) }
        return try db.queue.write { dbc in
            let old = try Self.nativeOperation(id: id, expectedRevision: expectedRevision, in: dbc)
            guard [.deliveryUnknown, .acknowledged].contains(old.state),
                  old.kind != .send || nativeTurnID != nil,
                  old.kind == .send || nativeTurnID == nil,
                  old.nativeTurnID == nil || old.nativeTurnID == nativeTurnID else {
                throw WorkspaceCodexNativeError.invalidTransition
            }
            if old.state == .acknowledged && old.nativeTurnID == nativeTurnID { return old }
            try dbc.execute(sql: "UPDATE workspaceCodexNativeOperation SET nativeTurnID = ? WHERE id = ?",
                arguments: [nativeTurnID, id])
            return try Self.nativeTransition(old, to: .acknowledged, in: dbc, now: now)
        }
    }

    /// A local stop request is not a completed or cancelled provider operation.
    /// The caller may interrupt a known native turn only after this is durable.
    @discardableResult
    public func requestWorkspaceCodexNativeCancellation(id: UUID, expectedRevision: Int,
        now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        try db.queue.write { dbc in
            let old = try Self.nativeOperation(id: id, expectedRevision: expectedRevision, in: dbc)
            guard !old.state.isTerminal else { throw WorkspaceCodexNativeError.invalidTransition }
            if old.cancellationRequestedAt != nil { return old }
            try dbc.execute(sql: "UPDATE workspaceCodexNativeOperation SET cancellationRequestedAt = ? WHERE id = ?",
                arguments: [max(now, old.createdAt), id])
            let state: WorkspaceCodexNativeOperationState = [.requested, .prepared].contains(old.state) ? .cancelled : old.state
            return try Self.nativeTransition(old, to: state, in: dbc, now: now)
        }
    }

    /// Terminal provider outcomes require explicit confirmation. Local monitoring
    /// failure is deliveryUnknown, not failed/completed/cancelled. Codes only: do
    /// not put prompts, provider output or raw errors into Activity metadata.
    @discardableResult
    public func finishWorkspaceCodexNativeOperation(id: UUID, state: WorkspaceCodexNativeOperationState,
        expectedRevision: Int, providerConfirmed: Bool = false, failureCode: String? = nil,
        now: Date = .now) throws -> WorkspaceCodexNativeOperation {
        if let failureCode { try Self.nativeIdentifier(failureCode, limit: 128) }
        return try db.queue.write { dbc in
            let old = try Self.nativeOperation(id: id, expectedRevision: expectedRevision, in: dbc)
            guard !old.state.isTerminal else { throw WorkspaceCodexNativeError.invalidTransition }
            let notDelivered = [.requested, .prepared].contains(old.state)
            let permitted = state == .deliveryUnknown ? !notDelivered
                : state.isTerminal && (notDelivered ? [.failed, .cancelled].contains(state) : providerConfirmed)
            guard permitted, state != .completed || (old.kind != .send || old.nativeTurnID != nil) else {
                throw WorkspaceCodexNativeError.invalidTransition
            }
            try dbc.execute(sql: "UPDATE workspaceCodexNativeOperation SET failureCode = ? WHERE id = ?",
                arguments: [failureCode, id])
            return try Self.nativeTransition(old, to: state, in: dbc, now: now)
        }
    }

    /// Explicit startup reconciliation; no initialization side effects and no
    /// network. Every unfinished intent stays uncertain and blocks automatic replay.
    @discardableResult
    public func reconcileUnfinishedWorkspaceCodexNativeOperations(now: Date = .now) throws -> Int {
        try db.queue.write { dbc in
            let operations = try WorkspaceCodexNativeOperation
                .filter(["requested", "prepared", "acknowledged"].contains(Column("state"))).fetchAll(dbc)
            for old in operations { _ = try Self.nativeTransition(old, to: .deliveryUnknown, in: dbc, now: now) }
            return operations.count
        }
    }

    public func workspaceCodexNativeOperation(id: UUID) throws -> WorkspaceCodexNativeOperation? {
        try db.queue.read { try WorkspaceCodexNativeOperation.fetchOne($0, key: id) }
    }

    public func workspaceCodexNativeOperations(chatLinkID: UUID, unresolvedOnly: Bool = false) throws -> [WorkspaceCodexNativeOperation] {
        try db.queue.read { dbc in
            try WorkspaceCodexNativeOperation.fetchAll(dbc, sql: """
                SELECT * FROM workspaceCodexNativeOperation WHERE chatLinkID = ?
                    AND (? = 0 OR state NOT IN ('completed','failed','interrupted','cancelled'))
                ORDER BY createdAt, id
                """, arguments: [chatLinkID, unresolvedOnly ? 1 : 0])
        }
    }

    public func workspaceCodexNativeOperationEvents(id: UUID) throws -> [WorkspaceCodexNativeOperationEvent] {
        try db.queue.read { try WorkspaceCodexNativeOperationEvent.filter(Column("operationID") == id)
            .order(Column("revision")).fetchAll($0) }
    }

    private static func nativeProjection(chatLinkID: UUID, in dbc: Database) throws -> WorkspaceCodexNativeProjection? {
        guard let row = try Row.fetchOne(dbc, sql: "SELECT * FROM workspaceCodexNativeProjection WHERE chatLinkID = ?",
            arguments: [chatLinkID]) else { return nil }
        return try .init(chatLinkID: chatLinkID, revision: row["revision"], snapshot: nativeDecode(row["snapshotJSON"]),
            observedAt: row["observedAt"])
    }

    private static func nativeLinks(chatLinkID: UUID, projectRevision: Int, chatRevision: Int,
        in dbc: Database) throws -> (WorkspaceCodexChatLink, Row) {
        guard let link = try WorkspaceCodexChatLink.fetchOne(dbc, key: chatLinkID),
              let project = try Row.fetchOne(dbc, sql: "SELECT * FROM workspaceCodexProjectLink WHERE id = ?",
                arguments: [link.projectLinkID]) else { throw WorkspaceCodexNativeError.linkNotFound }
        let revision: Int = project["revision"]
        guard revision == projectRevision, link.revision == chatRevision else { throw WorkspaceCodexNativeError.staleRevision }
        return (link, project)
    }

    private static func nativeReadyLink(chatLinkID: UUID, projectRevision: Int, chatRevision: Int,
        projectionRevision: Int, kind: WorkspaceCodexNativeOperationKind, fingerprint: String?,
        in dbc: Database) throws -> (WorkspaceCodexChatLink, WorkspaceCodexNativeProjection) {
        let (link, project) = try nativeLinks(chatLinkID: chatLinkID,
            projectRevision: projectRevision, chatRevision: chatRevision, in: dbc)
        let state: String = project["state"]
        guard state == "linked", let chat = try WorkspaceChat.fetchOne(dbc, key: link.chatID), chat.archivedAt == nil,
              let localProject = try WorkspaceProject.fetchOne(dbc, key: link.projectID), localProject.isVisible else {
            throw WorkspaceCodexNativeError.reviewRequired
        }
        let snapshot: NativeProjectSnapshot = try nativeDecode(project["approvedSnapshotJSON"])
        let roots: [WorkspaceCodexRootReview] = try nativeDecode(project["approvedRootsJSON"])
        guard !roots.isEmpty, roots.allSatisfy({ $0.availability == .available }) else { throw WorkspaceCodexNativeError.reviewRequired }
        if link.hostID == "local", workspaceCodexRootReviews(for: snapshot) != roots { throw WorkspaceCodexNativeError.reviewRequired }
        let cwd = URL(fileURLWithPath: link.workingDirectory).standardizedFileURL
        let canonicalCwd = link.hostID == "local" ? cwd.resolvingSymlinksInPath().path : cwd.path
        if link.hostID == "local" {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonicalCwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw WorkspaceCodexNativeError.reviewRequired
            }
        }
        guard roots.contains(where: { root in
            guard let canonical = root.canonicalPath else { return false }
            let base = nativeNormalizedPath(canonical)
            return canonicalCwd == base || canonicalCwd.hasPrefix(base == "/" ? "/" : base + "/")
        }) else { throw WorkspaceCodexNativeError.reviewRequired }
        guard let projection = try nativeProjection(chatLinkID: chatLinkID, in: dbc),
              projection.revision == projectionRevision else { throw WorkspaceCodexNativeError.staleRevision }
        guard projection.snapshot.complete, projection.threadState == .idle,
              !projection.snapshot.turns.contains(where: { WorkspaceCodexNativeTurnState(nativeValue: $0.status) == .inProgress
                  || WorkspaceCodexNativeTurnState(nativeValue: $0.status) == .unknown }) else {
            throw WorkspaceCodexNativeError.busyNativeThread
        }
        if kind == .send {
            guard let fingerprint, let grant = try WorkspaceCodexNativeAuthorization.fetchOne(dbc, key: chatLinkID),
                  grant.mode == "nativeCodex", grant.projectRevision == projectRevision,
                  grant.chatRevision == chatRevision, grant.effectiveConfigurationFingerprint == fingerprint else {
                throw WorkspaceCodexNativeError.reviewRequired
            }
        }
        return (link, projection)
    }

    private static func nativeRevalidateOperation(_ operation: WorkspaceCodexNativeOperation, in dbc: Database) throws {
        _ = try nativeReadyLink(chatLinkID: operation.chatLinkID, projectRevision: operation.projectRevision,
            chatRevision: operation.chatRevision, projectionRevision: operation.projectionRevision,
            kind: operation.kind, fingerprint: operation.effectiveConfigurationFingerprint, in: dbc)
    }

    private static func nativeOperation(id: UUID, expectedRevision: Int? = nil, in dbc: Database) throws -> WorkspaceCodexNativeOperation {
        guard let operation = try WorkspaceCodexNativeOperation.fetchOne(dbc, key: id) else { throw WorkspaceCodexNativeError.operationNotFound }
        if let expectedRevision, expectedRevision != operation.revision { throw WorkspaceCodexNativeError.staleRevision }
        return operation
    }

    private static func nativeTransition(_ old: WorkspaceCodexNativeOperation, to state: WorkspaceCodexNativeOperationState,
        in dbc: Database, now: Date) throws -> WorkspaceCodexNativeOperation {
        let timestamp = max(now, old.createdAt)
        try dbc.execute(sql: """
            UPDATE workspaceCodexNativeOperation SET state = ?, revision = revision + 1,
                updatedAt = ?, endedAt = ? WHERE id = ? AND revision = ?
            """, arguments: [state.rawValue, timestamp, state.isTerminal ? timestamp : nil, old.id, old.revision])
        guard dbc.changesCount == 1 else { throw WorkspaceCodexNativeError.staleRevision }
        try nativeOperationEvent(id: old.id, revision: old.revision + 1, state: state, now: timestamp, in: dbc)
        return try nativeOperation(id: old.id, in: dbc)
    }

    private static func nativeOperationEvent(id: UUID, revision: Int, state: WorkspaceCodexNativeOperationState,
        now: Date, in dbc: Database) throws {
        try dbc.execute(sql: "INSERT INTO workspaceCodexNativeOperationEvent(operationID, revision, state, timestamp) VALUES (?, ?, ?, ?)",
            arguments: [id, revision, state.rawValue, now])
    }

    private static func validateNativeSnapshot(_ snapshot: CodexNativeThreadSnapshot) throws {
        guard snapshot.complete else { throw WorkspaceCodexNativeError.incompleteSnapshot }
        try nativeIdentifier(snapshot.id)
        guard snapshot.cwd.hasPrefix("/"), !snapshot.cwd.contains("\0"), snapshot.turns.count <= 100_000,
              snapshot.items.count <= 500_000, Set(snapshot.turns.map(\.id)).count == snapshot.turns.count,
              Set(snapshot.turns.map(\.order)).count == snapshot.turns.count else { throw WorkspaceCodexNativeError.invalidValue }
        let turnIDs = Set(snapshot.turns.map(\.id))
        var itemIDs = Set<String>(), orders = Set<String>()
        for turn in snapshot.turns {
            try nativeIdentifier(turn.id)
            guard turn.order >= 0 else { throw WorkspaceCodexNativeError.invalidValue }
        }
        for item in snapshot.items {
            try nativeIdentifier(item.id); try nativeIdentifier(item.kind)
            let key = "\(item.turnID.utf8.count):\(item.turnID):\(item.id)"
            let order = "\(item.turnID.utf8.count):\(item.turnID):\(item.order)"
            guard turnIDs.contains(item.turnID), item.order >= 0, itemIDs.insert(key).inserted,
                  orders.insert(order).inserted else { throw WorkspaceCodexNativeError.invalidValue }
        }
        guard try nativeJSON(snapshot).utf8.count <= 64 * 1024 * 1024 else { throw WorkspaceCodexNativeError.invalidValue }
    }

    private static func nativeMessage(_ item: CodexNativeItemSnapshot) -> (String?, String) {
        let raw = item.raw["item"] ?? item.raw
        switch item.kind {
        case "userMessage":
            let text = (raw["content"]?.arrayValue ?? []).compactMap { input -> String? in
                guard input["type"]?.stringValue == "text" || input["type"]?.stringValue == "inputText" else { return nil }
                return input["text"]?.stringValue
            }.joined(separator: "\n")
            return ("user", text)
        case "agentMessage": return ("assistant", raw["text"]?.stringValue ?? "")
        default: return (nil, "")
        }
    }

    private static func nativeTimestamp(_ value: CodexJSONValue) -> Date? {
        func number(_ value: CodexJSONValue?) -> Double? {
            switch value {
            case .int(let v): Double(v)
            case .double(let v): v.isFinite ? v : nil
            default: nil
            }
        }
        if let milliseconds = number(value["startedAtMs"]) { return Date(timeIntervalSince1970: milliseconds / 1000) }
        for key in ["createdAt", "startedAt", "timestamp"] {
            if let seconds = number(value[key]) { return Date(timeIntervalSince1970: seconds) }
            if let string = value[key]?.stringValue, let date = ISO8601DateFormatter().date(from: string) { return date }
        }
        return nil
    }

    private static func nativeNormalizedPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    private static func nativeIdentifier(_ value: String, limit: Int = 4096) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkspaceCodexNativeError.invalidValue
        }
    }

    private static func nativeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func nativeDecode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
