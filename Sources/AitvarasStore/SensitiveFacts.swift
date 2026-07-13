import Foundation

/// O7 default: which pipeline-extracted facts are quarantined (`needsReview`)
/// until the user approves them in the memory UI. Deliberately conservative
/// and deterministic — a keyword screen, not a model call. Explicit user
/// statements (`userStated`/`userAnswered`) bypass this entirely: saying
/// "remember this" *is* the consent.
public enum SensitiveFacts {
    /// Health, other-people judgments, beliefs/politics/religion (EN + DE).
    private static let terms: [String] = [
        // health / medical
        "diagnos", "krank", "illness", "disease", "therap", "medikament",
        "medication", "depress", "anxiety", "angststörung", "adhd", "adhs",
        // beliefs / politics / religion
        "politic", "politik", "religio", "glaube", "believes that", "wählt",
        "votes for",
        // judgments about third parties
        "hates ", "hasst ", "dislikes ", "kann nicht leiden", "is incompetent",
        "ist unfähig", "annoying", "nervig"
    ]

    public static func isSensitive(text: String, kind: MemoryFact.Kind) -> Bool {
        if kind == .belief { return true }
        let lower = text.lowercased()
        return terms.contains { lower.contains($0) }
    }

    /// Apply the O7 policy to a drafted fact: pipeline sources get
    /// quarantined when sensitive; user-stated sources never do.
    public static func applyPolicy(to fact: inout MemoryFact) {
        switch fact.sourceValue {
        case .userStated, .userAnswered:
            fact.needsReview = false
        case .extracted, .reflected:
            fact.needsReview = isSensitive(text: fact.text, kind: fact.kindValue)
        }
    }
}
