import Foundation
import GRDB
import AitvarasCore

/// Which thread produced a transcript entry. Local turns are stateless and
/// share one key; every provider thread has its own (D30).
public enum WorkspaceThreadKey {
    public static let local = "local"
    public static func codexSession(_ id: UUID) -> String { "codex:session:\(id.uuidString)" }
    public static func claudeSession(_ id: UUID) -> String { "claude:session:\(id.uuidString)" }
    public static func codexNative(_ chatLinkID: UUID) -> String { "codex:native:\(chatLinkID.uuidString)" }

    /// The provider name shown for a thread, from its key.
    public static func provider(_ key: String) -> String {
        key == local ? "local" : String(key.prefix { $0 != ":" })
    }
}

/// The text of a handover block, and how it is recognised again.
public enum WorkspaceHandoverText {
    public static let header = "[Aitvaras context handover"
    public static let footer = "[End of handover · current message follows]"

    public static func providerName(_ provider: String) -> String {
        switch provider {
        case "local": "Local"
        case "codex": "Codex"
        case "claude": "Claude"
        default: provider
        }
    }

    /// Strip only an exact, durably attributed wire message. Marker-looking
    /// user content (including a footer inside earlier messages) is ordinary text.
    public static func stripped(_ text: String, recordedHandover: String? = nil,
                                originalMessage: String? = nil) -> String {
        guard let recordedHandover, let originalMessage,
              text == wire(handover: recordedHandover, message: originalMessage) else { return text }
        return originalMessage
    }

    /// What goes on the wire: the block, then the message.
    public static func wire(handover: String?, message: String) -> String {
        guard let handover, !handover.isEmpty else { return message }
        return handover + "\n" + message
    }
}

/// Messages a thread has not seen, ready to travel with the next Send.
public struct WorkspaceHandoverPlan: Sendable, Equatable {
    public let threadKey: String
    public let text: String
    public let entryCount: Int
    public let omittedCount: Int
    public let providers: [String]
    public let throughTimestamp: Date
    public let throughEntryID: String

    public init(threadKey: String, text: String, entryCount: Int, omittedCount: Int, providers: [String],
                throughTimestamp: Date, throughEntryID: String) {
        self.threadKey = threadKey; self.text = text; self.entryCount = entryCount
        self.omittedCount = omittedCount; self.providers = providers
        self.throughTimestamp = throughTimestamp; self.throughEntryID = throughEntryID
    }
}

/// A delivered handover: the exact text that left with an acknowledged turn.
public struct WorkspaceHandover: Codable, Sendable, Equatable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspaceHandover"
    public var id: UUID
    public var chatID: UUID
    public var threadKey: String
    public var turnID: UUID
    public var entryCount: Int
    public var omittedCount: Int
    public var providers: String
    public var text: String
    public var throughTimestamp: Date
    public var throughEntryID: String
    public var anchorTimestamp: Date
    public var createdAt: Date
}

extension Stores {
    public static let maximumHandoverEntryCharacters = 6_000

