import Foundation
import AitvarasCore
import AitvarasStore
import Testing
import Synchronization
@testable import AitvarasAgent
@testable import AitvarasConnectors

@Suite struct CaptureTranscriptTests {
    @Test func provisionalCheckpointIsExplicitAndDoesNotMutateFinalText() {
        var transcript = CaptureTranscript(startedAt: start)
        transcript.append(channel: .microphone, text: "Final phrase", at: start)
        let checkpoint = transcript.includingUnfinalized([.microphone: "Provisional tail", .systemAudio: "Online tail"], at: start.addingTimeInterval(1))
        #expect(!transcript.rendered().contains("Provisional tail"))
        #expect(checkpoint.rendered().contains("[Mikrofon] [Unfinalized speech] Provisional tail"))
        #expect(checkpoint.rendered().contains("[Systemaudio] [Unfinalized speech] Online tail"))
        #expect(checkpoint.lines.count == 3)
    }

    @Test func captureWarningsRemainDistinctAndDeduplicated() {
        var transcript = CaptureTranscript(startedAt: start)
        transcript.append(channel: .microphone, text: "Known speech", at: start)
        transcript.addWarning("Screen text unavailable")
        transcript.addWarning("Screen text unavailable")
        #expect(transcript.warnings.count == 1)
        #expect(transcript.rendered().hasPrefix("> Capture warning: Screen text unavailable"))
        #expect(transcript.rendered().contains("[Mikrofon] Known speech"))
    }
    @Test func audioModesRouteOnlyRequestedInputs() {
        #expect(CaptureAudioMode.microphone.usesMicrophone)
        #expect(!CaptureAudioMode.microphone.usesSystemAudio)
        #expect(!CaptureAudioMode.microphone.needsScreenStream(includingScreen: false))
        #expect(CaptureAudioMode.microphone.needsScreenStream(includingScreen: true))
        #expect(CaptureAudioMode.microphone.storageValue == "mic")
        #expect(CaptureAudioMode.system.usesSystemAudio)
        #expect(!CaptureAudioMode.system.usesMicrophone)
        #expect(CaptureAudioMode.system.needsScreenStream(includingScreen: false))
        #expect(CaptureAudioMode.systemAndMic.usesMicrophone && CaptureAudioMode.systemAndMic.usesSystemAudio)
        #expect(!CaptureAudioMode.none.usesMicrophone && !CaptureAudioMode.none.usesSystemAudio)
        #expect(!CaptureAudioMode.none.needsScreenStream(includingScreen: false))
    }

