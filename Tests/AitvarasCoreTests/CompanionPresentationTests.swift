import Foundation
import Testing
@testable import AitvarasCore

@Suite(.timeLimit(.minutes(2))) struct CompanionPresentationTests {
    @Test func defaultsToMinimalAndUnknownValuesRecover() throws {
        let name = "app.aitvaras.test.companion.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(CompanionPresentation.load(from: preferences) == .minimal)
        preferences.set("unknown", forKey: CompanionPresentation.preferenceKey)
        #expect(CompanionPresentation.load(from: preferences) == .minimal)
    }

    @Test func minimalModePersistsWithoutChangingCharacterOrVoice() throws {
        let name = "app.aitvaras.test.companion.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        preferences.set("creature", forKey: "avatar.style")
        preferences.set("de-DE", forKey: "voice.locale")
        CompanionPresentation.minimal.save(to: preferences)
        #expect(CompanionPresentation.load(from: preferences) == .minimal)
        #expect(!CompanionPresentation.minimal.usesAvatar)
        #expect(preferences.string(forKey: "avatar.style") == "creature")
        #expect(preferences.string(forKey: "voice.locale") == "de-DE")
        CompanionPresentation.avatar.save(to: preferences)
        #expect(CompanionPresentation.load(from: preferences) == .avatar)
        #expect(CompanionPresentation.avatar.usesAvatar)
    }
}
