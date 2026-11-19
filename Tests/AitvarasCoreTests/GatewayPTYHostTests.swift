import Darwin
import Foundation
import XCTest
@testable import AitvarasAgents

final class GatewayPTYHostTests: XCTestCase {
    @MainActor
    func testInputResizeAndInterruptReachFinitePTYChild() async throws {
        var master: Int32 = -1, slave: Int32 = -1
        var window = winsize(ws_row: 23, ws_col: 70, ws_xpixel: 0, ws_ypixel: 0)
        if openpty(&master, &slave, nil, nil, &window) < 0 {
            let code = errno
            if code == EPERM || code == EACCES || code == ENXIO {
                throw XCTSkip("PTY allocation unavailable: openpty, errno \(code). Repeat on the host.")
            }
            throw GatewayTransportError.system("openpty", code)
        }
        defer { close(master); close(slave) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        let tty = slave
        let before = try settings(tty)
        let child = Task.detached {
            try GatewayPTY.run(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-I", "-c", Self.fixture], environment: ProcessInfo.processInfo.environment,
                interactive: true, input: tty, output: tty, testTimeoutMS: 10_000)
        }
        do {
            try read(master, contains: "READY:70", seconds: 2)
            try write(master, Array("fixture input\n".utf8))
            try read(master, contains: "INPUT:fixture input", seconds: 2)
            window.ws_col = 96
            guard ioctl(slave, TIOCSWINSZ, &window) == 0 else { throw GatewayTransportError.system("PTY resize", errno) }
            guard kill(getpid(), SIGWINCH) == 0 else { throw GatewayTransportError.system("send SIGWINCH", errno) }
            try read(master, contains: "RESIZED:96", seconds: 2)
            try write(master, [3]) // Ctrl-C through the child's controlling terminal.
            let status = try await child.value
            XCTAssertEqual(status, 42)
            let after = try settings(tty)
            // Darwin sets PENDIN/FLUSHO as transient line-discipline state.
            let persistent = ~tcflag_t(PENDIN | FLUSHO)
            XCTAssertEqual(before.c_lflag & persistent, after.c_lflag & persistent)
            XCTAssertEqual(before.c_iflag, after.c_iflag)
            XCTAssertEqual(before.c_oflag, after.c_oflag)
            XCTAssertEqual(before.c_cflag, after.c_cflag)
        } catch {
            let fixtureError = error
            let status: Int32
            do { status = try await child.value }
            catch GatewayTransportError.system(let operation, let code) where code == EPERM || code == EACCES || code == ENXIO {
                throw XCTSkip("PTY supervisor unavailable: \(operation), errno \(code). Repeat on the host.")
            } catch {
                XCTFail("PTY fixture failed: \(fixtureError). Supervisor error: \(error).")
                return
            }
            XCTFail("PTY fixture failed: \(fixtureError). Child exit status: \(status).")
        }
    }

    private func settings(_ fd: Int32) throws -> termios {
        var value = termios()
        guard tcgetattr(fd, &value) == 0 else { throw GatewayTransportError.system("inspect terminal", errno) }
        return value
    }

    private func read(_ master: Int32, contains message: String, seconds: Int64) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        var received = Data()
        while !String(decoding: received, as: UTF8.self).contains(message) {
            var fd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let wait: Int32
            do { wait = try gatewayPollTimeout(deadline) }
            catch {
                let output = String(decoding: received, as: UTF8.self)
                throw FixtureReadTimeout(expected: message, output: output)
            }
            let ready = poll(&fd, 1, wait)
            if ready <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 1_024)
            let size = Darwin.read(master, &bytes, bytes.count)
            guard size > 0 else { throw GatewayTransportError.system("read fixture PTY", errno) }
            received.append(contentsOf: bytes.prefix(size))
            guard received.count < 8_192 else { throw GatewayTransportError.invalidFrame }
        }
    }

    private struct FixtureReadTimeout: Error, CustomStringConvertible {
        let expected: String
        let output: String
        var description: String { "Expected \(expected) from the fixture. Received: \(output)" }
    }

    private func write(_ master: Int32, _ bytes: [UInt8]) throws {
        let count = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw GatewayTransportError.system("write fixture PTY", errno) }
    }

    private static let fixture = #"""
import os, signal, sys
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
signal.alarm(7)
signal.signal(signal.SIGWINCH, lambda *_: print("RESIZED:" + str(os.get_terminal_size().columns), flush=True))
signal.signal(signal.SIGINT, lambda *_: sys.exit(42))
assert os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp()
print("READY:" + str(os.get_terminal_size().columns), flush=True)
print("INPUT:" + sys.stdin.readline().strip(), flush=True)
signal.pause()
signal.pause()
sys.exit(9)
"""#
}
