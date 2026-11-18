import Foundation
import Testing
@testable import AitvarasAgents

@Suite(.timeLimit(.minutes(2))) struct AgentMCPResolverTests {
    @Test func fingerprintNormalizesJSONOrderAndDefaultsAndTracksDefinitionChanges() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        try writeRepo(#"{"mcpServers":{"echo":{"command":"echo","env":{"MODE":"example"}}}}"#, in: fixture.directory)
        let first = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        try writeRepo(#"{"otherTool":true,"mcpServers":{"echo":{"env":{"MODE":"example"},"command":"echo"}}}"#, in: fixture.directory)
        let reordered = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        let fingerprint = try #require(first.repositoryFingerprints["echo"])
        #expect(fingerprint == reordered.repositoryFingerprints["echo"])
        #expect(fingerprint.count == 64)
        let variants: [AgentMCPServer] = [
            .init(command: "other", env: ["MODE": .literal("example")]),
            .init(command: "echo", args: ["one"], env: ["MODE": .literal("example")]),
            .init(command: "echo", env: ["OTHER": .literal("example")]),
            .init(command: "echo", env: ["MODE": .literal("changed")]),
            .init(command: "echo", env: ["MODE": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000003")])
        ]
        for server in variants { #expect(try server.fingerprint() != fingerprint) }
        let ref = AgentMCPServer(transport: .http, url: "https://service.example.invalid/mcp", headers: ["Authorization": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])
        let changed = AgentMCPServer(transport: .http, url: ref.url, headers: ["Authorization": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000002")])
        #expect(try ref.fingerprint() != changed.fingerprint())
        #expect(try ref.fingerprint() == ref.fingerprint())
        for variant in [
            AgentMCPServer(transport: .sse, url: ref.url, headers: ref.headers),
            AgentMCPServer(transport: .http, url: "https://other.example.invalid/mcp", headers: ref.headers),
            AgentMCPServer(transport: .http, url: ref.url, headers: ["Access": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])
        ] { #expect(try ref.fingerprint() != variant.fingerprint()) }
        #expect(try AgentMCPServer(command: "echo").fingerprint() == "30f9d2a45f4baf9eb1260213fc5d4a1d603ecbd540b0668dac26a4c901eab18d")
    }

    @Test func freshReadRequiresMatchingApprovalAndDenialWins() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        try writeRepo(#"{"mcpServers":{"echo":{"command":"echo"},"other":{"command":"echo"}}}"#, in: fixture.directory)
        let pending = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        #expect(pending.disabledProjectServers == ["echo", "other"])
        #expect(pending.effectiveServers.isEmpty)
        var setup = AgentMCPProjectConfiguration(approvedServers: pending.repositoryFingerprints, localMayUseMCP: true)
        let approved = try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup)
        #expect(approved.disabledProjectServers.isEmpty)
        #expect(approved.effectiveServers.count == 2)
        #expect(approved.claudeServers.isEmpty)
        #expect(approved.localServers.count == 2)
        setup.deniedServers = ["echo"]
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup).disabledProjectServers == ["echo"])
        setup.deniedServers = []
        try writeRepo(#"{"mcpServers":{"echo":{"command":"changed"},"new":{"command":"echo"}}}"#, in: fixture.directory)
        let changed = try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup)
        #expect(changed.disabledProjectServers == ["echo", "new"])
        #expect(changed.settingsJSON == #"{"disabledMcpjsonServers":["echo","new"]}"#)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent(".mcp.json"))
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup).repositoryServers.isEmpty)
    }

    @Test func mergePrecedenceGlobalDisablesAndAppRepoCollisions() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let global = ["echo": AgentMCPServer(command: "global"), "disabled": .init(command: "global")]
        let setup = AgentMCPProjectConfiguration(projectServers: ["echo": .init(command: "project")], disabledGlobalServers: ["disabled"])
        let result = try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup, globalServers: global)
        #expect(result.effectiveServers == setup.projectServers)
        #expect(result.claudeServers == result.effectiveServers)
        #expect(result.unavailableForLocal == ["echo": .optInRequired])
        try writeRepo(#"{"mcpServers":{"echo":{"command":"echo"}}}"#, in: fixture.directory)
        #expect(throws: AgentMCPError.nameCollision) {
            try AgentMCPResolver.prepare(directory: fixture.directory, setup: setup, globalServers: global)
        }
    }

    @Test func localIsStdioOnlyAndRemoteServersHaveAnExplicitReason() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let servers: [String: AgentMCPServer] = ["echo": .init(command: "echo"),
            "http": .init(transport: .http, url: "https://service.example.invalid/mcp", headers: ["Access": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")]),
            "events": .init(transport: .sse, url: "https://service.example.invalid/events")]
        let result = try AgentMCPResolver.prepare(directory: fixture.directory,
            setup: .init(projectServers: servers, localMayUseMCP: true))
        #expect(result.localServers == ["echo": servers["echo"]!])
        #expect(result.unavailableForLocal == ["http": .remoteTransport, "events": .remoteTransport])
        #expect(result.unavailableForLocal.values.allSatisfy { $0.explanation.contains("stdio") })
        #expect(result.effectiveServers.count == 3)
    }

    @Test func inventoryIncludesAncestorsOfActualCwd() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let other = fixture.directory.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try writeRepo(#"{"mcpServers":{"parent":{"command":"echo"}}}"#, in: fixture.directory)
        try writeRepo(#"{"mcpServers":{"child":{"command":"echo"}}}"#, in: other)
        #expect(try AgentMCPResolver.prepare(directory: other, setup: .init()).disabledProjectServers == ["child", "parent"])
    }

    @Test(arguments: ["garbage", #"{}"#, #"{"mcpServers":[]}"#])
    func malformedRepositoryFailsClosed(json: String) throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        try writeRepo(json, in: fixture.directory)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init()).repositoryUnreadable)
    }

    @Test func oversizedSymlinkAndNonRegularInventoriesFailClosed() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let file = fixture.directory.appendingPathComponent(".mcp.json")
        try writeRepo(String(repeating: "x", count: AgentMCPConfiguration.maximumBytes + 1), in: fixture.directory)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init()).repositoryUnreadable)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.executable)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init()).repositoryUnreadable)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init()).repositoryUnreadable)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory.appendingPathComponent("missing"), setup: .init()).repositoryUnreadable)
    }

    @Test func unknownServerFieldsArePreservedAndFingerprintChangesRequireReview() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        try writeRepo(#"{"otherTool":{},"mcpServers":{"echo":{"command":"echo","timeout":12,"oauth":{"mode":"example"}}}}"#, in: fixture.directory)
        let first = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        #expect(!first.repositoryUnreadable)
        #expect(first.repositoryEntries["echo"]?.canonicalJSON.contains("oauth") == true)
        let approved = AgentMCPProjectConfiguration(approvedServers: first.repositoryFingerprints)
        #expect(try AgentMCPResolver.prepare(directory: fixture.directory, setup: approved).disabledProjectServers.isEmpty)
        try writeRepo(#"{"mcpServers":{"echo":{"command":"echo","timeout":13,"oauth":{"mode":"example"}}}}"#, in: fixture.directory)
        let changed = try AgentMCPResolver.prepare(directory: fixture.directory, setup: approved)
        #expect(changed.repositoryFingerprints != first.repositoryFingerprints)
        #expect(changed.disabledProjectServers == ["echo"])
    }

    @Test func unsupportedServersAreListedAndCannotBeApproved() throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        try writeRepo(#"{"mcpServers":{"echo":{"command":"echo"},"bad":{"command":"echo","args":[1]},"future":{"type":"future"},"scalar":7}}"#, in: fixture.directory)
        let inventory = try AgentMCPResolver.prepare(directory: fixture.directory, setup: .init())
        #expect(inventory.repositoryEntries.count == 4)
        #expect(inventory.repositoryEntries["bad"]?.unsupportedReason == "Unsupported MCP server configuration.")
        let approved = try AgentMCPResolver.prepare(directory: fixture.directory,
            setup: .init(approvedServers: inventory.repositoryFingerprints))
        #expect(!approved.repositoryUnreadable)
        #expect(approved.disabledProjectServers == ["bad", "future", "scalar"])
        #expect(Set(approved.effectiveServers.keys) == ["echo"])
    }

    @Test func appConfigurationRejectsInvalidTransportsValuesAndNames() throws {
        let invalid: [AgentMCPServer] = [
            .init(command: ""), .init(command: "echo", url: "https://service.example.invalid/mcp"),
            .init(command: "echo", env: ["ACCESS": .secretReference("")]),
            .init(command: "echo", env: ["BAD=KEY": .literal("example")]),
            .init(transport: .http, url: "file:///tmp/example"),
            .init(transport: .http, url: "https://service.example.invalid/mcp", headers: ["Access": .literal("one\ntwo")])
        ]
        for server in invalid { #expect(throws: AgentMCPError.invalidConfiguration) { try AgentMCPConfiguration.validate(["echo": server]) } }
        #expect(throws: AgentMCPError.invalidName) { try AgentMCPConfiguration.validate(["bad name": .init(command: "echo")]) }
        #expect(throws: AgentMCPError.invalidConfiguration) { try AgentMCPConfiguration.decodeServers("[]") }
        let server = AgentMCPServer(command: "echo", env: ["MODE": .literal("example"), "ACCESS": .secretReference("agent.mcp.00000000-0000-4000-8000-000000000001")])
        #expect(try AgentMCPConfiguration.decodeServers(AgentMCPConfiguration.encode(["echo": server])) == ["echo": server])
    }
}

private func writeRepo(_ json: String, in directory: URL) throws {
    try Data(json.utf8).write(to: directory.appendingPathComponent(".mcp.json"))
}
