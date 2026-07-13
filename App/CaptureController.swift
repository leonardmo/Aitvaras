import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import Vision
import AitvarasCore
import AitvarasStore
import AitvarasAgent
import AitvarasVoice

/// Runs one capture session (F12): ScreenCaptureKit for window/display
/// frames and system audio, a second `TranscriberSession` for that audio,
/// optionally the mic as the user's own channel, and throttled Vision OCR
/// for on-screen text. Everything is transcribe/OCR-and-discard — no frame
/// and no audio buffer ever touches disk; only text reaches the store.
@MainActor
@Observable
final class CaptureController: NSObject {
    enum ScreenScope: Equatable {
        case window(SCWindow)
        case display(SCDisplay)
        case none

        var label: String {
            switch self {
            case .window(let window):
                "Fenster: \(window.owningApplication?.applicationName ?? window.title ?? "?")"
            case .display: "Ganzer Bildschirm"
            case .none: "Nur Audio"
            }
        }
    }

    enum AudioMode: String, CaseIterable, Identifiable {
        case none = "Kein Audio"
        case system = "Nur Inhalts-Audio"
        case systemAndMic = "Inhalt + mein Mikrofon"
        var id: String { rawValue }

        var storageValue: String {
            switch self {
            case .none: "none"
            case .system: "system"
            case .systemAndMic: "system+mic"
            }
        }
    }

    struct Config {
        var scope: ScreenScope
        var audio: AudioMode
        var title: String
        var consentConfirmed: Bool

        var isValid: Bool {
            !(scope == .none && audio == .none) && consentConfirmed
        }
    }

    // Observable session state (companion chip + status tool).
    private(set) var isActive = false
    private(set) var startedAt: Date?
    private(set) var scopeLabel = ""
    private(set) var lineCount = 0
    /// Set when a session just finished — the UI shows the result sheet.
    var finishedRecord: CaptureRecord?

    private let stores: Stores
    private let summarizer: CaptureSummarizer
    private let model: AppModel

    private var transcript = CaptureTranscript()
    private var config: Config?
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var systemTranscriber: TranscriberSession?
    private var micTranscriber: TranscriberSession?
    private var micCapture: MicCapture?
    private var readerTasks: [Task<Void, Never>] = []
    private var lastOCR = Date.distantPast

    /// Frames are OCRed at most this often; SCK delivers on-change anyway.
    nonisolated private static let ocrInterval: TimeInterval = 5

    init(stores: Stores, summarizer: CaptureSummarizer, model: AppModel) {
        self.stores = stores
        self.summarizer = summarizer
        self.model = model
    }

    // MARK: Lifecycle

    func start(config: Config) async throws {
        guard !isActive else { throw CaptureError("Es läuft bereits eine Aufnahme.") }
        guard config.isValid else { throw CaptureError("Bildschirm oder Audio wählen und Einverständnis bestätigen.") }
        if config.audio == .systemAndMic && model.voiceEnabled {
            throw CaptureError("Mikrofon ist durch die Sprachkonversation belegt — erst Voice beenden.")
        }

        transcript = CaptureTranscript()
        self.config = config
        lineCount = 0

        let locale = Locale(identifier: UserDefaults.standard.string(forKey: "voice.locale") ?? "de-DE")

        // System audio + frames via one SCStream.
        if config.scope != .none || config.audio != .none {
            try await startStream(config: config, locale: locale)
        }
        // The user's own channel.
        if config.audio == .systemAndMic {
            try await startMic(locale: locale)
        }

        isActive = true
        startedAt = transcript.startedAt
        scopeLabel = config.scope.label
    }

    @discardableResult
    func stop() async -> CaptureRecord? {
        guard isActive, let config else { return nil }
        isActive = false

        readerTasks.forEach { $0.cancel() }
        readerTasks = []
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
        micCapture?.stop()
        micCapture = nil
        await systemTranscriber?.stop()
        await micTranscriber?.stop()
        systemTranscriber = nil
        micTranscriber = nil

        let finished = transcript
        self.config = nil
        scopeLabel = ""
        startedAt = nil

        guard !finished.isEmpty else {
            try? stores.record(ActivityEvent(
                kind: .captureFinished, connectorID: "capture",
                summary: "Capture ended — nothing was transcribed (no speech/text detected)"))
            NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
            return nil
        }

        let record = await summarizer.finish(
            transcript: finished,
            title: config.title.isEmpty ? config.scope.label : config.title,
            scope: config.scope.label,
            audio: config.audio.storageValue,
            consentConfirmed: config.consentConfirmed)
        finishedRecord = record
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
        return record
    }

    func statusLine() -> String {
        guard isActive, let startedAt else { return "No capture session running." }
        let minutes = Int(Date.now.timeIntervalSince(startedAt) / 60)
        return "Capture RUNNING since \(minutes) min (\(scopeLabel)) — \(lineCount) transcript lines so far."
    }

    // MARK: SCK stream

