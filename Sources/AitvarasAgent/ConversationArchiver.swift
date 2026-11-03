import CryptoKit
import Foundation
import AitvarasCore
import AitvarasStore

/// End-of-conversation learning (MASTERPLAN §10, hot path): when a chat is
/// discarded (new chat, app quit, voice session end) a silent background-tier
/// turn summarizes it into an episode and flushes durable facts about the
/// user — OpenClaw's "pre-compaction memory flush", the fix for the
/// ecosystem's #1 observed failure: knowledge that lived only in a
/// conversation and vanished with it.
///
/// Design constraints: never blocks the UI (callers fire-and-forget), never
/// reorganizes existing memory (that's the nightly consolidator's job — Letta
/// lesson), idempotent per transcript, and degrades to "no facts, no episode"
/// when no engine is available rather than losing the transcript (episodes
/// can be re-archived because the fingerprint is only consumed on success).
public actor ConversationArchiver {
    private let router: EngineRouter
    private let stores: Stores
    private let reporter: ActivityReporter?
    private var inFlightFingerprints: Set<String> = []

    public init(router: EngineRouter, stores: Stores, reporter: ActivityReporter? = nil) {
        self.router = router
        self.stores = stores
        self.reporter = reporter
    }

    public struct Outcome: Sendable, Equatable {
        public var archived: Bool
        public var summary: String
        public var factsSaved: Int
        public var factsQuarantined: Int
    }

    /// Archive one durable History conversation. Tool-note rows remain in
    /// History but are excluded from the learning transcript.
    @discardableResult
    public func archiveStoredConversation(id: UUID) async throws -> Outcome {
        // Project chats retain their transcript but must never teach shared
        // memory. Lookup errors propagate: a failed scope check is not legacy
        // authorization to summarize or extract global facts.
        guard try stores.workspaceChat(forConversationID: id) == nil else {
            return Self.emptyOutcome
        }
        guard let conversation = try stores.conversation(id: id) else {
            return Self.emptyOutcome
        }
        let transcript = Self.transcript(from: try stores.messages(in: id))
        return await archive(transcript: transcript, label: conversation.title, sourceConversationID: id)
    }

    /// Retry durable conversations that were rotated out of the UI before a
    /// previous archive pass could finish. Already-consumed fingerprints and
    /// trivial chats are scanned without model work; `maxAttempts` bounds the
    /// expensive backlog work performed on one launch.
    @discardableResult
    public func retryStoredConversations(
        excluding excludedIDs: Set<UUID>, maxAttempts: Int = 3
    ) async throws -> Int {
        guard maxAttempts > 0 else { return 0 }
        var attempts = 0
        var archived = 0
        for conversation in try stores.conversations() where !excludedIDs.contains(conversation.id) {
            // Check before reading the transcript or spending a model attempt;
            // project chats are not an automatic archival backlog.
            guard try stores.workspaceChat(forConversationID: conversation.id) == nil else { continue }
            let transcript = Self.transcript(from: try stores.messages(in: conversation.id))
            guard Self.isSubstantial(transcript) else { continue }
            let fingerprint = Self.fingerprint(of: transcript)
            guard try !stores.hasSeen(connectorID: "archiver", itemID: fingerprint) else { continue }
            guard attempts < maxAttempts else { break }
            attempts += 1
            if await archive(transcript: transcript, label: conversation.title,
                             sourceConversationID: conversation.id).archived {
                archived += 1
            }
        }
        return archived
    }

    /// Substance gate: don't burn model time on "hi" — archive only
    /// conversations with real user content.
    public static func isSubstantial(_ transcript: [ChatMessage]) -> Bool {
        let userTurns = transcript.filter { $0.role == .user }
        let userChars = userTurns.reduce(0) { $0 + $1.content.count }
        return userTurns.count >= 2 || userChars >= 200
    }

    @discardableResult
    public func archive(transcript: [ChatMessage], label: String = "Chat") async -> Outcome {
        await archive(transcript: transcript, label: label, sourceConversationID: nil)
    }

    private func archive(transcript: [ChatMessage], label: String, sourceConversationID: UUID?) async -> Outcome {
        guard ActivityExecution.permits(.archiving, stores: stores, reporter: reporter),
              !Task.isCancelled, Self.isSubstantial(transcript) else { return Self.emptyOutcome }
        let fingerprint = Self.fingerprint(of: transcript)
        guard !inFlightFingerprints.contains(fingerprint),
              (try? stores.hasSeen(connectorID: "archiver", itemID: fingerprint)) != true else { return Self.emptyOutcome }
        let runID = reporter?.begin(ActivityRun(category: .memory,
            title: "Archive conversation", stage: "Preparing transcript",
            executionLocation: "Local", dataAccess: "Saved conversation", dataDestination: "Local memory"))
        return await ActivityTaskContext.$runID.withValue(runID ?? ActivityTaskContext.runID) {
            let outcome = await archiveContent(transcript: transcript, label: label,
                                              runID: runID, sourceConversationID: sourceConversationID)
            if let runID { reporter?.finish(id: runID,
                state: Task.isCancelled ? .cancelled : (outcome.archived ? .succeeded : .failed),
                outcome: Task.isCancelled ? "Cancelled; transcript retained" :
                    (outcome.archived ? "Conversation archived" : "No archive saved; transcript retained")) }
            return outcome
        }
    }

    private func archiveContent(transcript: [ChatMessage], label: String, runID: UUID?,
                                sourceConversationID: UUID?) async -> Outcome {
        let none = Self.emptyOutcome
        guard ActivityExecution.permits(.archiving, stores: stores, reporter: reporter) else { return none }
        guard Self.isSubstantial(transcript) else { return none }

        let fingerprint = Self.fingerprint(of: transcript)
        guard inFlightFingerprints.insert(fingerprint).inserted else { return none }
        defer { inFlightFingerprints.remove(fingerprint) }
        do {
            guard try !stores.hasSeen(connectorID: "archiver", itemID: fingerprint) else {
                return none
            }
        } catch {
            return none
        }

        guard let engine = await router.engine(for: .background) else { return none }
        if let runID { reporter?.update(id: runID, stage: "Extracting summary and facts",
            provider: await engine.identifier) }

        let rendered = Self.render(transcript)
        let messages = [
            ChatMessage(role: .system, content: """
                A conversation between the user and their assistant just ended. \
                Extract what should outlive it. Reply ONLY with JSON, no prose:
                {"summary": "1-2 sentences, what the conversation was about and any outcome",
                 "facts": [{"text": "...", "kind": "preference|biography|event|procedure|belief|rhythm", "importance": 1-10, "entities": "comma,separated,names"}]}
                Facts are durable statements about the USER — preferences, life facts, \
                projects, people, habits. Write each as a standalone sentence. \
                NEVER include: transient details, the assistant's own knowledge, \
                anything the user only asked about. Most conversations contain no \
                facts — then reply with "facts": []. /no_think
                """),
            ChatMessage(role: .user, content: rendered)
        ]

        var raw = ""
        do {
            for try await chunk in await engine.completeWithInactivityTimeout(
                messages: messages, tools: [], tier: .background) {
                try Task.checkCancellation()
                if case .done(.cancelled) = chunk { throw CancellationError() }
                if case .text(let t) = chunk { raw += t }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if let runID { reporter?.finish(id: runID, state: .cancelled, outcome: "Cancelled; transcript retained") }
            return none
        } catch {
            return none   // fingerprint not consumed — retryable later
        }

        guard let parsed = Self.parse(raw) else { return none }

        let knownFacts: [MemoryFact]
        do {
            // Assignment can occur while inference is suspended. Discard its
            // result before reading shared memory; the final save repeats this
            // boundary atomically with all episode/fact/fingerprint writes.
            if let sourceConversationID,
               try stores.workspaceChat(forConversationID: sourceConversationID) != nil { return none }
            knownFacts = try stores.allFacts()
        } catch {
            return none
        }

        // Novelty gate: normalized-text dedup against everything already
        // known and against repeated drafts in the same model response.
        var known = Set(knownFacts.map { Self.normalize($0.text) })
        let episodeID = UUID()
        var facts: [MemoryFact] = []
        for draft in parsed.facts {
            let normalized = Self.normalize(draft.text)
            guard known.insert(normalized).inserted else { continue }
            var fact = MemoryFact(
                text: draft.text,
                entitiesText: Self.entityNames(draft.entities),
                kind: draft.kind,
                importance: draft.importance,
                confidence: 0.8,
                source: .extracted,
                sourceEpisodesJSON: #"["\#(episodeID.uuidString)"]"#)
            SensitiveFacts.applyPolicy(to: &fact)
            facts.append(fact)
        }

        let episode = ActivityEvent(
            id: episodeID,
            kind: .conversationArchived,
            connectorID: "memory",
            summary: "\(label) archived: \(parsed.summary)",
            detailJSON: #"{"messages":\#(transcript.count),"facts":\#(facts.count)}"#)
        do {
            try Task.checkCancellation()
            guard ActivityExecution.permits(.archiving, stores: stores, reporter: reporter) else { return none }
            if let runID { reporter?.update(id: runID, stage: "Saving archive") }
            guard try stores.archiveConversation(
                episode, fingerprint: fingerprint, facts: facts,
                sourceConversationID: sourceConversationID) else { return none }
        } catch {
            return none
        }
        return Outcome(archived: true, summary: parsed.summary,
                       factsSaved: facts.count,
                       factsQuarantined: facts.count(where: \.needsReview))
    }

    // MARK: Parsing

    struct DraftFact: Equatable {
        var text: String
        var kind: MemoryFact.Kind
        var importance: Int
        var entities: String?
    }

    struct Parsed: Equatable {
        var summary: String
        var facts: [DraftFact]
    }

    /// Lenient JSON extraction — small local models decorate their output.
    static func parse(_ raw: String) -> Parsed? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let summary = (json["summary"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 1_000 else { return nil }
        let facts = ((json["facts"] as? [[String: Any]]) ?? []).prefix(20)
            .compactMap { item -> DraftFact? in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text.count <= MemoryFact.maximumTextCharacters else { return nil }
            let entities = item["entities"] as? String
            guard (entities?.count ?? 0) <= MemoryFact.maximumEntitiesCharacters else {
                return nil
            }
            let kind = MemoryFact.Kind(rawValue: (item["kind"] as? String ?? "").lowercased()) ?? .biography
            let importance = (item["importance"] as? NSNumber)?.intValue
                ?? Int(item["importance"] as? String ?? "") ?? 5
            return DraftFact(text: text, kind: kind, importance: importance,
                             entities: entities)
        }
        return Parsed(summary: summary, facts: facts)
    }

    // MARK: Helpers

    private static let emptyOutcome = Outcome(
        archived: false, summary: "", factsSaved: 0, factsQuarantined: 0)

    public static func transcript(from messages: [StoredMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            switch message.role {
            case "user": ChatMessage(role: .user, content: message.content)
            case "assistant": ChatMessage(role: .assistant, content: message.content)
            default: nil
            }
        }
    }

    static func render(_ transcript: [ChatMessage]) -> String {
        let lines = transcript.compactMap { message -> String? in
            switch message.role {
            case .user: "User: \(message.content)"
            case .assistant: "Assistant: \(message.content)"
            case .system, .tool: nil
            }
        }
        // Keep the tail — that's where conclusions live.
        return String(lines.joined(separator: "\n").suffix(6000))
    }

    static func fingerprint(of transcript: [ChatMessage]) -> String {
        let joined = transcript.map { "\($0.role.rawValue):\($0.content)" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func entityNames(_ names: String?) -> String {
        guard let names else { return "" }
        return names.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}
