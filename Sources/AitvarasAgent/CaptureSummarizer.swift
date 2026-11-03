import Foundation
import AitvarasCore
import AitvarasStore

public enum CaptureSummaryError: Error, LocalizedError, Sendable, Equatable {
    case recordMissing
    case modelUnavailable

    public var errorDescription: String? {
        switch self {
        case .recordMissing:
            "The saved capture no longer exists."
        case .modelUnavailable:
            "No local model could produce a summary. Check the model setup and try again."
        }
    }
}

/// Turns a finished capture transcript into a structured summary (F12).
/// Long sessions are map-reduced: chunk summaries on the background tier,
/// then one final pass. If no engine is available the transcript is still
/// persisted with `summaryPending` — the capture is never lost, and the
/// summary can be regenerated later.
public actor CaptureSummarizer {
    private let router: EngineRouter
    private let stores: Stores
    private let reporter: ActivityReporter?

    /// Transcript length that fits one direct pass; beyond it, chunk.
    static let directPassLimit = 20_000
    static let chunkSize = 12_000

    public init(router: EngineRouter, stores: Stores, reporter: ActivityReporter? = nil) {
        self.router = router
        self.stores = stores
        self.reporter = reporter
    }

    /// Summarize, persist the record, and write the activity episode.
    /// Returns the stored record (with summary or `summaryPending`).
    @discardableResult
    public func finish(transcript: CaptureTranscript, title: String,
                       scope: String, audio: String, consentConfirmed: Bool,
                       endedAt: Date = .now,
                       recordID: UUID = UUID()) async throws -> CaptureRecord {
        let rendered = transcript.rendered()
        var record = CaptureRecord(
            id: recordID,
            startedAt: transcript.startedAt, endedAt: endedAt,
            title: title, scope: scope, audio: audio,
            consentConfirmed: consentConfirmed,
            transcript: rendered, summaryPending: true)

        // Durability comes before inference. A local model can take minutes,
        // hang, or be interrupted by app termination; the raw transcript must
        // already be recoverable throughout that work. This first write is
        // the one failure callers need to surface to the user.
        phase("Saving transcript")
        try stores.saveCaptureRecord(record)
        try Task.checkCancellation()

        var finalRecord = record
        if let summary = try await summarize(rendered) {
            finalRecord.summary = summary
            finalRecord.summaryPending = false
        }
        try Task.checkCancellation()

        let minutes = max(1, Int(endedAt.timeIntervalSince(transcript.startedAt) / 60))
        let event = ActivityEvent(
            kind: .captureFinished,
            connectorID: "capture",
            summary: finalRecord.summaryPending
                ? "Capture (\(minutes) min) saved — summary pending"
                : "Capture (\(minutes) min) saved with summary",
            detailJSON: #"{"lines":\#(transcript.lines.count),"screenNotes":\#(transcript.screenNotes.count),"consent":\#(consentConfirmed)}"#,
            sourceID: record.id.uuidString)
        // Keep the already-durable pending record if either the summary update
        // or its audit entry fails. A retry can then complete both together.
        phase(finalRecord.summaryPending ? "Transcript saved; summary pending" : "Saving summary")
        if (try? stores.saveCaptureRecord(finalRecord, recording: event)) != nil {
            record = finalRecord
        }
        return record
    }

    /// Regenerate a pending summary (e.g. models became available again).
    @discardableResult
    public func retrySummary(for recordID: UUID) async -> Bool {
        (try? await retrySummaryRecord(for: recordID)) != nil
    }

    /// Throwing retry used by the UI so model, lookup, and persistence
    /// failures can be explained rather than flattened into a generic false.
    @discardableResult
    public func retrySummaryRecord(for recordID: UUID) async throws -> CaptureRecord {
        try Task.checkCancellation()
        phase("Retrying saved transcript summary")
        guard var record = try stores.captureRecord(id: recordID) else {
            throw CaptureSummaryError.recordMissing
        }
        guard record.summaryPending || record.summary.isEmpty else { return record }
        guard let summary = try await summarize(record.transcript) else {
            try Task.checkCancellation()
            throw CaptureSummaryError.modelUnavailable
        }
        try Task.checkCancellation()
        record.summary = summary
        record.summaryPending = false
        let event = ActivityEvent(
            kind: .captureFinished,
            connectorID: "capture",
            summary: "Capture summary regenerated; saved capture updated",
            sourceID: record.id.uuidString)
        guard try stores.updateCaptureRecordIfPresent(record, recording: event) else {
            throw CaptureSummaryError.recordMissing
        }
        return record
    }

    // MARK: Model passes

    func summarize(_ rendered: String) async throws -> String? {
        guard !rendered.isEmpty else { return "" }
        try Task.checkCancellation()
        let runID = reporter?.begin(ActivityRun(category: .capture,
            title: "Summarize capture", stage: "Selecting summary model",
            executionLocation: "Local", dataAccess: "Saved capture transcript", dataDestination: "Local capture summary"))
        guard let engine = await router.engine(for: .background) else {
            if let runID { reporter?.finish(id: runID, state: .failed,
                outcome: "Transcript retained; no summary model is available") }
            return nil
        }
        if let runID { reporter?.update(id: runID, stage: "Preparing summary", provider: await engine.identifier) }
        return try await ActivityTaskContext.$runID.withValue(runID ?? ActivityTaskContext.runID) {
            let summary: String?
            do { summary = try await summarizeContent(rendered, engine: engine) }
            catch {
                if let runID { reporter?.finish(id: runID, state: error is CancellationError ? .cancelled : .failed,
                    outcome: "Summary not completed; full transcript retained") }
                throw error
            }
            if let runID { reporter?.finish(id: runID,
                state: Task.isCancelled ? .cancelled : (summary == nil ? .failed : .succeeded),
                outcome: summary == nil ? "Summary incomplete; full transcript retained" : "Summary generated") }
            return summary
        }
    }

    private func summarizeContent(_ rendered: String, engine: any InferenceEngine) async throws -> String? {

        if rendered.count <= Self.directPassLimit {
            return try await finalPass(engine: engine, material: rendered)
        }
        // Map: chunk summaries. Reduce: final pass over the summaries.
        var partials: [String] = []
        let chunks = Self.chunks(of: rendered, size: Self.chunkSize)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            phase("Summarizing transcript part \(index + 1)", completed: index, total: chunks.count)
            let partial = try await complete(engine: engine, messages: [
                ChatMessage(role: .system, content: """
                    Summarize this segment (part \(index + 1)) of a capture transcript \
                    densely: content, statements per speaker, decisions, tasks, \
                    on-screen material. Keep names/numbers/dates exact. Prose, no preamble. /no_think
                    """),
                ChatMessage(role: .user, content: chunk)
            ])
            // Never label a summary complete after silently dropping a failed
            // part of the source. Keep the full durable transcript retryable.
            guard let partial else { return nil }
            partials.append(partial)
        }
        guard !partials.isEmpty else { return nil }
        return try await finalPass(engine: engine, material: partials.joined(separator: "\n\n---\n\n"))
    }

    private func finalPass(engine: any InferenceEngine, material: String) async throws -> String? {
        phase("Writing final summary")
        return try await complete(engine: engine, messages: [
            ChatMessage(role: .system, content: """
                Write a structured summary of a captured session (meeting, lecture, \
                video, work session). [Mikrofon] and [Systemaudio] label audio \
                sources, NOT speaker identities; either can contain multiple people. \
                Legacy [Ich]/[Andere] labels may occur. [Bildschirm] is screen OCR. \
                Preserve uncertainty in [Unfinalized speech] and capture warnings; \
                do not turn missing screen/audio material into invented content. \
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

    private func complete(engine: any InferenceEngine, messages: [ChatMessage]) async throws -> String? {
        var out = ""
        do {
            try Task.checkCancellation()
            for try await chunk in await engine.completeWithInactivityTimeout(
                messages: messages, tools: [], tier: .background) {
                try Task.checkCancellation()
                if case .done(.cancelled) = chunk { throw CancellationError() }
                if case .text(let t) = chunk { out += t }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            if let id = ActivityTaskContext.runID { reporter?.finish(id: id,
                state: .cancelled, outcome: "Summary cancelled; transcript retained") }
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func phase(_ stage: String, completed: Int? = nil, total: Int? = nil) {
        if let id = ActivityTaskContext.runID {
            reporter?.update(id: id, stage: stage, progressCompleted: completed, progressTotal: total)
        }
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
