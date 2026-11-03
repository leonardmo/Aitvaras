import Foundation

/// Resumable, profile-scoped Hugging Face model downloads. The downloader has
/// its own small Python environment and therefore does not depend on the much
/// larger optional neural-voice installation.
public enum ModelDownloader {
    public enum Stage: Sendable {
        case locatingPython
        case preparingDownloader
        case checkingDiskSpace
        case downloading
        case verifying
    }

    public struct DownloadError: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    static let pythonCandidates = [
        "/opt/homebrew/bin/python3.14",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3.10",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.14",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3.10",
        "/usr/local/bin/python3",
        "/usr/bin/python3"
    ]

    static var environmentURL: URL {
        AitvarasPaths.stateDirectory
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("model-download-venv", isDirectory: true)
    }

    public static func download(
        repository: String,
        revision: String,
        to destination: URL,
        expectedBytes: Int64,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in }
    ) async throws {
        guard isPinnedRevision(revision) else {
            throw DownloadError("Model downloads require a pinned 40-character revision.")
        }
        try createPrivateNetworkDirectories(fileManager: .default)
        onStage(.locatingPython)
        let python = try await ensureToolEnvironment(onStage: onStage)
        try Task.checkCancellation()

        onStage(.checkingDiskSpace)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try checkDiskSpace(destination: destination, expectedBytes: expectedBytes)
        try Task.checkCancellation()

        onStage(.downloading)
        let script = """
            import os, sys
            os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
            os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
            from huggingface_hub import snapshot_download
            snapshot_download(
                repo_id=sys.argv[1],
                local_dir=sys.argv[2],
                revision=sys.argv[3],
                max_workers=4,
                token=False,
            )
            """
        let output = try await DisclaimedProcess.run(
            executable: python.path,
            arguments: ["-c", script, repository, destination.path, revision],
            timeout: 12 * 60 * 60,
            environment: privateNetworkEnvironment,
            inheritEnvironment: false)
        guard output.exitCode == 0 else {
            throw DownloadError(
                "The model download stopped (code \(output.exitCode)). "
                    + diagnosticTail(output.stdout))
        }

        onStage(.verifying)
        guard AitvarasPaths.isCompleteModelDirectory(destination) else {
            throw DownloadError(
                "The download is incomplete. Retry it to continue from the saved files.")
        }
    }

    static func ensureToolEnvironment(
        onStage: @escaping @Sendable (Stage) -> Void
    ) async throws -> URL {
        let environment = environmentURL
        let installedPython = environment.appendingPathComponent("bin/python")
        if await hasHuggingFaceHub(installedPython.path) { return installedPython }

        guard let sourcePython = await findCompatiblePython() else {
            throw DownloadError(
                "Model downloads need Python 3.10 or newer. Install Python 3.12 with Homebrew, then retry.")
        }

        onStage(.preparingDownloader)
        let fileManager = FileManager.default
        let parent = environment.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try createPrivateNetworkDirectories(fileManager: fileManager)
        let staged = parent.appendingPathComponent(
            ".model-download-venv-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staged) }

        let created = try await DisclaimedProcess.run(
            executable: sourcePython,
            arguments: ["-m", "venv", staged.path],
            timeout: 2 * 60,
            environment: privateNetworkEnvironment,
            inheritEnvironment: false)
        guard created.exitCode == 0 else {
            throw DownloadError(
                "The private model downloader could not be created. "
                    + diagnosticTail(created.stdout))
        }

        let stagedPython = staged.appendingPathComponent("bin/python")
        let installed = try await DisclaimedProcess.run(
            executable: stagedPython.path,
            arguments: [
                "-m", "pip", "install",
                "--disable-pip-version-check", "--quiet", "--upgrade",
                "huggingface_hub>=0.34,<2"
            ],
            timeout: 10 * 60,
            environment: privateNetworkEnvironment,
            inheritEnvironment: false)
        guard installed.exitCode == 0,
              await hasHuggingFaceHub(stagedPython.path) else {
            throw DownloadError(
                "The model download helper could not be installed. "
                    + diagnosticTail(installed.stdout))
        }

        // Only derived tooling lives here. Replace an incomplete old helper
        // after the staged environment has been fully verified.
        if fileManager.fileExists(atPath: environment.path) {
            try fileManager.removeItem(at: environment)
        }
        try fileManager.moveItem(at: staged, to: environment)
        return environment.appendingPathComponent("bin/python")
    }

    static func findCompatiblePython(
        candidates: [String] = pythonCandidates
    ) async -> String? {
        for candidate in candidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            guard let output = try? await DisclaimedProcess.run(
                executable: candidate,
                arguments: [
                    "-c",
                    "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
                ],
                timeout: 5),
                output.exitCode == 0,
                isCompatiblePythonVersion(output.stdout) else { continue }
            return candidate
        }
        return nil
    }

    static func isCompatiblePythonVersion(_ output: String) -> Bool {
        let numbers = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return false }
        return numbers[0] > 3 || (numbers[0] == 3 && numbers[1] >= 10)
    }

    static func isPinnedRevision(_ revision: String) -> Bool {
        revision.count == 40 && revision.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }

    static func requiredAdditionalBytes(
        expectedBytes: Int64,
        existingBytes: Int64,
        headroom: Int64 = 512 * 1_024 * 1_024
    ) -> Int64 {
        max(0, expectedBytes - max(0, existingBytes)) + headroom
    }

    private static func hasHuggingFaceHub(_ python: String) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: python),
              let output = try? await DisclaimedProcess.run(
                executable: python,
                arguments: ["-c", "import huggingface_hub"],
                timeout: 10,
                environment: privateNetworkEnvironment,
                inheritEnvironment: false) else { return false }
        return output.exitCode == 0
    }

    private static func checkDiskSpace(destination: URL, expectedBytes: Int64) throws {
        let fileManager = FileManager.default
        let existing = directoryBytes(destination, fileManager: fileManager)
        let needed = requiredAdditionalBytes(
            expectedBytes: expectedBytes, existingBytes: existing)
        let probe = fileManager.fileExists(atPath: destination.path)
            ? destination : destination.deletingLastPathComponent()
        let available = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        guard let available else { return }
        guard available >= needed else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            throw DownloadError(
                "Not enough free space. About \(formatter.string(fromByteCount: needed)) "
                    + "is still needed, including safety headroom.")
        }
    }

    private static func directoryBytes(_ directory: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey
            ],
            options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey
            ]) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static var privateNetworkEnvironment: [String: String] {
        let tools = environmentURL.deletingLastPathComponent()
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": tools.appendingPathComponent("sandbox-home").path,
            "HF_HOME": tools.appendingPathComponent("hf-home").path,
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PIP_NO_CACHE_DIR": "1",
            "NO_COLOR": "1",
            "PYTHONUNBUFFERED": "1",
            "PYTHONNOUSERSITE": "1"
        ]
    }

    private static func createPrivateNetworkDirectories(fileManager: FileManager) throws {
        let tools = environmentURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: tools.appendingPathComponent("sandbox-home", isDirectory: true),
            withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: tools.appendingPathComponent("hf-home", isDirectory: true),
            withIntermediateDirectories: true)
    }

    private static func diagnosticTail(_ output: String) -> String {
        let meaningful = output.split(separator: "\n")
            .suffix(4).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return meaningful.isEmpty ? "Retry to continue." : String(meaningful.suffix(600))
    }
}
