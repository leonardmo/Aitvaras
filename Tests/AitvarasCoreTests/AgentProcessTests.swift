import Darwin
import Foundation
import Testing
@testable import AitvarasAgents

struct AgentProcessTests {
    @Test func framesSplitUTF8AndTrailingLine() async throws {
        let fixture = try AgentExecutableFixture("printf '\\303'; /bin/sleep 0.03; printf '\\244\\n\\nlast'")
        defer { fixture.remove() }
        let process = fixture.process()
        try process.start()
        var lines: [String] = []
        for try await line in process.lines { lines.append(line) }
        #expect(try await process.waitForExit() == 0)
        #expect(lines == ["ä", "last"])
    }

    @Test func oneShotPreservesEmptyLinesAndExitStatus() async throws {
        let fixture = try AgentExecutableFixture("printf 'one\\n\\nthree\\n'; printf diagnostic >&2; exit 7")
        defer { fixture.remove() }
        let output = try await fixture.run()
        #expect(output.stdout == "one\n\nthree")
        #expect(output.stderr == "diagnostic")
        #expect(output.exitCode == 7)
        #expect(!output.timedOut)
    }

    @Test func timeoutDoesNotWaitForUncancellableExitContinuation() async throws {
        let fixture = try AgentExecutableFixture("trap '' TERM; while :; do /bin/sleep 1; done")
        defer { fixture.remove() }
        let start = ContinuousClock.now
        let output = try await fixture.run(timeout: .milliseconds(100))
        #expect(output.timedOut)
        #expect(output.exitCode != 0)
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test func shutdownKillsTermIgnoringChildrenAndInheritedPipes() async throws {
        let fixture = try AgentExecutableFixture("""
        trap '' TERM
        /bin/sh -c 'trap "" TERM; echo $$ > child.pid; printf "ready\\n"; while :; do /bin/sleep 1; done' &
        wait
        """)
        defer { fixture.remove() }
        let process = fixture.process()
        defer { process.terminate() }
        try process.start()
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")
        let child = try fixture.childPID()
        try await process.shutdown(grace: .milliseconds(30))
        #expect(!process.isRunning)
        #expect(await gone(child))
    }

    @Test func serverGroupGetsTwoSecondsBeforeKillEvenWhenWrapperExits() async throws {
        let fixture = try AgentExecutableFixture("""
        /bin/sh -c 'trap "" TERM; echo $$ > child.pid; printf "ready\\n"; while :; do /bin/sleep 1; done' &
        wait
        """)
        defer { fixture.remove() }
        let process = StreamingProcess(executable: fixture.executable, arguments: [], currentDirectory: fixture.directory,
            environment: fixture.environment, terminationDelay: .seconds(2))
        defer { process.terminate() }
        try process.start()
        #expect(getpgid(process.processIdentifier) == process.processIdentifier)
        #expect(getpgid(process.processIdentifier) != getpgrp())
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")
        let child = try fixture.childPID()
        let started = ContinuousClock.now
        try await process.shutdown(grace: .zero)
        #expect(started.duration(to: .now) >= .seconds(2))
        #expect(started.duration(to: .now) < .seconds(4))
        #expect(!process.isRunning)
        #expect(await gone(child))
    }

    @Test func parentExitCleansUpGrandchildHoldingPipes() async throws {
        let fixture = try AgentExecutableFixture("""
        /bin/sh -c 'trap "" TERM; echo $$ > child.pid; printf "ready\\n"; while :; do /bin/sleep 1; done' &
        while test ! -f child.pid; do /bin/sleep 0.01; done
        exit 0
        """)
        defer { fixture.remove() }
        let output = try await fixture.run()
        #expect(output.exitCode == 0)
        #expect(!output.timedOut)
        #expect(output.stdout == "ready")
        #expect(await gone(try fixture.childPID()))
    }

    @Test func lineSizeAndInvalidUTF8FailObservably() async throws {
        for (body, expected) in [
            ("/usr/bin/head -c \(StreamingProcess.maximumLineBytes + 1) /dev/zero", AgentProcessError.outputLimit),
            ("printf '\\377\\n'", AgentProcessError.invalidUTF8)
        ] {
            let fixture = try AgentExecutableFixture(body)
            defer { fixture.remove() }
            await #expect(throws: expected) { _ = try await fixture.run() }
        }
    }

    @Test func slowConsumerOverflowFailsInsteadOfDroppingFrames() async throws {
        let fixture = try AgentExecutableFixture("i=0; while test $i -lt 200; do echo frame; i=$((i+1)); done")
        defer { fixture.remove() }
        let process = fixture.process()
        try process.start()
        _ = try await process.waitForExit() // Deliberately do not consume until exit.
        var received = 0
        await #expect(throws: AgentProcessError.outputLimit) {
            for try await _ in process.lines { received += 1 }
        }
        #expect(received <= StreamingProcess.maximumQueuedLines)
    }

    @Test func stderrTailIsBounded() async throws {
        let fixture = try AgentExecutableFixture("/usr/bin/head -c 65536 /dev/zero >&2; printf tail >&2")
        defer { fixture.remove() }
        let output = try await fixture.run()
        #expect(output.stderr.utf8.count == StreamingProcess.stderrLimit)
        #expect(output.stderr.hasSuffix("tail"))
    }

