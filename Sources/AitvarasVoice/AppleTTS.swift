import Foundation
@preconcurrency import AVFoundation
import NaturalLanguage
import Synchronization

/// Baseline TTS (D3): Apple voices via AVSpeechSynthesizer, played
/// through an AVAudioEngine so we get per-buffer amplitude (drives the
/// avatar's mouth) and instant cancellation (barge-in).
/// Swappable: a neural engine (Chatterbox) can replace this behind the
/// same surface later.
public final class AppleTTS: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false
    private let cancelled = Mutex(false)

    /// Called with 0…1 mouth energy while speaking (main-thread hop is the
    /// consumer's job).
    public var amplitudeHandler: (@Sendable (Float) -> Void)?
    public var preferredVoiceIdentifiers: [String: String] = [:]   // language code → voice id

    public init() {}

    /// Best installed voice for a language: premium > enhanced > default.
    public static func bestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languageCode) }
        let ranked = voices.sorted { a, b in
            quality(a) > quality(b)
        }
        return ranked.first
    }

    private static func quality(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    public static func detectLanguage(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        switch recognizer.dominantLanguage {
        case .german: return "de"
        default: return "en"
        }
    }

    /// Speak one chunk of text; returns when playback finished or was
    /// cancelled. Amplitude flows via `amplitudeHandler`.
    public func speak(_ text: String, languageCode: String? = nil) async {
        let language = languageCode ?? Self.detectLanguage(of: text)
        cancelled.withLock { $0 = false }

        let utterance = AVSpeechUtterance(string: text)
        if let preferred = preferredVoiceIdentifiers[language],
           let voice = AVSpeechSynthesisVoice(identifier: preferred) {
            utterance.voice = voice
        } else if let voice = Self.bestVoice(for: language) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        // Collect buffers from the synthesizer, schedule them on the player.
        var format: AVAudioFormat?
        let bufferStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            synthesizer.write(utterance) { audioBuffer in
                guard let pcm = audioBuffer as? AVAudioPCMBuffer else {
                    continuation.finish()
                    return
                }
                if pcm.frameLength == 0 {
                    continuation.finish()
                } else {
                    continuation.yield(pcm)
                }
            }
        }

        // Schedule buffers as they arrive (synthesis runs ahead of
        // realtime); completion fires per buffer at playback end. We're
        // done when the stream ended AND the last buffer played.
        let tracker = PlaybackTracker()
        let amplitude = amplitudeHandler

        for await buffer in bufferStream {
            if cancelled.withLock({ $0 }) { break }

            if format == nil {
                format = buffer.format
                startEngineIfNeeded(format: buffer.format)
            }
            VoiceVolume.apply(to: buffer)
            tracker.willSchedule()
            let level = Self.energy(of: buffer)
            player.scheduleBuffer(buffer) {
                amplitude?(level)
                tracker.didFinishOne()
            }
        }

        if cancelled.withLock({ $0 }) {
            tracker.abandon()
        } else {
            await tracker.waitUntilDrained()
        }
        amplitudeHandler?(0)
    }

    /// Immediate stop (barge-in).
    public func stop() {
        cancelled.withLock { $0 = true }
        player.stop()
        amplitudeHandler?(0)
    }

    private func startEngineIfNeeded(format: AVAudioFormat) {
        if !started {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            started = true
        }
        // stop() (barge-in) halts the player node permanently — every
        // utterance must re-arm engine and player or scheduled buffers
        // never play and the drain wait hangs forever.
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }

    static func energy(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        var i = 0
        while i < n { sum += data[i] * data[i]; i += 64 }
        let rms = sqrt(sum / Float(max(n / 64, 1)))
        return min(rms * 8, 1)
    }
}

/// Counts scheduled vs. played buffers so speak() can await drain.
final class PlaybackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var streamEnded = false
    private var continuation: CheckedContinuation<Void, Never>?

    func willSchedule() {
        lock.lock(); pending += 1; lock.unlock()
    }

    func didFinishOne() {
        lock.lock()
        pending -= 1
        let done = streamEnded && pending <= 0
        let cont = done ? continuation : nil
        if done { continuation = nil }
        lock.unlock()
        cont?.resume()
    }

    func abandon() {
        lock.lock()
        streamEnded = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }

    func waitUntilDrained() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            streamEnded = true
            if pending <= 0 {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}
