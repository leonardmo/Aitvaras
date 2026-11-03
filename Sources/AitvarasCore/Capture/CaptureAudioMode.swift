import Foundation

/// Audio sources, not speaker identities. A lecture microphone can contain
/// the lecturer and the room; system audio can contain several remote people.
public enum CaptureAudioMode: String, CaseIterable, Sendable, Identifiable {
    case none = "Kein Audio"
    case microphone = "Nur Mikrofon"
    case system = "Nur Systemaudio"
    case systemAndMic = "Systemaudio + Mikrofon"

    public var id: String { rawValue }
    public var usesMicrophone: Bool { self == .microphone || self == .systemAndMic }
    public var usesSystemAudio: Bool { self == .system || self == .systemAndMic }
    public var storageValue: String {
        switch self {
        case .none: "none"
        case .microphone: "mic"
        case .system: "system"
        case .systemAndMic: "system+mic"
        }
    }

    public func needsScreenStream(includingScreen: Bool) -> Bool { includingScreen || usesSystemAudio }
}
