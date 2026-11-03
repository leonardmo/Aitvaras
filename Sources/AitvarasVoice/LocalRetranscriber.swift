import Foundation
import AVFoundation
import MLX
import MLXAudioSTT
import AitvarasCore

/// Native second-pass ASR. No fromPretrained/repository-loading API is used:
/// callers must explicitly install every required asset before starting.
public actor LocalRetranscriber {
    public enum Failure: Error, LocalizedError, Sendable {
        case busy, modelNotInstalled, archiveUnavailable, unsupportedAudio, noSpeech, inference
        public var errorDescription: String? {
            switch self {
            case .busy: "A local retranscription is already running."
            case .modelNotInstalled: "Download and verify the selected speech model first."
            case .archiveUnavailable: "A finalized audio recording is required."
            case .unsupportedAudio: "The saved audio could not be read safely."
            case .noSpeech: "No speech was recognized in the saved audio. Original transcript unchanged."
            case .inference: "The local speech model could not transcribe this recording."
            }
        }
    }

    public private(set) var isProcessing = false
    public init() {}

    /// Cancellation is acknowledged only after the active native chunk returns.
    /// Upstream Whisper does not expose cooperative token cancellation. We do
    /// not detach inference or claim that a cancelled consumer stopped the GPU.
    /// There are no background warm-up, polling or idle inference tasks.
    public func transcribe(
        archiveID: UUID,
        store: CaptureAudioArchiveStore,
        model selected: CaptureRefinementModel,
        language: CaptureLanguage,
        modelsRoot: URL = AitvarasPaths.modelsDirectory,
        onProgress: @escaping @Sendable (CaptureRefinementProgress) -> Void = { _ in }
    ) async throws -> CaptureRefinementCandidate {
        guard !isProcessing else { throw Failure.busy }
        guard selected.isInstalled(in: modelsRoot) else { throw Failure.modelNotInstalled }
        isProcessing = true
        defer { isProcessing = false }
        try Task.checkCancellation()
        let lease = try store.acquireLease(archiveID)
        defer { withExtendedLifetime(lease) {} }
        guard let manifest = try store.inspect(archiveID).manifest,
              manifest.state == .finalized, !manifest.sources.isEmpty else { throw Failure.archiveUnavailable }
        guard manifest.sources.count <= CaptureAudioSource.allCases.count,
              Set(manifest.sources.map { $0.source.rawValue }).count == manifest.sources.count,
              manifest.sources.allSatisfy({ source in
                  source.sampleRate.isFinite && (8_000...192_000).contains(source.sampleRate)
                      && (1...8).contains(source.channels) && source.storedBitsPerChannel == 16
                      && source.firstBufferOffset.isFinite && source.firstBufferOffset >= 0
              }) else { throw Failure.unsupportedAudio }
        let total = manifest.sources.reduce(0.0) { total, source in
            total + (source.sampleRate > 0 ? Double(source.frameCount) / source.sampleRate : 0)
        }
        var completed = 0.0
        onProgress(.init(completedAudioSeconds: 0, totalAudioSeconds: total))

        // Drop model weights explicitly before clearing the reuse cache, on
        // every exit path. No model is retained by this service between jobs.
        var recognizer: (any STTGenerationModel)? = nil
        defer { recognizer = nil; MLX.Memory.clearCache() }
        do {
            switch selected {
            case .qwen3ASR17B8bit:
                recognizer = try await Qwen3ASRModel.fromModelDirectory(selected.directory(in: modelsRoot))
            case .whisperLargeV3Turbo:
                // isInstalled requires tokenizer.json so the library's optional
                // downloadTokenizerAssets fallback cannot be reached.
                recognizer = try await WhisperModel.fromDirectory(selected.directory(in: modelsRoot))
            }
        } catch {
            try Task.checkCancellation()
            throw Failure.inference
        }
        try Task.checkCancellation()
        let parameters = STTGenerateParameters(
            maxTokens: selected == .whisperLargeV3Turbo ? 448 : 2048,
            temperature: 0, topP: 1, verbose: false,
            language: language == .german ? "German" : "English",
            chunkDuration: 30, minChunkDuration: 0.01)
        var segments: [CaptureRefinementCandidate.Segment] = []
        for source in manifest.sources {
            try Task.checkCancellation()
            guard source.firstBufferOffset.isFinite, source.firstBufferOffset >= 0 else { throw Failure.unsupportedAudio }
            let file: AVAudioFile
            do { file = try AVAudioFile(forReading: lease.audioURL(for: source.source), commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { throw Failure.unsupportedAudio }
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate >= 8_000, format.sampleRate <= 192_000,
                  (1...8).contains(format.channelCount),
                  format.channelCount == source.channels,
                  abs(format.sampleRate - source.sampleRate) < 1,
                  file.length >= 0, UInt64(file.length) == source.frameCount else { throw Failure.unsupportedAudio }
            let capacity = AVAudioFrameCount(format.sampleRate * 30)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure.unsupportedAudio }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let position = file.framePosition
                do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), file.length - position))) }
                catch { throw Failure.unsupportedAudio }
                guard buffer.frameLength > 0 else { throw Failure.unsupportedAudio }
                let duration = Double(buffer.frameLength) / format.sampleRate
                let samples = try Self.mono16k(buffer)
                // Avoid manufacturing a transcript for digitally silent audio.
                let hasSignal = samples.contains { abs($0) > 0.0001 }
                if hasSignal {
                    guard let output = recognizer?.generate(audio: MLXArray(samples), generationParameters: parameters) else {
                        throw Failure.inference
                    }
                    try Task.checkCancellation()
                    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let start = source.firstBufferOffset + Double(position) / format.sampleRate
                        segments.append(.init(source: source.source, start: start, end: start + duration, text: text))
                    }
                }
                completed += duration
                onProgress(.init(completedAudioSeconds: completed, totalAudioSeconds: total))
                MLX.Memory.clearCache()
                // Release the actor executor between chunks. The model itself
                // remains confined here; no other transcribe can enter.
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        guard !segments.isEmpty else { throw Failure.noSpeech }
        return CaptureRefinementCandidate(archiveID: archiveID, model: selected, segments: segments)
    }

    static func mono16k(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 64) else {
            throw Failure.unsupportedAudio
        }
        // AVAudioConverter defaults to remapping (often only channel zero),
        // which would lose speech present exclusively on another channel.
        converter.downmix = true
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard status != .error, error == nil, output.frameLength > 0,
              let data = output.floatChannelData?[0] else { throw Failure.unsupportedAudio }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
