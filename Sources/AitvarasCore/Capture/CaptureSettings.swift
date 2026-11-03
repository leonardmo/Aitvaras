import Foundation

/// Capture language is independent from the companion's conversation language.
public enum CaptureLanguage: String, CaseIterable, Sendable, Identifiable, Hashable {
    case english = "en-US"
    case german = "de-DE"

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var displayName: String { self == .english ? "English (US)" : "Deutsch" }
}

/// Only implemented local routes are represented here. Cloud capture
/// postprocessing is intentionally not an available selection.
public enum CapturePostprocessing: String, CaseIterable, Sendable, Identifiable, Hashable {
    case localSummary
    case transcriptOnly

    public var id: String { rawValue }
}

public struct CaptureSettings: Equatable, Sendable {
    public var language: CaptureLanguage
    public var postprocessing: CapturePostprocessing
    public var audioRetention: CaptureAudioRetention

    public init(language: CaptureLanguage = .german,
                postprocessing: CapturePostprocessing = .localSummary,
                audioRetention: CaptureAudioRetention = .discard) {
        self.language = language
        self.postprocessing = postprocessing
        self.audioRetention = audioRetention
    }

    public static func load(defaults: UserDefaults = AitvarasPreferences.current) -> Self {
        Self(language: CaptureLanguage(rawValue: defaults.string(forKey: "capture.language") ?? "") ?? .german,
             postprocessing: CapturePostprocessing(rawValue: defaults.string(forKey: "capture.postprocessing") ?? "") ?? .localSummary,
             audioRetention: CaptureAudioRetention(rawValue: defaults.string(forKey: "capture.audioRetention") ?? "") ?? .discard)
    }

    public func save(defaults: UserDefaults = AitvarasPreferences.current) {
        defaults.set(language.rawValue, forKey: "capture.language")
        defaults.set(postprocessing.rawValue, forKey: "capture.postprocessing")
        defaults.set(audioRetention.rawValue, forKey: "capture.audioRetention")
    }
}
