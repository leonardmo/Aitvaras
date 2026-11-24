import Foundation

public enum AppMotion {
    public static let overrideKey = "appearance.alwaysAnimate"

    public static func load(from preferences: UserDefaults = AitvarasPreferences.current) -> Bool {
        preferences.bool(forKey: overrideKey)
    }

    public static func save(_ alwaysAnimate: Bool, to preferences: UserDefaults = AitvarasPreferences.current) {
        preferences.set(alwaysAnimate, forKey: overrideKey)
    }

    public static func shouldReduceMotion(system: Bool, alwaysAnimate: Bool) -> Bool {
        system && !alwaysAnimate
    }
}
