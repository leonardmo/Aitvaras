import Foundation
import Testing
import AitvarasCore

@Suite struct CaptureSettingsTests {
    @Test func defaultsDoNotFollowConversationLanguage() {
        let suite = "app.aitvaras.tests.capture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en-US", forKey: "voice.locale")
        #expect(CaptureSettings.load(defaults: defaults) == CaptureSettings(language: .german))
    }

    @Test func settingsRoundTripWithoutChangingVoice() {
        let suite = "app.aitvaras.tests.capture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("de-DE", forKey: "voice.locale")
        let settings = CaptureSettings(language: .english, postprocessing: .transcriptOnly, audioRetention: .sevenDays)
        settings.save(defaults: defaults)
        #expect(CaptureSettings.load(defaults: defaults) == settings)
        #expect(defaults.string(forKey: "voice.locale") == "de-DE")
    }

    @Test func unknownRoutesFallBackToImplementedLocalSettings() {
        let suite = "app.aitvaras.tests.capture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported", forKey: "capture.language")
        defaults.set("cloud", forKey: "capture.postprocessing")
        defaults.set("forever-without-consent", forKey: "capture.audioRetention")
        #expect(CaptureSettings.load(defaults: defaults) == CaptureSettings())
        #expect(CaptureLanguage.allCases.map(\.rawValue) == ["en-US", "de-DE"])
        #expect(CapturePostprocessing.allCases.count == 2)
        #expect(CaptureSettings.load(defaults: defaults).audioRetention == .discard)
    }
}
