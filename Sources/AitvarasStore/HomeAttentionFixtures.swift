import Foundation
import GRDB
import AitvarasCore

/// Seedable Home attention state for isolated test profiles (TESTING.md, D36):
/// `Aitvaras --seed-home-attention` with `AITVARAS_STATE_DIR` set. Fictional,
/// generic content only. Seeds once per profile and never runs against the
/// default state directory (the app checks isolation before calling this).
///
/// What it produces on Home, in card order:
/// - Decisions: one pending tool suggestion (add a goal; harmless if approved)
/// - Problems: a grouped indexing failure ×3, a failed model download, an
///   interrupted consolidation, a delivery with an unknown outcome, and a
///   failed archive of a stored conversation (Retry + Open conversation)
/// - Notices: two held updates, plus the automatic-work prompt of a fresh profile
/// It also seeds a capture-summary failure that a later success already
/// recovered, which must not appear, and one expired held update, which must
/// be removed on the first read.
public enum HomeAttentionFixtures {
    static let markerKey = "fixtures.homeAttention.v1"
    /// Fixed so self-drive scenarios can address the seeded rows by identifier.
    public static let conversationID = UUID(uuidString: "0A170000-0000-4000-8000-000000000001")!
    public static let unknownOutcomeRunID = UUID(uuidString: "0A170000-0000-4000-8000-000000000002")!
    public static let suggestionID = UUID(uuidString: "0A170000-0000-4000-8000-000000000003")!
    public static let heldUpdateIDs = [UUID(uuidString: "0A170000-0000-4000-8000-000000000004")!,
                                       UUID(uuidString: "0A170000-0000-4000-8000-000000000005")!]
    static let captureRecordID = UUID(uuidString: "0A170000-0000-4000-8000-000000000006")!
    public static let indexingJobKey = ActivityJobKey.indexing(sourceIDs: ["fixture-source"])

    @discardableResult
    public static func seed(into stores: Stores, now: Date = .now) throws -> Bool {
        guard try stores.value(forKey: markerKey) == nil else { return false }
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

        let conversation = Conversation(id: conversationID, title: "Example planning chat")
        try stores.saveConversation(conversation)
        let lines = [
            ("user", "Let's plan the example seminar talk. I'd like to rehearse twice before Friday."),
            ("assistant", "Sounds good. I suggest Wednesday and Thursday evening for the rehearsals."),
            ("user", "Wednesday works. Please remember that I prefer short slides with one idea each."),
            ("assistant", "Noted: short slides, one idea per slide.")
        ]
        for (index, line) in lines.enumerated() {
            try stores.appendMessage(StoredMessage(conversationID: conversation.id, role: line.0, content: line.1,
                createdAt: at(Double(300 - index))))
        }
        let transcript = lines.map { ChatMessage(role: $0.0 == "user" ? .user : .assistant, content: $0.1) }
        let archiveKey = ActivityJobKey.archiving(conversationID: conversation.id,
            fingerprint: TranscriptFingerprint.of(transcript))

        let indexing = indexingJobKey
        let captureRecord = captureRecordID
        let summaryKey = ActivityJobKey.captureSummary(recordID: captureRecord)
        func run(_ title: String, _ category: ActivityCategory, _ state: ActivityRunState, started: Double,
                 outcome: String, key: String?, reference: String? = nil, id: UUID = UUID(),
                 access: String = "Local example data", destination: String = "This Mac only") -> ActivityRun {
            ActivityRun(id: id, parentID: nil, referenceID: reference, category: category, trigger: .automatic,
                state: state, title: title, startedAt: at(started), updatedAt: at(started - 1),
                finishedAt: state.isTerminal ? at(started - 1) : nil, executionLocation: "This Mac",
                dataAccess: access, dataDestination: destination, outcome: outcome, jobKey: key)
        }
        let runs = [
            run("Index selected folders", .knowledge, .failed, started: 180,
                outcome: "The embedding service did not respond.", key: indexing,
                access: "Registered example folder", destination: "Local search index"),
            run("Index selected folders", .knowledge, .failed, started: 120,
                outcome: "The embedding service did not respond.", key: indexing,
                access: "Registered example folder", destination: "Local search index"),
            run("Index selected folders", .knowledge, .failed, started: 60,
                outcome: "Some files could not be read.", key: indexing,
                access: "Registered example folder", destination: "Local search index"),
            run("Download local model", .model, .failed, started: 90,
                outcome: "The download stopped before it finished.", key: ActivityJobKey.modelDownload(
                    modelID: "fixture-model", repository: "example/fixture-model", revision: "main"),
                reference: "fixture-model", access: "Public model files",
                destination: "Model download host; no conversation content"),
            run("Nightly memory consolidation", .memory, .interrupted, started: 240,
                outcome: "Aitvaras quit before this finished. Nothing was replayed.", key: ActivityJobKey.consolidation,
                access: "Recent episodes", destination: "Local memory"),
            run("Send queued external notification", .delivery, .outcomeUnknown, started: 45,
                outcome: "The connection closed before the result was confirmed.", key: nil, id: unknownOutcomeRunID,
                access: "Previously queued notification", destination: "Configured phone account"),
            run("Archive conversation", .memory, .failed, started: 30,
                outcome: "No archive saved; transcript retained", key: archiveKey,
                reference: conversation.id.uuidString, access: "Saved conversation", destination: "Local memory"),
            // Recovered by the later success below: must not appear on Home.
            run("Summarize saved capture", .capture, .failed, started: 200,
                outcome: "Transcript retained; summary not completed", key: summaryKey,
                reference: captureRecord.uuidString),
            run("Retry capture summary", .capture, .succeeded, started: 20,
                outcome: "Summary saved", key: summaryKey, reference: captureRecord.uuidString)
        ]
        try stores.db.queue.write { db in
            for run in runs { try run.insert(db) }
            try HeldNotification(id: heldUpdateIDs[0], title: "Library pickup ready",
                body: "An example book is ready for pickup at the front desk.", createdAt: at(50)).insert(db)
            try HeldNotification(id: heldUpdateIDs[1], title: "Build finished",
                body: "The example project's nightly build finished without warnings.", createdAt: at(15)).insert(db)
            // Older than 24 hours: expired on the first read, never shown.
            try HeldNotification(title: "Expired example update",
                body: "This update is older than a day.", createdAt: at(25 * 60)).insert(db)
        }
        try stores.saveSuggestion(Suggestion(id: suggestionID, createdAt: at(10), title: "Add a goal for today",
            detail: "Add \"Rehearse the example seminar talk\" to today's goals.",
            connectorID: "goals", toolName: "add_goal",
            argumentsJSON: #"{"text":"Rehearse the example seminar talk"}"#))
        try stores.setValue("seeded", forKey: markerKey)
        return true
    }
}
