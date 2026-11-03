import Foundation

/// Preferences follow the active local profile just like its database and
/// logs. Normal launches retain the app's existing standard defaults; an
/// `AITVARAS_STATE_DIR` launch receives a deterministic separate domain so a
/// demo/test profile cannot change real volume, model, avatar or autonomy
/// settings.
public enum AitvarasPreferences {
    public static var current: UserDefaults {
        guard let path = ProcessInfo.processInfo.environment[AitvarasPaths.stateDirEnvVar],
              !path.isEmpty else { return .standard }
        return UserDefaults(suiteName: suiteName(forStateDirectory: path)) ?? .standard
    }

    public static func suiteName(forStateDirectory path: String) -> String {
        "app.aitvaras.profile." + profileIdentifier(forStateDirectory: path)
    }

    /// Stable, non-reversible identifier shared by the profile-scoped
    /// preferences and Keychain domains. It deliberately contains no path
    /// component that could disclose the user's local directory layout.
    public static func profileIdentifier(forStateDirectory path: String) -> String {
        let resolved = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return StableIdentifier.short([resolved], length: 32)
    }
}
