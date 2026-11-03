import Foundation
@preconcurrency import AVFoundation

/// Microphone capture with the system voice-processing unit enabled
/// (echo cancellation — required for hands-free conversation while
/// Aitvaras is speaking through the same machine, D3).
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let lifecycleLock = NSLock()
    private var stopped = true
    private var failureReported = false
    private var configurationObserver: NSObjectProtocol?
    private let onFailure: @Sendable (String) -> Void

    public private(set) var format: AVAudioFormat?

    public init(onFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onFailure = onFailure
    }

    deinit { stop() }

    /// Start capturing. Returns the buffer stream; the caller owns stopping.
    ///
    /// `voiceProcessing` (AEC) is off by default: the process-global
    /// voice-processing unit proved unreliable across session restarts
    /// (input tap silently dies) — echo is instead handled half-duplex
    /// in the conversation loop.
    public func start(voiceProcessing: Bool = false, copyBuffers: Bool = false) throws -> AsyncStream<AVAudioPCMBuffer> {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard stopped else {
            throw NSError(
                domain: "Aitvaras.MicCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone capture is already running."])
        }
        stopped = false
        failureReported = false

        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                VoiceLog.log("mic: voice processing enabled")
            } catch {
                VoiceLog.log("mic: voice processing FAILED (\(error.localizedDescription)) — continuing without AEC")
            }
        } else {
            VoiceLog.log("mic: plain tap (no AEC)")
        }

        let format = input.outputFormat(forBus: 0)
        self.format = format
        VoiceLog.log("mic: format \(format.sampleRate)Hz \(format.channelCount)ch")

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation

        let counter = TapCounter()
        self.counter = counter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            counter.tick(level: Self.level(of: buffer))
            // Capture may retain a buffer for asynchronous disk writing while
            // Speech reads it. Never hand an engine-owned reusable tap buffer
            // to those consumers. Conversational voice retains its old path.
            let owned: AVAudioPCMBuffer
            if copyBuffers {
                guard let copy = Self.copy(buffer) else {
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        self?.reportFailureIfActive("Microphone audio could not be copied safely. The transcript may have a gap.")
                    }
                    return
                }
                owned = copy
            } else { owned = buffer }
            if case .dropped = continuation.yield(owned), copyBuffers {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.reportFailureIfActive("Microphone input could not keep up. The transcript or retained audio may have a gap.")
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            self.counter = nil
            stopped = true
            throw error
        }
        VoiceLog.log("mic: engine started, running=\(engine.isRunning)")

        // The engine sometimes starts but never delivers (device change,
        // wedged HAL after config change). Detect and restart once.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            VoiceLog.log("mic: CONFIGURATION CHANGE — restarting engine")
            // AVAudioEngine may post this synchronously from within its own
            // stop/reconfigure path. Never re-enter the lifecycle lock on
            // that notification stack.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.restartEngine()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self, counter] in
            guard let self else { return }
            if counter.total == 0 {
                VoiceLog.log("mic: NO CALLBACKS after 2s (running=\(self.isEngineRunning)) — restarting engine")
                self.restartEngine()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    let total = counter.total
                    VoiceLog.log("mic: after restart: \(total) callbacks, running=\(self.isEngineRunning)")
                    if total == 0 {
                        self.reportFailureIfActive(
                            "The microphone started but is not delivering audio. Check the selected input device and try voice mode again.")
                    }
                }
            }
        }
        return stream
    }

    private var counter: TapCounter?

    private static func copy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        output.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return output
    }

    private func restartEngine() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        engine.stop()
        engine.prepare()
        do {
            try engine.start()
            VoiceLog.log("mic: engine restarted, running=\(engine.isRunning)")
            lifecycleLock.unlock()
        } catch {
            VoiceLog.log("mic: engine restart failed")
            lifecycleLock.unlock()
            reportFailureIfActive(
                "The microphone stopped after the audio device changed. Try voice mode again.")
        }
    }

    private var isEngineRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return !stopped && engine.isRunning
    }

    private func reportFailureIfActive(_ message: String) {
        lifecycleLock.lock()
        guard !stopped, !failureReported else {
            lifecycleLock.unlock()
            return
        }
        failureReported = true
        lifecycleLock.unlock()
        onFailure(message)
    }

    public func stop() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        let observer = configurationObserver
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        counter = nil
        lifecycleLock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Logs buffer counts + peak level every ~5s of audio so voice.log
    /// shows whether the mic actually delivers signal.
    final class TapCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var peak: Float = -120
        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func tick(level: Float) {
            var logLine: String?
            lock.lock()
            count += 1
            peak = max(peak, level)
            if count == 1 {
                logLine = "mic: first buffer arrived"
            }
            if count % 60 == 0 {
                logLine = "mic: \(count) buffers, peak \(String(format: "%.1f", peak)) dBFS\(peak < -70 ? " ← SILENCE" : "")"
                peak = -120
            }
            lock.unlock()
            if let logLine { VoiceLog.log(logLine) }
        }
    }

    /// Mean power of a buffer in dBFS — used for simple level metering.
    /// Handles both float32 and int16 buffers (the analyzer format is
    /// int16; floatChannelData is nil there).
    public static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -120 }
        var sum: Float = 0
        if let data = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += data[i] * data[i] }
        } else if let data = buffer.int16ChannelData?[0] {
            for i in 0..<n {
                let sample = Float(data[i]) / 32768
                sum += sample * sample
            }
        } else {
            return -120
        }
        let rms = sqrt(sum / Float(n))
        return 20 * log10(max(rms, 1e-6))
    }
}
