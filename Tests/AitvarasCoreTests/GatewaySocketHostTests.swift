import Darwin
import Foundation
import XCTest
@testable import AitvarasAgents

final class GatewaySocketHostTests: XCTestCase {
    @MainActor
    func testPrivateSocketStaleReplacementAndActiveOwner() async throws {
        try await requireSocketAccess {
            let root = try scratchGatewayDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let endpoint = GatewayEndpoint(stateDirectory: root)
            let folder = endpoint.socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            let stale = try GatewayUnixSocket.newSocket()
            let bound = try GatewayUnixSocket.withAddress(endpoint.socketURL.path) { Darwin.bind(stale, $0, $1) }
            let code = errno
            close(stale)
            guard bound == 0 else { throw GatewayTransportError.system("bind(AF_UNIX)", code) }
            let listener = try GatewayUnixListener(endpoint)
            defer { listener.stop() }
            XCTAssertEqual(try GatewayUnixSocket.statAt(folder.path).st_mode & 0o777, 0o700)
            XCTAssertEqual(try GatewayUnixSocket.statAt(endpoint.socketURL.path).st_mode & 0o777, 0o600)
            XCTAssertThrowsError(try GatewayUnixListener(endpoint)) { error in
                XCTAssertEqual(error as? GatewayTransportError, .alreadyRunning)
            }
            let receiver = try GatewayUnixSocket.connect(endpoint, until: .now.advanced(by: .seconds(1)))
            receiver.stop()
            // Simulate an external replacement. Shutdown must leave it intact.
            try FileManager.default.removeItem(at: endpoint.socketURL)
            try Data("replacement".utf8).write(to: endpoint.socketURL)
            listener.stop()
            XCTAssertEqual(try Data(contentsOf: endpoint.socketURL), Data("replacement".utf8))
        }
    }

