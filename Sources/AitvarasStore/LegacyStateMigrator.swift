import Foundation
import GRDB
import AitvarasCore

public enum LegacyStateMigrationError: LocalizedError, Sendable {
    case conflictingProfiles

    public var errorDescription: String? {
        switch self {
        case .conflictingProfiles:
            "Both the former Naomi profile and the Aitvaras profile contain data. "
            + "Neither was changed; choose which profile to keep before starting Aitvaras."
        }
    }
}

/// Moves state left behind by the Naomi -> Aitvaras rename without ever
/// overwriting a populated Aitvaras profile. The operation is idempotent:
/// each component is moved independently and an interrupted run can resume.
public enum LegacyStateMigrator {
    public enum Result: Equatable, Sendable {
        case notNeeded
        case migrated([String])
        case conflict
    }

    private static let databaseTables = [
        "activityEvent", "captureRecord", "conversation", "curiosityQuestion",
        "goal", "heldNotification", "memory", "memoryEntity", "memoryFact", "ragDocument",
        "storedMessage", "suggestion"
    ]

    private static let movableDirectories = [
        "Models", "voice-venv", "Avatar", "logs", "Connectors"
    ]

    @discardableResult
    public static func migrateIfNeeded(
        currentRoot: URL = AitvarasPaths.defaultStateDirectory,
        legacyRoot: URL = AitvarasPaths.legacyStateDirectory,
        fileManager: FileManager = .default
    ) throws -> Result {
        guard currentRoot.standardizedFileURL != legacyRoot.standardizedFileURL,
              fileManager.fileExists(atPath: legacyRoot.path) else {
            return .notNeeded
        }

        let currentDB = currentRoot.appendingPathComponent("aitvaras.sqlite")
        let legacyDB = legacyRoot.appendingPathComponent("naomi.sqlite")
        let currentHasData = try profileHasUserData(at: currentDB, fileManager: fileManager)
        let legacyHasData = try profileHasUserData(at: legacyDB, fileManager: fileManager)

        // Merging two independently-used profiles needs an explicit UI. Never
        // guess which memories should win.
        if currentHasData && legacyHasData {
            return .conflict
        }

        try fileManager.createDirectory(at: currentRoot, withIntermediateDirectories: true)
        var moved: [String] = []

        if fileManager.fileExists(atPath: legacyDB.path),
           !fileManager.fileExists(atPath: currentDB.path) || (!currentHasData && legacyHasData) {
            if fileManager.fileExists(atPath: currentDB.path) {
                let backup = currentRoot
                    .appendingPathComponent("Migration Backups", isDirectory: true)
                    .appendingPathComponent("before-naomi-import", isDirectory: true)
                try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
                try moveSQLiteFamily(
                    from: currentDB,
                    to: backup.appendingPathComponent("aitvaras.sqlite"),
                    fileManager: fileManager)
            }
            try moveSQLiteFamily(from: legacyDB, to: currentDB, fileManager: fileManager)
            moved.append("database")
        }

        for name in movableDirectories {
            let source = legacyRoot.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = currentRoot.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                let contents = try? fileManager.contentsOfDirectory(atPath: destination.path)
                guard contents?.isEmpty == true else { continue }
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            moved.append(name)
        }

        // The old installer marker would otherwise make the migrated neural
        // voice look uninstalled even though the full environment is present.
        let voiceVenv = currentRoot.appendingPathComponent("voice-venv", isDirectory: true)
        let oldMarker = voiceVenv.appendingPathComponent(".naomi-ready")
        let newMarker = voiceVenv.appendingPathComponent(".aitvaras-ready")
        if fileManager.fileExists(atPath: oldMarker.path),
           !fileManager.fileExists(atPath: newMarker.path) {
            try fileManager.moveItem(at: oldMarker, to: newMarker)
            moved.append("voice marker")
        }

        if let leftovers = try? fileManager.contentsOfDirectory(atPath: legacyRoot.path),
           leftovers.isEmpty {
            try? fileManager.removeItem(at: legacyRoot)
        }
        return moved.isEmpty ? .notNeeded : .migrated(moved)
    }

    private static func profileHasUserData(
        at url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.read { db in
            for table in databaseTables where try db.tableExists(table) {
                let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM \"\(quoted)\" LIMIT 1)") ?? false
                if exists { return true }
            }
            return false
        }
    }

    private static func moveSQLiteFamily(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            let to = URL(fileURLWithPath: destination.path + suffix)
            if fileManager.fileExists(atPath: to.path) {
                try fileManager.removeItem(at: to)
            }
            try fileManager.moveItem(at: from, to: to)
        }
    }
}
