import Foundation
import Testing
import Darwin
import AitvarasCore
import AitvarasVoice
@preconcurrency import AVFoundation

@Suite struct CaptureAudioArchiveTests {
    private func profile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func discardDoesNotCreateArchiveRoot() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.retentionDisabled) {
            _ = try store.create(.init(startedAt: .now, retention: .discard))
        }
        #expect(!FileManager.default.fileExists(atPath: store.root.path))
        #expect(try store.list().isEmpty)
    }

    @Test func manifestIsPrivateAndCrashLeftoversAreInspectable() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let manifest = CaptureAudioManifest(startedAt: .now, retention: .sevenDays)
        var lease: CaptureAudioArchiveStore.Lease? = try store.create(manifest)
        #expect(try store.inspect(manifest.id).isLeased)
        let folder = store.directory(for: manifest.id)
        let file = folder.appendingPathComponent("manifest.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(profile.path))
        #expect(!text.contains("transcript"))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
        #expect(try store.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        withExtendedLifetime(lease) {}
        lease = nil
        let entry = try store.inspect(manifest.id)
        #expect(entry.isInterrupted)
        #expect(entry.manifest?.state == .recording)
        #expect(try store.list().count == 1)
    }

    @Test func leasesPreventDeletionAcrossStoreInstances() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let otherStore = CaptureAudioArchiveStore(profileDirectory: profile)
        let manifest = CaptureAudioManifest(startedAt: .now.addingTimeInterval(-8 * 86400), retention: .sevenDays)
        var writer: CaptureAudioArchiveStore.Lease? = try store.create(manifest)
        var reader: CaptureAudioArchiveStore.Lease? = try otherStore.acquireLease(manifest.id)
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.busy) { try store.delete(manifest.id) }
        #expect(try store.deleteExpired().isEmpty)
        withExtendedLifetime(writer) {}; writer = nil
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.busy) { try store.delete(manifest.id) }
        withExtendedLifetime(reader) {}; reader = nil
        #expect(try otherStore.deleteExpired() == [manifest.id])
    }

    @Test func manualRetentionSurvivesExpiryCleanup() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let manifest = CaptureAudioManifest(startedAt: .distantPast, retention: .untilDeleted)
        _ = try store.create(manifest)
        #expect(try store.deleteExpired().isEmpty)
        #expect(try store.inspect(manifest.id).manifest?.expiresAt == nil)
        try store.delete(manifest.id)
        #expect(try store.list().isEmpty)
    }

    @Test func unknownFilesAndSymlinksAreNeverTraversedOrDeleted() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let manifest = CaptureAudioManifest(startedAt: .now, retention: .untilDeleted)
        _ = try store.create(manifest)
        let outside = profile.appendingPathComponent("synthetic-sentinel")
        try Data("keep".utf8).write(to: outside)
        let link = store.directory(for: manifest.id).appendingPathComponent("microphone.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.unsafePath) { try store.delete(manifest.id) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: link)
        let unknown = store.directory(for: manifest.id).appendingPathComponent("unrecognized")
        try Data().write(to: unknown)
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.unsafePath) { try store.delete(manifest.id) }
        #expect(FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test func rootSymlinkIsRejected() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let external = try self.profile(); defer { try? FileManager.default.removeItem(at: external) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        try FileManager.default.createSymbolicLink(at: store.root, withDestinationURL: external)
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.unsafePath) {
            _ = try store.create(.init(startedAt: .now, retention: .sevenDays))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test func malformedManifestIsInspectableButNotExpired() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let manifest = CaptureAudioManifest(startedAt: .now, retention: .sevenDays)
        _ = try store.create(manifest)
        try Data("broken".utf8).write(to: store.directory(for: manifest.id).appendingPathComponent("manifest.json"))
        #expect(try store.inspect(manifest.id).isInterrupted)
        #expect(try store.deleteExpired(now: .distantFuture).isEmpty)
    }

    @Test func exportCopiesOnlyKnownFilesAndDoesNotOverwrite() throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let destination = try self.profile(); defer { try? FileManager.default.removeItem(at: destination) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        var manifest = CaptureAudioManifest(startedAt: .now, retention: .untilDeleted)
        _ = try store.create(manifest)
        manifest.state = .finalized
        try store.writeManifest(manifest)
        let exported = try store.export(manifest.id, to: destination)
        #expect(exported.lastPathComponent == manifest.id.uuidString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: exported.path) == ["manifest.json"])
        #expect(throws: CaptureAudioArchiveStore.ArchiveError.io) { _ = try store.export(manifest.id, to: destination) }
        try store.delete(manifest.id)
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("manifest.json").path))
    }

    @Test func recorderKeepsSeparateSourceFormatsOffsetsAndFrames() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let start = Date.now
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: start,
                                                             retention: .sevenDays, onWarning: { _ in })
        for (source, rate, channels, offset) in [
            (CaptureAudioSource.microphone, 16_000.0, UInt32(1), 0.25),
            (.systemAudio, 48_000.0, UInt32(2), 1.5)
        ] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for channel in 0..<Int(channels) {
                for frame in 0..<480 { buffer.floatChannelData![channel][frame] = 0.125 }
            }
            #expect(recorder.append(handoff: .init(buffer: buffer), source: source, at: start.addingTimeInterval(offset)))
        }
        let result = await recorder.finish()
        #expect(result.state == .finalized)
        let manifest = try #require(store.inspect(recorder.id).manifest)
        #expect(manifest.sources.count == 2)
        let mic = try #require(manifest.sources.first { $0.source == .microphone })
        let system = try #require(manifest.sources.first { $0.source == .systemAudio })
        #expect(mic.frameCount == 480 && system.frameCount == 480)
        #expect(mic.sampleRate == 16_000 && system.sampleRate == 48_000)
        #expect(mic.channels == 1 && system.channels == 2)
        #expect(abs(mic.firstBufferOffset - 0.25) < 0.001)
        #expect(abs(system.firstBufferOffset - 1.5) < 0.001)
        let lease = try store.acquireLease(recorder.id)
        let audio = try AVAudioFile(forReading: lease.audioURL(for: .microphone))
        #expect(audio.length == 480)
        #expect(audio.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
    }

    @Test func recorderRejectsOversizedQueueItemsWithoutBreakingTranscriptPath() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: .now,
                                                             retention: .untilDeleted, onWarning: { _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 200_000)!
        buffer.frameLength = 200_000
        #expect(!recorder.append(handoff: .init(buffer: buffer), source: .systemAudio))
        let result = await recorder.finish()
        #expect(result.state == .failed)
        #expect(try store.inspect(recorder.id).manifest?.failure == .queueOverflow)
    }

    @Test func sourceFormatChangeIsNotSilentlyConcatenated() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: .now,
                                                             retention: .untilDeleted, onWarning: { _ in })
        for rate in [16_000.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
            buffer.frameLength = 16
            for frame in 0..<16 { buffer.floatChannelData![0][frame] = 0 }
            #expect(recorder.append(handoff: .init(buffer: buffer), source: .microphone))
        }
        let result = await recorder.finish()
        #expect(result.state == .failed)
        #expect(try store.inspect(recorder.id).manifest?.failure == .formatChanged)
    }

    @Test func upstreamGapCannotProduceAFinalizedArchive() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: .now,
                                                             retention: .untilDeleted, onWarning: { _ in })
        recorder.markIncomplete()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        for frame in 0..<16 { buffer.floatChannelData![0][frame] = 0 }
        #expect(recorder.append(handoff: .init(buffer: buffer), source: .microphone))
        let result = await recorder.finish()
        #expect(result.state == .failed)
        let manifest = try #require(store.inspect(recorder.id).manifest)
        #expect(manifest.failure == .upstreamGap)
        #expect(manifest.sources.first?.frameCount == 16)
    }

    @Test func recordingCheckpointAndPartialCAFRemainInspectable() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: .now,
                                                             retention: .untilDeleted, onWarning: { _ in })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for frame in 0..<480 { buffer.floatChannelData![0][frame] = 0.125 }
        #expect(recorder.append(handoff: .init(buffer: buffer), source: .microphone))
        // Wait only for the first checkpoint, not finish/CAF close. This covers
        // inspectability of an idle writer's partial CAF, not physical power loss.
        var entry = try store.inspect(recorder.id)
        for _ in 0..<100 where entry.manifest?.sources.first?.frameCount != 480 {
            try await Task.sleep(for: .milliseconds(10))
            entry = try store.inspect(recorder.id)
        }
        #expect(entry.manifest?.state == .recording)
        #expect(entry.manifest?.sources.first?.frameCount == 480)
        #expect(entry.availableSources == [.microphone])
        let lease = try store.acquireLease(recorder.id)
        let partial = try AVAudioFile(forReading: lease.audioURL(for: .microphone))
        #expect(partial.length == 480)
        let result = await recorder.finish()
        #expect(result.state == .finalized)
    }

    @Test func concurrentSourceProducersDoNotCauseFalseOverflow() async throws {
        let profile = try profile(); defer { try? FileManager.default.removeItem(at: profile) }
        let store = CaptureAudioArchiveStore(profileDirectory: profile)
        let recorder = try await CaptureAudioRecorder.create(store: store, startedAt: .now,
                                                             retention: .untilDeleted, onWarning: { _ in })
        // Forty-eight total enqueues cannot exhaust the sixty-four-slot queue,
        // even if no disk write completes while these two producers run.
        await withTaskGroup(of: Void.self) { group in
            for source in CaptureAudioSource.allCases {
                group.addTask {
                    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    for _ in 0..<24 {
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
                        buffer.frameLength = 16
                        for frame in 0..<16 { buffer.floatChannelData![0][frame] = 0.125 }
                        #expect(recorder.append(handoff: .init(buffer: buffer), source: source))
                    }
                }
            }
        }
        let result = await recorder.finish()
        #expect(result.state == .finalized)
        let manifest = try #require(store.inspect(recorder.id).manifest)
        #expect(manifest.failure == nil)
        #expect(manifest.sources.count == 2)
        #expect(manifest.sources.allSatisfy { $0.frameCount == 24 * 16 })
    }
}
