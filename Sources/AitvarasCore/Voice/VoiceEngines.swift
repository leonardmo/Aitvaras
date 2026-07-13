import Foundation

public enum VoiceLanguage: String, Sendable, Codable {
    case german = "de-DE"
    case english = "en-US"
}

/// Streaming speech-to-text. Implementation: SpeechAnalyzer (macOS 26);
/// optional whisper-MLX fallback (D3).
public protocol STTEngine: Actor {
    /// Feed audio, receive volatile partials and finalized segments.
    func transcribe(audio: AsyncStream<[Float]>, language: VoiceLanguage?)
        -> AsyncThrowingStream<STTResult, Error>
}

public struct STTResult: Sendable, Equatable {
    public var text: String
    /// Partials may be revised; finalized segments are stable.
    public var isFinal: Bool
    public var detectedLanguage: VoiceLanguage?

    public init(text: String, isFinal: Bool, detectedLanguage: VoiceLanguage? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.detectedLanguage = detectedLanguage
    }
}

/// Text-to-speech. Quality bar: ChatGPT voice mode (D3). Implementations
/// are swappable: AVSpeech baseline, neural sidecar (Chatterbox) candidate.
public protocol TTSEngine: Actor {
    var identifier: String { get }
    func supports(_ language: VoiceLanguage) -> Bool

    /// Synthesize one sentence/chunk; streaming PCM so playback can start
    /// before synthesis finishes and barge-in can cancel mid-sentence.
    func synthesize(text: String, language: VoiceLanguage)
        -> AsyncThrowingStream<AudioChunk, Error>
}

public struct AudioChunk: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Drives the companion character's animation (D4) — observed by the
/// RealityKit layer, written by the voice pipeline and agent loop.
public enum CharacterState: String, Sendable, Codable {
    case idle
    case listening
    case thinking
    case speaking
}
