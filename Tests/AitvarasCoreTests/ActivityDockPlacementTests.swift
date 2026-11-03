import Foundation
import Testing
@testable import AitvarasCore

@Suite struct ActivityDockPlacementTests {
    @Test func missingOrInvalidPreferenceUsesBottomDock() throws {
        let name = "app.aitvaras.tests.activity-dock.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        #expect(ActivityDockPlacement.load(from: preferences) == .bottomDock)
        preferences.set("unknown-placement", forKey: ActivityDockPlacement.preferenceKey)
        #expect(ActivityDockPlacement.load(from: preferences) == .bottomDock)
    }

    @Test func everyBoundedPlacementIsRemembered() throws {
        let name = "app.aitvaras.tests.activity-dock.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: name))
        defer { preferences.removePersistentDomain(forName: name) }
        for placement in ActivityDockPlacement.allCases {
            placement.save(to: preferences)
            #expect(ActivityDockPlacement.load(from: preferences) == placement)
        }
        #expect(ActivityDockPlacement.allCases.count == 3)
    }

    @Test func collapsingSidebarKeepsStatusVisibleWithoutChangingPreference() {
        #expect(ActivityDockPlacement.sidebarFooter.resolved(sidebarVisible: false) == .minimized)
        #expect(ActivityDockPlacement.sidebarFooter.resolved(sidebarVisible: true) == .sidebarFooter)
        #expect(ActivityDockPlacement.bottomDock.resolved(sidebarVisible: false) == .bottomDock)
        #expect(ActivityDockPlacement.minimized.resolved(sidebarVisible: true) == .minimized)
    }
}
