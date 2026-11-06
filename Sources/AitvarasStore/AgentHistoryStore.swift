import Foundation
import GRDB
import AitvarasAgents

/// Refreshes only the derived transcript. Journals and immutable native
/// observations retain the evidence for messages removed from a native branch.
extension Stores: AgentHistoryPersistence {
    public func reconcileAgentHistory(session: AgentChatSession, entries: [AgentTranscriptEntry]) throws {
        try reconcileAgentHistories([(session, entries)])
    }

    public func reconcileAgentHistories(_ histories: [(session: AgentChatSession, entries: [AgentTranscriptEntry])]) throws {
        try db.queue.write { dbc in
            for (session, entries) in histories { try Self.reconcileHistory(session: session, entries: entries, in: dbc) }
        }
    }

    private static func reconcileHistory(session: AgentChatSession, entries: [AgentTranscriptEntry], in dbc: Database) throws {
        var seen = Set<String>()
        guard let native = session.sessionID, native.provider != .local,
              !native.host.isEmpty, !native.profile.isEmpty, !native.nativeID.isEmpty, entries.count <= 100_000,
              entries.allSatisfy({ $0.chatID == session.chatID && $0.sessionID == session.id && $0.provider == session.provider
                  && ["user", "assistant"].contains($0.kind) && $0.nativeMessageID.map { !$0.isEmpty && seen.insert($0).inserted } == true }) else {
            throw AgentNativeHistoryError.identityConflict
        }
        guard try AgentChatSession.fetchOne(dbc, key: session.id) == session else { throw AgentNativeHistoryError.identityConflict }
        guard try AgentJournalTurn.filter(Column("chatID") == session.chatID)
            .filter(Column("state") == AgentJournalState.running.rawValue).fetchCount(dbc) == 0 else { throw AgentSessionManagerError.chatBusy }
        let identity = JSONValue.array([.string(native.provider.rawValue), .string(native.host), .string(native.profile), .string(native.nativeID)]).jsonString
        if let previousIdentity = try String.fetchOne(dbc, sql: "SELECT identityJSON FROM agentHistoryObservation WHERE sessionID = ? ORDER BY id DESC LIMIT 1", arguments: [session.id]), previousIdentity != identity {
            throw AgentNativeHistoryError.identityConflict
        }
        let all = try AgentTranscriptEntry.filter(Column("chatID") == session.chatID).order(Column("position")).fetchAll(dbc)
        let activeIDs = Set(try UUID.fetchAll(dbc, sql: "SELECT id FROM agentTranscriptEntry WHERE chatID = ? AND isActive = 1", arguments: [session.chatID]))
        let own = all.filter { $0.sessionID == session.id && ["user", "assistant"].contains($0.kind) }
        var byNative: [String: AgentTranscriptEntry] = [:]
        for entry in own { if let id = entry.nativeMessageID { byNative[id] = entry } }
        let ownByID = Dictionary(uniqueKeysWithValues: own.map { ($0.id, $0) })
        var journalInputID: UUID?
        var canonical: [AgentTranscriptEntry] = []
        for incoming in entries {
            var value = incoming
            let metadata = incoming.payloadJSON.flatMap(JSONValue.parse)?["nativeHistory"]
            let nativeTurn = metadata?["turnID"]?.stringValue
            let oldItem = metadata?["itemID"]?.stringValue.flatMap { byNative[$0] }
            let legacyItem = nativeTurn != nil && oldItem?.payloadJSON.flatMap(JSONValue.parse)?["nativeTurnID"]?.stringValue == nativeTurn ? oldItem : nil
            let old = byNative[value.nativeMessageID!] ?? legacyItem ?? UUID(uuidString: value.nativeMessageID!).flatMap { ownByID[$0] }
            if value.kind == "user" {
                journalInputID = try old.flatMap { try AgentJournalTurn.fetchOne(dbc, key: $0.id)?.id }
            }
            if let old {
                let sameTurn = nativeTurn.map { old.payloadJSON.flatMap(JSONValue.parse)?["nativeTurnID"]?.stringValue == $0 } ?? false
                guard old.kind == value.kind else { throw AgentNativeHistoryError.identityConflict }
                value.id = old.id
                // Strip only the exact acknowledged send, tied to its native
                // message identity. Marker-looking or edited text is untouched.
                if value.kind == "user", let turn = try AgentJournalTurn.fetchOne(dbc, key: old.id),
                   turn.delivery == .acknowledged, turn.sessionID == session.id,
                   (session.provider == .claude || sameTurn),
                   let record = try AgentHandoverRecord.fetchOne(dbc, key: turn.id),
                   turn.prompt == incoming.text, turn.prompt == (try record.context).wire(message: old.text) {
                    value.text = old.text
                }
                // Preserve selected attachment chips and follow-up status.
                if case .object(var payload)? = old.payloadJSON.flatMap(JSONValue.parse) {
                    payload["nativeHistory"] = value.payloadJSON.flatMap(JSONValue.parse)?["nativeHistory"]
                    value.payloadJSON = JSONValue.object(payload).jsonString
                }
            }
            if let journalInputID, case .object(var payload)? = value.payloadJSON.flatMap(JSONValue.parse) {
                payload["journalInputID"] = .string(journalInputID.uuidString)
                value.payloadJSON = JSONValue.object(payload).jsonString
            }
            canonical.append(value)
        }
        // Fill the existing session slots in canonical order. External new
        // messages follow the current transcript; other providers retain order.
        let canonicalIDs = Set(canonical.map(\.id))
        let replacing = Set(own.filter { activeIDs.contains($0.id) && ($0.nativeMessageID != nil || canonicalIDs.contains($0.id)) }.map(\.id))
        var merged: [AgentTranscriptEntry] = [], index = 0
        for entry in all where activeIDs.contains(entry.id) {
            if replacing.contains(entry.id) {
                if index < canonical.count { merged.append(canonical[index]); index += 1 }
            } else { merged.append(entry) }
        }
        merged += canonical.dropFirst(index)
        let mergedIDs = Set(merged.map(\.id))
        let retired = all.filter { !mergedIDs.contains($0.id) }
        // All active and retired positions stay unique, even during reorder.
        let offset = (all.map(\.position).max() ?? 0) + merged.count + all.count + 1
        try dbc.execute(sql: "UPDATE agentTranscriptEntry SET position = position + ? WHERE chatID = ?", arguments: [offset, session.chatID])
        try dbc.execute(sql: "UPDATE agentTranscriptEntry SET isActive = 0 WHERE sessionID = ? AND kind IN ('user','assistant') AND nativeMessageID IS NOT NULL", arguments: [session.id])
        for (position, var entry) in merged.enumerated() {
            entry.position = position
            try entry.save(dbc)
            try dbc.execute(sql: "UPDATE agentTranscriptEntry SET isActive = 1 WHERE id = ?", arguments: [entry.id])
        }
        for (index, var entry) in retired.enumerated() {
            entry.position = merged.count + index
            try entry.update(dbc)
            try dbc.execute(sql: "UPDATE agentTranscriptEntry SET isActive = 0 WHERE id = ?", arguments: [entry.id])
        }
        // Serialize only stable wire evidence, not randomly assigned row UUIDs.
        let snapshot = JSONValue.array(entries.map { entry in .object([
            "id": .string(entry.nativeMessageID!), "role": .string(entry.kind), "text": .string(entry.text),
            "history": entry.payloadJSON.flatMap(JSONValue.parse)?["nativeHistory"] ?? .null
        ]) }).jsonString
        let previous = try String.fetchOne(dbc, sql: "SELECT snapshotJSON FROM agentHistoryObservation WHERE sessionID = ? ORDER BY id DESC LIMIT 1", arguments: [session.id])
        if previous != snapshot {
            try dbc.execute(sql: "INSERT INTO agentHistoryObservation(sessionID, identityJSON, snapshotJSON) VALUES (?, ?, ?)", arguments: [session.id, identity, snapshot])
        }
    }
}
