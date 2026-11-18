import Foundation
import GRDB
import AitvarasCore

/// Process-local monotonic time. Receipts deliberately do not survive restart.
public struct AttentionUndoClock: Sendable {
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleepUntil: @Sendable (ContinuousClock.Instant) async throws -> Void

    public init(now: @escaping @Sendable () -> ContinuousClock.Instant,
                sleepUntil: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
        self.now = now
        self.sleepUntil = sleepUntil
    }

    public static let continuous = AttentionUndoClock(now: { ContinuousClock.now }, sleepUntil: {
        try await ContinuousClock().sleep(until: $0)
    })
}

public struct AttentionRunDismissal: Sendable, Equatable {
    public let previous: ActivityRun
    public let written: ActivityRun
}

public struct AttentionPromptDismissal: Sendable, Equatable {
    public let previous: String?
    public let written: String
}

public struct AttentionMonitoringDismissal: Sendable, Equatable {
    public let incidentID: UUID
    public let previousHiddenByReceiptID: UUID?
    public let writtenHiddenByReceiptID: UUID
}

/// Exact proofs, kept only in memory. Never serialize this receipt into an audit:
/// run records can contain content; the audit contains only IDs and counts.
public struct AttentionDismissalReceipt: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let runs: [AttentionRunDismissal]
    public let heldUpdates: [HeldNotificationDismissal]
    public let prompt: AttentionPromptDismissal?
    public let monitoring: AttentionMonitoringDismissal?
    public var monitoringIncidentID: UUID? { monitoring?.incidentID }
    public let itemCount: Int
    public let deadline: ContinuousClock.Instant
    let undoEventID: UUID
    public var isEmpty: Bool { itemCount == 0 }
}

public struct AttentionUndoResult: Sendable, Equatable {
    public var runIDs: [UUID] = []
    public var heldUpdateIDs: [UUID] = []
    public var restoredPrompt = false
    public var monitoringIncidentID: UUID?
    public init() {}
}

extension Stores {
    /// An opaque receipt marker means deferred; no policy settings are changed.
    public static let automaticWorkPromptDeferredKey = "home.automaticWorkPromptDeferred"

    public func automaticWorkPromptDeferred() throws -> Bool {
        try db.queue.read { try Self.automaticWorkPromptDeferred(in: $0) }
    }

    static func automaticWorkPromptDeferred(in db: Database) throws -> Bool {
        try AttentionSetting.fetchOne(db, key: Self.automaticWorkPromptDeferredKey) != nil
    }

    /// The represented records are a click-time snapshot. A newer occurrence
    /// of a coalesced problem must not be swept up by a stale row action.
    public func dismissAttentionProblemGroup(_ group: ActivityAttentionGroup) throws -> AttentionDismissalReceipt {
        try dismissAttention(.group(group))
    }

    public func dismissUnknownOutcome(id: UUID) throws -> AttentionDismissalReceipt {
        try dismissAttention(.unknown(id))
    }

    public func dismissHeldUpdates(ids: [UUID]) throws -> AttentionDismissalReceipt {
        try dismissAttention(.held(ids))
    }

    public func deferAutomaticWorkPrompt() throws -> AttentionDismissalReceipt {
        try dismissAttention(.prompt)
    }

    /// Selection and mutation share one transaction, across the complete
    /// database projection, regardless of Home's visible row limit.
    public func dismissAllAttention() throws -> AttentionDismissalReceipt {
        try dismissAttention(.all)
    }

    /// The holder applies the in-memory hide only after this audit commits.
    func dismissMonitoringIncident(id: UUID) throws -> AttentionDismissalReceipt {
        try dismissAttention(.monitoring(id))
    }

