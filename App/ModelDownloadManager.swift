import Foundation
import Observation
import AitvarasCore
import AitvarasStore

/// App-lifetime state for one resumable model download. Keeping the task out
/// of the Setup view means navigation changes cannot orphan a child process.
@MainActor
@Observable
final class ModelDownloadManager {
    var reporter: ActivityReporter?
    private(set) var activeModelID: String?
    private(set) var isCancelling = false
    private(set) var status: [String: String] = [:]
    private(set) var completionRevision = 0

    private var operationID: UUID?
    private var task: Task<Void, Never>?

    func start(
        repository: String, revision: String, modelID: String, expectedBytes: Int64
    ) {
        guard task == nil else { return }
        let operation = UUID()
        operationID = operation
        reporter?.begin(ActivityRun(id: operation, referenceID: modelID, category: .model,
            title: "Download local model", stage: "Preparing download",
            executionLocation: "This Mac", dataAccess: "Public model files",
            dataDestination: "Model download host; no conversation content"))
        activeModelID = modelID
        status[modelID] = "Finding a local Python runtime…"
        let destination = AitvarasPaths.modelsDirectory
            .appendingPathComponent(modelID, isDirectory: true)

        task = Task { [weak self] in
            do {
                try await ModelDownloader.download(
                    repository: repository,
                    revision: revision,
                    to: destination,
                    expectedBytes: expectedBytes,
                    onStage: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            self?.set(stage: stage, for: modelID, operation: operation)
                        }
                    })
                guard let self, self.operationID == operation else { return }
                status[modelID] = nil
                completionRevision += 1
                finish(operation: operation, state: .succeeded)
            } catch is CancellationError {
                guard let self, self.operationID == operation else { return }
                status[modelID] = "Paused — Retry continues from saved files"
                finish(operation: operation, state: .cancelled)
            } catch {
                guard let self, self.operationID == operation else { return }
                status[modelID] = "Failed: \(error.localizedDescription)"
                finish(operation: operation, state: .failed)
            }
        }
    }

    func cancelActive() {
        guard let modelID = activeModelID else { return }
        isCancelling = true
        if let operationID { reporter?.update(id: operationID, stage: "Pausing download safely", state: .cancellationRequested) }
        status[modelID] = "Pausing safely…"
        task?.cancel()
    }

    /// App termination waits for the bounded process runner to kill and reap
    /// its child, preventing a multi-gigabyte download from becoming orphaned.
    func stopBeforeTermination() async {
        guard let running = task else { return }
        cancelActive()
        await running.value
    }

    private func set(stage: ModelDownloader.Stage, for modelID: String, operation: UUID) {
        guard operationID == operation else { return }
        switch stage {
        case .locatingPython:
            status[modelID] = "Finding a local Python runtime…"
        case .preparingDownloader:
            status[modelID] = "Preparing a small private downloader…"
        case .checkingDiskSpace:
            status[modelID] = "Checking free space…"
        case .downloading:
            status[modelID] = "Downloading… Pausing and retrying is safe"
        case .verifying:
            status[modelID] = "Verifying downloaded weights…"
        }
        reporter?.update(id: operation, stage: status[modelID])
    }

    private func finish(operation: UUID, state: ActivityRunState) {
        guard operationID == operation else { return }
        reporter?.finish(id: operation, state: state,
            outcome: state == .succeeded ? "Model files verified" : state == .cancelled ? "Paused; downloaded files retained" : "Download failed; retry is available in Settings")
        operationID = nil
        task = nil
        activeModelID = nil
        isCancelling = false
    }
}
