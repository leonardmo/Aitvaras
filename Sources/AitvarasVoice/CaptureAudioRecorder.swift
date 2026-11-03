import Foundation
import Synchronization
@preconcurrency import AVFoundation
import AitvarasCore

/// Opt-in, local, uncompressed PCM16 CAF archive. Channels and native sample
/// rates are preserved; float input is quantized to PCM16, not bit-exact float.
/// This writer never touches a transcript or downloads a model.
public final class CaptureAudioRecorder: @unchecked Sendable {
    public struct FinishResult: Sendable {
        public var id: UUID
        public var state: CaptureAudioManifest.State
        public var warning: String?
    }
    public let id: UUID
    private let store: CaptureAudioArchiveStore
    private let queue = DispatchQueue(label: "app.aitvaras.capture-audio", qos: .utility)
    private let enqueueLock = NSLock()
    private let slots = DispatchSemaphore(value: 64)
    private let accepting = Atomic(false)
    private let overflow = Atomic(false)
    private let upstreamGap = Atomic(false)
    private let quarantined = Atomic(false)
    private let warned = Atomic(false)
    private let onWarning: @Sendable (String) -> Void
    // Accessed only on the serial writer queue after initialization.
    private var manifest: CaptureAudioManifest
    private var lease: CaptureAudioArchiveStore.Lease?
    private var files: [CaptureAudioSource: AVAudioFile] = [:]
    private var formats: [CaptureAudioSource: AVAudioFormat] = [:]
    private var lastCheckpoint = Date.distantPast
    private var finished: FinishResult?

    private init(store: CaptureAudioArchiveStore, id: UUID, startedAt: Date,
                 retention: CaptureAudioRetention, onWarning: @escaping @Sendable (String) -> Void) {
        self.store = store; self.id = id; self.onWarning = onWarning
        manifest = CaptureAudioManifest(id: id, startedAt: startedAt, retention: retention)
    }

