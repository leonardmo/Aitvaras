import AVFoundation
import Foundation
import AitvarasCore
import AitvarasVoice

/// Explicit diagnostic only. The caller supplies synthetic audio; no capture
/// permission, microphone, system audio, account, or remote inference is used.
enum CaptureRefinementCheck {
    struct ModelResult: Codable, Sendable {
        var modelID: String
        var succeeded: Bool
        var segmentCount: Int
        var characterCount: Int
        var sourcePreserved: Bool
        var firstOffsetPreserved: Bool
        var separatelySaved: Bool
        var elapsedSeconds: Double
        var failure: String?
    }
    struct Report: Codable, Sendable {
        var version = 1
        var language: String
        var inputDurationSeconds: Double
        var inputStartOffsetSeconds: Double
        var sourceOffsets: [String: Double]
        var models: [ModelResult]
        var succeeded: Bool { models.count == 2 && models.allSatisfy(\.succeeded) }
    }

    static func run(
        audioURL: URL, outputDirectory: URL,
        language: CaptureLanguage = .english,
        includeMicrophone: Bool = false,
        modelsRoot: URL = AitvarasPaths.modelsDirectory
    ) async throws -> Report {
        let profile = outputDirectory.appendingPathComponent("synthetic-refinement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let archiveStore = CaptureAudioArchiveStore(profileDirectory: profile)
        let outputStore = CaptureRefinementStore(profileDirectory: profile)
        let firstOffset = 5.25
        let archiveID = try await Task.detached {
            try createSyntheticArchive(audioURL: audioURL, store: archiveStore, firstOffset: firstOffset,
                includeMicrophone: includeMicrophone)
        }.value
        guard let manifest = try archiveStore.inspect(archiveID).manifest,
              let source = manifest.sources.first else { throw CheckError.archive }
        let duration = Double(source.frameCount) / source.sampleRate
        let sourceOffsets = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.source.rawValue, $0.firstBufferOffset) })
        let backend = LocalRetranscriber()
        var results: [ModelResult] = []
        for model in CaptureRefinementModel.allCases {
            try Task.checkCancellation()
            let started = Date()
            var result = ModelResult(modelID: model.rawValue, succeeded: false,
                segmentCount: 0, characterCount: 0, sourcePreserved: false,
                firstOffsetPreserved: false, separatelySaved: false, elapsedSeconds: 0)
            do {
                let candidate = try await backend.transcribe(archiveID: archiveID, store: archiveStore,
                    model: model, language: language, modelsRoot: modelsRoot)
                let file = try outputStore.save(candidate)
                let reloaded = try outputStore.load(candidate.id)
                result.segmentCount = candidate.segments.count
                result.characterCount = candidate.segments.reduce(0) { $0 + $1.text.count }
                let recognizedSources = Set(candidate.segments.map { $0.source.rawValue })
                result.sourcePreserved = recognizedSources == Set(sourceOffsets.keys)
                result.firstOffsetPreserved = manifest.sources.allSatisfy { source in
                    candidate.segments.first(where: { $0.source == source.source })
                        .map { abs($0.start - source.firstBufferOffset) < 0.001 } ?? false
                }
                result.separatelySaved = file.deletingLastPathComponent() == outputStore.root
                    && reloaded.id == candidate.id && reloaded.archiveID == archiveID
                    && reloaded.segments == candidate.segments
                result.succeeded = result.characterCount > 0 && result.sourcePreserved
                    && result.firstOffsetPreserved && result.separatelySaved
                if !result.succeeded { result.failure = "Synthetic output validation failed" }
            } catch is CancellationError { throw CancellationError() }
            catch let error as LocalRetranscriber.Failure {
                // Only our closed vocabulary, never upstream errors or audio.
                result.failure = error.localizedDescription
            } catch { result.failure = "Synthetic recognition or output storage failed" }
            result.elapsedSeconds = Date().timeIntervalSince(started)
            results.append(result)
        }
        return Report(language: language.rawValue, inputDurationSeconds: duration,
            inputStartOffsetSeconds: firstOffset, sourceOffsets: sourceOffsets, models: results)
    }

    @discardableResult static func runAndWrite(
        audioURL: URL, outputDirectory: URL,
        language: CaptureLanguage = .english,
        includeMicrophone: Bool = false,
        modelsRoot: URL = AitvarasPaths.modelsDirectory
    ) async throws -> URL {
        let report = try await run(audioURL: audioURL, outputDirectory: outputDirectory,
            language: language, includeMicrophone: includeMicrophone, modelsRoot: modelsRoot)
        let file = outputDirectory.appendingPathComponent("capture-refinement-report.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard report.succeeded else { throw CheckError.recognition }
        return file
    }

    private enum CheckError: Error { case archive, recognition }

    private static func createSyntheticArchive(
        audioURL: URL, store: CaptureAudioArchiveStore, firstOffset: Double,
        includeMicrophone: Bool
    ) throws -> UUID {
        let input = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        // Diagnostics are intentionally small and bounded, not an alternate
        // import route for user recordings.
        guard input.length > 0, input.length <= Int64(format.sampleRate * 60),
              format.channelCount == 1 else { throw CheckError.archive }
        var manifest = CaptureAudioManifest(startedAt: Date(timeIntervalSince1970: 1_700_000_000), retention: .untilDeleted)
        let lease = try store.create(manifest)
        defer { withExtendedLifetime(lease) {} }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CheckError.archive }
        let sources: [CaptureAudioSource] = includeMicrophone ? [.systemAudio, .microphone] : [.systemAudio]
        for captureSource in sources {
            input.framePosition = 0
            let file = try store.reserveAudioFile(captureSource, id: manifest.id)
            var writer: AVAudioFile? = try AVAudioFile(forWriting: file, settings: settings,
                commonFormat: .pcmFormatFloat32, interleaved: false)
            while input.framePosition < input.length {
                try input.read(into: buffer)
                try writer?.write(from: buffer)
            }
            let frameCount = writer?.length ?? 0
            writer = nil // finalize CAF before it becomes eligible for inference
            let offset = firstOffset + (captureSource == .microphone ? 12.5 : 0)
            var source = CaptureAudioManifest.Source(source: captureSource, sampleRate: format.sampleRate,
                channels: 1, inputFormat: "synthetic PCM fixture", firstBufferOffset: offset)
            source.frameCount = UInt64(frameCount)
            manifest.sources.append(source)
        }
        manifest.state = .finalized
        let end = manifest.sources.map { $0.firstBufferOffset + Double($0.frameCount) / $0.sampleRate }.max() ?? 0
        manifest.endedAt = manifest.startedAt.addingTimeInterval(end)
        try store.writeManifest(manifest)
        return manifest.id
    }
}
