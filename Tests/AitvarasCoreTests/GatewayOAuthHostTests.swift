import Darwin
import Foundation
import XCTest
import AitvarasAgents
@testable import AitvarasAgent

final class GatewayOAuthHostTests: XCTestCase {
    @MainActor
    func testFiniteLoopbackCallback() async throws {
        let callback: GatewayOAuthCallback
        do { callback = try await GatewayOAuthCallback.start(timeout: .seconds(3)) }
        catch {
            try Self.requireLoopback()
            throw error
        }
        defer { callback.stop() }
        let url = try XCTUnwrap(URL(string: callback.redirect.absoluteString + "?code=synthetic&state=example"))
        let send = GatewayHTTPClient.make()
        async let response = send(URLRequest(url: url), nil)
        let received = try await callback.receive()
        XCTAssertEqual(received, url)
        let reply = try await response
        XCTAssertEqual(reply.status, 200)
        let code = try GatewayOAuth.code(received, redirect: callback.redirect, state: "example",
                                         issuer: URL(string: "https://auth.example.invalid")!)
        XCTAssertEqual(code, "synthetic")
    }

    @MainActor
    func testLoopbackUpstreamSSEEndsAfterMatchingReply() async throws {
        try Self.requireLoopback()
        let process = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", "-c", Self.server], currentDirectory: nil)
        try process.start()
        process.closeInput()
        let send = GatewayHTTPClient.make()
        do {
            var lines = process.lines.makeAsyncIterator()
            let first = try await lines.next()
            let port = try XCTUnwrap(first.flatMap(Int.init))
            let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
            let id = JSONValue.string("request")
            let request = GatewayOAuth.rpc(endpoint, method: "tools/call", id: id, params: .object(["name": .string("list_issues")]),
                                           authorization: "test-access", sessionID: "test-session", version: "2025-06-18")
            let reply = try await send(request, id)
            XCTAssertEqual(reply.json?["result"]?["content"]?.arrayValue?.first?["text"], .string("Synthetic issue"))
            let exit = try await process.waitForExit()
            XCTAssertEqual(exit, 0)
        } catch {
            try? await process.shutdown(grace: .zero)
            throw error
        }
    }

    private static func requireLoopback() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            if errno == EPERM || errno == EACCES { throw XCTSkip("Sandbox denied creation of an IPv4 TCP socket.") }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            if errno == EPERM || errno == EACCES { throw XCTSkip("Sandbox denied IPv4 loopback bind.") }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if listen(fd, 1) != 0 {
            if errno == EPERM || errno == EACCES { throw XCTSkip("Sandbox denied IPv4 loopback listen.") }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private static let server = #"""
import http.server, json, signal
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
signal.alarm(8)

class Upstream(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == '/mcp'
        assert self.headers['Authorization'] == 'Bearer test-access'
        assert self.headers['Mcp-Session-Id'] == 'test-session'
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert request['method'] == 'tools/call' and request['params']['name'] == 'list_issues'
        # Deliberately send a notification first and close without Content-Length.
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        self.wfile.write(b'event: message\r\ndata: {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\r\n\r\n')
        reply = {"jsonrpc":"2.0","id":request["id"],"result":{"content":[{"type":"text","text":"Synthetic issue"}]}}
        self.wfile.write(('data: ' + json.dumps(reply) + '\n\n').encode())
        self.wfile.flush()

with http.server.HTTPServer(('127.0.0.1', 0), Upstream) as server:
    server.timeout = 5
    print(server.server_port, flush=True)
    server.handle_request()
"""#
}
