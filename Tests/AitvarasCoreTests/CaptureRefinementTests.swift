import Foundation
import AVFoundation
import Testing
import AitvarasCore
@testable import AitvarasVoice

@Suite struct CaptureRefinementTests {
    @Test func catalogueIsPinnedAndOutsideChatCatalogue() throws {
        #expect(CaptureRefinementModel.allCases.count == 2)
        for model in CaptureRefinementModel.allCases {
            #expect(model.revision.count == 40)
            #expect(model.revision.allSatisfy { $0.isHexDigit })
            #expect(model.directoryName.hasPrefix("Transcription/"))
            #expect(model.expectedBytes >= model.requiredFiles.values.reduce(0, +))
            #expect(model.requiredFiles["model.safetensors"] != nil)
            #expect(model.requiredFiles["tokenizer_config.json"] != nil)
        }
        #expect(CaptureRefinementModel.whisperLargeV3Turbo.requiredFiles["tokenizer.json"] != nil)
    }

    @Test func installationRequiresCompleteLocalAssetsAndRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-asr-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CaptureRefinementModel.whisperLargeV3Turbo
        #expect(!model.isInstalled(in: root))
        let folder = model.directory(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, size) in model.requiredFiles {
            let file = folder.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size)) // sparse fixture, no real weights
            try handle.close()
        }
        #expect(model.isInstalled(in: root))
        #expect(!AitvarasPaths.isCompleteModelDirectory(root.appendingPathComponent("Transcription")))
        let tokenizer = folder.appendingPathComponent("tokenizer.json")
        let moved = root.appendingPathComponent("synthetic-tokenizer.json")
        try FileManager.default.moveItem(at: tokenizer, to: moved)
        #expect(!model.isInstalled(in: root))
        try FileManager.default.createSymbolicLink(at: tokenizer, withDestinationURL: moved)
        #expect(!model.isInstalled(in: root))
        try FileManager.default.removeItem(at: tokenizer)
        try FileManager.default.moveItem(at: moved, to: tokenizer)
        #expect(model.isInstalled(in: root))
        let extra = folder.appendingPathComponent("unexpected.safetensors")
        try Data([1]).write(to: extra)
        #expect(!model.isInstalled(in: root))
    }

    @Test func candidatesPreserveSourceAndCoarseOffsets() throws {
        let candidate = CaptureRefinementCandidate(archiveID: UUID(), model: .qwen3ASR17B8bit,
            segments: [.init(source: .systemAudio, start: 63.5, end: 93.5, text: "Synthetic lecture."),
                       .init(source: .microphone, start: 4.25, end: 14.25, text: "Synthetic question.")])
        #expect(candidate.rendered().hasPrefix("[00:00:04] [Mikrofon]"))
        #expect(candidate.rendered().contains("[00:01:03] [Systemaudio]"))
        #expect(candidate.document.contains("not word-level alignment"))
        #expect(candidate.document.contains("original live transcript is unchanged"))
        #expect(candidate.segments[0].start == 63.5)
        #expect(candidate.segments[1].end == 14.25)
    }

    @Test func candidateStoreIsSeparateVersionedAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-asr-output-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureRefinementStore(profileDirectory: root)
        let archive = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CaptureRefinementCandidate(archiveID: archive, model: .qwen3ASR17B8bit, createdAt: date,
            segments: [.init(source: .systemAudio, start: 8, end: 18, text: "Synthetic transcript one.")])
        let second = CaptureRefinementCandidate(archiveID: archive, model: .whisperLargeV3Turbo, createdAt: date.addingTimeInterval(1),
            segments: [.init(source: .systemAudio, start: 8, end: 18, text: "Synthetic transcript two.")])
        let file = try store.save(first)
        _ = try store.save(second)
        #expect(try store.load(first.id) == first)
        #expect(try store.list(archiveID: archive).map(\.id) == [second.id, first.id])
        #expect(try store.list(archiveID: UUID()).isEmpty)
        #expect(throws: (any Error).self) { try store.save(first) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CaptureAudio").path))
    }

    @Test func candidateStoreRejectsSymlinkRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-asr-link-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("CaptureRefinements"), withDestinationURL: outside)
        let candidate = CaptureRefinementCandidate(archiveID: UUID(), model: .whisperLargeV3Turbo, segments: [])
        #expect(throws: (any Error).self) { try CaptureRefinementStore(profileDirectory: root).save(candidate) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func deletingCandidatesPreservesUnrelatedAndUnknownFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-asr-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureRefinementStore(profileDirectory: root)
        let selected = CaptureRefinementCandidate(archiveID: UUID(), model: .whisperLargeV3Turbo, segments: [])
        let unrelated = CaptureRefinementCandidate(archiveID: UUID(), model: .qwen3ASR17B8bit, segments: [])
        _ = try store.save(selected); _ = try store.save(unrelated)
        let unknown = store.root.appendingPathComponent("unknown.txt")
        try Data("synthetic unknown file".utf8).write(to: unknown)
        try store.delete(archiveID: selected.archiveID)
        #expect(!FileManager.default.fileExists(atPath: store.url(for: selected.id).path))
        #expect(try store.load(unrelated.id).id == unrelated.id)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test func stereoSpeechOnSecondChannelIsDownmixedAndResampled() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channels = try #require(buffer.floatChannelData)
        for index in 0..<48_000 {
            channels[0][index] = 0
            channels[1][index] = 0.2 * sin(Float(index) * 2 * .pi * 440 / 48_000)
        }
        let samples = try LocalRetranscriber.mono16k(buffer)
        #expect((15_900...16_100).contains(samples.count))
        let allFinite = samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect(samples.contains { abs($0) > 0.01 })
    }

    @Test func progressClampsMalformedValues() {
        #expect(CaptureRefinementProgress(completedAudioSeconds: -1, totalAudioSeconds: 10).fraction == 0)
        #expect(CaptureRefinementProgress(completedAudioSeconds: 11, totalAudioSeconds: 10).fraction == 1)
        #expect(CaptureRefinementProgress(completedAudioSeconds: .infinity, totalAudioSeconds: 10).fraction == 0)
    }
}
