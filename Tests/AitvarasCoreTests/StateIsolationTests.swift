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
        #expect(AitvarasPaths.modelsDirectory == AitvarasPaths.defaultStateDirectory
            .appendingPathComponent("Models", isDirectory: true))
        // The directory was actually created — a fresh profile boots cold.
        #expect(FileManager.default.fileExists(atPath: dir))
        try? FileManager.default.removeItem(atPath: dir)
    }

    @Test func defaultStateDirIsApplicationSupport() {
        #expect(!AitvarasPaths.isIsolated)
        #expect(AitvarasPaths.defaultStateDirectory.path.hasSuffix("Application Support/Aitvaras"))
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

        // Second seed refuses — an existing profile is never polluted.
        #expect(try !StateFixtures.seedDemoProfile(into: stores))
        #expect(try stores.factStats().total == stats.total)
    }
}
