import Foundation
import Darwin
import Testing
import AitvarasConnectors

/// Manual opt-in only. Uses an existing authenticated profile and account quota.
/// Never enable without the user's explicit approval for this synthetic read.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AITVARAS_APPROVED_CODEX_FILE_TEST"] == "1"))
struct CodexProjectReadLiveTests {
    private actor Evidence {
        var output = ""
        var read = false
        var completed = false
        func record(_ event: CodexInteractiveEvent) {
            switch event {
            case .textDelta(let text): output += text
            case .projectFileAccess(let tool, let path, _):
                if tool == "aitvaras_project_read" && path == "project[0]/example.txt" { read = true }
            case .completed(let state, _, _): completed = state == "completed"
            default: break
            }
        }
    }

    @Test func readsOnlyTheSyntheticApprovedProject() async throws {
        let profile = try #require(ProcessInfo.processInfo.environment["AITVARAS_APPROVED_CODEX_PROFILE"])
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("aitvaras-approved-read-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: raw) }
        let marker = "SYNTHETIC_READ_\(UUID().uuidString)"
        try Data(marker.utf8).write(to: raw.appendingPathComponent("example.txt"))
        let resolved = try #require(realpath(raw.path, nil))
        let root = String(cString: resolved); free(resolved)
        let client = CodexInteractiveClient(profileDirectory: URL(fileURLWithPath: profile))
        let status = try await client.status()
        #expect(status.authenticated)
        let selected = try #require(status.models.first)
        let evidence = Evidence()
        try await client.run(sessionID: nil, context: "Synthetic file-reader verification. No personal context or history.",
            model: selected.id, effort: selected.efforts.contains("low") ? "low" : selected.efforts.first,
            prompt: "Call the direct function aitvaras_project.read with root 0 and path example.txt, not exec. Reply with only the exact file contents, no formatting.",
            projectRoots: [root]) { event in await evidence.record(event) }
        #expect(await evidence.read)
        #expect(await evidence.completed)
        #expect(await evidence.output.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
        await client.shutdown()
    }
}