    /// Call only after explicit retention consent. Discard never creates files.
    public static func create(store: CaptureAudioArchiveStore, id: UUID = UUID(), startedAt: Date,
                              retention: CaptureAudioRetention,
                              onWarning: @escaping @Sendable (String) -> Void) async throws -> CaptureAudioRecorder {
        guard retention != .discard else { throw CaptureAudioArchiveStore.ArchiveError.retentionDisabled }
        let recorder = CaptureAudioRecorder(store: store, id: id, startedAt: startedAt,
                                            retention: retention, onWarning: onWarning)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            recorder.queue.async {
                do {
                    recorder.lease = try store.create(recorder.manifest)
                    recorder.accepting.store(true, ordering: .releasing)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        return recorder
    }

    /// Bounded handoff for detached capture-feed tasks, not realtime taps.
    /// A short ordering lock serializes producers/finish; it never covers disk
    /// work or waits for queue capacity. The buffer must be owned, immutable, and
    /// never reused by its producer after handoff. Read-only STT use may coexist.
    /// At most 64 buffers (each <= 1 MiB) are queued; overload disables the
    /// archive with a warning rather than silently creating a gapped success.
    @discardableResult public func append(handoff: TranscriberSession.BufferHandoff,
                                         source: CaptureAudioSource, at: Date = .now) -> Bool {
        guard accepting.load(ordering: .acquiring) else { return false }
        enqueueLock.lock()
        defer { enqueueLock.unlock() }
        guard accepting.load(ordering: .acquiring) else { return false }
        let bytes = UnsafeMutableAudioBufferListPointer(handoff.buffer.mutableAudioBufferList)
            .reduce(UInt64(0)) { $0 + UInt64($1.mDataByteSize) }
        guard bytes <= 1_048_576, slots.wait(timeout: .now()) == .success else {
            stopForOverflow(); return false
        }
        queue.async { [self] in
            defer { slots.signal() }
            guard !quarantined.load(ordering: .acquiring), manifest.failure == nil || manifest.failure == .upstreamGap else { return }
            if overflow.load(ordering: .acquiring) { fail(.queueOverflow); return }
            do { try write(handoff.buffer, source: source, at: at) }
            catch { fail(.storage) }
        }
        return true
    }

    /// Called when upstream capture drops PCM or cannot drain before its
    /// deadline. Keep any subsequent audio, but never claim a complete archive.
    /// Atomic and non-waiting; does not touch files or the live transcript.
    public func markIncomplete() {
        upstreamGap.store(true, ordering: .releasing)
        warn("Audio was dropped before archiving. The retained recording is incomplete; the live transcript remains separate.")
    }

    private func stopForOverflow() {
        overflow.store(true, ordering: .releasing)
        accepting.store(false, ordering: .releasing)
        warn("Audio archiving could not keep up and stopped. The live transcript continues; the retained recording is incomplete.")
    }
    private func warn(_ message: String) {
        guard !warned.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let callback = onWarning
        DispatchQueue.global(qos: .utility).async { callback(message) }
    }
    private func fail(_ failure: CaptureAudioManifest.Failure) {
        accepting.store(false, ordering: .releasing)
        manifest.state = .failed; manifest.failure = failure
        warn("Audio archiving stopped after a storage or format error. The live transcript continues; the retained recording is incomplete.")
        files.removeAll()
        try? store.writeManifest(manifest)
    }
    private func write(_ buffer: AVAudioPCMBuffer, source: CaptureAudioSource, at: Date) throws {
        guard buffer.frameLength > 0 else { return }
        if upstreamGap.load(ordering: .acquiring), manifest.failure == nil { manifest.failure = .upstreamGap }
        if let format = formats[source], format != buffer.format {
            fail(.formatChanged); return
        }
        if files[source] == nil {
            let format = buffer.format
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
                throw CaptureAudioArchiveStore.ArchiveError.invalidManifest
            }
            let url = try store.reserveAudioFile(source, id: id)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            files[source] = try AVAudioFile(forWriting: url, settings: settings,
                                           commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            formats[source] = format
            manifest.sources.append(.init(source: source, sampleRate: format.sampleRate,
                                          channels: format.channelCount,
                                          inputFormat: "pcm-\(format.commonFormat.rawValue)-\(format.isInterleaved ? "interleaved" : "planar")",
                                          firstBufferOffset: max(0, at.timeIntervalSince(manifest.startedAt))))
        }
        try files[source]!.write(from: buffer)
        if let index = manifest.sources.firstIndex(where: { $0.source == source }) {
            manifest.sources[index].frameCount += UInt64(buffer.frameLength)
        }
        if Date.now.timeIntervalSince(lastCheckpoint) >= 5 {
            try store.writeManifest(manifest)
            lastCheckpoint = .now
        }
    }

    /// Bounded even if a filesystem call ignores cancellation. A timed-out
    /// worker is quarantined; its lease protects files until it actually exits.
    /// Never wait for this result before saving the independent live transcript.
    public func finish(timeout: Duration = .seconds(3)) async -> FinishResult {
        do {
            return try await AsyncDeadline.run(for: timeout) { [self] in
                await withCheckedContinuation { continuation in
                    enqueueLock.lock()
                    accepting.store(false, ordering: .releasing)
                    queue.async { [self] in
                        if let finished { continuation.resume(returning: finished); return }
                        files.removeAll() // closes CAF headers, on the worker only
                        manifest.endedAt = .now
                        if quarantined.load(ordering: .acquiring) {
                            manifest.state = .interrupted; manifest.failure = .finalizationTimeout
                        } else if overflow.load(ordering: .acquiring) {
                            manifest.state = .failed; manifest.failure = .queueOverflow
                        } else if upstreamGap.load(ordering: .acquiring), manifest.failure == nil || manifest.failure == .upstreamGap {
                            manifest.state = .failed; manifest.failure = .upstreamGap
                        } else if manifest.failure == nil { manifest.state = .finalized }
                        do { try store.writeManifest(manifest) }
                        catch { manifest.state = .failed; manifest.failure = .storage }
                        // A late completion must not upgrade a quarantined run.
                        if quarantined.load(ordering: .acquiring) {
                            manifest.state = .interrupted; manifest.failure = .finalizationTimeout
                            try? store.writeManifest(manifest)
                        }
                        let result = FinishResult(id: id, state: manifest.state,
                            warning: manifest.state == .finalized ? nil : "Retained audio is incomplete; the live transcript remains saved separately.")
                        finished = result
                        lease = nil
                        continuation.resume(returning: result)
                    }
                    enqueueLock.unlock()
                }
            }
        } catch {
            accepting.store(false, ordering: .releasing)
            quarantined.store(true, ordering: .releasing)
            let warning = "Audio finalization timed out. Its files are quarantined until the writer stops; the live transcript remains separate."
            warn(warning)
            return FinishResult(id: id, state: .interrupted, warning: warning)
        }
    }
}
