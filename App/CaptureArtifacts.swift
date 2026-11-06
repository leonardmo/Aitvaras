import Foundation
import AitvarasCore

extension AppModel {
    /// Avoid running a memory-heavy recognizer beside another local AI job.
    /// New chat/voice/capture and automatic entry points also check the reservation.
    var canStartCaptureRefinement: Bool {
        guard !captureRefinement.isProcessing, !isResponding, !localAgentReplyActive, !microphoneInUseByVoice,
              !captureActive, modelDownloads.activeModelID == nil else { return false }
        let competing: Set<ActivityCategory> = [.chat, .voice, .capture, .memory, .automation, .cloud, .knowledge, .model]
        return !currentActivityRuns.contains { [.running, .cancellationRequested].contains($0.state) && competing.contains($0.category) }
    }

    /// Retention is a prior explicit user choice, not permission to run inference.
    /// No audio file is decoded and no model is loaded during this maintenance.
    func prepareCaptureAudioArchives() async {
        let id = activityReporter?.begin(ActivityRun(category: .startup,
            title: "Check retained capture audio", stage: "Applying chosen retention and finding interrupted recordings",
            executionLocation: "This Mac", dataAccess: "App-owned audio metadata", dataDestination: "This Mac only"))
        let store = captureAudioArchives
        do {
            let counts = try await Task.detached { () throws -> (Int, Int) in
                let expired = try store.deleteExpired().count
                let interrupted = try store.list().filter(\.isInterrupted).count
                return (expired, interrupted)
            }.value
            if let id { activityReporter?.finish(id: id, state: .succeeded,
                outcome: "Retention checked; \(counts.0) expired recordings removed; \(counts.1) interrupted archives preserved") }
        } catch {
            if let id { activityReporter?.finish(id: id, state: .failed,
                outcome: "Audio retention could not be checked; existing recordings left for review") }
        }
    }

    func deleteCaptureAndArtifacts(_ id: UUID) async throws {
        guard capture?.canDeleteRecord(id) != false,
              !(captureRefinement.isProcessing && captureRefinement.activeArchiveID == id) else {
            throw CaptureError("Stop capture or second-pass processing before deleting this record.")
        }
        let operation = activityReporter?.begin(ActivityRun(referenceID: id.uuidString, category: .capture,
            title: "Delete saved capture", stage: "Removing app-owned audio, candidates and text",
            executionLocation: "This Mac", dataAccess: "Selected saved capture", dataDestination: "Local deletion only"))
        do {
            let store = captureAudioArchives
            try await Task.detached {
                if FileManager.default.fileExists(atPath: store.directory(for: id).path) { try store.delete(id) }
            }.value
            try await captureRefinement.deleteSaved(archiveID: id)
            try stores?.deleteCaptureRecord(id)
            if let operation { activityReporter?.finish(id: operation, state: .succeeded, outcome: "Selected capture and its app-owned artifacts removed; exported copies unchanged") }
            NotificationCenter.default.post(name: .aitvarasCaptureAudioChanged, object: nil)
        } catch {
            if let operation { activityReporter?.finish(id: operation, state: .failed, outcome: "Deletion did not finish; inspect remaining capture artifacts before retrying") }
            throw error
        }
    }
}
