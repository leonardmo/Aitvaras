import Foundation
import Testing
import AitvarasCore

struct AppMotionTests {
    @Test func defaultFollowsSystemAndOverrideCanBeRestored() throws {
        let name = "synthetic-motion-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }

        #expect(!AppMotion.load(from: preferences))
        #expect(AppMotion.shouldReduceMotion(system: true, alwaysAnimate: AppMotion.load(from: preferences)))

        AppMotion.save(true, to: preferences)
        #expect(AppMotion.load(from: preferences))
        #expect(!AppMotion.shouldReduceMotion(system: true, alwaysAnimate: AppMotion.load(from: preferences)))

        AppMotion.save(false, to: preferences)
        #expect(AppMotion.shouldReduceMotion(system: true, alwaysAnimate: AppMotion.load(from: preferences)))
        #expect(!AppMotion.shouldReduceMotion(system: false, alwaysAnimate: AppMotion.load(from: preferences)))
    }
}
