import Foundation
import AitvarasCore
import AitvarasStore
import Testing
@testable import AitvarasAgent

@Suite struct CaptureTranscriptTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func rendersChannelsAndScreenChronologically() {
        var transcript = CaptureTranscript(startedAt: start)
        transcript.append(channel: .others, text: "Willkommen zum Meeting.", at: start.addingTimeInterval(5))
        transcript.appendScreenNote("Agenda: Budget 2026, Personalplanung, Sonstiges", at: start.addingTimeInterval(12))
        transcript.append(channel: .me, text: "Kurze Frage zum Budget.", at: start.addingTimeInterval(65))

        let rendered = transcript.rendered()
        let lines = rendered.split(separator: "\n").map(String.init)
        #expect(lines[0] == "[00:00:05] [Andere] Willkommen zum Meeting.")
        #expect(lines[1] == "[00:00:12] [Bildschirm]")
        #expect(lines[2].contains("Agenda: Budget 2026"))
        #expect(lines[3] == "[00:01:05] [Ich] Kurze Frage zum Budget.")
    }

    @Test func screenNoteDedupSkipsRerenderedSlides() {
        var transcript = CaptureTranscript(startedAt: start)
        let first = transcript.appendScreenNote("Quarterly results: revenue up 12%, churn stable, roadmap on track")
        // Same slide, OCR jitter on one word → duplicate.
        let jittered = transcript.appendScreenNote("Quarterly results: revenue up 12%, churn stable, roadmap on trach")
        // Genuinely new slide → kept.
        let newSlide = transcript.appendScreenNote("Next steps: hire two engineers, ship beta in March, review pricing")
        #expect(first && !jittered && newSlide)
        #expect(transcript.screenNotes.count == 2)
        #expect(transcript.duplicateFramesSkipped == 1)
    }

    @Test func shortOCRNoiseIsIgnored() {
        var transcript = CaptureTranscript(startedAt: start)
        let tiny = transcript.appendScreenNote("OK")
        let blank = transcript.appendScreenNote("  \n ")
        #expect(!tiny && !blank)
        #expect(transcript.screenNotes.isEmpty)
        transcript.append(channel: .me, text: "   ")
        #expect(transcript.isEmpty)
    }

    @Test func chunkingBreaksAtLineBoundaries() {
        let text = (0..<400).map { "Zeile \($0): etwas gesagtes Material für die Länge." }.joined(separator: "\n")
        let chunks = CaptureSummarizer.chunks(of: text, size: 2000)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)                       // lossless
        for chunk in chunks.dropLast() {
            #expect(chunk.hasSuffix("\n"))                     // line-aligned splits
            #expect(chunk.count <= 2000)
        }
    }
}

@Suite struct CaptureSummarizerTests {

    private func transcript(lines: Int = 4) -> CaptureTranscript {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var t = CaptureTranscript(startedAt: start)
        for i in 0..<lines {
            t.append(channel: i.isMultiple(of: 2) ? .others : .me,
                     text: "Diskussionspunkt Nummer \(i) mit etwas Substanz.",
                     at: start.addingTimeInterval(Double(i * 30)))
        }
        return t
    }

    @Test func finishStoresRecordSummaryAndEpisode() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: ["## Überblick\nBudgetrunde mit zwei Aufgaben."])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let record = await summarizer.finish(
            transcript: transcript(), title: "Team-Meeting",
            scope: "Fenster: Zoom", audio: "system+mic", consentConfirmed: true)

        #expect(!record.summaryPending)
        #expect(record.summary.contains("Budgetrunde"))
        #expect(record.transcript.contains("[Andere] Diskussionspunkt Nummer 0"))
        #expect(record.consentConfirmed)

        let stored = try stores.captureRecords()
        #expect(stored.count == 1)
        let episodes = try stores.recentActivity().filter { $0.kind == .captureFinished }
        #expect(episodes.count == 1)
        #expect(episodes[0].summary.contains("Team-Meeting"))
        #expect(episodes[0].sourceID == record.id.uuidString)
    }

    @Test func engineDownKeepsTranscriptAndMarksPending() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: [ScriptedEngine.throwMarker])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let record = await summarizer.finish(
            transcript: transcript(), title: "Vorlesung",
            scope: "Ganzer Bildschirm", audio: "system", consentConfirmed: true)

        #expect(record.summaryPending)                          // loud, not lost
        #expect(record.transcript.contains("Diskussionspunkt"))
        #expect(try stores.captureRecords().count == 1)
        let episode = try #require(try stores.recentActivity().first { $0.kind == .captureFinished })
        #expect(episode.summary.contains("summary pending"))

        // Retry succeeds once an engine responds.
        let retryEngine = ScriptedEngine(responses: ["## Überblick\nNachgeholt."])
        let retrier = CaptureSummarizer(router: EngineRouter(ranked: [retryEngine]), stores: stores)
        #expect(await retrier.retrySummary(for: record.id))
        let updated = try #require(try stores.captureRecords().first)
        #expect(!updated.summaryPending)
        #expect(updated.summary.contains("Nachgeholt"))
    }

    @Test func longTranscriptGoesThroughMapReduce() async throws {
        let stores = try inMemoryStores()
        var long = transcript()
        for i in 0..<600 {
            long.append(channel: .others,
                        text: "Ausführlicher Punkt \(i): " + String(repeating: "Detail ", count: 10))
        }
        // 1 final + N chunk responses; provide plenty.
        let responses = (0..<10).map { "Teilzusammenfassung \($0)." } + ["## Überblick\nLange Sitzung."]
        let engine = ScriptedEngine(responses: responses)
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let record = await summarizer.finish(
            transcript: long, title: "Langes Meeting",
            scope: "Nur Audio", audio: "system", consentConfirmed: true)

        #expect(!record.summaryPending)
        #expect(await engine.callCount() > 2)                   // map + reduce, not one pass
        #expect(record.summary.contains("Überblick") || record.summary.contains("Teilzusammenfassung"))
    }

    @Test func captureRecordRoundTripsAndDeletes() throws {
        let stores = try inMemoryStores()
        let record = CaptureRecord(
            startedAt: .now, title: "Test", scope: "Nur Audio", audio: "system",
            consentConfirmed: false, transcript: "[00:00:01] [Ich] Hallo")
        try stores.saveCaptureRecord(record)
        #expect(try stores.captureRecords().first?.title == "Test")
        try stores.deleteCaptureRecord(record.id)
        #expect(try stores.captureRecords().isEmpty)
    }
}
