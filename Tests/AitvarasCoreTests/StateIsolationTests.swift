import Foundation
import AitvarasCore
import AitvarasStore
import Testing

/// Serialized: these tests mutate the process environment.
@Suite(.serialized) struct StateIsolationTests {

    @Test func stateDirHonorsEnvironmentOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-isolated-\(UUID().uuidString)").path
        setenv(AitvarasPaths.stateDirEnvVar, dir, 1)
        defer { unsetenv(AitvarasPaths.stateDirEnvVar) }

        #expect(AitvarasPaths.isIsolated)
        #expect(AitvarasPaths.stateDirectory.path == dir)
        #expect(AitvarasPaths.databaseURL.path == dir + "/aitvaras.sqlite")
        #expect(AitvarasPaths.logsDirectory.path.hasPrefix(dir))
        // Models follow the profile unless sharing is opted into.
        #expect(AitvarasPaths.modelsDirectory.path.hasPrefix(dir))
        setenv(AitvarasPaths.shareModelsEnvVar, "1", 1)
        defer { unsetenv(AitvarasPaths.shareModelsEnvVar) }
        #expect(AitvarasPaths.modelsDirectory == AitvarasPaths.resolvedModelsDirectory(
            currentRoot: AitvarasPaths.defaultStateDirectory,
            legacyRoot: AitvarasPaths.legacyStateDirectory))
        // The directory was actually created — a fresh profile boots cold.
        #expect(FileManager.default.fileExists(atPath: dir))
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func isolatedProfilesDoNotSharePreferencesWithRealAppOrEachOther() {
        let first = "/tmp/aitvaras-preferences-\(UUID().uuidString)"
        let second = "/tmp/aitvaras-preferences-\(UUID().uuidString)"
        let key = "isolation-test-\(UUID().uuidString)"
        let firstSuite = AitvarasPreferences.suiteName(forStateDirectory: first)
        let secondSuite = AitvarasPreferences.suiteName(forStateDirectory: second)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults().removePersistentDomain(forName: firstSuite)
            UserDefaults().removePersistentDomain(forName: secondSuite)
            unsetenv(AitvarasPaths.stateDirEnvVar)
        }

        setenv(AitvarasPaths.stateDirEnvVar, first, 1)
        AitvarasPreferences.current.set("first", forKey: key)
        #expect(UserDefaults.standard.string(forKey: key) == nil)

        setenv(AitvarasPaths.stateDirEnvVar, second, 1)
        #expect(AitvarasPreferences.current.string(forKey: key) == nil)
        AitvarasPreferences.current.set("second", forKey: key)

        setenv(AitvarasPaths.stateDirEnvVar, first, 1)
        #expect(AitvarasPreferences.current.string(forKey: key) == "first")
    }

    @Test func isolatedProfilesDoNotShareKeychainDomainsWithRealAppOrEachOther() {
        let first = "/tmp/aitvaras-keychain-\(UUID().uuidString)"
        let second = "/tmp/aitvaras-keychain-\(UUID().uuidString)"

        let regular = KeychainStore.serviceName(stateDirectoryOverride: nil)
        let firstProfile = KeychainStore.serviceName(stateDirectoryOverride: first)
        let sameFirstProfile = KeychainStore.serviceName(stateDirectoryOverride: first)
        let secondProfile = KeychainStore.serviceName(stateDirectoryOverride: second)

        #expect(regular == KeychainStore.defaultService)
        #expect(firstProfile != regular)
        #expect(firstProfile == sameFirstProfile)
        #expect(firstProfile != secondProfile)
        #expect(!firstProfile.contains(first))
        #expect(!secondProfile.contains(second))
    }

    @Test func explicitKeychainServiceIsNotRewrittenForTestsOrEmbeddingHosts() {
        let service = "app.example.aitvaras-test-\(UUID().uuidString)"
        setenv(AitvarasPaths.stateDirEnvVar, "/tmp/isolated", 1)
        defer { unsetenv(AitvarasPaths.stateDirEnvVar) }

        #expect(KeychainStore(service: service).service == service)
    }

    @Test func defaultStateDirIsApplicationSupport() {
        #expect(!AitvarasPaths.isIsolated)
        #expect(AitvarasPaths.defaultStateDirectory.path.hasSuffix("Application Support/Aitvaras"))
        #expect(AitvarasPaths.legacyStateDirectory.path.hasSuffix("Application Support/Naomi"))
    }

    @Test func demoAndExplicitSafeRunsDisableExternalIntegrations() {
        #expect(AitvarasPaths.shouldDisableExternalIntegrations(
            arguments: ["Aitvaras", "--seed-demo-state"], environment: [:]))
        #expect(AitvarasPaths.shouldDisableExternalIntegrations(
            arguments: ["Aitvaras"],
            environment: [AitvarasPaths.disableExternalIntegrationsEnvVar: "1"]))
        #expect(!AitvarasPaths.shouldDisableExternalIntegrations(
            arguments: ["Aitvaras"],
            environment: [AitvarasPaths.stateDirEnvVar: "/tmp/isolated-only"]))
    }

    @Test func modelResolutionUsesLegacyOnlyWhenRenamedLocationIsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-model-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Aitvaras")
        let legacy = root.appendingPathComponent("Naomi")
        let legacyModel = legacy.appendingPathComponent("Models/LightModel")
        try FileManager.default.createDirectory(at: legacyModel, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacyModel.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: legacyModel.appendingPathComponent("model.safetensors"))

        #expect(AitvarasPaths.resolvedModelsDirectory(
            currentRoot: current, legacyRoot: legacy) == legacy.appendingPathComponent("Models"))

        let currentModel = current.appendingPathComponent("Models/NewModel")
        try FileManager.default.createDirectory(at: currentModel, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: currentModel.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: currentModel.appendingPathComponent("model.safetensors"))
        #expect(AitvarasPaths.resolvedModelsDirectory(
            currentRoot: current, legacyRoot: legacy) == current.appendingPathComponent("Models"))
    }

    @Test func shardedModelRequiresEveryIndexedWeightFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-model-completeness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data(#"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#.utf8)
            .write(to: root.appendingPathComponent("model.safetensors.index.json"))

        try Data("first".utf8).write(
            to: root.appendingPathComponent("model-00001-of-00002.safetensors"))
        #expect(!AitvarasPaths.isCompleteModelDirectory(root))

        try Data("second".utf8).write(
            to: root.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(AitvarasPaths.isCompleteModelDirectory(root))
    }

    @Test func legacyMigrationRecoversPopulatedProfileAndKeepsEmptyBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-legacy-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Aitvaras")
        let legacy = root.appendingPathComponent("Naomi")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        // A previous launch/setup can leave an empty destination directory;
        // that must not strand the complete legacy models.
        try FileManager.default.createDirectory(
            at: current.appendingPathComponent("Models"), withIntermediateDirectories: true)

        _ = try AitvarasDatabase(url: current.appendingPathComponent("aitvaras.sqlite"))
        let oldStores = Stores(db: try AitvarasDatabase(
            url: legacy.appendingPathComponent("naomi.sqlite")))
        try oldStores.record(ActivityEvent(kind: .voiceTurn, summary: "legacy marker"))
        let oldModel = legacy.appendingPathComponent("Models/LightModel")
        try FileManager.default.createDirectory(at: oldModel, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: oldModel.appendingPathComponent("config.json"))
        let oldVoice = legacy.appendingPathComponent("voice-venv")
        try FileManager.default.createDirectory(at: oldVoice, withIntermediateDirectories: true)
        try Data().write(to: oldVoice.appendingPathComponent(".naomi-ready"))

        let result = try LegacyStateMigrator.migrateIfNeeded(
            currentRoot: current, legacyRoot: legacy)
        guard case .migrated(let components) = result else {
            Issue.record("Expected migration, got \(result)")
            return
        }
        #expect(components.contains("database"))
        #expect(components.contains("Models"))
        #expect(components.contains("voice-venv"))
        #expect(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Migration Backups/before-naomi-import/aitvaras.sqlite").path))
        #expect(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("Models/LightModel/config.json").path))
        #expect(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("voice-venv/.aitvaras-ready").path))
        #expect(!FileManager.default.fileExists(
            atPath: current.appendingPathComponent("voice-venv/.naomi-ready").path))
        let migrated = Stores(db: try AitvarasDatabase(
            url: current.appendingPathComponent("aitvaras.sqlite")))
        #expect(try migrated.recentActivity(limit: 10).contains { $0.summary == "legacy marker" })
        #expect(try LegacyStateMigrator.migrateIfNeeded(
            currentRoot: current, legacyRoot: legacy) == .notNeeded)
    }

    @Test func legacyMigrationNeverOverwritesTwoPopulatedProfiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-legacy-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Aitvaras")
        let legacy = root.appendingPathComponent("Naomi")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let currentStores = Stores(db: try AitvarasDatabase(
            url: current.appendingPathComponent("aitvaras.sqlite")))
        try currentStores.record(ActivityEvent(kind: .voiceTurn, summary: "current"))
        let legacyStores = Stores(db: try AitvarasDatabase(
            url: legacy.appendingPathComponent("naomi.sqlite")))
        try legacyStores.record(ActivityEvent(kind: .voiceTurn, summary: "legacy"))

        #expect(try LegacyStateMigrator.migrateIfNeeded(
            currentRoot: current, legacyRoot: legacy) == .conflict)
        #expect(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("aitvaras.sqlite").path))
        #expect(FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent("naomi.sqlite").path))
    }

    @Test func demoFixturesSeedOnlyEmptyProfiles() throws {
        let stores = try inMemoryStores()
        #expect(try StateFixtures.seedDemoProfile(into: stores))

        let stats = try stores.factStats()
        #expect(stats.total >= 8)
        #expect(try stores.factsNeedingReview().count == 1)      // review flow exercisable
        #expect(try stores.openQuestions().count == 2)           // Q&A flow exercisable
        #expect(try stores.allFacts().contains { !$0.isCurrentlyValid })   // history visible
        #expect(try stores.entities().count == 3)
        #expect(try stores.newsTopics().map(\.name) == [
            "AI tools & workflows", "International politics", "Germany"
        ])
        #expect(try stores.commandRoutines().count == 2)

        // Second seed refuses — an existing profile is never polluted.
        #expect(try !StateFixtures.seedDemoProfile(into: stores))
        #expect(try stores.factStats().total == stats.total)
    }

    @Test func databaseOpenFailureThrowsInsteadOfCrashing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-invalid-db-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        #expect(throws: Error.self) {
            _ = try AitvarasDatabase(url: root.appendingPathComponent("aitvaras.sqlite"))
        }
    }
}
