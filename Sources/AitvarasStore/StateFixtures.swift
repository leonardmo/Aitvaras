import Foundation
import AitvarasCore

/// Seedable demo state for testing (TESTING.md): a fictional persona —
/// "Alex", a Munich physics student with a small homelab — so UI runs,
/// screenshots and agent-driven test sessions have realistic content
/// without ever touching real user data.
///
/// Used two ways:
/// - tests call `seedDemoProfile(into:)` on an in-memory store
/// - `Aitvaras.app --seed-demo-state` seeds an EMPTY database (pair it with
///   `AITVARAS_STATE_DIR` for a throwaway profile; it refuses to touch a
///   database that already contains facts)
public enum StateFixtures {
    @discardableResult
    public static func seedDemoProfile(into stores: Stores) throws -> Bool {
        guard try stores.factStats().total == 0 else { return false }

        let uni = MemoryEntity(name: "TU München", kind: .org,
                               summary: "Alex's university; physics program, campus in Garching.")
        let homelab = MemoryEntity(name: "Homelab", kind: .system,
                                   summary: "One mini-PC: Proxmox with a TrueNAS VM and Home Assistant.")
        let sarah = MemoryEntity(name: "Sarah", kind: .person,
                                 summary: "Lab partner in the electronics practical; usually books the lab slots.")
        for entity in [uni, homelab, sarah] { try stores.saveEntity(entity) }

        let facts: [(String, MemoryFact.Kind, Int, MemoryFact.Source, [MemoryEntity])] = [
            ("Studies physics, currently 4th semester", .biography, 8, .userStated, [uni]),
            ("Prefers answers in German for casual chat, English for technical topics", .preference, 7, .userStated, []),
            ("Bikes to campus unless it rains", .rhythm, 6, .extracted, [uni]),
            ("Runs Proxmox with a TrueNAS VM; tokens are read-only", .procedure, 6, .userStated, [homelab]),
            ("Deep-work blocks work best before noon", .rhythm, 7, .reflected, []),
            ("Shares electronics practical with Sarah on Wednesdays", .event, 5, .extracted, [sarah, uni])
        ]
        for (text, kind, importance, source, entities) in facts {
            let fact = MemoryFact(
                text: text,
                entitiesText: entities.map(\.name).joined(separator: ", "),
                kind: kind, importance: importance, source: source)
            try stores.saveFact(fact, entityIDs: entities.map(\.id))
        }

        // One superseded pair so the validity timeline has history to show.
        let old = MemoryFact(text: "Uses Notion for study notes", kind: .biography, source: .extracted)
        let new = MemoryFact(text: "Uses Obsidian for study notes", kind: .biography, source: .userStated)
        try stores.saveFact(old)
        try stores.replaceFact(old.id, with: new)

        // One quarantined fact so the review flow is exercisable.
        var quarantined = MemoryFact(text: "Finds the Thursday lecture exhausting",
                                     kind: .belief, source: .extracted)
        SensitiveFacts.applyPolicy(to: &quarantined)
        try stores.saveFact(quarantined)

        try stores.saveQuestion(CuriosityQuestion(
            text: "Which calendar should study blocks go into?",
            motivation: "Planning tools need a default target", expectedValue: 8))
        try stores.saveQuestion(CuriosityQuestion(
            text: "Do you want homelab warnings on your phone or only in briefings?",
            motivation: "Tunes notification routing", expectedValue: 6))

        try stores.record(ActivityEvent(
            kind: .conversationArchived, connectorID: "memory",
            summary: "Chat archived: planned the electronics practical write-up"))
        try stores.record(ActivityEvent(
            kind: .consolidationRun, connectorID: "memory",
            summary: "Nightly consolidation: learned morning deep-work preference",
            detailJSON: #"{"episodes":4,"added":1,"superseded":0,"insights":1,"questions":1}"#))

        try stores.saveGoal(Goal(day: Goal.today(), text: "Finish practical write-up"))

        // No articles are fabricated: the normal silent scheduler fills the
        // editable starter topics from live feeds when networking is available.
        try stores.installDefaultNewsTopics()

        let focusStep = CommandRoutineStep(
            connectorID: "goals", toolName: "start_focus_session",
            argumentsJSON: "{}", risk: .reversibleWrite,
            label: "Start focus session")
        try stores.saveCommandRoutine(CommandRoutine(
            title: "Let's focus",
            triggerKind: .phrase,
            phrases: ["Let's focus", "Fokus an"],
            steps: [focusStep],
            status: .active,
            evidenceCount: 4,
            explanation: "Learned after 4 identical successful runs. Exact phrase only; no AI model is used.",
            dedupeKey: "fixture:focus-shortcut",
            lastRunAt: Date.now.addingTimeInterval(-86_400),
            runCount: 2))
        try stores.saveCommandRoutine(CommandRoutine(
            title: "Start focus session",
            triggerKind: .schedule,
            scheduleMinuteOfDay: 9 * 60,
            scheduleWeekdayMask: (2...6).reduce(0) { $0 | (1 << ($1 - 1)) },
            steps: [focusStep],
            status: .suggested,
            evidenceCount: 7,
            explanation: "Suggested—not active—after 7 weekday runs around the same time.",
            dedupeKey: "fixture:focus-schedule"))
        return true
    }
}
