import Foundation
import Testing
import AitvarasCore
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPRuntimeFileTests {
    @Test func privateCreationResolvesOnlyIntoTheFileAndAuditsMetadata() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let audit = MCPRuntimeAudit()
        let secrets = MCPTestSecrets(["mcp.access": "synthetic-access-value"])
        let project = UUID(), run = UUID()
        let servers: [String: AgentMCPServer] = [
            "echo": .init(command: "echo", args: ["one", "two"], env: ["MODE": .literal("example"), "ACCESS": .secretReference("mcp.access")]),
            "remote": .init(transport: .http, url: "https://service.example.invalid/mcp", headers: ["Access": .secretReference("mcp.access")])]
        let fingerprint = try servers["echo"]!.fingerprint()
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
            servers: servers, audit: { try await audit.record($0) }, resolveSecret: { await secrets.get($0) })
        #expect(file.url == fixture.directory.appendingPathComponent("Runtime/mcp/\(project.uuidString)/\(run.uuidString).json"))
        let raw = try String(contentsOf: file.url, encoding: .utf8)
        let json = try #require(JSONValue.parse(raw))
        #expect(json["mcpServers"]?["echo"]?["env"]?["ACCESS"] == .string("synthetic-access-value"))
        #expect(json["mcpServers"]?["remote"]?["headers"]?["Access"] == .string("synthetic-access-value"))
        #expect(json["mcpServers"]?["echo"]?["args"] == .array([.string("one"), .string("two")]))
        #expect(await secrets.requests == ["mcp.access"])
        #expect(try servers["echo"]!.fingerprint() == fingerprint)
        #expect(try mode(file.url) == 0o600)
        #expect(try mode(file.url.deletingLastPathComponent()) == 0o700)
        #expect(try mode(fixture.directory.appendingPathComponent("Runtime")) == 0o700)
        try await file.remove(); try await file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        let events = await audit.events
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.runID == run && !$0.summary.contains("synthetic-access-value") && !($0.detailJSON ?? "").contains("synthetic-access-value") })
    }

    @Test func opencodeFormatIsStdioOnlyAndCarriesCommandAndEnvironment() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
            servers: ["echo": .init(command: "echo", args: ["example"], env: ["ACCESS": .secretReference("mcp.access")])], format: .opencode,
            audit: { _ in }, resolveSecret: { _ in "synthetic-value" })
        let json = try #require(JSONValue.parse(String(contentsOf: file.url, encoding: .utf8)))
        #expect(json["mcp"]?["echo"]?["type"] == .string("local"))
        #expect(json["mcp"]?["echo"]?["enabled"] == .bool(true))
        #expect(json["mcp"]?["echo"]?["command"] == .array([.string("echo"), .string("example")]))
        #expect(json["mcp"]?["echo"]?["environment"]?["ACCESS"] == .string("synthetic-value"))
        try await file.remove()
        await #expect(throws: AgentMCPError.invalidConfiguration) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
                servers: ["remote": .init(transport: .http, url: "https://service.example.invalid/mcp")], format: .opencode,
                audit: { _ in }, resolveSecret: { _ in nil })
        }
    }

    @Test func sameProjectRunsHaveIndependentFilesAndCannotClobber() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let project = UUID(), run = UUID()
        async let first = AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
            servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        async let second = AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: UUID(),
            servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        let (one, two) = try await (first, second)
        await #expect(throws: AgentMCPError.runtimeFile) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
                servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        }
        try await one.remove()
        #expect(FileManager.default.fileExists(atPath: two.url.path))
        try await two.remove()
    }

    @Test func missingAndThrowingSecretResolutionDoesNotCreateAFileOrExposeErrors() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        for shouldThrow in [false, true] {
            await #expect(throws: AgentMCPError.secretUnavailable) {
                try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
                    servers: ["echo": .init(command: "echo", env: ["ACCESS": .secretReference("mcp.access")])],
                    audit: { _ in }, resolveSecret: { _ in
                        if shouldThrow { throw MCPFixtureFailure() }; return nil
                    })
            }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Runtime").path))
    }

    @Test func failedAuditBeforeOrAfterWritingLeavesNoCredentialFile() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        for stage in ["authorized", "created"] {
            let project = UUID(), run = UUID()
            await #expect(throws: AgentMCPError.auditFailed) {
                try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
                    servers: ["echo": .init(command: "echo", env: ["ACCESS": .secretReference("mcp.access")])],
                    audit: { event in if event.summary == "MCP runtime: " + stage { throw MCPFixtureFailure() } },
                    resolveSecret: { _ in "synthetic-value" })
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Runtime/mcp/\(project)/\(run).json").path))
        }
    }

    @Test func cancellationAfterWritingRemovesTheFile() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let project = UUID(), run = UUID()
        let gate = MCPRuntimeGate()
        let task = Task {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
                servers: [:], audit: { event in
                    if event.summary == "MCP runtime: created" { await gate.pause() }
                }, resolveSecret: { _ in nil })
        }
        for _ in 0..<100 where !(await gate.waiting) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.waiting)
        task.cancel(); await gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Runtime/mcp/\(project)/\(run).json").path))
    }

    @Test func unsafeDirectoriesAndExistingSymlinksAreNotFollowedOrModified() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent("Runtime")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.directory)
        await #expect(throws: AgentMCPError.runtimeFile) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
                servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        }
        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        await #expect(throws: AgentMCPError.runtimeFile) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
                servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        }
        #expect(try mode(root) == 0o755)
    }

    @Test func removalStillErasesWhenAuditFailsAndDeinitIsABackstop() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
            servers: [:], audit: { if $0.summary == "MCP runtime: removed" { throw MCPFixtureFailure() } }, resolveSecret: { _ in nil })
        await #expect(throws: AgentMCPError.auditFailed) { try await file.remove() }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        let backstop = try await makeAndRelease(in: fixture.directory)
        #expect(!FileManager.default.fileExists(atPath: backstop.path))
    }

    @Test func explicitCleanupAfterStubStartupFailureRemovesTheRuntime() async throws {
        let fixture = try AgentExecutableFixture("exit 9")
        defer { fixture.remove() }
        let file = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: UUID(), runID: UUID(),
            servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
        let output = try await fixture.run()
        #expect(output.exitCode == 9)
        try await file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func credentialRotationChangesRuntimeOnlyAndExistingFilesAreNotFollowed() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let server = AgentMCPServer(command: "echo", env: ["ACCESS": .secretReference("mcp.access")])
        let fingerprint = try server.fingerprint()
        let project = UUID(), run = UUID()
        let one = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
            servers: ["echo": server], audit: { _ in }, resolveSecret: { _ in "synthetic-first" })
        let first = try String(contentsOf: one.url, encoding: .utf8)
        try await one.remove()
        let two = try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
            servers: ["echo": server], audit: { _ in }, resolveSecret: { _ in "synthetic-second" })
        #expect(try String(contentsOf: two.url, encoding: .utf8) != first)
        #expect(try server.fingerprint() == fingerprint)
        try await two.remove()
        try FileManager.default.createSymbolicLink(at: two.url, withDestinationURL: fixture.executable)
        let original = try Data(contentsOf: fixture.executable)
        await #expect(throws: AgentMCPError.runtimeFile) {
            try await AgentMCPRuntimeFile.create(stateDirectory: fixture.directory, projectID: project, runID: run,
                servers: ["echo": server], audit: { _ in }, resolveSecret: { _ in "synthetic-third" })
        }
        #expect(try Data(contentsOf: fixture.executable) == original)
        #expect(try fixture.directory.appendingPathComponent("Runtime/mcp/\(project)/\(run).json")
            .resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }
}

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue
}
private func makeAndRelease(in directory: URL) async throws -> URL {
    let file = try await AgentMCPRuntimeFile.create(stateDirectory: directory, projectID: UUID(), runID: UUID(),
        servers: [:], audit: { _ in }, resolveSecret: { _ in nil })
    return file.url
}
private struct MCPFixtureFailure: Error {}
private actor MCPRuntimeAudit {
    var events: [ActivityEvent] = []
    func record(_ event: ActivityEvent) throws { events.append(event) }
}
private actor MCPTestSecrets {
    let values: [String: String]
    var requests: [String] = []
    init(_ values: [String: String]) { self.values = values }
    func get(_ key: String) -> String? { requests.append(key); return values[key] }
}
private actor MCPRuntimeGate {
    var waiting: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
