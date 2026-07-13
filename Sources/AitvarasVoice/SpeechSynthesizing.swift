import Foundation
@preconcurrency import AVFoundation

/// Aitvaras's speech volume (0…2; >1 is soft-boosted). Applied per buffer
/// in both engines so slider changes take effect mid-sentence.
public enum VoiceVolume {
    public static var gain: Float {
        get {
            let raw = UserDefaults.standard.object(forKey: "voice.volume") as? Double
            return Float(raw ?? 1.0)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "voice.volume") }
    }

    /// Scale float samples in place, hard-limiting to avoid crackle.
    public static func apply(to buffer: AVAudioPCMBuffer) {
        let g = gain
        guard g != 1.0, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let data = channels[channel]
            for i in 0..<frames {
                data[i] = max(-1, min(1, data[i] * g))
            }
        }
    }
}

/// Common surface for TTS engines (D3): AppleTTS baseline, NeuralTTS
/// (Chatterbox sidecar) for the real voice quality.
public protocol SpeechSynthesizing: AnyObject, Sendable {
    var amplitudeHandler: (@Sendable (Float) -> Void)? { get set }
    /// Speak one chunk; returns when playback finished or was stopped.
    func speak(_ text: String, languageCode: String?) async
    /// Immediate cancel (barge-in).
    func stop()
}

extension AppleTTS: SpeechSynthesizing {}
