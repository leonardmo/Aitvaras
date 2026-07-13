import Foundation
import AitvarasCore
import AitvarasStore

/// The nightly "sleeping brain" (MASTERPLAN §10, K2): one consolidated
/// model pass over the day's episodes that extracts new facts, reconciles
/// them against what's already known (supersede, never delete), reflects
/// higher-level insights, emits curiosity questions, and writes a
/// human-readable learning digest into the activity log.
///
/// Design rules carried over from the research:
/// - One consolidated prompt per run (budget discipline), engine-abstracted:
///   runs on the background tier — the local model by default; a stronger
///   offline engine can be ranked into the router later without changes here.
/// - Failures are LOUD: an engine/parse failure records a failed
///   `consolidationRun` event and does not advance the watermark, so the
///   same episodes are retried next time. No silent skipping.
/// - The interactive agent never reorganizes memory; only this job does
///   (Letta's sleep-time lesson).
public actor Consolidator {
    private let router: EngineRouter
    private let stores: Stores

    static let lastRunKey = "consolidator.lastRun"
    /// Local hour after which a run is due (O8 default: first opportunity
    /// after 04:00 — a closed MacBook runs nothing at literal 3am).
    static let dueHour = 4
    static let maxOpenQuestions = 20
    static let questionMaxAge: TimeInterval = 14 * 24 * 3600

    public init(router: EngineRouter, stores: Stores) {
        self.router = router
        self.stores = stores
    }

    public struct Outcome: Sendable, Equatable {
        public var ran: Bool
        public var digest: String
        public var factsAdded: Int
        public var factsSuperseded: Int
        public var insights: Int
        public var questionsQueued: Int
        public var failed: Bool

        static let skipped = Outcome(ran: false, digest: "", factsAdded: 0,
                                     factsSuperseded: 0, insights: 0,
                                     questionsQueued: 0, failed: false)
    }

    // MARK: Scheduling

    /// True when a consolidation should run now: past the due hour and the
    /// last successful run predates today's due moment.
    public func isDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let dueToday = calendar.date(bySettingHour: Self.dueHour, minute: 0, second: 0, of: now),
              now >= dueToday else { return false }
        guard let raw = try? stores.value(forKey: Self.lastRunKey),
              let seconds = Double(raw ?? "") else { return true }
        return Date(timeIntervalSince1970: seconds) < dueToday
    }

    /// App-side entry point, safe to call on any cadence.
    @discardableResult
    public func runIfDue(now: Date = .now) async -> Outcome {
        guard isDue(now: now) else { return .skipped }
        return await run(now: now)
    }

    // MARK: The run

    @discardableResult
    public func run(now: Date = .now) async -> Outcome {
        decayStaleQuestions(now: now)

        let since = lastRun() ?? now.addingTimeInterval(-24 * 3600)
        let episodes = (try? stores.activity(since: since)) ?? []
        // Consolidating the consolidator's own trail would loop forever.
        let material = episodes.filter { $0.kind != .consolidationRun }
        guard !material.isEmpty else {
            setLastRun(now)   // clean no-op night; nothing to retry
            return .skipped
        }

        guard let engine = await router.engine(for: .background) else {
            recordFailure("no inference engine available", now: now)
            return Outcome(ran: true, digest: "", factsAdded: 0, factsSuperseded: 0,
                           insights: 0, questionsQueued: 0, failed: true)
        }

        let known = (try? stores.activeFacts(limit: 60)) ?? []
        let prompt = Self.prompt(episodes: material, knownFacts: known)

        var raw = ""
        do {
            for try await chunk in await engine.complete(
                messages: prompt, tools: [], tier: .background) {
                if case .text(let t) = chunk { raw += t }
            }
        } catch {
            recordFailure(error.localizedDescription, now: now)
            return Outcome(ran: true, digest: "", factsAdded: 0, factsSuperseded: 0,
                           insights: 0, questionsQueued: 0, failed: true)
        }

        guard let plan = Self.parse(raw) else {
            recordFailure("model output was not parseable", now: now)
            return Outcome(ran: true, digest: "", factsAdded: 0, factsSuperseded: 0,
                           insights: 0, questionsQueued: 0, failed: true)
        }

        let applied = apply(plan, knownFacts: known, now: now)
        try? stores.record(ActivityEvent(
            kind: .consolidationRun,
            connectorID: "memory",
            summary: "Nightly consolidation: \(plan.digest)",
            detailJSON: #"{"episodes":\#(material.count),"added":\#(applied.added),"superseded":\#(applied.superseded),"insights":\#(applied.insights),"questions":\#(applied.questions)}"#))
        setLastRun(now)
        return Outcome(ran: true, digest: plan.digest,
                       factsAdded: applied.added, factsSuperseded: applied.superseded,
                       insights: applied.insights, questionsQueued: applied.questions,
                       failed: false)
    }

    // MARK: Applying the plan

    private func apply(_ plan: Plan, knownFacts: [MemoryFact], now: Date)
        -> (added: Int, superseded: Int, insights: Int, questions: Int) {
        var known = Set((((try? stores.allFacts()) ?? []).map { Self.normalize($0.text) }))
        var added = 0, superseded = 0, insights = 0

        func save(_ draft: DraftFact, source: MemoryFact.Source) -> MemoryFact? {
            let normalized = Self.normalize(draft.text)
            guard !known.contains(normalized) else { return nil }
            known.insert(normalized)
            let entities = (try? stores.upsertEntities(names: draft.entities)) ?? []
            var fact = MemoryFact(
                text: draft.text,
                entitiesText: entities.map(\.name).joined(separator: ", "),
                kind: draft.kind, importance: draft.importance,
                confidence: 0.8, source: source)
            SensitiveFacts.applyPolicy(to: &fact)
            guard (try? stores.saveFact(fact, entityIDs: entities.map(\.id))) != nil else { return nil }
            return fact
        }

        for operation in plan.operations {
            switch operation {
            case .add(let draft):
                if save(draft, source: .extracted) != nil { added += 1 }
            case .supersede(let oldID, let draft):
                // Only touch facts that really exist and are still valid.
                guard let old = try? stores.fact(id: oldID), old.isCurrentlyValid,
                      let replacement = save(draft, source: .extracted)
                else { continue }
                try? stores.supersedeFact(old.id, by: replacement.id, at: now)
                superseded += 1
            }
        }
        for insight in plan.insights where save(insight, source: .reflected) != nil {
            insights += 1
        }

        var questionsQueued = 0
        let open = (try? stores.openQuestions()) ?? []
        var openTexts = Set(open.map { Self.normalize($0.text) })
        for question in plan.questions {
            guard open.count + questionsQueued < Self.maxOpenQuestions else { break }
            let normalized = Self.normalize(question.text)
            guard !openTexts.contains(normalized) else { continue }
            openTexts.insert(normalized)
            let record = CuriosityQuestion(text: question.text, motivation: question.motivation,
                                           expectedValue: question.value)
            if (try? stores.saveQuestion(record)) != nil { questionsQueued += 1 }
        }
        return (added, superseded, insights, questionsQueued)
    }

    /// Unanswered curiosity decays (a stale queue is memory hoarding).
    private func decayStaleQuestions(now: Date) {
        for question in (try? stores.openQuestions()) ?? []
        where now.timeIntervalSince(question.createdAt) > Self.questionMaxAge {
            try? stores.setQuestionStatus(question.id, to: .dismissed, at: now)
        }
    }

    // MARK: Prompt + parsing

    static func prompt(episodes: [ActivityEvent], knownFacts: [MemoryFact]) -> [ChatMessage] {
        let episodeLines = episodes.map { e in
            "[\(e.kind.rawValue)] \(e.summary)"
        }.joined(separator: "\n")
        let factLines = knownFacts.map { f in
            "\(f.id.uuidString) | \(f.text)"
        }.joined(separator: "\n")

        return [
            ChatMessage(role: .system, content: """
                You are the nightly memory consolidation for a personal assistant. \
                Input: today's activity episodes and the currently known facts about the user. \
                Reply ONLY with JSON:
                {"digest": "2-3 sentences: what you learned about the user today, plain language",
                 "operations": [
                   {"op": "add", "text": "...", "kind": "preference|biography|event|procedure|belief|rhythm", "importance": 1-10, "entities": "comma,separated"},
                   {"op": "supersede", "old_id": "<id from the known-facts list>", "text": "corrected fact", "kind": "...", "importance": 1-10, "entities": "..."}],
                 "insights": [{"text": "higher-level pattern inferred from several episodes", "kind": "...", "importance": 1-10, "entities": "..."}],
                 "questions": [{"text": "one question to ask the user", "motivation": "why knowing this helps", "value": 1-10}]}
                Rules: operations only for durable knowledge about the USER; supersede when an \
                episode contradicts a known fact (never both add and keep the contradiction); \
                insights only when a pattern spans multiple episodes; questions only when the \
                answer would change future behavior. Empty arrays are the normal case. /no_think
                """),
            ChatMessage(role: .user, content: """
                # Known facts (id | text)
                \(factLines.isEmpty ? "(none)" : factLines)

                # Today's episodes
                \(String(episodeLines.suffix(8000)))
                """)
        ]
    }

    struct DraftFact: Equatable {
        var text: String
        var kind: MemoryFact.Kind
        var importance: Int
        var entities: String?
    }

    enum Operation: Equatable {
        case add(DraftFact)
        case supersede(oldID: UUID, DraftFact)
    }

    struct DraftQuestion: Equatable {
        var text: String
        var motivation: String
        var value: Int
    }

    struct Plan: Equatable {
        var digest: String
        var operations: [Operation]
        var insights: [DraftFact]
        var questions: [DraftQuestion]
    }

    static func parse(_ raw: String) -> Plan? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let digest = (json["digest"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digest.isEmpty else { return nil }

        func draft(from item: [String: Any]) -> DraftFact? {
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return DraftFact(
                text: text,
                kind: MemoryFact.Kind(rawValue: (item["kind"] as? String ?? "").lowercased()) ?? .biography,
                importance: (item["importance"] as? NSNumber)?.intValue ?? 5,
                entities: item["entities"] as? String)
        }

        let operations = ((json["operations"] as? [[String: Any]]) ?? []).compactMap { item -> Operation? in
            guard let fact = draft(from: item) else { return nil }
            switch (item["op"] as? String ?? "add").lowercased() {
            case "supersede":
                guard let oldID = UUID(uuidString: item["old_id"] as? String ?? "") else { return nil }
                return .supersede(oldID: oldID, fact)
            default:
                return .add(fact)
            }
        }
        let insights = ((json["insights"] as? [[String: Any]]) ?? []).compactMap(draft(from:))
        let questions = ((json["questions"] as? [[String: Any]]) ?? []).compactMap { item -> DraftQuestion? in
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return DraftQuestion(text: text,
                                 motivation: item["motivation"] as? String ?? "",
                                 value: (item["value"] as? NSNumber)?.intValue ?? 5)
        }
        return Plan(digest: digest, operations: operations, insights: insights, questions: questions)
    }

    // MARK: Watermark + failure trail

    private func lastRun() -> Date? {
        guard let raw = try? stores.value(forKey: Self.lastRunKey),
              let seconds = Double(raw ?? "") else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func setLastRun(_ date: Date) {
        try? stores.setValue(String(date.timeIntervalSince1970), forKey: Self.lastRunKey)
    }

    private func recordFailure(_ reason: String, now: Date) {
        try? stores.record(ActivityEvent(
            kind: .consolidationRun,
            connectorID: "memory",
            summary: "Nightly consolidation FAILED: \(reason) — will retry",
            detailJSON: #"{"failed":true}"#))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
