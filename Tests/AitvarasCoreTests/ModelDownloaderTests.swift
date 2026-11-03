import Foundation
import Testing
@testable import AitvarasCore

@Suite struct ModelDownloaderTests {
    @Test func pythonCompatibilityRequiresSupportedMajorAndMinor() {
        #expect(!ModelDownloader.isCompatiblePythonVersion("3.9\n"))
        #expect(ModelDownloader.isCompatiblePythonVersion("3.10\n"))
        #expect(ModelDownloader.isCompatiblePythonVersion("3.14\n"))
        #expect(ModelDownloader.isCompatiblePythonVersion("4.0\n"))
        #expect(!ModelDownloader.isCompatiblePythonVersion("not a version"))
    }

    @Test func revisionsMustBeImmutableCommitIdentifiers() {
        #expect(ModelDownloader.isPinnedRevision(
            "3b1b1768f8f8cf8351c712464f906e86c2b8269e"))
        #expect(!ModelDownloader.isPinnedRevision("main"))
        #expect(!ModelDownloader.isPinnedRevision(
            "3B1B1768F8F8CF8351C712464F906E86C2B8269E"))
        #expect(!ModelDownloader.isPinnedRevision("../../../unexpected"))
    }

    @Test func pythonDiscoverySkipsOldRuntimeAndSelectsFirstCompatibleOne() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-python-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = try executable(at: root.appendingPathComponent("old-python"), output: "3.9")
        let current = try executable(
            at: root.appendingPathComponent("current-python"), output: "3.12")

        #expect(await ModelDownloader.findCompatiblePython(
            candidates: [old.path, current.path]) == current.path)
    }

    @Test func diskEstimateAccountsForPartialDownloadsAndHeadroom() {
        let gib: Int64 = 1_024 * 1_024 * 1_024
        #expect(ModelDownloader.requiredAdditionalBytes(
            expectedBytes: 17 * gib, existingBytes: 12 * gib, headroom: gib) == 6 * gib)
        #expect(ModelDownloader.requiredAdditionalBytes(
            expectedBytes: 2 * gib, existingBytes: 3 * gib, headroom: gib) == gib)
        #expect(ModelDownloader.requiredAdditionalBytes(
            expectedBytes: 2 * gib, existingBytes: -1, headroom: 0) == 2 * gib)
    }

    /// Opt-in real-network check for the exact clean bootstrap + snapshot
    /// path used by Setup. Run only as a filtered test with
    /// `AITVARAS_RUN_NETWORK_TESTS=1`; the regular suite stays offline.
    @Test func cleanEnvironmentDownloadsAndVerifiesTinySnapshot() async throws {
        guard ProcessInfo.processInfo.environment["AITVARAS_RUN_NETWORK_TESTS"] == "1"
        else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitvaras-model-network-\(UUID().uuidString)")
        defer {
            unsetenv(AitvarasPaths.stateDirEnvVar)
            try? FileManager.default.removeItem(at: root)
        }
        setenv(AitvarasPaths.stateDirEnvVar, root.path, 1)
        let model = root.appendingPathComponent("Models/tiny-random-qwen3")

        try await ModelDownloader.download(
            repository: "optimum-intel-internal-testing/tiny-random-qwen3",
            revision: "2befc315528c185f6f31b90fc4a5f27fb14baf67",
            to: model,
            expectedBytes: 36_000_000)

        #expect(AitvarasPaths.isCompleteModelDirectory(model))
        #expect(FileManager.default.fileExists(
            atPath: model.appendingPathComponent(".cache/huggingface").path))
    }

    private func executable(at url: URL, output: String) throws -> URL {
        try Data("#!/bin/sh\nprintf '\(output)'\n".utf8).write(to: url)
        guard chmod(url.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return url
    }
}
