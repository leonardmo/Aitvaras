import Darwin
import Foundation
import Synchronization
import Testing
import XCTest
@testable import AitvarasAgents

@Suite struct GatewayProcessIdentityUnitTests {
    @Test func deniesReusedParentAndChangedLink() throws {
        let root = GatewayProcessIdentity(pid: 10, startSeconds: 1, startMicroseconds: 0)
        let peer = GatewayProcessIdentity(pid: 11, startSeconds: 2, startMicroseconds: 0)
        let replacement = GatewayProcessIdentity(pid: 10, startSeconds: 3, startMicroseconds: 0)
        let inspector = GatewayProcessInspector(snapshot: { pid in
            pid == peer.pid ? .init(identity: peer, parentPID: root.pid, effectiveUID: 0)
                : .init(identity: replacement, parentPID: 1, effectiveUID: 0)
        }, socketPeer: { _ in throw GatewayProcessInspectionError.invalidPeer })
        #expect(throws: GatewayProcessInspectionError.invalidAncestry) {
            try inspector.nearestAncestor(of: peer) { $0 == root }
        }

        let changed = GatewayProcessInspector(snapshot: { pid in
            pid == peer.pid ? .init(identity: peer, parentPID: 1, effectiveUID: 0)
                : .init(identity: root, parentPID: 1, effectiveUID: 0)
        }, socketPeer: inspector.socketPeer)
        #expect(try changed.nearestAncestor(of: peer) { $0 == root } == nil)
        #expect(throws: GatewayProcessInspectionError.invalidAncestry) {
            try changed.nearestAncestor(of: replacement) { $0 == root }
        }
    }

    @Test func rejectsAParentLinkThatChangesDuringInspection() {
        let root = GatewayProcessIdentity(pid: 10, startSeconds: 1, startMicroseconds: 0)
        let peer = GatewayProcessIdentity(pid: 11, startSeconds: 2, startMicroseconds: 0)
        let inspectedPeer = Mutex(false)
        let inspector = GatewayProcessInspector(snapshot: { pid in
            guard pid == peer.pid else { return .init(identity: root, parentPID: 1, effectiveUID: 0) }
            let parent = inspectedPeer.withLock {
                let parent = $0 ? 1 : root.pid
                $0 = true
                return parent
            }
            return .init(identity: peer, parentPID: parent, effectiveUID: 0)
        }, socketPeer: { _ in throw GatewayProcessInspectionError.invalidPeer })
        #expect(throws: GatewayProcessInspectionError.invalidAncestry) {
            try inspector.nearestAncestor(of: peer) { $0 == root }
        }
    }
}

final class GatewayProcessIdentityTests: XCTestCase {
    func testCurrentProcessHasStableKernelStartTime() throws {
        let inspector = GatewayProcessInspector.live
        let first: GatewayProcessSnapshot
        do {
            first = try inspector.snapshot(getpid())
        } catch GatewayProcessInspectionError.system(let operation, let code) where code == EPERM || code == EACCES {
            throw XCTSkip("Process inspection denied: \(operation), errno \(code). Repeat on the host.")
        }
        XCTAssertEqual(first.identity.pid, getpid())
        XCTAssertEqual(first.parentPID, getppid())
        XCTAssertEqual(first.effectiveUID, geteuid())
        XCTAssertGreaterThan(first.identity.startSeconds, 0)
        XCTAssertEqual(try inspector.snapshot(getpid()).identity, first.identity)
    }