    @Test func sourceLabelsDoNotAssumeWhoIsSpeaking() {
        let start = Date(timeIntervalSince1970: 100)
        var transcript = CaptureTranscript(startedAt: start)
        transcript.append(channel: .microphone, text: "Room speaker", at: start)
        transcript.append(channel: .systemAudio, text: "Online speaker", at: start.addingTimeInterval(1))
        #expect(transcript.rendered().contains("[Mikrofon] Room speaker"))
        #expect(transcript.rendered().contains("[Systemaudio] Online speaker"))
        #expect(!transcript.rendered().contains("[Ich]"))
    }

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
    @Test func transcriptOnlyCaptureCanBeSummarizedExplicitlyLater() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: ["A later local summary."])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)
        let record = CaptureRecord(startedAt: .now, title: "Synthetic lecture", scope: "Audio",
            audio: "mic", consentConfirmed: true, transcript: "Synthetic lecture content.", summaryPending: false)
        try stores.saveCaptureRecord(record)
        let updated = try await summarizer.retrySummaryRecord(for: record.id)
        #expect(updated.summary == "A later local summary.")
        #expect(!updated.summaryPending)
        #expect(try stores.captureRecords().count == 1)
    }
    @Test func captureChangesNotifyOnlyAfterTheDatabaseMutation() throws {
        let stores = try inMemoryStores()
        let record = CaptureRecord(startedAt: .now, title: "Synthetic capture", scope: "Audio",
            audio: "mic", consentConfirmed: true, transcript: "Synthetic transcript")
        let observed = Mutex<[Bool]>([])
        let token = NotificationCenter.default.addObserver(forName: .aitvarasCaptureRecordsChanged,
            object: stores.db.queue, queue: nil) { _ in
                let exists = (try? stores.captureRecord(id: record.id)) != nil
                observed.withLock { $0.append(exists) }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        try stores.saveCaptureRecord(record)
        try stores.deleteCaptureRecord(record.id)
        #expect(observed.withLock { $0 } == [true, false])
        try stores.deleteCaptureRecord(record.id)
        #expect(observed.withLock { $0.count } == 2)
    }

    @Test func deletingDuringSummaryRetryCannotResurrectTheCapture() async throws {
        let stores = try inMemoryStores()
        let engine = GatedCaptureEngine()
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)
        let record = CaptureRecord(startedAt: .now, title: "Synthetic capture", scope: "Audio",
            audio: "mic", consentConfirmed: true, transcript: "Synthetic transcript", summaryPending: true)
        try stores.saveCaptureRecord(record)
        let retry = Task { try await summarizer.retrySummaryRecord(for: record.id) }
        await engine.waitForRequest()
        try stores.deleteCaptureRecord(record.id)
        await engine.finish(with: "Synthetic summary")
        await #expect(throws: CaptureSummaryError.self) { _ = try await retry.value }
        #expect(try stores.captureRecord(id: record.id) == nil)
        #expect(try stores.recentActivity().filter { $0.kind == .captureFinished }.isEmpty)
    }

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

        let record = try await summarizer.finish(
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
        #expect(episodes[0].summary.contains("saved with summary"))
        #expect(!episodes[0].summary.contains("Team-Meeting"))
        #expect(!episodes[0].summary.contains("Budgetrunde"))
        #expect(episodes[0].sourceID == record.id.uuidString)
    }

    @Test func engineDownKeepsTranscriptAndMarksPending() async throws {
        let stores = try inMemoryStores()
        let engine = ScriptedEngine(responses: [ScriptedEngine.throwMarker])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let record = try await summarizer.finish(
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
        let retried = try await retrier.retrySummaryRecord(for: record.id)
        #expect(!retried.summaryPending)
        let updated = try #require(try stores.captureRecord(id: record.id))
        #expect(!updated.summaryPending)
        #expect(updated.summary.contains("Nachgeholt"))
        #expect(try stores.recentActivity().filter { $0.kind == .captureFinished }.count == 2)
    }

    @Test func transcriptIsDurableBeforeSummarizationCompletes() async throws {
        let stores = try inMemoryStores()
        let engine = GatedCaptureEngine()
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let task = Task {
            try await summarizer.finish(
                transcript: transcript(), title: "Langsame Zusammenfassung",
                scope: "Nur Audio", audio: "system", consentConfirmed: true)
        }

        await engine.waitForRequest()

        let storedWhileModelRuns = try stores.captureRecords()
        #expect(storedWhileModelRuns.count == 1)
        #expect(storedWhileModelRuns[0].summaryPending)
        #expect(storedWhileModelRuns[0].transcript.contains("Diskussionspunkt"))

        await engine.finish(with: "## Überblick\nSpäter fertiggestellt.")
        let record = try await task.value
        #expect(!record.summaryPending)
        #expect(try stores.captureRecords().first?.summary.contains("Später fertiggestellt") == true)
    }

    @Test func finishUpdatesExistingCheckpointInsteadOfDuplicatingIt() async throws {
        let stores = try inMemoryStores()
        let id = UUID()
        let draft = CaptureRecord(
            id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Laufende Aufnahme", scope: "Nur Audio", audio: "system",
            consentConfirmed: true, transcript: "[00:00:01] [Andere] Erster Stand",
            summaryPending: true)
        try stores.saveCaptureRecord(draft)

        let engine = ScriptedEngine(responses: ["## Überblick\nVollständig gespeichert."])
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)
        let record = try await summarizer.finish(
            transcript: transcript(), title: "Laufende Aufnahme",
            scope: "Nur Audio", audio: "system", consentConfirmed: true,
            recordID: id)

        #expect(record.id == id)
        #expect(try stores.captureRecords().count == 1)
        #expect(try stores.captureRecord(id: id)?.transcript.contains("Diskussionspunkt Nummer 3") == true)
        #expect(try stores.captureRecord(id: id)?.summaryPending == false)
    }

    @Test func failedSummaryUpdateDoesNotClaimSummaryWasStored() async throws {
        let stores = try inMemoryStores()
        let engine = GatedCaptureEngine()
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let task = Task {
            try await summarizer.finish(
                transcript: transcript(), title: "Unterbrochene Speicherung",
                scope: "Nur Audio", audio: "system", consentConfirmed: true)
        }

        await engine.waitForRequest()
        try stores.db.queue.close()
        await engine.finish(with: "## Überblick\nDieses Ergebnis kann nicht mehr gespeichert werden.")

        let returned = try await task.value
        #expect(returned.summaryPending)
        #expect(returned.summary.isEmpty)
        #expect(returned.transcript.contains("Diskussionspunkt"))
    }

    @Test func failedSummaryAuditRollsBackSummaryForRetry() async throws {
        let stores = try inMemoryStores()
        let engine = GatedCaptureEngine()
        let summarizer = CaptureSummarizer(router: EngineRouter(ranked: [engine]), stores: stores)

        let task = Task {
            try await summarizer.finish(
                transcript: transcript(), title: "Audit-Ausfall",
                scope: "Nur Audio", audio: "system", consentConfirmed: true)
        }

        await engine.waitForRequest()
        try await stores.db.queue.write { dbc in
            try dbc.execute(sql: """
                CREATE TRIGGER reject_capture_activity
                BEFORE INSERT ON activityEvent
                WHEN NEW.kind = 'captureFinished'
                BEGIN
                    SELECT RAISE(ABORT, 'injected capture activity failure');
                END
                """)
        }
        await engine.finish(with: "## Überblick\nDiese Zusammenfassung bleibt wiederholbar.")

        let returned = try await task.value
        #expect(returned.summaryPending)
        let stored = try #require(try stores.captureRecords().first)
        #expect(stored.summaryPending)
        #expect(stored.summary.isEmpty)
        #expect(try stores.recentActivity().allSatisfy { $0.kind != .captureFinished })
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

        let record = try await summarizer.finish(
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

    @Test func captureStatusReportsStorageFailure() async throws {
        let stores = try inMemoryStores()
        let connector = CaptureConnector(stores: stores)
        try stores.db.queue.close()

        await #expect(throws: (any Error).self) {
            try await connector.execute(toolName: "capture_status", argumentsJSON: "{}")
        }
    }
}

private actor GatedCaptureEngine: InferenceEngine {
    nonisolated let identifier = "gated-capture"
    private var streamContinuation: AsyncThrowingStream<InferenceChunk, Error>.Continuation?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func isAvailable(for tier: ModelTier) async -> Bool { true }

    func complete(messages: [ChatMessage], tools: [ToolDefinition], tier: ModelTier)
        -> AsyncThrowingStream<InferenceChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<InferenceChunk, Error>.makeStream()
        streamContinuation = continuation
        requestWaiters.forEach { $0.resume() }
        requestWaiters.removeAll()
        return stream
    }

    func waitForRequest() async {
        if streamContinuation != nil { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(with text: String) {
        streamContinuation?.yield(.text(text))
        streamContinuation?.yield(.done(stopReason: .endOfTurn))
        streamContinuation?.finish()
        streamContinuation = nil
    }
}
