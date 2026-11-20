import Foundation
import Testing
import AitvarasCore

private actor NonCooperativeOperation {
    private var continuation: CheckedContinuation<Int, Never>?
    private var finished = false
    private(set) var started = false
    func run() async -> Int {
        if finished { return 7 }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func finish() { finished = true; continuation?.resume(returning: 7); continuation = nil }
}

@Suite(.timeLimit(.minutes(2))) struct AsyncDeadlineTests {
    @Test func successfulOperationReturnsItsValue() async throws {
        #expect(try await AsyncDeadline.run(for: .seconds(10)) { 42 } == 42)
    }

    @Test func deadlineDoesNotWaitForNonCooperativeCleanup() async {
        let operation = NonCooperativeOperation()
        let safety = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await operation.finish()
        }
        defer { safety.cancel() }
        let running = Task { await operation.run() }
        let readyBy = ContinuousClock.now + .seconds(10)
        while !(await operation.started), ContinuousClock.now < readyBy {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await operation.started)
        let start = ContinuousClock.now
        await #expect(throws: AsyncDeadline.Exceeded.self) {
            try await AsyncDeadline.run(for: .milliseconds(25)) { await running.value }
        }
        #expect(start.duration(to: .now) < .seconds(10))
        await operation.finish()
    }

    @Test func cancellationReturnsWithoutWaitingForFramework() async {
        let operation = NonCooperativeOperation()
        let task = Task { try await AsyncDeadline.run(for: .seconds(30)) { await operation.run() } }
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await operation.started), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await operation.started)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await operation.finish()
    }
}
