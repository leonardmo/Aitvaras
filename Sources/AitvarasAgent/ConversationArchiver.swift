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

    public init(router: EngineRouter, stores: Stores) {
        self.router = router
        self.stores = stores
    }

    public struct Outcome: Sendable, Equatable {
        public var archived: Bool
        public var summary: String
        public var factsSaved: Int
        public var factsQuarantined: Int
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
        let none = Outcome(archived: false, summary: "", factsSaved: 0, factsQuarantined: 0)
        guard Self.isSubstantial(transcript) else { return none }

        guard let engine = await router.engine(for: .background) else { return none }

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
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { raw += t }
            }
        } catch {
            return none   // fingerprint not consumed — retryable later
        }

        guard let parsed = Self.parse(raw) else { return none }

        // Consume the transcript fingerprint only once we can actually write.
        let fingerprint = Self.fingerprint(of: transcript)
        guard (try? stores.markSeen(connectorID: "archiver", itemID: fingerprint)) == true else {
            return none   // already archived
        }

        let episode = ActivityEvent(
            kind: .conversationArchived,
            connectorID: "memory",
            summary: "\(label) archived: \(parsed.summary)",
            detailJSON: #"{"messages":\#(transcript.count),"facts":\#(parsed.facts.count)}"#)
        guard let recorded = try? stores.record(episode) else { return none }

        // Novelty gate: normalized-text dedup against everything already known.
        let known = Set(((try? stores.allFacts()) ?? []).map { Self.normalize($0.text) })
        var saved = 0, quarantined = 0
        for draft in parsed.facts where !known.contains(Self.normalize(draft.text)) {
            let entities = (try? stores.upsertEntities(names: draft.entities)) ?? []
            var fact = MemoryFact(
                text: draft.text,
                entitiesText: entities.map(\.name).joined(separator: ", "),
                kind: draft.kind,
                importance: draft.importance,
                confidence: 0.8,
                source: .extracted,
                sourceEpisodesJSON: #"["\#(recorded.id.uuidString)"]"#)
            SensitiveFacts.applyPolicy(to: &fact)
            if (try? stores.saveFact(fact, entityIDs: entities.map(\.id))) != nil {
                saved += 1
                if fact.needsReview { quarantined += 1 }
            }
        }
        return Outcome(archived: true, summary: parsed.summary,
                       factsSaved: saved, factsQuarantined: quarantined)
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
        let summary = (json["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        let facts = ((json["facts"] as? [[String: Any]]) ?? []).compactMap { item -> DraftFact? in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let kind = MemoryFact.Kind(rawValue: (item["kind"] as? String ?? "").lowercased()) ?? .biography
            let importance = (item["importance"] as? NSNumber)?.intValue
                ?? Int(item["importance"] as? String ?? "") ?? 5
            return DraftFact(text: text, kind: kind, importance: importance,
                             entities: item["entities"] as? String)
        }
        return Parsed(summary: summary, facts: facts)
    }

    // MARK: Helpers

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
}
