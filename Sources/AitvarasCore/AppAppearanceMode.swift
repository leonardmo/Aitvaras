import Foundation

public enum AppAppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    public static let preferenceKey = "appearance.mode"
    public static func load(from preferences: UserDefaults = AitvarasPreferences.current) -> Self {
        preferences.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .system
    }
    public func save(to preferences: UserDefaults = AitvarasPreferences.current) {
        preferences.set(rawValue, forKey: Self.preferenceKey)
    }
}
