import Foundation
import Testing
import AitvarasCore

private actor NonCooperativeOperation {
    private var continuation: CheckedContinuation<Int, Never>?
    private(set) var started = false
    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func finish() { continuation?.resume(returning: 7); continuation = nil }
}

@Suite struct AsyncDeadlineTests {
    @Test func successfulOperationReturnsItsValue() async throws {
        #expect(try await AsyncDeadline.run(for: .seconds(1)) { 42 } == 42)
    }

    @Test func deadlineDoesNotWaitForNonCooperativeCleanup() async {
        let operation = NonCooperativeOperation()
        let start = ContinuousClock.now
        await #expect(throws: AsyncDeadline.Exceeded.self) {
            try await AsyncDeadline.run(for: .milliseconds(25)) { await operation.run() }
        }
        #expect(start.duration(to: .now) < .seconds(1))
        await operation.finish()
    }

    @Test func cancellationReturnsWithoutWaitingForFramework() async {
        let operation = NonCooperativeOperation()
        let task = Task { try await AsyncDeadline.run(for: .seconds(30)) { await operation.run() } }
        while !(await operation.started) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await operation.finish()
    }
}