    @Test func concurrentWritesArriveAsWholeFrames() async throws {
        let fixture = try AgentExecutableFixture("while IFS= read -r line; do printf '%s\\n' \"$line\"; done")
        defer { fixture.remove() }
        let process = fixture.process()
        defer { process.terminate() }
        try process.start()
        let collector = Task { () throws -> [String] in
            var values: [String] = []
            for try await line in process.lines { values.append(line) }
            return values
        }
        let payloads = (0..<12).map { "\($0):" + String(repeating: "x", count: 32_768) }
        // Each writer is concurrent; the transport promises atomic frames, not
        // scheduler ordering between independent Tasks.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for payload in payloads { group.addTask { try await process.write(line: payload) } }
            try await group.waitForAll()
        }
        process.closeInput()
        let lines = try await collector.value
        #expect(Set(lines) == Set(payloads))
        #expect(lines.count == payloads.count)
        #expect(try await process.waitForExit() == 0)
    }

    @Test func writesAfterChildClosesInputFail() async throws {
        let fixture = try AgentExecutableFixture("exec 0<&-; printf 'ready\\n'; /bin/sleep 30")
        defer { fixture.remove() }
        let process = fixture.process()
        defer { process.terminate() }
        try process.start()
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")
        await #expect(throws: AgentProcessError.writeFailed) { try await process.write(line: "message") }
        try await process.shutdown(grace: .zero)
        await #expect(throws: AgentProcessError.closed) { try await process.write(line: "late") }
    }

    @Test func blockedStdinAndPendingQueueAreBoundedAndCancellable() async throws {
        let fixture = try AgentExecutableFixture("printf 'ready\\n'; exec /bin/sleep 30")
        defer { fixture.remove() }
        let process = fixture.process()
        defer { process.terminate() }
        try process.start()
        var iterator = process.lines.makeAsyncIterator()
        #expect(try await iterator.next() == "ready")
        let payload = String(repeating: "x", count: 900_000)
        let writers = (0..<8).map { _ in Task { () -> AgentProcessError? in
            do { try await process.write(line: payload); return nil }
            catch { return error as? AgentProcessError }
        } }
        // The child never reads; two frames fill the pending-byte budget and
        // later submissions fail without allocating an unbounded transport queue.
        try await Task.sleep(for: .milliseconds(100))
        try await process.shutdown(grace: .zero)
        var errors: [AgentProcessError] = []
        for writer in writers { if let error = await writer.value { errors.append(error) } }
        #expect(errors.contains(.inputLimit))
        #expect(errors.count == writers.count)
    }

    @Test func waitAndOneShotCancellationCleanUp() async throws {
        let fixture = try AgentExecutableFixture("echo $$ > child.pid; exec /bin/sleep 30")
        defer { fixture.remove() }
        let run = Task { try await fixture.run() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try fixture.childPID()
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(await gone(pid))
    }

    @Test func launchFailureAndNotStartedWaitAreFinite() async throws {
        let fixture = try AgentExecutableFixture("exit 0")
        defer { fixture.remove() }
        let process = StreamingProcess(executable: fixture.directory.appendingPathComponent("missing"),
            arguments: [], currentDirectory: fixture.directory, environment: fixture.environment)
        await #expect(throws: AgentProcessError.notStarted) { _ = try await process.waitForExit() }
        #expect(throws: AgentProcessError.launchFailed) { try process.start() }
        await #expect(throws: AgentProcessError.launchFailed) { _ = try await process.waitForExit() }
        #expect(throws: AgentProcessError.alreadyStarted) { try process.start() }
    }

    @Test func oneShotCollectionHasATotalBoundEvenWithSmallFrames() async throws {
        let fixture = try AgentExecutableFixture("/usr/bin/awk 'BEGIN { s=sprintf(\"%016384d\",0); for(i=0;i<600;i++) print s }'")
        defer { fixture.remove() }
        await #expect(throws: AgentProcessError.outputLimit) { _ = try await fixture.run() }
    }

    @Test func cancellingAnExitWaiterDoesNotHangOrStopItsProcess() async throws {
        let fixture = try AgentExecutableFixture("exec /bin/sleep 30")
        defer { fixture.remove() }
        let process = fixture.process()
        try process.start()
        let waiter = Task { try await process.waitForExit() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        #expect(process.isRunning)
        try await process.shutdown(grace: .zero)
    }

    @Test func oversizedAndMultilineWritesAreRejectedBeforeDelivery() async throws {
        let fixture = try AgentExecutableFixture("exec /bin/sleep 30")
        defer { fixture.remove() }
        let process = fixture.process()
        try process.start()
        await #expect(throws: AgentProcessError.inputLimit) {
            try await process.write(line: String(repeating: "x", count: StreamingProcess.maximumLineBytes))
        }
        await #expect(throws: AgentProcessError.writeFailed) { try await process.write(line: "one\ntwo") }
        try await process.shutdown(grace: .zero)
    }

    private func gone(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// Generated executables and an explicit synthetic environment; never a live CLI.
struct AgentExecutableFixture: Sendable {
    let directory: URL
    let executable: URL
    var environment: [String: String] {
        ["HOME": directory.path, "PATH": "/usr/bin:/bin", "USER": "example-user", "LANG": "C"]
    }
    init(_ body: String, name: String = "fake agent") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func process() -> StreamingProcess {
        StreamingProcess(executable: executable, arguments: [], currentDirectory: directory, environment: environment)
    }
    func run(timeout: Duration = .seconds(3)) async throws -> OneShotProcess.Output {
        try await OneShotProcess.run(executable: executable, arguments: [], currentDirectory: directory,
            environment: environment, timeout: timeout)
    }
    func childPID() throws -> Int32 {
        let text = try String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
        return try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
