import Foundation

/// Bounded window-level status locations. There is deliberately no hidden state:
/// recording and attention remain discoverable in every presentation.
public enum ActivityDockPlacement: String, CaseIterable, Identifiable, Sendable {
    case bottomDock
    case sidebarFooter
    case minimized

    public static let preferenceKey = "activity.dockPlacement"
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bottomDock: "Bottom dock"
        case .sidebarFooter: "Sidebar footer"
        case .minimized: "Minimized"
        }
    }

    public static func load(from preferences: UserDefaults = AitvarasPreferences.current) -> Self {
        preferences.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .bottomDock
    }

    public func save(to preferences: UserDefaults = AitvarasPreferences.current) {
        preferences.set(rawValue, forKey: Self.preferenceKey)
    }

    /// A collapsed sidebar must not conceal activity or overwrite the user's choice.
    public func resolved(sidebarVisible: Bool) -> Self {
        self == .sidebarFooter && !sidebarVisible ? .minimized : self
    }
}
