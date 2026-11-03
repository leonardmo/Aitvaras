import Foundation

/// Presentation only: switching modes never changes the selected character,
/// voice session, or assistant configuration.
public enum CompanionPresentation: String, CaseIterable, Sendable {
    case avatar
    case minimal

    public static let preferenceKey = "companion.presentation"

    public var usesAvatar: Bool { self == .avatar }

    public static func load(from preferences: UserDefaults = AitvarasPreferences.current) -> Self {
        preferences.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .avatar
    }

    public func save(to preferences: UserDefaults = AitvarasPreferences.current) {
        preferences.set(rawValue, forKey: Self.preferenceKey)
    }
}