    @MainActor
    func testFixtureStartsItsFullProcessChainWithoutBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try Self.startFixture(socketPath: directory.appendingPathComponent("socket").path, mode: "probe")
        let status = try await Self.waitForFixture(process)
        XCTAssertEqual(status, 0, Self.fixtureReport(process, status: status))
    }

    @MainActor
    func testSpawnedSocketPeerHasLiveRegisteredAncestor() async throws {
        do {
            try await exerciseSpawnedChain()
        } catch let error as GatewayProcessInspectionError {
            switch error {
            case .system(let operation, let code) where code == EPERM || code == EACCES:
                throw XCTSkip("Kernel inspection or Unix-socket operation denied: \(operation), errno \(code). Repeat on the host.")
            default:
                throw error
            }
        }
    }

    @MainActor
    private func exerciseSpawnedChain() async throws {
        let socket = try GatewayTestSocket()
        let process = try Self.startFixture(socketPath: socket.path, mode: "connect")
        let registry = GatewayLaunchRegistry()
        do {
            let rootFD = try Self.accept(on: socket, role: "launcher")
            defer { close(rootFD) }
            let leafFD = try Self.accept(on: socket, role: "leaf")
            defer { close(leafFD) }
            let inspector = GatewayProcessInspector.live
            let root = try inspector.socketPeer(rootFD).identity
            let leaf = try inspector.socketPeer(leafFD).identity
            let middle = try inspector.snapshot(inspector.snapshot(leaf.pid).parentPID)
            XCTAssertNotEqual(middle.identity.pid, root.pid)
            XCTAssertEqual(middle.parentPID, root.pid)
            XCTAssertGreaterThan(leaf.startSeconds, 0)
            XCTAssertFalse(root.started(after: leaf))
            XCTAssertEqual(try inspector.snapshot(root.pid).identity, root)

            let context = GatewayLaunchContext(client: .claude, projectID: UUID())
            let launch = try await registry.registerLauncher(on: rootFD, context: context) { $0.identity == root }
            let connection = try await registry.connect(on: leafFD)
            XCTAssertEqual(connection.launch, launch)
            let validated = try await registry.validate(connection)
            XCTAssertEqual(validated, context)

            let other = try socket.connect()
            defer { close(other) }
            let otherFD = try socket.accept()
            defer { close(otherFD) }
            do {
                _ = try await registry.connect(on: otherFD)
                XCTFail("An ancestor of the registered launcher was admitted as its descendant")
            } catch GatewayLaunchRegistryError.unauthorized {}

            // The leaf can exit without the byte and has its own deadline.
            var byte: UInt8 = 1
            guard send(leafFD, &byte, 1, 0) == 1 else {
                throw GatewayProcessInspectionError.system(operation: "send", code: errno)
            }
            let status = try await Self.waitForFixture(process)
            XCTAssertEqual(status, 0, Self.fixtureReport(process, status: status))
            XCTAssertThrowsError(try inspector.socketPeer(leafFD))
            let invalidation = await withTaskGroup(of: GatewayLaunchRegistry.Invalidation?.self) { group in
                group.addTask {
                    var iterator = connection.invalidations.makeAsyncIterator()
                    return await iterator.next()
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
            XCTAssertEqual(invalidation, .launchExited)
            do {
                _ = try await registry.validate(connection)
                XCTFail("An exited launch retained access")
            } catch GatewayLaunchRegistryError.unauthorized {}
            await registry.shutdown()
        } catch {
            await registry.shutdown()
            let status = try? await Self.waitForFixture(process)
            let report = Self.fixtureReport(process, status: status)
            if case GatewayProcessInspectionError.system(let operation, let code) = error {
                if code == EPERM || code == EACCES {
                    throw XCTSkip("\(operation) denied, errno \(code). \(report) Repeat on the host.")
                }
                if code == ETIMEDOUT, operation.hasPrefix("wait for "), status == 71 || status == 73 {
                    let denied = status == 71 ? EPERM : EACCES
                    throw XCTSkip("Fixture Unix socket denied, errno \(denied), during \(operation). \(report) Repeat on the host.")
                }
            }
            throw FixtureFailure(description: "\(error). \(report)")
        }
    }

    @MainActor
    private static func startFixture(socketPath: String, mode: String) throws -> StreamingProcess {
        let script = URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("gateway-peer.py")
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        let process = StreamingProcess(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                       arguments: ["-I", script.path, socketPath, "root", mode], currentDirectory: nil)
        do { try process.start() }
        catch {
            throw FixtureFailure(description: "Spawn /usr/bin/python3: \(error). \(fixtureReport(process, status: nil))")
        }
        return process
    }

    private struct FixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func fixtureReport(_ process: StreamingProcess, status: Int32?) -> String {
        let exit = status.map(String.init) ?? "unavailable"
        let stderr = process.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Fixture exit status: \(exit). Stderr: \(stderr.isEmpty ? "(empty)" : stderr)"
    }

    private static func waitForFixture(_ process: StreamingProcess) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { try await process.waitForExit() }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                process.terminate()
                throw FixtureFailure(description: "Fixture exceeded its exit deadline. \(fixtureReport(process, status: nil))")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func accept(on socket: GatewayTestSocket, role: String) throws -> Int32 {
        do { return try socket.accept() }
        catch GatewayProcessInspectionError.system(operation: "poll", code: ETIMEDOUT) {
            throw GatewayProcessInspectionError.system(operation: "wait for \(role) fixture connection", code: ETIMEDOUT)
        }
    }

    private static let fixture = #"""
from contextlib import nullcontext
import errno, socket, subprocess, sys
path, role, mode = sys.argv[1:]
if mode == "probe":
    assert callable(socket.socket)

def connect():
    try:
        sock = socket.socket(socket.AF_UNIX)
        sock.settimeout(4)
        sock.connect(path)
    except OSError as error:
        if error.errno in (errno.EPERM, errno.EACCES):
            print(f"{role}: Unix socket denied: {error}", file=sys.stderr)
            sys.exit(71 if error.errno == errno.EPERM else 73)
        raise
    return sock

if role == "leaf":
    if mode == "probe":
        sys.exit(0)
    with connect() as sock:
        sys.exit(0 if sock.recv(1) == b"\x01" else 2)

def child(next_role, timeout):
    return subprocess.run([sys.executable, "-I", sys.argv[0], path, next_role, mode], timeout=timeout).returncode

if role == "root":
    with (nullcontext() if mode == "probe" else connect()):
        sys.exit(child("middle", 7))
sys.exit(child("leaf", 5))
"""#
}

private final class GatewayTestSocket {
    let path: String
    private let fd: Int32
    private let directory: URL

    init() throws {
        var template = Array("/tmp/aitvaras-gateway.XXXXXX".utf8CString)
        guard let path = template.withUnsafeMutableBufferPointer({ buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }) else { throw Self.failure("mkdtemp") }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        self.directory = directory
        self.path = directory.appendingPathComponent("socket").path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let error = Self.failure("socket(AF_UNIX)")
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.fd = fd
        do {
            try Self.withAddress(self.path) { address, length in
                guard bind(fd, address, length) == 0 else { throw Self.failure("bind(AF_UNIX)") }
            }
            guard listen(fd, 4) == 0 else { throw Self.failure("listen(AF_UNIX)") }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        close(fd)
        try? FileManager.default.removeItem(at: directory)
    }

    func accept() throws -> Int32 {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 4_000)
        if ready == 0 { throw GatewayProcessInspectionError.system(operation: "poll", code: ETIMEDOUT) }
        guard ready > 0 else { throw Self.failure("poll") }
        let peer = Darwin.accept(fd, nil, nil)
        guard peer >= 0 else { throw Self.failure("accept(AF_UNIX)") }
        guard fcntl(peer, F_SETNOSIGPIPE, 1) != -1 else {
            let error = Self.failure("F_SETNOSIGPIPE")
            close(peer)
            throw error
        }
        return peer
    }

    func connect() throws -> Int32 {
        let peer = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard peer >= 0 else { throw Self.failure("socket(AF_UNIX)") }
        do {
            try Self.withAddress(path) { address, length in
                guard Darwin.connect(peer, address, length) == 0 else { throw Self.failure("connect(AF_UNIX)") }
            }
        } catch {
            close(peer)
            throw error
        }
        return peer
    }

    private static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func failure(_ operation: String) -> GatewayProcessInspectionError {
        .system(operation: operation, code: errno)
    }
}
