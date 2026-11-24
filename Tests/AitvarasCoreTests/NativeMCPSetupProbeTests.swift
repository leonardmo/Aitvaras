import Darwin
import Foundation
import Testing
@testable import AitvarasAgent
import AitvarasAgents

@Suite(.timeLimit(.minutes(1))) struct NativeMCPSetupProbeTests {
    @Test func stdioDiscoversPagedToolsAndStopsTheProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = "agent.mcp." + UUID().uuidString
        let credential = "probe-fixture-credential"
        let server = AgentMCPServer(command: "python3", args: ["-I", "-c", fixture, "list"],
                                    env: ["MCP_FIXTURE_VALUE": .secretReference(reference)])
        let names = try await NativeMCPSetupProbe.test(server: server, directory: directory,
            providerEnvironment: ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "ambient-fixture", "MCP_UNRELATED": "ambient-fixture"]) { key in
                #expect(key == reference)
                return credential
            }
        #expect(names == ["get_example", "list_examples"])
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test(arguments: ["oversize", "credentials", "wrong-id", "repeat"])
    func stdioRejectsMalformedOrSecretBearingResults(mode: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference = "agent.mcp." + UUID().uuidString
        let server = AgentMCPServer(command: "/usr/bin/python3", args: ["-I", "-c", fixture, mode],
                                    env: ["MCP_FIXTURE_VALUE": .secretReference(reference)])
        await #expect(throws: NativeMCPSetupProbe.Failure.invalidResponse) {
            try await NativeMCPSetupProbe.test(server: server, directory: directory, providerEnvironment: [:],
                                              resolveSecret: { _ in "probe-fixture-credential" })
        }
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func timeoutTerminatesTheStdioServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = AgentMCPServer(command: "/usr/bin/python3", args: ["-I", "-c", fixture, "hang"])
        await #expect(throws: NativeMCPSetupProbe.Failure.timedOut) {
            try await NativeMCPSetupProbe.test(server: server, directory: directory, providerEnvironment: [:],
                                              resolveSecret: { _ in nil }, timeout: .seconds(1))
        }
        let pid = try #require(Int32(String(contentsOf: directory.appendingPathComponent("child-pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func nativeHTTPSUsesOnlyTheApprovedEndpointAndSendsInventoryRequests() async throws {
        let directory = FileManager.default.temporaryDirectory
        let reference = "agent.mcp." + UUID().uuidString
        let transport = ProbeHTTPFixture()
        let server = AgentMCPServer(transport: .http, url: "https://mcp.example.invalid/tools",
                                    headers: ["Authorization": .secretReference(reference)])
        let names = try await NativeMCPSetupProbe.test(server: server, directory: directory, providerEnvironment: [:],
            resolveSecret: { key in
                #expect(key == reference)
                return "Bearer probe-fixture-credential"
            }, timeout: .seconds(2), send: { try await transport.send($0, id: $1) })
        #expect(names == ["list_examples"])
        #expect(await transport.methods == ["initialize", "notifications/initialized", "tools/list"])
    }

    @Test func nativeHTTPSRejectsReservedHeadersBeforeLookingUpCredentials() async throws {
        let reference = "agent.mcp." + UUID().uuidString
        let server = AgentMCPServer(transport: .http, url: "https://mcp.example.invalid/tools",
                                    headers: ["Mcp-Session-Id": .secretReference(reference)])
        await #expect(throws: NativeMCPSetupProbe.Failure.invalidDefinition) {
            try await NativeMCPSetupProbe.test(server: server, directory: FileManager.default.temporaryDirectory,
                providerEnvironment: [:], resolveSecret: { _ in
                    Issue.record("Credential lookup occurred before validating the header.")
                    return nil
                }, timeout: .seconds(2), send: { _, _ in
                    Issue.record("An invalid definition should never send a request.")
                    throw NativeMCPSetupProbe.Failure.invalidResponse
                })
        }
    }

    private let fixture = #"""
        import json, os, sys, time
        from pathlib import Path

        mode = sys.argv[1]
        Path("child-pid").write_text(str(os.getpid()))
        if mode == "hang":
            time.sleep(30)
            raise SystemExit(0)

        secret = os.environ["MCP_FIXTURE_VALUE"]
        assert secret == "probe-fixture-credential"
        assert "MCP_UNRELATED" not in os.environ and "OPENAI_API_KEY" not in os.environ
        print(secret, file=sys.stderr, flush=True)

        def receive(method):
            message = json.loads(sys.stdin.readline())
            assert message["jsonrpc"] == "2.0" and message["method"] == method
            return message

        def reply(request, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)

        def tool(name):
            return {"name": name, "inputSchema": {"type": "object"}}

        init = receive("initialize")
        reply(init, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}})
        assert "id" not in receive("notifications/initialized")
        request = receive("tools/list")
        if mode == "oversize":
            print("x" * (256 * 1024 + 1), flush=True)
        elif mode == "credentials":
            reply(request, {"tools": [tool(secret)]})
        elif mode == "wrong-id":
            reply({"id": "a-different-request"}, {"tools": []})
        else:
            reply(request, {"tools": [tool("list_examples")], "nextCursor": "fixture-page"})
            request = receive("tools/list")
            assert request["params"] == {"cursor": "fixture-page"}
            reply(request, {"tools": [tool("get_example")], **({"nextCursor": "fixture-page"} if mode == "repeat" else {})})
        assert sys.stdin.read() == ""
        """#
}

private actor ProbeHTTPFixture {
    private(set) var methods: [String] = []

    func send(_ request: URLRequest, id: JSONValue?) throws -> GatewayHTTPResponse {
        #expect(request.url?.absoluteString == "https://mcp.example.invalid/tools")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer probe-fixture-credential")
        let body = try #require(request.httpBody)
        let payload = try #require(JSONValue.parse(String(decoding: body, as: UTF8.self)))
        let method = try #require(payload["method"]?.stringValue)
        methods.append(method)
        #expect(payload["id"] == id)
        if method == "initialize" {
            return reply(id: id, result: .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object(["tools": .object([:])])]),
                         headers: ["mcp-session-id": "probe-fixture-session"])
        }
        #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == "probe-fixture-session")
        #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        if method == "notifications/initialized" { return .init(status: 202, headers: [:], body: Data()) }
        guard method == "tools/list" else { throw NativeMCPSetupProbe.Failure.invalidResponse }
        return reply(id: id, result: .object(["tools": .array([.object(["name": .string("list_examples"),
            "inputSchema": .object(["type": .string("object")])])])]))
    }

    private func reply(id: JSONValue?, result: JSONValue, headers: [String: String] = [:]) -> GatewayHTTPResponse {
        .init(status: 200, headers: headers, body: Data(JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id ?? .null, "result": result
        ]).jsonString.utf8))
    }
}
