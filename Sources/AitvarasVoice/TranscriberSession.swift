import Foundation
@preconcurrency import AVFoundation
import Speech
import AitvarasCore

/// Streaming on-device STT via the macOS 26 SpeechAnalyzer (D3).
/// One session per conversation; feed mic buffers, read volatile +
/// final results.
public actor TranscriberSession {
    public struct Update: Sendable {
        public var text: String
        public var isFinal: Bool
    }

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

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
            try await request.downloadAndInstall()
        }
        return true
    }

    /// Start transcribing. Returns the update stream. `micFormat` is the
    /// format of buffers that will be fed via `feed(_:)`.
    public func start(locale: Locale, micFormat: AVAudioFormat) async throws -> AsyncThrowingStream<Update, Error> {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        VoiceLog.log("stt: requested \(locale.identifier) → using \(supported.identifier); installed: \(await SpeechTranscriber.installedLocales.map(\.identifier))")
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
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

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: inputSequence)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    VoiceLog.log("stt: result stream opened")
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        VoiceLog.log("stt: \(result.isFinal ? "FINAL" : "partial") \"\(text)\"")
                        continuation.yield(Update(text: text, isFinal: result.isFinal))
                    }
                    VoiceLog.log("stt: result stream ended")
                    continuation.finish()
                } catch {
                    VoiceLog.log("stt: result stream ERROR \(error)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private var fedBuffers = 0
    private var fedFrames: AVAudioFrameCount = 0
    private var dropLogged = false
    private var convertedPeak: Float = -120
    private var debugFile: AVAudioFile?
    private var debugFramesWritten: AVAudioFramePosition = 0

    /// Where the analyzer-input dump lands (first ~12s per session) —
    /// lets the exact audio the analyzer sees be inspected offline.
    public static var debugDumpURL: URL {
        VoiceLog.url.deletingLastPathComponent().appendingPathComponent("analyzer-input.wav")
    }

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
                return
            }
            if converted.frameLength > 0 {
                trackFeed(converted.frameLength, rate: analyzerFormat.sampleRate)
                dumpDebugAudio(converted)
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            } else if !dropLogged {
                VoiceLog.log("stt: converter produced 0 frames — buffers being DROPPED")
                dropLogged = true
            }
        } else {
            trackFeed(buffer.frameLength, rate: buffer.format.sampleRate)
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    private func trackFeed(_ frames: AVAudioFrameCount, rate: Double) {
        fedBuffers += 1
        fedFrames += frames
        if fedBuffers % 600 == 0 {
            VoiceLog.log("stt: fed \(fedBuffers) buffers ≈ \(String(format: "%.0f", Double(fedFrames) / rate))s audio, converted peak \(String(format: "%.1f", convertedPeak)) dBFS")
            convertedPeak = -120
        }
    }

    private var debugFileFailed = false

    private func dumpDebugAudio(_ buffer: AVAudioPCMBuffer) {
        convertedPeak = max(convertedPeak, MicCapture.level(of: buffer))
        guard !debugFileFailed else { return }
        if debugFile == nil {
            try? FileManager.default.removeItem(at: Self.debugDumpURL)
            // The file's processing format must match the buffers exactly
            // (same common format + interleaving) or ExtAudioFile aborts
            // the process on write.
            debugFile = try? AVAudioFile(
                forWriting: Self.debugDumpURL,
                settings: buffer.format.settings,
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved)
            if debugFile == nil {
                debugFileFailed = true
                VoiceLog.log("stt: debug dump disabled (file create failed for \(buffer.format))")
                return
            }
        }
        guard let debugFile, debugFramesWritten < AVAudioFramePosition(12 * buffer.format.sampleRate) else { return }
        do {
            try debugFile.write(from: buffer)
            debugFramesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            debugFileFailed = true
            VoiceLog.log("stt: debug dump disabled (write failed: \(error.localizedDescription))")
        }
    }

    public func stop() async {
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        converter = nil
    }
}
