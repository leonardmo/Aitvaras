import Foundation
import Testing
import GRDB
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

@MainActor
@Suite struct NativeHistoryOperationCoordinatorTests {
    @Test func runningHistoryPrecedesWorkAndProgressIsReal() async throws {
        let stores = try inMemoryStores()
        let coordinator = NativeHistoryOperationCoordinator(reporter: ActivityReporter(stores: stores))
        let value = try await coordinator.run(title: "Preview native history", provider: .codex,
            dataAccess: "Native chat text", dataDestination: "Local preview") {
            let active = try stores.currentActivityRuns()
            #expect(active.count == 1)
            #expect(active.first?.id == coordinator.activeRunID)
            #expect(active.first?.state == .running)
            #expect(active.first?.trigger == .manual)
            #expect(ActivityTaskContext.runID == coordinator.activeRunID)
            coordinator.updateProgress(stage: "Reading text pages", completed: 2, total: 3)
            #expect(try stores.currentActivityRuns().first?.progressCompleted == 2)
            return 17
        }
        #expect(value == 17)
        #expect(!coordinator.isBusy)
        #expect(try stores.currentActivityRuns().isEmpty)
        #expect(try stores.activityRuns().first?.state == .succeeded)
    }

    @Test func cancellationRemainsRequestedUntilWorkerAcknowledgesAndQuitWaits() async throws {
        let stores = try inMemoryStores()
        let coordinator = NativeHistoryOperationCoordinator(reporter: ActivityReporter(stores: stores))
        let gate = NativeOperationGate()
        let caller = Task {
            try await coordinator.run(title: "Install native history SDK", provider: .claude,
                dataAccess: "Public SDK packages", dataDestination: "Private local installation") {
                await gate.wait()
                return 1
            }
        }
        while !gate.isWaiting { await Task.yield() }
        let id = try #require(coordinator.activeRunID)
        coordinator.cancelActive()
        #expect(coordinator.isBusy)
        #expect(coordinator.isCancelling)
        #expect(try stores.activityRun(id: id)?.state == .cancellationRequested)
        #expect(try stores.activityRun(id: id)?.finishedAt == nil)
        var quitFinished = false
        let quit = Task {
            await coordinator.stopBeforeTermination()
            quitFinished = true
        }
        await Task.yield()
        #expect(!quitFinished)
        gate.release()
        await quit.value
        #expect(quitFinished)
        #expect(!coordinator.isBusy)
        #expect(!coordinator.isCancelling)
        #expect(try stores.activityRun(id: id)?.state == .cancelled)
        #expect(try stores.activityRun(id: id)?.finishedAt != nil)
        do { _ = try await caller.value; Issue.record("Cancelled worker returned success") }
        catch { #expect(error is CancellationError) }

        do {
            _ = try await coordinator.run(title: "Check native history setup", provider: .codex,
                dataAccess: "Local runtime", dataDestination: "Local view") { 2 }
            Issue.record("Shutdown accepted new work")
        } catch { #expect(error is NativeHistoryOperationCoordinator.OperationError) }
        coordinator.resumeAfterCancelledTermination()
        let resumed = try await coordinator.run(title: "Check native history setup", provider: .codex,
            dataAccess: "Local runtime", dataDestination: "Local view") { 3 }
        #expect(resumed == 3)
    }

    @Test func browserDismissalDoesNotCancelSourceRefresh() async throws {
        let coordinator = NativeHistoryOperationCoordinator()
        let gate = NativeOperationGate()
        let caller = Task {
            try await coordinator.run(title: "Refresh native history", provider: .codex,
                dataAccess: "Native chat text", dataDestination: "Local saved source", kind: .sourceRefresh) {
                await gate.wait()
                return 1
            }
        }
        while !gate.isWaiting { await Task.yield() }
        coordinator.cancelBrowserOperation()
        #expect(coordinator.isBusy)
        #expect(!coordinator.isCancelling)
        gate.release()
        #expect(try await caller.value == 1)
    }

    @Test func callerCancellationReachesRetainedWorker() async throws {
        let stores = try inMemoryStores()
        let coordinator = NativeHistoryOperationCoordinator(reporter: ActivityReporter(stores: stores))
        let gate = NativeOperationGate()
        let caller = Task {
            try await coordinator.run(title: "Read native history", provider: .codex,
                dataAccess: "Native chat text", dataDestination: "Local preview") {
                await gate.wait()
            }
        }
        while !gate.isWaiting { await Task.yield() }
        caller.cancel()
        while !coordinator.isCancelling { await Task.yield() }
        #expect(coordinator.isBusy)
        gate.release()
        _ = await caller.result
        #expect(try stores.activityRuns().first?.state == .cancelled)
    }

    @Test func errorsAreRedactedAndTelemetryFailureNeverRepeatsProviderWork() async throws {
        let stores = try inMemoryStores()
        let reporter = ActivityReporter(stores: stores)
        let coordinator = NativeHistoryOperationCoordinator(reporter: reporter)
        do {
            try await coordinator.run(title: "Read native history", provider: .claude,
                dataAccess: "Native chat text", dataDestination: "Local preview") {
                throw NativeOperationPrivateError()
            }
            Issue.record("Expected provider error")
        } catch { #expect(error is NativeOperationPrivateError) }
        let failed = try #require(try stores.activityRuns().first)
        #expect(failed.state == .failed)
        #expect(failed.outcome == "Native history operation failed")
        #expect(!String(describing: failed).contains("SYNTHETIC_PRIVATE_CONTENT"))

        try await stores.db.queue.write { try $0.execute(sql: "DROP TABLE activityRun") }
        var calls = 0
        let value = try await coordinator.run(title: "Read native history", provider: .claude,
            dataAccess: "Native chat text", dataDestination: "Local preview") {
            calls += 1
            return 9
        }
        #expect(calls == 1)
        #expect(value == 9)
        #expect(reporter.failureMessage != nil)
        #expect(!coordinator.isBusy)
    }
}

@MainActor
private final class NativeOperationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct NativeOperationPrivateError: LocalizedError {
    var errorDescription: String? { "SYNTHETIC_PRIVATE_CONTENT /private/example native transcript" }
}
