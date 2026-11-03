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
    public static let disableExternalIntegrationsEnvVar = "AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS"

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

    /// Previous state root used before the app was renamed. Kept only as a
    /// migration source so existing local models and memories are not stranded.
    public static var legacyStateDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Naomi", isDirectory: true)
    }

    public static var isIsolated: Bool {
        ProcessInfo.processInfo.environment[stateDirEnvVar]?.isEmpty == false
    }

    /// Demo/agent runs must not touch real Mail, Calendar, Reminders,
    /// Keychain-backed accounts or network connectors merely by booting.
    public static var externalIntegrationsDisabled: Bool {
        shouldDisableExternalIntegrations(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment)
    }

    public static func shouldDisableExternalIntegrations(
        arguments: [String], environment: [String: String]
    ) -> Bool {
        arguments.contains("--seed-demo-state")
            || environment[disableExternalIntegrationsEnvVar] == "1"
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
            return resolvedModelsDirectory(
                currentRoot: defaultStateDirectory,
                legacyRoot: legacyStateDirectory)
        }
        if isIsolated {
            return stateDirectory.appendingPathComponent("Models", isDirectory: true)
        }
        return resolvedModelsDirectory(
            currentRoot: defaultStateDirectory,
            legacyRoot: legacyStateDirectory)
    }

    /// Prefer the renamed location, but keep a read-only compatibility path
    /// until the guarded store migration has had a chance to run. A directory
    /// only counts as usable when it contains at least one complete model.
    public static func resolvedModelsDirectory(currentRoot: URL, legacyRoot: URL) -> URL {
        let current = currentRoot.appendingPathComponent("Models", isDirectory: true)
        if containsInstalledModel(current) { return current }

        let legacy = legacyRoot.appendingPathComponent("Models", isDirectory: true)
        if containsInstalledModel(legacy) { return legacy }
        return current
    }

    private static func containsInstalledModel(_ directory: URL) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries.contains(where: isCompleteModelDirectory)
    }

    /// A model is usable only when configuration and actual non-empty weight
    /// files are present. For sharded Hugging Face downloads, every filename
    /// referenced by the index must exist; this prevents an interrupted
    /// download from shadowing a complete compatibility location.
    public static func isCompleteModelDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: directory.appendingPathComponent("config.json").path) else { return false }

        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        if fileManager.fileExists(atPath: indexURL.path) {
            guard let data = try? Data(contentsOf: indexURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String] else { return false }
            let shards = Set(weightMap.values)
            return !shards.isEmpty && shards.allSatisfy {
                isNonEmptyFile(directory.appendingPathComponent($0))
            }
        }

        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.contains {
            $0.pathExtension == "safetensors" && isNonEmptyFile($0)
        }
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } == true
    }
}
