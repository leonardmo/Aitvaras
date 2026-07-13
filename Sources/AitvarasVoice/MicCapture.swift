import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Microphone capture with the system voice-processing unit enabled
/// (echo cancellation — required for hands-free conversation while
/// Aitvaras is speaking through the same machine, D3).
public final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    public private(set) var format: AVAudioFormat?

    public init() {}

    /// Start capturing. Returns the buffer stream; the caller owns stopping.
    ///
    /// `voiceProcessing` (AEC) is off by default: the process-global
    /// voice-processing unit proved unreliable across session restarts
    /// (input tap silently dies) — echo is instead handled half-duplex
    /// in the conversation loop.
    public func start(voiceProcessing: Bool = false) throws -> AsyncStream<AVAudioPCMBuffer> {
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
        VoiceLog.log("mic: device \"\(Self.defaultInputDeviceName())\", format \(format.sampleRate)Hz \(format.channelCount)ch")

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        self.continuation = continuation

        let counter = TapCounter()
        self.counter = counter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            counter.tick(level: Self.level(of: buffer))
            continuation.yield(buffer)
        }
        engine.prepare()
        try engine.start()
        VoiceLog.log("mic: engine started, running=\(engine.isRunning)")

        // The engine sometimes starts but never delivers (device change,
        // wedged HAL after config change). Detect and restart once.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            VoiceLog.log("mic: CONFIGURATION CHANGE — restarting engine")
            self?.restartEngine()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let counter = self.counter else { return }
            if counter.total == 0 {
                VoiceLog.log("mic: NO CALLBACKS after 2s (running=\(self.engine.isRunning), device \"\(Self.defaultInputDeviceName())\") — restarting engine")
                self.restartEngine()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    VoiceLog.log("mic: after restart: \(counter.total) callbacks, running=\(self.engine.isRunning)")
                }
            }
        }
        return stream
    }

    private var counter: TapCounter?

    private func restartEngine() {
        engine.stop()
        engine.prepare()
        try? engine.start()
        VoiceLog.log("mic: engine restarted, running=\(engine.isRunning)")
    }

    /// Name of the current default input device (CoreAudio).
    static func defaultInputDeviceName() -> String {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0 else { return "unknown" }

        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, pointer)
        }
        return status == noErr ? (name as String) : "unknown"
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    /// Logs buffer counts + peak level every ~5s of audio so voice.log
    /// shows whether the mic actually delivers signal.
    final class TapCounter: @unchecked Sendable {
        private var count = 0
        private var peak: Float = -120
        var total: Int { count }

        func tick(level: Float) {
            count += 1
            peak = max(peak, level)
            if count == 1 {
                VoiceLog.log("mic: first buffer arrived")
            }
            if count % 60 == 0 {
                VoiceLog.log("mic: \(count) buffers, peak \(String(format: "%.1f", peak)) dBFS\(peak < -70 ? " ← SILENCE" : "")")
                peak = -120
            }
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