    /// A receipt can be used once, before its monotonic deadline. No row is
    /// inserted/recreated; a recovered or subsequently changed run stays hidden.
    public func undoAttentionDismissal(_ receipt: AttentionDismissalReceipt,
                                      monitoringIncidentID: UUID? = nil) throws -> AttentionUndoResult {
        guard !receipt.isEmpty, attentionUndoClock.now() < receipt.deadline else { return AttentionUndoResult() }
        try Self.authorizeAttentionMutation()
        let (result, expired) = try db.queue.write { db in
            // Recheck after acquiring the writer: waiting for another
            // transaction must not extend Undo or use a stale expiry boundary.
            guard attentionUndoClock.now() < receipt.deadline,
                  try ActivityEvent.fetchOne(db, key: receipt.id) != nil,
                  try ActivityEvent.fetchOne(db, key: receipt.undoEventID) == nil else {
                return (AttentionUndoResult(), 0)
            }
            let now = heldNotificationClock()
            let expired = receipt.heldUpdates.isEmpty ? 0 : try Self.expireHeldNotifications(in: db, at: now)
            let eligible: Set<UUID> = receipt.runs.isEmpty ? [] : Set(try Self.activityAttentionSnapshot(in: db,
                includingAcknowledged: Set(receipt.runs.map { $0.written.id })).runIDs)
            var result = AttentionUndoResult()
            for change in receipt.runs where eligible.contains(change.written.id) {
                guard var current = try ActivityRun.fetchOne(db, key: change.written.id),
                      current == change.written else { continue }
                current.acknowledgedAt = change.previous.acknowledgedAt
                try current.update(db)
                result.runIDs.append(current.id)
            }
            result.heldUpdateIDs = try Self.restoreHeldNotifications(ifUnchanged: receipt.heldUpdates, in: db, at: now)
            if let prompt = receipt.prompt,
               let current = try AttentionSetting.fetchOne(db, key: Self.automaticWorkPromptDeferredKey),
               current.value == prompt.written {
                // Settings may have completed the review in the meantime.
                if !(try Self.attentionBackgroundPolicy(in: db)).reviewed {
                    if let previous = prompt.previous {
                        try AttentionSetting(key: Self.automaticWorkPromptDeferredKey, value: previous).save(db)
                    } else {
                        try current.delete(db)
                    }
                    result.restoredPrompt = true
                }
            }
            if let incident = receipt.monitoringIncidentID, incident == monitoringIncidentID {
                result.monitoringIncidentID = incident
            }
            // Even a conditional no-op consumes the proof, so it cannot be
            // replayed later after a coincidentally identical write.
            try Self.auditAttention(id: receipt.undoEventID, action: .undone, receiptID: receipt.id,
                runIDs: result.runIDs, heldIDs: result.heldUpdateIDs, prompt: result.restoredPrompt,
                incidentID: result.monitoringIncidentID, at: now, in: db)
            return (result, expired)
        }
        Self.notifyHeldNotificationsChanged(if: !result.heldUpdateIDs.isEmpty || expired > 0)
        if !result.runIDs.isEmpty || result.restoredPrompt { Self.notifyAttentionChanged() }
        return result
    }

