import Foundation
import Observation
import AitvarasCore
import AitvarasStore
import AitvarasVoice

/// App-lifetime owner: navigating away cannot orphan work or release an audio
/// lease. Callers must prevent competing local chat/voice/summary workloads.
@MainActor @Observable
final class CaptureRefinementManager {
    var reporter: ActivityReporter?
    private(set) var isProcessing = false
    private(set) var isCancelling = false
    private(set) var activeArchiveID: UUID?
    private(set) var lastArchiveID: UUID?
    private(set) var progress: CaptureRefinementProgress?
    private(set) var status: String?
    private(set) var candidate: CaptureRefinementCandidate?
    private(set) var savedCandidates: [CaptureRefinementCandidate] = []
    private(set) var candidateURL: URL?
    private var selectedProfileDirectory = AitvarasPaths.stateDirectory
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var selectionRevision = 0
    private let retranscriber = LocalRetranscriber()

    func start(archiveID: UUID, model: CaptureRefinementModel, language: CaptureLanguage,
               profileDirectory: URL = AitvarasPaths.stateDirectory) {
        guard task == nil else { return }
        guard model.isInstalled() else { status = "Download the selected speech model first."; return }
        selectionRevision += 1
        lastArchiveID = archiveID
        selectedProfileDirectory = profileDirectory
        if candidate?.archiveID != archiveID { candidate = nil; candidateURL = nil; savedCandidates = [] }
        if candidate?.archiveID != archiveID { candidate = nil; candidateURL = nil }
        let operation = UUID()
        operationID = operation; activeArchiveID = archiveID
        isProcessing = true; isCancelling = false; progress = nil
        status = "Loading local speech model…"
        reporter?.begin(ActivityRun(id: operation, referenceID: archiveID.uuidString, category: .capture,
            title: "Local second-pass transcription", stage: "Loading speech model",
            provider: model.displayName, executionLocation: "This Mac",
            dataAccess: "User-retained audio recording", dataDestination: "Separate local transcript candidate; no network"))
        let audioStore = CaptureAudioArchiveStore(profileDirectory: profileDirectory)
        let outputStore = CaptureRefinementStore(profileDirectory: profileDirectory)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await retranscriber.transcribe(archiveID: archiveID, store: audioStore,
                    model: model, language: language, onProgress: { [weak self] update in
                        Task { @MainActor [weak self] in
                            guard let self, operationID == operation, !isCancelling else { return }
                            progress = update
                            status = "Transcribing locally… \(Int(update.fraction * 100))%"
                            reporter?.update(id: operation, stage: "Recognizing saved audio in bounded windows",
                                progressCompleted: Int(update.completedAudioSeconds), progressTotal: max(1, Int(update.totalAudioSeconds)))
                        }
                    })
                try Task.checkCancellation()
                // Saving remains off the main actor and never touches the live
                // capture record. No transcript content enters activity logs.
                let url = try await Task.detached { try outputStore.save(output) }.value
                candidate = output; candidateURL = url
                savedCandidates.insert(output, at: 0)
                status = "Second-pass candidate saved. Original transcript unchanged."
                finish(operation, state: .succeeded, outcome: "Separate local candidate saved; coarse audio-window timestamps")
            } catch is CancellationError {
                status = "Cancelled. Original transcript unchanged."
                finish(operation, state: .cancelled, outcome: "Native recognition stopped; original transcript unchanged")
            } catch {
                status = (error as? LocalRetranscriber.Failure)?.localizedDescription
                    ?? "The second-pass transcript could not be saved. Original transcript unchanged."
                finish(operation, state: .failed, outcome: "Local retranscription failed; original transcript unchanged")
            }
        }
    }

    func cancelActive() {
        guard task != nil else { return }
        isCancelling = true
        status = "Stopping after the current audio window…"
        if let operationID { reporter?.update(id: operationID, stage: "Waiting for native recognition to acknowledge cancellation", state: .cancellationRequested) }
        task?.cancel()
    }

    func stopBeforeTermination() async {
        guard let pending = task else { return }
        cancelActive()
        await pending.value
    }

    func loadSaved(archiveID: UUID, profileDirectory: URL = AitvarasPaths.stateDirectory) async {
        guard !isProcessing else { return }
        selectionRevision += 1
        let request = selectionRevision
        if lastArchiveID != archiveID { status = nil; candidate = nil; candidateURL = nil; savedCandidates = [] }
        lastArchiveID = archiveID
        selectedProfileDirectory = profileDirectory
        let store = CaptureRefinementStore(profileDirectory: profileDirectory)
        let versions = await Task.detached { (try? store.list(archiveID: archiveID)) ?? [] }.value
        guard !isProcessing, selectionRevision == request, lastArchiveID == archiveID else { return }
        savedCandidates = versions
        let selected = candidate.flatMap { previous in versions.first { $0.id == previous.id } } ?? versions.first
        candidate = selected; candidateURL = selected.map { store.url(for: $0.id) }
    }

    func selectSavedCandidate(_ id: UUID) {
        guard let selected = savedCandidates.first(where: { $0.id == id && $0.archiveID == lastArchiveID }) else { return }
        candidate = selected
        candidateURL = CaptureRefinementStore(profileDirectory: selectedProfileDirectory).url(for: id)
    }

    func deleteSaved(archiveID: UUID, profileDirectory: URL = AitvarasPaths.stateDirectory) async throws {
        guard !(isProcessing && activeArchiveID == archiveID) else { throw LocalRetranscriber.Failure.busy }
        selectionRevision += 1
        let request = selectionRevision
        let store = CaptureRefinementStore(profileDirectory: profileDirectory)
        do {
            try await Task.detached { try store.delete(archiveID: archiveID) }.value
            guard selectionRevision == request else { return }
            if candidate?.archiveID == archiveID { candidate = nil; candidateURL = nil }
            savedCandidates.removeAll { $0.archiveID == archiveID }
            if lastArchiveID == archiveID { status = "Saved second-pass candidates deleted. Original transcript unchanged." }
        } catch {
            if selectionRevision == request, lastArchiveID == archiveID { status = "Saved candidates could not be deleted safely." }
            throw error
        }
    }

    private func finish(_ operation: UUID, state: ActivityRunState, outcome: String) {
        guard operationID == operation else { return }
        reporter?.finish(id: operation, state: state, outcome: outcome)
        isProcessing = false; isCancelling = false; activeArchiveID = nil
        task = nil; operationID = nil
    }
}
