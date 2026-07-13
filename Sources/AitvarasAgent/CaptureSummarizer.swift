import Foundation
import AitvarasCore
import AitvarasStore

/// Turns a finished capture transcript into a structured summary (F12).
/// Long sessions are map-reduced: chunk summaries on the background tier,
/// then one final pass. If no engine is available the transcript is still
/// persisted with `summaryPending` — the capture is never lost, and the
/// summary can be regenerated later.
public actor CaptureSummarizer {
    private let router: EngineRouter
    private let stores: Stores

    /// Transcript length that fits one direct pass; beyond it, chunk.
    static let directPassLimit = 20_000
    static let chunkSize = 12_000

    public init(router: EngineRouter, stores: Stores) {
        self.router = router
        self.stores = stores
    }

    /// Summarize, persist the record, and write the activity episode.
    /// Returns the stored record (with summary or `summaryPending`).
    @discardableResult
    public func finish(transcript: CaptureTranscript, title: String,
                       scope: String, audio: String, consentConfirmed: Bool,
                       endedAt: Date = .now) async -> CaptureRecord {
        let rendered = transcript.rendered()
        var record = CaptureRecord(
            startedAt: transcript.startedAt, endedAt: endedAt,
            title: title, scope: scope, audio: audio,
            consentConfirmed: consentConfirmed,
            transcript: rendered)

        if let summary = await summarize(rendered) {
            record.summary = summary
        } else {
            record.summaryPending = true
        }
        try? stores.saveCaptureRecord(record)

        let minutes = max(1, Int(endedAt.timeIntervalSince(transcript.startedAt) / 60))
        try? stores.record(ActivityEvent(
            kind: .captureFinished,
            connectorID: "capture",
            summary: record.summaryPending
                ? "Capture \"\(title)\" (\(minutes) min) saved — summary pending, no engine available"
                : "Capture \"\(title)\" (\(minutes) min): \(Self.firstLine(of: record.summary))",
            detailJSON: #"{"lines":\#(transcript.lines.count),"screenNotes":\#(transcript.screenNotes.count),"consent":\#(consentConfirmed)}"#,
            sourceID: record.id.uuidString))
        return record
    }

    /// Regenerate a pending summary (e.g. models became available again).
    @discardableResult
    public func retrySummary(for recordID: UUID) async -> Bool {
        guard var record = (try? stores.captureRecords(limit: 200))?.first(where: { $0.id == recordID }),
              record.summaryPending,
              let summary = await summarize(record.transcript) else { return false }
        record.summary = summary
        record.summaryPending = false
        try? stores.saveCaptureRecord(record)
        return true
    }

    // MARK: Model passes

    func summarize(_ rendered: String) async -> String? {
        guard !rendered.isEmpty else { return "" }
        guard let engine = await router.engine(for: .background) else { return nil }

        if rendered.count <= Self.directPassLimit {
            return await finalPass(engine: engine, material: rendered)
        }
        // Map: chunk summaries. Reduce: final pass over the summaries.
        var partials: [String] = []
        for (index, chunk) in Self.chunks(of: rendered, size: Self.chunkSize).enumerated() {
            let partial = await complete(engine: engine, messages: [
                ChatMessage(role: .system, content: """
                    Summarize this segment (part \(index + 1)) of a capture transcript \
                    densely: content, statements per speaker, decisions, tasks, \
                    on-screen material. Keep names/numbers/dates exact. Prose, no preamble. /no_think
                    """),
                ChatMessage(role: .user, content: chunk)
            ])
            if let partial { partials.append(partial) }
        }
        guard !partials.isEmpty else { return nil }
        return await finalPass(engine: engine, material: partials.joined(separator: "\n\n---\n\n"))
    }

    private func finalPass(engine: any InferenceEngine, material: String) async -> String? {
        await complete(engine: engine, messages: [
            ChatMessage(role: .system, content: """
                Write a structured summary of a captured session (meeting, lecture, \
                video, work session). The transcript labels the user's own voice \
                [Ich], other audio [Andere], and on-screen text [Bildschirm]. \
                Answer in the transcript's dominant language. Markdown sections:
                ## Überblick — 2-3 sentences
                ## Kernpunkte — the substance, grouped by topic
                ## Entscheidungen & Aufgaben — decisions and action items with owner \
                if identifiable ("(offen)" when none); omit the section if none
                ## Offene Fragen — omit if none
                Keep names, numbers and dates exact. No invented content. /no_think
                """),
            ChatMessage(role: .user, content: material)
        ])
    }

    private func complete(engine: any InferenceEngine, messages: [ChatMessage]) async -> String? {
        var out = ""
        do {
            for try await chunk in await engine.complete(messages: messages, tools: [], tier: .background) {
                if case .text(let t) = chunk { out += t }
            }
        } catch {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Helpers

    static func chunks(of text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var remainder = Substring(text)
        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex,
                                      offsetBy: size, limitedBy: remainder.endIndex) ?? remainder.endIndex
            // Prefer breaking at a line boundary near the target size.
            let slice = remainder[..<end]
            let breakIndex = end == remainder.endIndex
                ? end
                : (slice.lastIndex(of: "\n").map { remainder.index(after: $0) } ?? end)
            result.append(String(remainder[..<breakIndex]))
            remainder = remainder[breakIndex...]
        }
        return result
    }

    static func firstLine(of text: String) -> String {
        let flattened = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return String(flattened.prefix(140))
    }
}