    private func dismissAttention(_ selection: AttentionDismissalSelection) throws -> AttentionDismissalReceipt {
        try Self.authorizeAttentionMutation()
        let id = UUID()
        let (receipt, expired) = try db.queue.write { db in
            let now = heldNotificationClock()
            var selected: [ActivityRun] = []
            var heldIDs: [UUID] = []
            var manageHeldUpdates = false
            var deferPrompt = false
            var incidentID: UUID?
            switch selection {
            case .group(let represented):
                let snapshot = try Self.activityAttentionSnapshot(in: db)
                if let group = snapshot.groups.first(where: { $0.id == represented.id }) {
                    let originals = Dictionary(represented.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    selected = group.runs.filter {
                        ($0.state == .failed || $0.state == .interrupted) && originals[$0.id] == $0
                    }
                }
            case .unknown(let id):
                selected = try Self.activityAttentionSnapshot(in: db).groups.flatMap(\.runs)
                    .filter { $0.id == id && $0.state == .outcomeUnknown }
            case .held(let ids):
                heldIDs = ids
                manageHeldUpdates = true
            case .prompt: deferPrompt = true
            case .monitoring(let id): incidentID = id
            case .all:
                manageHeldUpdates = true
                selected = try Self.activityAttentionSnapshot(in: db).groups.flatMap(\.runs)
                    .filter { $0.state == .failed || $0.state == .interrupted }
                heldIDs = try Self.activeHeldNotificationRequest(at: now).select(Column("id"), as: UUID.self).fetchAll(db)
                deferPrompt = true
            }
            let expired = manageHeldUpdates ? try Self.expireHeldNotifications(in: db, at: now) : 0
            var changes: [AttentionRunDismissal] = []
            for original in selected {
                var written = original
                written.acknowledgedAt = now
                try written.update(db)
                written = try ActivityRun.find(db, key: original.id)
                changes.append(AttentionRunDismissal(previous: original, written: written))
            }
            let held = try Self.softDismissHeldNotifications(ids: heldIDs, in: db, at: now)
            var prompt: AttentionPromptDismissal?
            if deferPrompt, !(try Self.attentionBackgroundPolicy(in: db)).reviewed,
               try AttentionSetting.fetchOne(db, key: Self.automaticWorkPromptDeferredKey) == nil {
                let marker = id.uuidString
                try AttentionSetting(key: Self.automaticWorkPromptDeferredKey, value: marker).insert(db)
                prompt = AttentionPromptDismissal(previous: nil, written: marker)
            }
            let groups = Set(selected.map { run -> ActivityAttentionGroup.ID in
                if run.state != .outcomeUnknown, let key = run.jobKey { return .job(key) }
                return .run(run.id)
            })
            let receipt = AttentionDismissalReceipt(id: id, runs: changes, heldUpdates: held, prompt: prompt,
                monitoring: incidentID.map { AttentionMonitoringDismissal(incidentID: $0,
                    previousHiddenByReceiptID: nil, writtenHiddenByReceiptID: id) },
                itemCount: groups.count + held.count + (prompt == nil ? 0 : 1) + (incidentID == nil ? 0 : 1),
                deadline: attentionUndoClock.now().advanced(by: .seconds(Self.heldNotificationUndoWindow)), undoEventID: UUID())
            if !receipt.isEmpty {
                try Self.auditAttention(id: id, action: .dismissed, receiptID: id, runIDs: changes.map { $0.written.id },
                    heldIDs: held.map(\.id), prompt: prompt != nil, incidentID: incidentID, at: now, in: db)
            }
            return (receipt, expired)
        }
        Self.notifyHeldNotificationsChanged(if: !receipt.heldUpdates.isEmpty || expired > 0)
        // Monitoring visibility belongs to the holder. Do not request an
        // operational refresh (or accidentally clear a transient error) on hide.
        if !receipt.runs.isEmpty || receipt.prompt != nil { Self.notifyAttentionChanged() }
        return receipt
    }

    static func attentionBackgroundPolicy(in db: Database) throws -> BackgroundWorkPolicy {
        guard let setting = try AttentionSetting.fetchOne(db, key: "backgroundWorkPolicy.v1") else { return BackgroundWorkPolicy() }
        let policy = try JSONDecoder().decode(BackgroundWorkPolicy.self, from: Data(setting.value.utf8))
        guard policy.version == BackgroundWorkPolicy.currentVersion else { throw ActivityMonitoringError.unsupportedPolicyVersion }
        return policy
    }

    static func notifyAttentionChanged() {
        NotificationCenter.default.post(name: .aitvarasMonitoringChanged, object: nil)
    }

    private static func authorizeAttentionMutation() throws {
        guard AutonomyPolicy().verdict(for: attentionDismissalTool, connectorID: "attention") == .allow else {
            throw AttentionDismissalError.confirmationRequired
        }
    }

    public static let attentionDismissalTool = ToolDefinition(name: "dismiss_attention", description: "Review local attention items",
        parametersJSON: "{}", risk: .reversibleWrite)

    private static func auditAttention(id: UUID, action: AttentionAudit.Action, receiptID: UUID,
                                      runIDs: [UUID], heldIDs: [UUID], prompt: Bool, incidentID: UUID?,
                                      at now: Date, in db: Database) throws {
        let payload = AttentionAudit(action: action, receiptID: receiptID, runIDs: runIDs, heldUpdateIDs: heldIDs,
            prompt: prompt, monitoringIncidentID: incidentID, count: runIDs.count + heldIDs.count + (prompt ? 1 : 0) + (incidentID == nil ? 0 : 1))
        try ActivityEvent(id: id, kind: .attentionChanged, timestamp: now, connectorID: "attention",
            summary: "Attention items \(action.rawValue)",
            detailJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)).insert(db)
    }
}

private enum AttentionDismissalSelection {
    case group(ActivityAttentionGroup), unknown(UUID), held([UUID]), prompt, monitoring(UUID), all
}
private enum AttentionDismissalError: Error { case confirmationRequired }
private struct AttentionSetting: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "kv"
    let key: String
    let value: String
}
private struct AttentionAudit: Encodable {
    enum Action: String, Encodable { case dismissed, undone }
    let action: Action
    let receiptID: UUID
    let runIDs: [UUID]
    let heldUpdateIDs: [UUID]
    let prompt: Bool
    let monitoringIncidentID: UUID?
    let count: Int
}
