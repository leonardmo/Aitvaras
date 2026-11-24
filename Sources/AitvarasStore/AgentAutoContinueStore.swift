import Foundation
import GRDB
import AitvarasAgents
import AitvarasCore

extension AgentAutoContinue: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentAutoContinue" }
}
extension AgentUsageResetObservation: FetchableRecord, PersistableRecord {
    public static var databaseTableName: String { "agentUsageResetObservation" }
}
private struct AgentChatInputRevision: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentChatInputRevision"
    var chatID: UUID
    var revision: Int
}

/// State and its provenance commit together. This store never invokes a provider.
public struct AgentAutoContinueStore: AgentAutoContinuePersistence {
    public let db: AitvarasDatabase
    public init(db: AitvarasDatabase) { self.db = db }

    public func validate(_ authorization: AgentAutoContinue) throws {
        try db.queue.read { dbc in
            try Self.requireSession(authorization, in: dbc)
            guard authorization.scope.hasKnownAccount,
                  try AgentAutoContinue.fetchOne(dbc, key: authorization.id) == authorization,
                  authorization.inputRevision == (try Self.revision(authorization.chatID, in: dbc)) else { throw AgentFailure.invalidTransition }
        }
    }
    public func hasValidSession(_ value: AgentAutoContinue) throws -> Bool {
        try db.queue.read { dbc in
            do { try Self.requireSession(value, in: dbc); return true }
            catch AgentStoreError.identityConflict { return false }
            catch AgentSessionManagerError.chatUnavailable { return false }
        }
    }
    public func pending() throws -> [AgentAutoContinue] {
        try db.queue.read { try AgentAutoContinue.filter(["pending", "claimed"].contains(Column("state")))
            .order(Column("createdAt"), Column("id")).fetchAll($0) }
    }
    public func continuation(id: UUID) throws -> AgentAutoContinue? {
        try db.queue.read { try AgentAutoContinue.fetchOne($0, key: id) }
    }
    public func continuation(failedInputID: UUID) throws -> AgentAutoContinue? {
        try db.queue.read { try AgentAutoContinue.filter(Column("failedInputID") == failedInputID).fetchOne($0) }
    }
    public func inputRevision(chatID: UUID) throws -> Int {
        try db.queue.read { dbc in
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw AgentStoreError.missingChat }
            return try Self.revision(chatID, in: dbc)
        }
    }
    static func revision(_ chatID: UUID, in dbc: Database) throws -> Int {
        try AgentChatInputRevision.fetchOne(dbc, key: chatID)?.revision ?? 0
    }
    static func requireSession(_ value: AgentAutoContinue, in dbc: Database) throws {
        guard let session = try AgentChatSession.fetchOne(dbc, key: value.sessionID),
              session.chatID == value.chatID, session.sessionID == value.native,
              session.provider == value.scope.provider, session.providerProfile == value.scope.providerProfile,
              value.native.provider != .local, !value.native.nativeID.isEmpty,
              !value.native.host.isEmpty, value.native.profile == value.scope.providerProfile else {
            throw AgentStoreError.identityConflict
        }
        if session.provider == .claude {
            let profileID = session.providerProfile == "default" ? AgentProviderProfile.defaultClaudeID : UUID(uuidString: session.providerProfile)
            guard let profileID, let profile = try AgentProviderProfile.fetchOne(dbc, key: profileID), !profile.isDeleted else {
                throw AgentStoreError.identityConflict
            }
        }
        guard let chat = try WorkspaceChat.fetchOne(dbc, key: value.chatID), chat.archivedAt == nil,
              let project = try WorkspaceProject.fetchOne(dbc, key: chat.projectID), project.isVisible else {
            throw AgentSessionManagerError.chatUnavailable
        }
    }
    @discardableResult public func schedule(_ value: AgentAutoContinue, causedBy: UUID? = nil) throws -> AgentAutoContinue {
        try db.queue.write { dbc in
            try Self.requireSession(value, in: dbc)
            guard let failed = try AgentJournalTurn.fetchOne(dbc, key: value.failedInputID),
                  failed.chatID == value.chatID, failed.sessionID == value.sessionID, failed.state == .failed else {
                throw AgentStoreError.identityConflict
            }
            if let old = try AgentAutoContinue.filter(Column("failedInputID") == value.failedInputID).fetchOne(dbc) {
                guard old.sessionID == value.sessionID, old.native == value.native, old.scope == value.scope else {
                    throw AgentStoreError.identityConflict
                }
                return old
            }
            guard value.state == .pending, value.version == 0, value.retryCount == 0,
                  value.continuationInputID == nil, value.delivery == .prepared, value.lastActivityID == nil,
                  value.inputRevision == (try Self.revision(value.chatID, in: dbc)),
                  value.inputRevision >= 0, value.updatedAt == value.createdAt,
                  value.fallbackStartedAt == value.createdAt,
                  value.nextCheckAt >= value.createdAt,
                  (value.resetSource == .fallback) == (value.resetsAt == nil),
                  value.scope.hasKnownAccount else { throw AgentFailure.invalidTransition }
            var saved = value
            saved.lastActivityID = causedBy
            try Self.audit(&saved, status: value.enabled ? "scheduled" : "cancelled", at: value.createdAt, in: dbc)
            try saved.insert(dbc)
            return try AgentAutoContinue.find(dbc, key: saved.id)
        }
    }
    private func change(_ id: UUID, at now: Date, status: String,
                        _ body: (inout AgentAutoContinue, Database) throws -> Void) throws -> AgentAutoContinue {
        try db.queue.write { dbc in
            guard var value = try AgentAutoContinue.fetchOne(dbc, key: id) else { throw AgentFailure.invalidRequest }
            let old = value
            try body(&value, dbc)
            guard value != old else { return old }
            guard old.version < Int.max else { throw AgentFailure.invalidTransition }
            value.version += 1; value.updatedAt = now
            try Self.audit(&value, status: status, at: now, in: dbc)
            try value.update(dbc)
            // Delivery compares the full record, including the stored timestamp precision.
            return try AgentAutoContinue.find(dbc, key: id)
        }
    }
    @discardableResult public func setOptions(id: UUID, enabled: Bool, keepAwake: Bool, now: Date) throws -> AgentAutoContinue {
        try change(id, at: now, status: enabled ? "scheduled" : "cancelled") { value, dbc in
            try Self.requireSession(value, in: dbc)
            guard (!enabled || value.scope.hasKnownAccount),
                  value.inputRevision == (try Self.revision(value.chatID, in: dbc)),
                  value.state == .pending || (value.state == .claimed && value.delivery == .prepared && !enabled) else {
                throw AgentFailure.invalidTransition
            }
            // Preserve the attempt ID so re-arming cannot reuse its delivery authorization.
            value.state = .pending
            value.enabled = enabled; value.keepAwake = keepAwake
        }
    }
    @discardableResult public func reschedule(id: UUID, version: Int, windowID: String?, resetsAt: Date?, source: AgentUsageResetSource,
                                             nextCheckAt: Date, nextPollAt: Date?, now: Date) throws -> AgentAutoContinue {
        try change(id, at: now, status: "scheduled") { value, _ in
            guard value.state == .pending, value.version == version, nextCheckAt >= now,
                  (source == .fallback) == (resetsAt == nil) else { throw AgentFailure.invalidTransition }
            value.windowID = windowID; value.resetsAt = resetsAt; value.resetSource = source
            value.nextCheckAt = nextCheckAt; value.nextPollAt = nextPollAt
        }
    }
    @discardableResult public func claim(id: UUID, version: Int, inputID: UUID, now: Date) throws -> AgentAutoContinue {
        try change(id, at: now, status: "claimed") { value, dbc in
            try Self.requireSession(value, in: dbc)
            guard value.state == .pending, value.enabled, value.version == version, value.scope.hasKnownAccount,
                  value.inputRevision == (try Self.revision(value.chatID, in: dbc)),
                  value.nextCheckAt <= now, inputID != value.failedInputID, inputID != value.continuationInputID,
                  try AgentJournalTurn.fetchOne(dbc, key: inputID) == nil else { throw AgentFailure.invalidTransition }
            value.state = .claimed; value.continuationInputID = inputID; value.delivery = .prepared
        }
    }
    @discardableResult public func advanceDelivery(id: UUID, inputID: UUID, to state: AgentDeliveryState, now: Date) throws -> AgentAutoContinue {
        try change(id, at: now, status: state.rawValue) { value, _ in
            guard value.state == .claimed, value.continuationInputID == inputID else { throw AgentFailure.invalidTransition }
            value.delivery = try value.delivery.advancing(to: state)
        }
    }
    /// Call only with definitive quota evidence; uncertain delivery is not a retry.
    @discardableResult public func retryAfterQuota(id: UUID, inputID: UUID, nextCheckAt: Date, now: Date) throws -> AgentAutoContinue {
        try change(id, at: now, status: "scheduled") { value, _ in
            guard value.state == .claimed, value.continuationInputID == inputID,
                  value.retryCount < Int.max, nextCheckAt > now else { throw AgentFailure.invalidTransition }
            value.state = .pending; value.retryCount += 1; value.nextCheckAt = nextCheckAt
            value.delivery = .prepared
        }
    }
    @discardableResult public func finish(id: UUID, state: AgentAutoContinue.State, now: Date) throws -> AgentAutoContinue {
        guard [.fired, .cancelled, .expired].contains(state) else { throw AgentFailure.invalidTransition }
        return try change(id, at: now, status: state.rawValue) { value, dbc in
            if value.state == state { return }
            guard [.pending, .claimed].contains(value.state),
                  state != .fired || (value.state == .claimed && value.delivery == .acknowledged) else {
                throw AgentFailure.invalidTransition
            }
            value.state = state
            if state == .cancelled { value.enabled = false }
            if state == .fired, let inputID = value.continuationInputID,
               try AgentAutomaticInput.fetchOne(dbc, key: inputID) != nil {
                let last = try AgentTranscriptEntry.filter(Column("chatID") == value.chatID)
                    .order(Column("position").desc).fetchOne(dbc)
                try AgentTranscriptEntry(id: inputID, chatID: value.chatID, provider: value.scope.provider,
                    kind: "automaticContinuation", sessionID: value.sessionID, position: (last?.position ?? -1) + 1).insert(dbc)
            }
        }
    }
    public func releasePrepared(id: UUID, inputID: UUID?, now: Date) throws {
        _ = try change(id, at: now, status: "scheduled") { value, dbc in
            guard value.state == .claimed, value.delivery == .prepared, value.continuationInputID == inputID else { throw AgentFailure.invalidTransition }
            if let inputID, let turn = try AgentJournalTurn.fetchOne(dbc, key: inputID) {
                guard turn.delivery == .prepared, turn.state != .running else { throw AgentFailure.invalidTransition }
            }
            value.state = .pending; value.nextCheckAt = max(now, value.nextCheckAt)
        }
    }
    public func retryAutomatic(id: UUID, inputID: UUID, reset: AgentUsageResetResolution?, nextCheckAt: Date, nextPollAt: Date?, now: Date) throws {
        _ = try change(id, at: now, status: "scheduled") { value, dbc in
            guard value.state == .claimed, value.continuationInputID == inputID,
                  let turn = try AgentJournalTurn.fetchOne(dbc, key: inputID), turn.state == .failed,
                  try Stores.stoppedRow(for: turn, in: dbc)?.stoppedTurn?.reason.kind == .quota,
                  value.retryCount < Int.max, nextCheckAt > now else { throw AgentFailure.invalidTransition }
            value.state = .pending; value.retryCount += 1; value.delivery = .prepared
            value.nextCheckAt = nextCheckAt; value.nextPollAt = nextPollAt
            value.windowID = reset?.windowID; value.resetsAt = reset?.resetsAt; value.resetSource = reset?.source ?? .fallback
        }
    }
    public func noteNewInput(chatID: UUID, now: Date) throws {
        try db.queue.write { try Self.noteNewInput(chatID: chatID, now: now, in: $0) }
    }
    static func noteNewInput(chatID: UUID, now: Date, in dbc: Database) throws {
            guard try WorkspaceChat.fetchOne(dbc, key: chatID) != nil else { throw AgentStoreError.missingChat }
            let old = try Self.revision(chatID, in: dbc)
            guard old < Int.max else { throw AgentFailure.invalidTransition }
            try AgentChatInputRevision(chatID: chatID, revision: old + 1).save(dbc)
            for var value in try AgentAutoContinue.filter(Column("chatID") == chatID)
                .filter(["pending", "claimed"].contains(Column("state"))).fetchAll(dbc) {
                guard value.version < Int.max else { throw AgentFailure.invalidTransition }
                value.state = .cancelled; value.enabled = false; value.version += 1; value.updatedAt = now
                try Self.audit(&value, status: "cancelled", at: now, in: dbc)
                try value.update(dbc)
            }
    }
    public func observations(scope: AgentUsageLimitScope) throws -> [AgentUsageResetObservation] {
        try db.queue.read { try Self.observationQuery(scope).order(Column("observedAt").desc, Column("windowID")).fetchAll($0) }
    }
    private static func observationQuery(_ scope: AgentUsageLimitScope) -> QueryInterfaceRequest<AgentUsageResetObservation> {
        AgentUsageResetObservation.filter(Column("provider") == scope.provider.rawValue)
            .filter(Column("providerProfile") == scope.providerProfile).filter(Column("accountKey") == (scope.accountKey ?? ""))
    }
    public func observe(_ observation: AgentUsageResetObservation) throws {
        guard observation.provider != .local, !observation.providerProfile.isEmpty, !observation.windowID.isEmpty,
              observation.scope.hasKnownAccount, observation.resetsAt.timeIntervalSince1970.isFinite,
              observation.observedAt.timeIntervalSince1970.isFinite else { throw AgentStoreError.invalidValue }
        try db.queue.write { dbc in
            var value = observation
            if let old = try Self.observationQuery(value.scope).filter(Column("windowID") == value.windowID).fetchOne(dbc) {
                guard value.observedAt > old.observedAt else { return }
                value.id = old.id
            }
            try value.save(dbc)
        }
    }
    static func advanceAutomaticDelivery(_ turn: AgentJournalTurn, in dbc: Database) throws {
        guard let receipt = try AgentAutomaticInput.fetchOne(dbc, key: turn.id),
              var pending = try AgentAutoContinue.fetchOne(dbc, key: receipt.intentID),
              pending.state == .claimed, pending.continuationInputID == turn.id else { return }
        pending.delivery = try pending.delivery.advancing(to: turn.delivery)
        pending.version += 1
        try audit(&pending, status: turn.delivery.rawValue, at: pending.updatedAt, in: dbc)
        try pending.update(dbc)
    }
    private static func audit(_ value: inout AgentAutoContinue, status: String, at now: Date, in dbc: Database) throws {
        let event = ActivityEvent(kind: .automationRun, timestamp: now, connectorID: "agent.autoContinue",
            summary: "Usage-reset continuation: " + status,
            detailJSON: JSONValue.object(["operation": .string("usageAutoContinue"), "status": .string(status),
                "intentID": .string(value.id.uuidString), "chatID": .string(value.chatID.uuidString),
                "inputID": .string(value.failedInputID.uuidString), "provider": .string(value.scope.provider.rawValue),
                "enabled": .bool(value.enabled), "keepAwake": .bool(value.keepAwake)]).jsonString,
            causedBy: value.lastActivityID, sourceID: value.failedInputID.uuidString, runID: value.failedInputID)
        try event.insert(dbc)
        value.lastActivityID = event.id
    }
}
