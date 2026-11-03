import Foundation
@preconcurrency import AVFoundation
import Speech
import Synchronization
import AitvarasCore

/// Streaming on-device STT via the macOS 26 SpeechAnalyzer (D3).
/// One session per conversation; feed mic buffers, read volatile +
/// final results.
public actor TranscriberSession {
    public struct Update: Sendable {
        public var text: String
        public var isFinal: Bool
        public init(text: String, isFinal: Bool) {
            self.text = text
            self.isFinal = isFinal
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var resultTask: Task<Void, Never>?
    private var outputContinuation: AsyncThrowingStream<Update, Error>.Continuation?
    private var resultStatus = SpeechResultStatus()

    public struct StopResult: Sendable {
        public var finalized: Bool
        public var warning: String?
    }

    public init() {}

    public static func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Ensure the on-device model for `locale` is installed (downloads on
    /// first use — surfaced to onboarding UI as a one-time step).
    public static func ensureModel(locale: Locale) async throws -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return false
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
                try Task.checkCancellation()
            } onCancel: { request.progress.cancel() }
        }
        return true
    }

    /// Start transcribing. Returns the update stream. `micFormat` is the
    /// format of buffers that will be fed via `feed(_:)`.
    public func start(locale: Locale, micFormat: AVAudioFormat, allowDownload: Bool = true) async throws -> AsyncThrowingStream<Update, Error> {
        guard analyzer == nil, resultTask == nil else {
            throw NSError(domain: "Aitvaras.Transcriber", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Speech recognition is already running."])
        }
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        VoiceLog.log("stt: requested \(locale.identifier) → using \(supported.identifier); installed: \(await SpeechTranscriber.installedLocales.map(\.identifier))")
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard allowDownload else {
                throw NSError(domain: "Aitvaras.Transcriber", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Speech assets are missing. Download the selected language in Capture settings before starting."])
            }
            VoiceLog.log("stt: downloading speech model assets…")
            try await request.downloadAndInstall()
            VoiceLog.log("stt: assets installed")
        } else {
            VoiceLog.log("stt: assets already present")
        }

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        VoiceLog.log("stt: analyzer format \(analyzerFormat.map { "\($0.sampleRate)Hz \($0.channelCount)ch" } ?? "NIL — no conversion target!")")
        if let analyzerFormat, analyzerFormat != micFormat {
            converter = AVAudioConverter(from: micFormat, to: analyzerFormat)
            VoiceLog.log("stt: converter \(micFormat.sampleRate)→\(analyzerFormat.sampleRate) created=\(converter != nil)")
        }

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(128))
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)

        let (updates, continuation) = AsyncThrowingStream<Update, Error>.makeStream()
        let resultStatus = SpeechResultStatus()
        self.resultStatus = resultStatus
        outputContinuation = continuation
        let task = Task {
                do {
                    VoiceLog.log("stt: result stream opened")
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        // Diagnostics describe pipeline health only. Never
                        // duplicate private speech content into voice.log.
                        if result.isFinal {
                            VoiceLog.log("stt: final result (\(text.count) chars)")
                        }
                        continuation.yield(Update(text: text, isFinal: result.isFinal))
                    }
                    VoiceLog.log("stt: result stream ended")
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { resultStatus.failed.withLock { $0 = true } }
                    VoiceLog.log("stt: result stream ERROR \(error)")
                    continuation.finish(throwing: error)
                }
        }
        resultTask = task
        continuation.onTermination = { _ in task.cancel() }
        return updates
    }

    private var fedBuffers = 0
    private var fedFrames: AVAudioFrameCount = 0
    private var dropLogged = false
    private var inputFailureReported = false
    private var convertedPeak: Float = -120

    /// Explicit ownership handoff for feeding buffers across isolation
    /// domains (capture pipeline): the producer yields the buffer and never
    /// touches it again — asserted Sendable because region analysis can't
    /// see through stream plumbing.
    public struct BufferHandoff: @unchecked Sendable {
        public let buffer: AVAudioPCMBuffer
        public init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    public func feed(handoff: BufferHandoff) {
        feed(handoff.buffer)
    }

    /// Feed a mic buffer (converted to the analyzer's format if needed).
    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let inputContinuation else { return }
        if let converter, let analyzerFormat {
            let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            final class FeedState: @unchecked Sendable { var consumed = false }
            let feed = FeedState()
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, outStatus in
                if feed.consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                feed.consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let conversionError {
                if !dropLogged {
                    VoiceLog.log("stt: conversion ERROR \(conversionError.localizedDescription) — buffers being DROPPED")
                    dropLogged = true
                }
                reportInputFailure("Audio format conversion failed; the transcript may have a gap.")
                return
            }
            if converted.frameLength > 0 {
                trackFeed(converted.frameLength, rate: analyzerFormat.sampleRate)
                convertedPeak = max(convertedPeak, MicCapture.level(of: converted))
                reportInputYield(inputContinuation.yield(AnalyzerInput(buffer: converted)))
            } else if !dropLogged {
                VoiceLog.log("stt: converter produced 0 frames — buffers being DROPPED")
                dropLogged = true
                reportInputFailure("Audio format conversion produced no samples; check the selected input.")
            }
        } else {
            trackFeed(buffer.frameLength, rate: buffer.format.sampleRate)
            reportInputYield(inputContinuation.yield(AnalyzerInput(buffer: buffer)))
        }
    }

    private func reportInputYield(_ result: AsyncStream<AnalyzerInput>.Continuation.YieldResult) {
        if case .dropped = result {
            reportInputFailure("Speech input could not keep up; audio was dropped. Check the saved transcript for a gap.")
        }
    }

    private func reportInputFailure(_ message: String) {
        guard !inputFailureReported else { return }
        inputFailureReported = true
        outputContinuation?.finish(throwing: NSError(domain: "Aitvaras.Transcriber", code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func trackFeed(_ frames: AVAudioFrameCount, rate: Double) {
        fedBuffers += 1
        fedFrames += frames
        if fedBuffers % 600 == 0 {
            VoiceLog.log("stt: fed \(fedBuffers) buffers ≈ \(String(format: "%.0f", Double(fedFrames) / rate))s audio, converted peak \(String(format: "%.1f", convertedPeak)) dBFS")
            convertedPeak = -120
        }
    }

    @discardableResult
    public func stop(finalizing: Bool = false) async -> StopResult {
        // Detach this session's state before awaiting a framework call. A late
        // result can only reach its old continuation, never a subsequent session.
        let analyzer = self.analyzer
        let resultTask = self.resultTask
        let continuation = outputContinuation
        let resultStatus = self.resultStatus
        self.analyzer = nil
        self.resultTask = nil
        outputContinuation = nil
        inputContinuation?.finish()
        inputContinuation = nil
        converter = nil
        analyzerFormat = nil
        guard let analyzer else {
            continuation?.finish()
            resultTask?.cancel()
            return StopResult(finalized: true, warning: nil)
        }

        var finalized = !finalizing
        var warning: String?
        do {
            if finalizing {
                try await AsyncDeadline.run(for: .seconds(8)) {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                finalized = true
            } else {
                try await AsyncDeadline.run(for: .seconds(2)) {
                    await analyzer.cancelAndFinishNow()
                }
            }
            if let resultTask {
                try await AsyncDeadline.run(for: .seconds(1)) { await resultTask.value }
            }
        } catch {
            finalized = false
            warning = "Speech recognition did not finish cleanly; the last words may be incomplete."
            // Best effort cleanup is bounded as well: cancellation must never
            // make the UI wait indefinitely for a framework result stream.
            _ = try? await AsyncDeadline.run(for: .seconds(2)) {
                await analyzer.cancelAndFinishNow()
            }
        }
        continuation?.finish()
        resultTask?.cancel()
        if finalizing, resultStatus.failed.withLock({ $0 }) {
            finalized = false
            warning = "Speech recognition reported a result-stream error; the transcript may have a gap."
        }
        return StopResult(finalized: finalized, warning: warning)
    }
}

private final class SpeechResultStatus: Sendable {
    let failed = Mutex(false)
}
