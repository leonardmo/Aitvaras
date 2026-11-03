import Foundation
import Testing
@testable import AitvarasCore

@Suite struct DisclaimedProcessTests {
    @Test func capturesBothOutputStreamsWithoutLeakingToParentConsole() async throws {
        let output = try await DisclaimedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf standard; printf diagnostic >&2"],
            timeout: 1)

        #expect(output.exitCode == 0)
        #expect(output.stdout.contains("standard"))
        #expect(output.stdout.contains("diagnostic"))
    }

    @Test func addsScopedEnvironmentWithoutDroppingTheParentPath() async throws {
        let output = try await DisclaimedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s|%s' \"$AITVARAS_HELPER_TEST\" \"$PATH\""],
            timeout: 1,
            environment: ["AITVARAS_HELPER_TEST": "isolated"])

        #expect(output.exitCode == 0)
        #expect(output.stdout.hasPrefix("isolated|"))
        #expect(output.stdout.count > "isolated|".count)
    }

    @Test func canRunWithAnExplicitMinimalEnvironment() async throws {
        let output = try await DisclaimedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s|%s' \"${HOME-unset}\" \"$ONLY_THIS\""],
            timeout: 1,
            environment: ["ONLY_THIS": "present"],
            inheritEnvironment: false)

        #expect(output.exitCode == 0)
        #expect(output.stdout == "unset|present")
    }

    @Test func silentHelperActuallyTimesOut() async {
        let start = Date.now

        do {
            _ = try await DisclaimedProcess.run(
                executable: "/bin/sleep", arguments: ["60"], timeout: 0.05)
            Issue.record("Expected helper timeout")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.code == Int(ETIMEDOUT))
        }

        // The 60-second helper must be killed promptly, but allow scheduler
        // overhead from ASan/TSan and the rest of the parallel test suite.
        #expect(Date.now.timeIntervalSince(start) < 1.0)
    }

    @Test func cancellationKillsAndReapsHelperPromptly() async {
        let task = Task {
            try await DisclaimedProcess.run(
                executable: "/bin/sleep", arguments: ["60"], timeout: 60)
        }
        try? await Task.sleep(for: .milliseconds(20))
        let start = Date.now
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(Date.now.timeIntervalSince(start) < 1.0)
    }
}