    private func startStream(config: Config, locale: Locale) async throws {
        let filter: SCContentFilter
        switch config.scope {
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display(let display):
            filter = SCContentFilter(display: display, excludingWindows: [])
        case .none:
            // Audio-only still needs a filter; use the main display but
            // deliver no video output below.
            guard let display = try await SCShareableContent.current.displays.first else {
                throw CaptureError("Kein Display gefunden.")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.width = 1512
        configuration.height = 945
        configuration.showsCursor = false
        if config.audio != .none {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true   // never transcribe Aitvaras's own TTS
        }

        let (audioStream, audioContinuation) = AsyncStream<TranscriberSession.BufferHandoff>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        let (frameStream, frameContinuation) = AsyncStream<Handoff<CVPixelBuffer>>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let output = CaptureStreamOutput(
            wantsAudio: config.audio != .none,
            wantsFrames: config.scope != .none,
            audioContinuation: audioContinuation,
            frameContinuation: frameContinuation)
        streamOutput = output

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        if config.scope != .none {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: CaptureStreamOutput.queue)
        }
        if config.audio != .none {
            try stream.addStreamOutput(output, type: .audio,
                                       sampleHandlerQueue: CaptureStreamOutput.queue)
        }
        try await stream.startCapture()
        self.stream = stream

        if config.audio != .none {
            try await startSystemTranscriber(locale: locale, buffers: audioStream)
        } else {
            audioContinuation.finish()
        }
        if config.scope != .none {
            startOCRReader(frames: frameStream)
        } else {
            frameContinuation.finish()
        }
    }

    private func startSystemTranscriber(locale: Locale,
                                        buffers: AsyncStream<TranscriberSession.BufferHandoff>) async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw CaptureError("Audioformat nicht verfügbar.")
        }
        let transcriber = TranscriberSession()
        systemTranscriber = transcriber
        let updates = try await transcriber.start(locale: locale, micFormat: format)

        // Detached: buffers stay off the main actor on their way into the
        // transcriber actor.
        readerTasks.append(Task.detached {
            for await handoff in buffers {
                await transcriber.feed(handoff: handoff)
                if Task.isCancelled { break }
            }
        })
        readerTasks.append(Task { [weak self] in
            do {
                for try await update in updates where update.isFinal {
                    self?.appendLine(channel: .others, text: update.text)
                }
            } catch { /* stream ended */ }
        })
    }

    private func startMic(locale: Locale) async throws {
        let capture = MicCapture()
        micCapture = capture
        let buffers = try capture.start()
        guard let format = capture.format else {
            throw CaptureError("Mikrofonformat nicht verfügbar.")
        }
        let transcriber = TranscriberSession()
        micTranscriber = transcriber
        let updates = try await transcriber.start(locale: locale, micFormat: format)

        readerTasks.append(Task.detached {
            for await buffer in buffers {
                await transcriber.feed(handoff: .init(buffer: buffer))
                if Task.isCancelled { break }
            }
        })
        readerTasks.append(Task { [weak self] in
            do {
                for try await update in updates where update.isFinal {
                    self?.appendLine(channel: .me, text: update.text)
                }
            } catch { /* stream ended */ }
        })
    }

    private func appendLine(channel: CaptureTranscript.Channel, text: String) {
        transcript.append(channel: channel, text: text)
        lineCount = transcript.lines.count
    }

    // MARK: OCR

    private func startOCRReader(frames: AsyncStream<Handoff<CVPixelBuffer>>) {
        readerTasks.append(Task.detached { [weak self] in
            var lastOCR = Date.distantPast
            for await handoff in frames {
                guard Date.now.timeIntervalSince(lastOCR) >= Self.ocrInterval else { continue }
                lastOCR = .now
                // OCR off-main; only the recognized text (Sendable) crosses back.
                if let text = await Self.recognizeText(in: handoff.value) {
                    await self?.appendScreenNote(text)
                }
                if Task.isCancelled { break }
            }
        })
    }

    private func appendScreenNote(_ text: String) {
        transcript.appendScreenNote(text)
    }

    /// Vision OCR, on-device, DE/EN — the frame is released right after.
    nonisolated static func recognizeText(in pixelBuffer: CVPixelBuffer) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["de-DE", "en-US"]
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer)
                try? handler.perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }
}

struct CaptureError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Explicit ownership handoff for AV buffers: the producer yields and never
/// touches the value again, so crossing isolation is safe by construction —
/// asserted here because region analysis can't see through the stream.
private struct Handoff<T>: @unchecked Sendable {
    let value: T
}

/// SCStream delegate/output living off the main actor: converts audio
/// sample buffers to PCM and forwards the latest video frame. Buffers are
/// handed over and dropped — nothing is retained or written.
private final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "aitvaras.capture.stream")

    private let wantsAudio: Bool
    private let wantsFrames: Bool
    private let audioContinuation: AsyncStream<TranscriberSession.BufferHandoff>.Continuation
    private let frameContinuation: AsyncStream<Handoff<CVPixelBuffer>>.Continuation

    init(wantsAudio: Bool, wantsFrames: Bool,
         audioContinuation: AsyncStream<TranscriberSession.BufferHandoff>.Continuation,
         frameContinuation: AsyncStream<Handoff<CVPixelBuffer>>.Continuation) {
        self.wantsAudio = wantsAudio
        self.wantsFrames = wantsFrames
        self.audioContinuation = audioContinuation
        self.frameContinuation = frameContinuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio:
            guard wantsAudio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
            audioContinuation.yield(TranscriberSession.BufferHandoff(buffer: pcm))
        case .screen:
            guard wantsFrames, sampleBuffer.isValid,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            frameContinuation.yield(Handoff(value: pixelBuffer))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        audioContinuation.finish()
        frameContinuation.finish()
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
