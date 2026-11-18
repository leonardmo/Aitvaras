import Foundation
import GRDB
import Testing
import AitvarasAgents
@testable import AitvarasStore

@Suite(.timeLimit(.minutes(2)))
struct AgentTranscriptIdentityMigrationTests {
    @Test func upgradesOnlyProvenCorruptClaudeUserIdentitiesAndRunsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        var before: [AgentTranscriptEntry] = []
        var repaired = Set<UUID>()
        var retiredID: UUID!
        var journals: [AgentJournalTurn] = []
        var sessions: [AgentChatSession] = []
        var history: MigrationHistoryObservation!
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, claude) = try agentStoreChat(stores, provider: .claude)
            let (_, codex) = try agentStoreChat(stores, provider: .codex)
            let (_, local) = try agentStoreChat(stores, provider: .local)
            let (_, otherClaude) = try agentStoreChat(stores, provider: .claude)
            sessions = [claude, codex, local, otherClaude]
            try stores.db.queue.write { db in
                var position = 0
                @discardableResult
                func seed(_ name: String, session: AgentChatSession = claude, kind: String = "user",
                          ownJournal: Bool = true, native: String? = UUID().uuidString,
                          payload: [String: JSONValue] = [:], malformed: String? = nil,
                          expectedRepair: Bool = false) throws -> AgentTranscriptEntry {
                    let input = AgentInput(text: name)
                    if ownJournal {
                        var turn = AgentJournalTurn(input: input, chatID: session.chatID, sessionID: session.id)
                        turn.state = .completed; turn.delivery = .acknowledged; turn.endedAt = turn.startedAt
                        try turn.insert(db)
                    }
                    let row = AgentTranscriptEntry(id: input.id, chatID: session.chatID, provider: session.provider,
                        kind: kind, text: name, payloadJSON: malformed ?? JSONValue.object(payload).jsonString,
                        sessionID: session.id, nativeMessageID: native, position: position)
                    position += 1
                    try row.insert(db)
                    if expectedRepair { repaired.insert(row.id) }
                    return row
                }
                let corrupt = try seed("corrupt", expectedRepair: true)
                var noPayload = try seed("no payload", expectedRepair: true)
                noPayload.payloadJSON = nil
                try noPayload.update(db)
                retiredID = try seed("retired", expectedRepair: true).id
                try AgentTranscriptEntry.filter(Column("id") == retiredID)
                    .updateAll(db, Column("isActive").set(to: false))
                var valid = try seed("valid")
                valid.nativeMessageID = valid.id.uuidString.lowercased()
                try valid.update(db)
                var validCanonical = try seed("valid canonical")
                validCanonical.nativeMessageID = validCanonical.id.uuidString
                validCanonical.payloadJSON = JSONValue.object(["nativeHistory": .object([
                    "itemID": .string(validCanonical.id.uuidString), "completed": .bool(true)
                ])]).jsonString
                try validCanonical.update(db)
                try seed("no native identity", native: nil)
                try seed("not a UUID", native: "unrecognized-native-id")
                try seed("assistant", kind: "assistant")
                try seed("external", ownJournal: false)
                try seed("codex", session: codex)
                try seed("local", session: local)
                try seed("inherited", payload: ["forkInheritedForSession": .string(claude.id.uuidString)])
                try seed("fork source", payload: ["forkSourceEntryID": .string(UUID().uuidString)])
                try seed("legacy", payload: ["legacyID": .string("legacy-example")])
                try seed("invalid JSON", malformed: "{")
                try seed("non-object JSON", malformed: "[]")
                try seed("bad journal metadata", payload: ["journalInputID": .string("invalid")])
                try seed("conflicting journal", payload: ["journalInputID": .string(corrupt.id.uuidString)])
                try seed("missing history item", payload: ["nativeHistory": .object(["completed": .bool(true)])])
                try seed("bad history item", payload: ["nativeHistory": .object(["itemID": .string("invalid")])])
                let canonicalID = UUID().uuidString
                try seed("canonical", native: canonicalID,
                    payload: ["nativeHistory": .object(["itemID": .string(canonicalID)])])
                try seed("imported canonical", ownJournal: false, native: UUID().uuidString,
                    payload: ["nativeHistory": .object(["itemID": .string(UUID().uuidString)])])
                var corroborated = try seed("corroborated", expectedRepair: true)
                corroborated.payloadJSON = JSONValue.object([
                    "journalInputID": .string(corroborated.id.uuidString),
                    "nativeHistory": .object(["itemID": .string(corroborated.id.uuidString.lowercased())])
                ]).jsonString
                try corroborated.update(db)
                // A new projection row can be linked by corroborated journal
                // metadata; metadata alone is not enough to prove ownership.
                try seed("linked", ownJournal: false, payload: [
                    "journalInputID": .string(corrupt.id.uuidString),
                    "nativeHistory": .object(["itemID": .string(corrupt.id.uuidString)])
                ], expectedRepair: true)
                try seed("uncorroborated link", ownJournal: false,
                    payload: ["journalInputID": .string(corrupt.id.uuidString)])
                try seed("missing journal", ownJournal: false, payload: [
                    "journalInputID": .string(UUID().uuidString),
                    "nativeHistory": .object(["itemID": .string(UUID().uuidString)])
                ])
                try seed("other session link", session: otherClaude, ownJournal: false, payload: [
                    "journalInputID": .string(corrupt.id.uuidString),
                    "nativeHistory": .object(["itemID": .string(corrupt.id.uuidString)])
                ])
                history = MigrationHistoryObservation(id: 1, sessionID: claude.id,
                    identityJSON: "[]", snapshotJSON: "[]")
                try history.insert(db)
                before = try AgentTranscriptEntry.order(Column("position")).fetchAll(db)
                journals = try AgentJournalTurn.order(Column("id")).fetchAll(db)
                try MigrationRegistration.filter(Column("identifier") == "v39-repair-claude-user-identities").deleteAll(db)
            }
            #expect(chat.id == claude.chatID)
        }
        let expected = before.map { row in
            var value = row
            if repaired.contains(row.id) { value.nativeMessageID = nil }
            return value
        }
        for _ in 0..<2 {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try stores.db.queue.read { db in
                #expect(try AgentTranscriptEntry.order(Column("position")).fetchAll(db) == expected)
                let after = try AgentJournalTurn.order(Column("id")).fetchAll(db)
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                #expect(try encoder.encode(after) == encoder.encode(journals))
                #expect(try AgentChatSession.order(Column("id")).fetchAll(db) == sessions.sorted { $0.id.uuidString < $1.id.uuidString })
                #expect(try MigrationHistoryObservation.fetchOne(db, key: 1) == history)
                #expect(try AgentTranscriptEntry.filter(Column("id") == retiredID)
                    .filter(Column("isActive") == false).fetchCount(db) == 1)
            }
        }
        // Prove this is a one-time repair, not a mutation on every launch.
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            try stores.db.queue.write { db in
                var row = try #require(try AgentTranscriptEntry.fetchOne(db, key: repaired.first!))
                row.nativeMessageID = UUID().uuidString
                try row.update(db)
            }
        }
        let reopened = Stores(db: try AitvarasDatabase(url: url))
        #expect(try reopened.db.queue.read { try AgentTranscriptEntry.fetchOne($0, key: repaired.first!)?.nativeMessageID } != nil)
    }

    @Test func repairedInputReconcilesToItsOriginalRowWithoutDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-reconcile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.sqlite")
        let input = AgentInput(text: "Original input")
        let savedSession: AgentChatSession
        do {
            let stores = Stores(db: try AitvarasDatabase(url: url))
            let (chat, initial) = try agentStoreChat(stores, provider: .claude)
            var session = initial
            session.sessionID = .init(provider: .claude, profile: "default", nativeID: UUID().uuidString)
            try stores.saveAgentSession(session)
            savedSession = session
            try stores.db.queue.write { db in
                var turn = AgentJournalTurn(input: input, chatID: chat.id, sessionID: session.id)
                turn.state = .completed; turn.delivery = .acknowledged
                try turn.insert(db)
                try AgentTranscriptEntry(id: input.id, chatID: chat.id, provider: .claude, kind: "user",
                    text: input.text, sessionID: session.id, nativeMessageID: UUID().uuidString).insert(db)
                try MigrationRegistration.filter(Column("identifier") == "v39-repair-claude-user-identities").deleteAll(db)
            }
        }
        let stores = Stores(db: try AitvarasDatabase(url: url))
        let canonical = AgentTranscriptEntry(chatID: savedSession.chatID, provider: .claude, kind: "user", text: input.text,
            payloadJSON: JSONValue.object(["nativeHistory": .object([
                "itemID": .string(input.id.uuidString), "completed": .bool(true)
            ])]).jsonString, sessionID: savedSession.id, nativeMessageID: input.id.uuidString)
        try stores.reconcileAgentHistory(session: savedSession, entries: [canonical])
        let entries = try stores.agentEntries(chatID: savedSession.chatID)
        #expect(entries.count == 1)
        #expect(entries.first?.id == input.id)
        #expect(entries.first?.text == input.text)
        #expect(entries.first?.nativeMessageID == input.id.uuidString)
        #expect(try stores.db.queue.read { try AgentTranscriptEntry.fetchCount($0) } == 1)
    }
}

private struct MigrationRegistration: TableRecord {
    static let databaseTableName = "grdb_migrations"
}
private struct MigrationHistoryObservation: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "agentHistoryObservation"
    var id: Int
    var sessionID: UUID
    var identityJSON: String
    var snapshotJSON: String
}
