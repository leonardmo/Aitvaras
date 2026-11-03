import Foundation
import Observation
import AitvarasCore
import AitvarasStore

/// Owns manually requested native-history work until the worker acknowledges
/// completion. All display strings supplied here must be metadata-only: never
/// pass a chat title, folder, transcript, provider diagnostic, or external ID.
@MainActor
@Observable
public final class NativeHistoryOperationCoordinator {
    public enum Kind: Sendable { case browser, sourceRefresh }
    public enum OperationError: Error { case busy, stopped }

    public var reporter: ActivityReporter?
    public private(set) var activeRunID: UUID?
    public private(set) var activeKind: Kind?
    public private(set) var isCancelling = false
    public var isBusy: Bool { activeRunID != nil }

    @ObservationIgnored private var cancelWorker: (() -> Void)?
    @ObservationIgnored private var waitForWorker: (() async -> Void)?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var activeReporter: ActivityReporter?

    public init(reporter: ActivityReporter? = nil) { self.reporter = reporter }

    public func run<T: Sendable>(title: String, provider: NativeSessionProvider,
        referenceID: String? = nil, dataAccess: String, dataDestination: String,
        kind: Kind = .browser,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        guard !stopped else { throw OperationError.stopped }
        guard !isBusy else { throw OperationError.busy }
        try Task.checkCancellation()
        let id = UUID()
        // Capture the reporter for this entire run, including shutdown.
        let reporter = reporter
        activeReporter = reporter
        activeRunID = id
        activeKind = kind
        isCancelling = false
        reporter?.begin(ActivityRun(id: id, referenceID: referenceID,
            category: .connection, trigger: .manual, title: title,
            stage: "Starting", provider: provider.displayName,
            executionLocation: "This Mac", dataAccess: dataAccess,
            dataDestination: dataDestination))

        let worker = Task { @MainActor in
            defer {
                self.activeRunID = nil
                self.activeKind = nil
                self.isCancelling = false
                self.cancelWorker = nil
                self.waitForWorker = nil
                self.activeReporter = nil
            }
            do {
                let value = try await ActivityTaskContext.$runID.withValue(id) {
                    try await ActivityTaskContext.$trigger.withValue(.manual) {
                        try Task.checkCancellation()
                        return try await operation()
                    }
                }
                try Task.checkCancellation()
                reporter?.finish(id: id, state: .succeeded, outcome: "Native history operation completed")
                return value
            } catch {
                if error is CancellationError || Task.isCancelled {
                    reporter?.finish(id: id, state: .cancelled, outcome: "Native history operation cancelled")
                    throw CancellationError()
                }
                // Provider errors can contain paths or native text. Never log them.
                reporter?.finish(id: id, state: .failed, outcome: "Native history operation failed")
                throw error
            }
        }
        cancelWorker = { worker.cancel() }
        waitForWorker = { _ = await worker.result }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(runID: id) }
        }
    }

    /// Report completed work, not fabricated percentages. Callers supply only
    /// generic stages (for example, "Reading text pages") and counts.
    public func updateProgress(stage: String, completed: Int? = nil, total: Int? = nil) {
        guard let id = activeRunID, !isCancelling else { return }
        activeReporter?.update(id: id, stage: stage, progressCompleted: completed, progressTotal: total)
    }

    public func cancelActive() {
        guard let id = activeRunID else { return }
        cancel(runID: id)
    }

    public func cancelBrowserOperation() {
        guard activeKind == .browser else { return }
        cancelActive()
    }

    private func cancel(runID: UUID) {
        guard activeRunID == runID, !isCancelling else { return }
        isCancelling = true
        activeReporter?.update(id: runID, stage: "Cancellation requested", state: .cancellationRequested)
        cancelWorker?()
    }

    /// Do not terminate the application or discard this owner before awaiting
    /// this method: subprocess cancellation and final reporting must settle.
    public func stopBeforeTermination() async {
        stopped = true
        let wait = waitForWorker
        cancelActive()
        await wait?()
    }

    /// A later quit-stage (for example saving a capture) may refuse to quit.
    /// Resuming enables only future explicit actions; cancelled work is not replayed.
    public func resumeAfterCancelledTermination() { stopped = false }
}
