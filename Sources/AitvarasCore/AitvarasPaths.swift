import Foundation

/// Single source of truth for where Aitvaras keeps its state (database, models,
/// logs, connector manifests, voice sidecar venv).
///
/// Default: `~/Library/Application Support/Aitvaras`. Setting the
/// `AITVARAS_STATE_DIR` environment variable relocates the entire state tree —
/// this is the testing seam: a test harness, a second "profile", or an agent
/// exercising the app can run against its own throwaway state without ever
/// touching (or leaking) the user's real memories.
///
///     AITVARAS_STATE_DIR=/tmp/aitvaras-test open Aitvaras.app   # isolated profile
///
/// Only the models directory is intentionally shared by default when the
/// override is set *with* `AITVARAS_SHARE_MODELS=1` — model weights are tens of
/// GB and profile-independent.
public enum AitvarasPaths {
    public static let stateDirEnvVar = "AITVARAS_STATE_DIR"
    public static let shareModelsEnvVar = "AITVARAS_SHARE_MODELS"

    /// The active state root, created on first access.
    public static var stateDirectory: URL {
        let root: URL
        if let override = ProcessInfo.processInfo.environment[stateDirEnvVar],
           !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = defaultStateDirectory
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    public static var defaultStateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aitvaras", isDirectory: true)
    }

    public static var isIsolated: Bool {
        ProcessInfo.processInfo.environment[stateDirEnvVar]?.isEmpty == false
    }

    // MARK: Well-known locations

    public static var databaseURL: URL {
        stateDirectory.appendingPathComponent("aitvaras.sqlite")
    }

    public static var logsDirectory: URL {
        let dir = stateDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var connectorsDirectory: URL {
        stateDirectory.appendingPathComponent("Connectors", isDirectory: true)
    }

    /// Model weights: huge and profile-independent, so an isolated profile
    /// may opt into sharing the default location instead of re-downloading.
    public static var modelsDirectory: URL {
        if isIsolated,
           ProcessInfo.processInfo.environment[shareModelsEnvVar] == "1" {
            return defaultStateDirectory.appendingPathComponent("Models", isDirectory: true)
        }
        return stateDirectory.appendingPathComponent("Models", isDirectory: true)
    }
}