    /// What `threadKey` has not seen: completed user/assistant messages from
    /// other threads after its last delivered handover. `nil` when nothing is
    /// missing. Only the newest messages that fit the budget are included;
    /// the rest are counted as omitted, never silently dropped.
    public func workspaceHandoverPlan(chatID: UUID, threadKey: String,
                                      maximumCharacters: Int = Stores.workspaceSharedHistoryCharacters) throws -> WorkspaceHandoverPlan? {
        let watermark = try db.queue.read { dbc in
            try Row.fetchOne(dbc, sql: """
                SELECT throughTimestamp, throughEntryID FROM workspaceHandover
                WHERE threadKey = ? ORDER BY throughTimestamp DESC, createdAt DESC LIMIT 1
                """, arguments: [threadKey])
        }.map { (timestamp: $0["throughTimestamp"] as Date, entryID: $0["throughEntryID"] as String) }
        guard maximumCharacters > 0 else { return nil }
        // Stream every eligible message, not a UI-sized tail. Keep only the
        // bounded output while counting all omissions, including long gaps.
        var remaining = maximumCharacters - 220
        var kept: [String] = []
        var providers: [String] = []
        var newest: WorkspaceChatTimelineEntry?
        var missingCount = 0
        try forEachWorkspaceHandoverMessage(chatID: chatID, watermark: watermark) { entry in
            guard entry.sourceThread != threadKey,
                  !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            missingCount += 1
            if newest == nil { newest = entry }
            let label = "[\(entry.role) · \(WorkspaceHandoverText.providerName(entry.provider))] "
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let room = min(remaining - label.count, Self.maximumHandoverEntryCharacters)
            guard room > 40 else { return }
            let body = text.count > room ? String(text.prefix(room - 1)) + "…" : text
            kept.append(label + body)
            remaining -= label.count + body.count + 1
            if !providers.contains(entry.provider) { providers.append(entry.provider) }
        }
        guard let newest, !kept.isEmpty else { return nil }
        let omitted = missingCount - kept.count
        let names = providers.map(WorkspaceHandoverText.providerName).joined(separator: ", ")
        let header = WorkspaceHandoverText.header
            + " · \(kept.count) message\(kept.count == 1 ? "" : "s") from \(names) since your last reply"
            + (omitted > 0 ? " · \(omitted) earlier omitted" : "") + " · oldest first]"
        let text = ([header] + kept.reversed() + [WorkspaceHandoverText.footer]).joined(separator: "\n")
        return WorkspaceHandoverPlan(threadKey: threadKey, text: text, entryCount: kept.count, omittedCount: omitted,
            providers: providers, throughTimestamp: newest.timestamp, throughEntryID: newest.id)
    }

    /// The plan, shrunk until block and message together fit a provider's
    /// byte limit. Only an extreme message leaves no room for any history.
    public func workspaceHandoverPlan(chatID: UUID, threadKey: String, fittingBeside message: String,
                                      maximumBytes: Int) throws -> WorkspaceHandoverPlan? {
        var budget = Self.workspaceSharedHistoryCharacters
        while budget >= 500 {
            guard let plan = try workspaceHandoverPlan(chatID: chatID, threadKey: threadKey, maximumCharacters: budget) else { return nil }
            if WorkspaceHandoverText.wire(handover: plan.text, message: message).utf8.count <= maximumBytes { return plan }
            budget /= 2
        }
        return nil
    }

    /// Records a handover once the provider has acknowledged the turn that
    /// carried it. This is what advances the thread's watermark.
    @discardableResult
    public func recordWorkspaceHandover(_ plan: WorkspaceHandoverPlan, chatID: UUID, turnID: UUID,
                                        anchor: Date, now: Date = .now) throws -> WorkspaceHandover {
        let handover = WorkspaceHandover(id: UUID(), chatID: chatID, threadKey: plan.threadKey, turnID: turnID,
            entryCount: plan.entryCount, omittedCount: plan.omittedCount, providers: plan.providers.joined(separator: ","),
            text: plan.text, throughTimestamp: plan.throughTimestamp, throughEntryID: plan.throughEntryID,
            anchorTimestamp: anchor, createdAt: now)
        try db.queue.write { dbc in
            if let existing = try WorkspaceHandover.filter(Column("threadKey") == plan.threadKey)
                .filter(Column("turnID") == turnID).fetchOne(dbc) {
                guard existing.text == plan.text else { throw WorkspaceFrontierError.immutableIdentity }
                return
            }
            try handover.insert(dbc)
        }
        return try db.queue.read {
            try WorkspaceHandover.filter(Column("threadKey") == plan.threadKey).filter(Column("turnID") == turnID).fetchOne($0)
        } ?? handover
    }

    public func workspaceHandovers(chatID: UUID) throws -> [WorkspaceHandover] {
        try db.queue.read {
            try WorkspaceHandover.filter(Column("chatID") == chatID).order(Column("anchorTimestamp")).fetchAll($0)
        }
    }
}
