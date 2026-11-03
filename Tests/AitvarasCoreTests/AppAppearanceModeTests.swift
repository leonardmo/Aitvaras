import Foundation
import Testing
import AitvarasCore

@Suite struct AppAppearanceModeTests {
    @Test func defaultsAndInvalidValuesFollowSystem() throws {
        let name = "synthetic-appearance-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(AppAppearanceMode.load(from: preferences) == .system)
        preferences.set("unknown-mode", forKey: AppAppearanceMode.preferenceKey)
        #expect(AppAppearanceMode.load(from: preferences) == .system)
    }

    @Test func allChoicesPersistAndSystemCanBeRestored() throws {
        let name = "synthetic-appearance-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        for mode in [AppAppearanceMode.light, .dark, .system] {
            mode.save(to: preferences)
            #expect(AppAppearanceMode.load(from: preferences) == mode)
        }
    }
}