    func testRegularAndSymlinkNodesAreNeverRemoved() throws {
        let root = try scratchGatewayDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = GatewayEndpoint(stateDirectory: root)
        let folder = endpoint.socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        try Data([1]).write(to: endpoint.socketURL)
        XCTAssertThrowsError(try GatewayUnixListener(endpoint)) { error in
            XCTAssertEqual(error as? GatewayTransportError, .insecurePath)
        }
        XCTAssertEqual(try Data(contentsOf: endpoint.socketURL), Data([1]))
        let sentinel = root.appendingPathComponent("sentinel")
        try FileManager.default.moveItem(at: endpoint.socketURL, to: sentinel)
        try FileManager.default.createSymbolicLink(at: endpoint.socketURL, withDestinationURL: sentinel)
        XCTAssertThrowsError(try GatewayUnixListener(endpoint)) { error in
            XCTAssertEqual(error as? GatewayTransportError, .insecurePath)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1]))
        XCTAssertEqual(try GatewayUnixSocket.type(GatewayUnixSocket.statAt(endpoint.socketURL.path)), mode_t(S_IFLNK))
    }

    @MainActor
    func testRegistrationKernelCWDAndRevocationCloseALiveSession() async throws {
        try await requireSocketAccess {
            let root = try scratchGatewayDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let endpoint = GatewayEndpoint(stateDirectory: root)
            let registry = GatewayLaunchRegistry()
            let invocation = GatewaySocketCallFixture()
            let tool = try gatewayFixtureTool()
            let service = GatewaySocketService(endpoint: endpoint, registry: registry,
                verifyLauncher: { $0.identity.pid == getpid() },
                resolveContext: { peer, client in
                    guard try peer.startingDirectory().resolvingSymlinksInPath().path ==
                            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path else {
                        throw GatewayTransportError.rejected
                    }
                    return .init(client: client, projectID: nil)
                },
                makeSession: { invocationContext, authorize in
                    MCPGateway(invocation: invocationContext, authorize: authorize, catalog: { _ in [tool] },
                        dispatch: { _, _, _, revalidate in
                            try await revalidate()
                            await invocation.start()
                            do { try await Task.sleep(for: .seconds(5)) }
                            catch { await invocation.cancel(); throw error }
                            return .init(text: "unexpected")
                        })
                })
            try await service.start()
            do {
                let startup = GatewayStartup(endpoint: endpoint, appBundle: root, budget: .seconds(2),
                    dial: { endpoint, deadline in try GatewayUnixSocket.connect(endpoint, until: deadline) },
                    openApp: { _, _, _ in throw GatewayTransportError.appNotReady })
                let registration = try await startup.connect(role: .register(.claude))
                registration.stop()
                let launches = await registry.activeLaunches()
                let launch = try XCTUnwrap(launches.first)
                let peer = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-I", "-c", Self.relayFixture, endpoint.socketURL.path, endpoint.profile], currentDirectory: nil)
                try peer.start()
                do {
                    try await Self.until { await invocation.started }
                    let revoked = await registry.revoke(id: launch.id)
                    XCTAssertTrue(revoked)
                    try await Self.until { await invocation.cancelled }
                    let status = try await peer.waitForExit()
                    XCTAssertEqual(status, 0, peer.stderrText)
                } catch {
                    _ = try? await peer.waitForExit()
                    throw error
                }
                await service.stop()
            } catch {
                await service.stop()
                throw error
            }
        }
    }

    @MainActor
    func testSignaturePinsExactSignedExecutableForSocketPeer() async throws {
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        guard FileManager.default.isExecutableFile(atPath: codesign.path) else {
            throw XCTSkip("Ad hoc peer signing requires /usr/bin/codesign.")
        }
        let root = try scratchGatewayDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("peer.c")
        let binary = root.appendingPathComponent("peer-unsigned")
        try Self.signedPeerFixture.write(to: source, atomically: true, encoding: .utf8)
        try await Self.runFixtureTool(URL(fileURLWithPath: "/usr/bin/xcrun"),
            ["clang", "-arch", "arm64", "-arch", "x86_64", source.path, "-o", binary.path])
        let signedPeer = root.appendingPathComponent("peer")
        let otherPeer = root.appendingPathComponent("other-peer")
        for copy in [signedPeer, otherPeer] {
            try FileManager.default.copyItem(at: binary, to: copy)
            try await Self.runFixtureTool(codesign, ["-s", "-", "-f", "--digest-algorithm=sha256",
                "-i", "org.example.gateway.\(copy.lastPathComponent)", copy.path])
        }
        let expected = try GatewayCodeIdentity(executable: signedPeer)
        let other = try GatewayCodeIdentity(executable: otherPeer)
        XCTAssertEqual(expected.hashes.count, 2, "The two slices must each supply a pinned SHA-256 CDHash.")
        XCTAssertEqual(other.hashes.count, 2)
        XCTAssertTrue(expected.hashes.isDisjoint(with: other.hashes))

        try await requireSocketAccess {
            let endpoint = GatewayEndpoint(stateDirectory: root)
            let listener = try GatewayUnixListener(endpoint)
            defer { listener.stop() }
            let process = StreamingProcess(executable: signedPeer, arguments: [endpoint.socketURL.path], currentDirectory: nil)
            try process.start()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        let channel = try await listener.acceptChannel()
                        defer { channel.stop() }
                        let peer = try GatewayProcessInspector.live.socketPeer(channel.socketFD)
                        XCTAssertNil(expected.mismatch(peer), "Signed peer failed identity verification.")
                        XCTAssertEqual(other.mismatch(peer), .path, "A separately signed copy passed the executable path check.")
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(4))
                        listener.stop()
                        throw GatewayTransportError.timeout
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                let status = try await process.waitForExit()
                XCTAssertEqual(status, 0, process.stderrText)
            } catch {
                let status = try? await process.waitForExit()
                XCTFail("Signed peer connection failed with \(error). Exit \(status.map(String.init) ?? "unknown"). \(process.stderrText)")
                throw error
            }
        }
    }

    private static func runFixtureTool(_ tool: URL, _ arguments: [String]) async throws {
        let result = try await OneShotProcess.run(executable: tool, arguments: arguments, timeout: .seconds(10))
        guard !result.timedOut, result.exitCode == 0 else {
            throw FixtureToolFailure(tool: tool.lastPathComponent, output: result)
        }
    }

    private struct FixtureToolFailure: Error, CustomStringConvertible {
        let tool: String
        let output: OneShotProcess.Output

        var description: String {
            "\(tool) failed while preparing a signed peer (exit \(output.exitCode), timed out \(output.timedOut)). \(output.stderr)"
        }
    }

    private static let signedPeerFixture = #"""
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
    struct sockaddr_un server = { .sun_family = AF_UNIX };
    if (argc != 2 || strlcpy(server.sun_path, argv[1], sizeof(server.sun_path)) >= sizeof(server.sun_path)) return 2;
    server.sun_len = SUN_LEN(&server);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&server, server.sun_len) < 0) {
        perror("connect to test socket");
        return 3;
    }
    struct pollfd peer = { .fd = fd, .events = POLLIN };
    int result = poll(&peer, 1, 3000);
    close(fd);
    return result < 0 ? 4 : 0;
}
"""#

    @MainActor
    private func requireSocketAccess(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch GatewayTransportError.system(let name, let code) where code == EPERM || code == EACCES {
            throw XCTSkip("Unix-socket operation denied: \(name), errno \(code). Repeat on the host.")
        }
    }

    private static func until(_ ready: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw GatewayTransportError.timeout
    }

    private static let relayFixture = #"""
import json, socket, sys
path, profile = sys.argv[1:]
with socket.socket(socket.AF_UNIX) as s:
    s.settimeout(6)
    s.connect(path)
    with s.makefile("rb") as stream:
        def send(body):
            s.sendall(json.dumps(body).encode() + b"\n")
        send({"version": 1, "profile": profile, "role": "relay"})
        assert json.loads(stream.readline())["status"] == "ready"
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
        assert json.loads(stream.readline())["result"]["serverInfo"]["name"] == "aitvaras"
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "memory_search"}})
        assert stream.readline() == b""
"""#
}

private actor GatewaySocketCallFixture {
    var started = false
    var cancelled = false
    func start() { started = true }
    func cancel() { cancelled = true }
}

private func scratchGatewayDirectory() throws -> URL {
    var template = Array("/tmp/ait-gw.XXXXXX".utf8CString)
    guard let path = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!).map { String(cString: $0) } }) else {
        throw GatewayTransportError.system("mkdtemp", errno)
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}
