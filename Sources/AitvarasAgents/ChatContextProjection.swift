import Foundation

/// Deterministic, bounded wire context. Callers supply only completed entries
/// from this chat; thinking, tools and previous envelopes never enter it.
public struct ChatContextProjection: Codable, Sendable, Equatable {
    public let text: String
    public let entryCount: Int
    public let omittedCount: Int
    public let throughPosition: Int

    public static func make(entries: [AgentTranscriptEntry], provider: AgentProvider,
                            after position: Int = -1, maximumBytes: Int = 16_000) -> Self? {
        let eligible = entries.filter {
            $0.position > position && (provider == .local || $0.provider != provider)
                && ["user", "assistant"].contains($0.kind) && !$0.text.isEmpty
        }.sorted { $0.position < $1.position }
        guard let newest = eligible.last else { return nil }
        var kept: [String] = []
        func block(_ messages: [String]) -> String {
            (["[Aitvaras context handover · \(messages.count) messages · \(eligible.count - messages.count) earlier omitted · oldest first]"]
             + messages + ["[End of handover · current message follows]"]).joined(separator: "\n")
        }
        // Keep a contiguous newest suffix. If the newest message alone is
        // oversized, explicitly clip its body at a Character boundary.
        for entry in eligible.reversed() {
            let label = "[\(entry.kind) · \(entry.provider.rawValue)] "
            let message = label + entry.text
            let candidate = [message] + kept
            guard block(candidate).utf8.count <= maximumBytes else {
                if kept.isEmpty {
                    let marker = "\n[message truncated]"
                    var room = maximumBytes - block([label + marker]).utf8.count
                    if room >= 0 {
                        var body = ""
                        for character in entry.text {
                            let size = String(character).utf8.count
                            guard size <= room else { break }
                            body.append(character); room -= size
                        }
                        kept = [label + body + marker]
                    }
                }
                break
            }
            kept = candidate
        }
        let text = block(kept)
        guard text.utf8.count <= maximumBytes else { return nil }
        return Self(text: text, entryCount: kept.count, omittedCount: eligible.count - kept.count,
                    throughPosition: newest.position)
    }

    public func wire(message: String) -> String { text + "\n" + message }
}
