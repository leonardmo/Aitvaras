import AppKit
import AVFoundation
@preconcurrency import ScreenCaptureKit
import Vision
import AitvarasCore
import AitvarasStore
import AitvarasAgent
import AitvarasVoice
import Synchronization

/// Runs one capture session (F12): ScreenCaptureKit for window/display
/// frames and system audio, a second `TranscriberSession` for that audio,
/// optionally the mic as the user's own channel, and throttled Vision OCR
/// for on-screen text. Frames are discarded after OCR. Audio is discarded by
/// default; an explicit capture setting enables a separate local audio archive.
@MainActor
@Observable
final class CaptureController: NSObject {
    enum ScreenScope: Equatable {
        case window(SCWindow)
        case display(SCDisplay)
        case none

        var label: String {
            switch self {
            case .window(let window):
                "Fenster: \(window.owningApplication?.applicationName ?? window.title ?? "?")"
            case .display: "Ganzer Bildschirm"
            case .none: "Nur Audio"
            }
        }
    }

    typealias AudioMode = CaptureAudioMode

    struct Config {
        var scope: ScreenScope
        var audio: AudioMode
        var title: String
        var consentConfirmed: Bool
        /// Local association only. Never a request to post to a chat or export.
        var targetChatID: UUID? = nil

        var isValid: Bool {
            !(scope == .none && audio == .none) && consentConfirmed
        }
    }

    // Observable session state (companion chip + status tool).
    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var sleepProtectionStatus: CaptureSleepProtectionStatus = .inactive
    var sleepProtectionSummary: String { sleepProtectionStatus.summary }
    private var sleepProtectionLease: CaptureSleepProtectionLease?
    private var sleepAssertionDriver: any CaptureSleepAssertionDriving
    private var startupCancelled = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set only by the isolated diagnostic below; never opens capture inputs.
    private var diagnosticInputStartup: (() async throws -> Void)?
    private(set) var startedAt: Date?
    private(set) var scopeLabel = ""
    private(set) var lineCount = 0
    /// Set when a session just finished — the UI shows the result sheet.
    var finishedRecord: CaptureRecord?
    /// A stopped transcript whose first durable write failed. Keeping it here
    /// lets the same stop control retry instead of silently discarding it.
    private var pendingFinish: PendingFinish?
    private(set) var isFinishing = false
    private var activityID: UUID?
    var activityRunID: UUID? { activityID }
    var canFinish: Bool { isActive || isStarting || pendingFinish != nil }
    var microphoneInUse: Bool { config?.audio.usesMicrophone == true }
    func canDeleteRecord(_ id: UUID) -> Bool { id != draftRecordID && id != pendingFinish?.recordID }

    private let stores: Stores
    private let summarizer: CaptureSummarizer
    private let model: AppModel

    private var transcript = CaptureTranscript()
    private var config: Config?
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var systemTranscriber: TranscriberSession?
    private var micTranscriber: TranscriberSession?
    private var micCapture: MicCapture?
    private var feedTasks: [Task<Void, Never>] = []
    private var resultTasks: [Task<Void, Never>] = []
    private var ocrTask: Task<Void, Never>?
    private var currentOCRRequest: CaptureOCRRequest?
    private var quarantinedOCRRequest: CaptureOCRRequest?
    private var screenOCRBlocked = false
    private var hardwareStopUnconfirmed = false
    private var isShuttingDown = false
    private var captureEpoch = UUID()
    private var provisional: [CaptureTranscript.Channel: String] = [:]
    private var sessionSettings = CaptureSettings()
    private var summaryTasks: [UUID: Task<Void, Never>] = [:]
    private var audioRecorder: CaptureAudioRecorder?
    var retainsAudio: Bool { audioRecorder != nil }
    private(set) var liveCaption = ""
    private(set) var liveCaptionSource = ""
    private(set) var liveCaptionIsFinal = true
    private(set) var lastScreenText = ""
    private(set) var microphoneLevel: Float = 0
    private(set) var systemAudioLevel: Float = 0
    private(set) var recentCaptionLines: [String] = []
    /// A capture gets one stable identifier from its first live checkpoint
    /// through its final summary, so a crash-safe draft is updated rather
    /// than duplicated when the user stops normally.
    private var draftRecordID: UUID?
    private var checkpointTask: Task<Void, Never>?
    private var lastCheckpointAttemptAt: Date?
    private var saveWarning: String?
    private(set) var inputWarning: String?
    var durabilityWarning: String? {
        let warnings = [saveWarning, inputWarning].compactMap { $0 }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }
    func isRecordInProgress(_ id: UUID) -> Bool {
        isRecordBeingCaptured(id) || isRecordSummarizing(id)
    }
    func isRecordBeingCaptured(_ id: UUID) -> Bool {
        id == draftRecordID && (isActive || isStarting || isFinishing || pendingFinish != nil)
    }
    func isRecordSummarizing(_ id: UUID) -> Bool { summaryTasks[id] != nil }
    /// Frames are OCRed at most this often; SCK delivers on-change anyway.
    nonisolated private static let ocrInterval: TimeInterval = 5
    /// Keep long sessions recoverable without writing on every recognition
    /// result. The first line is queued immediately; later changes coalesce.
    private static let checkpointInterval: TimeInterval = 10

    init(stores: Stores, summarizer: CaptureSummarizer, model: AppModel,
         sleepAssertionDriver: any CaptureSleepAssertionDriving = NativeCaptureSleepAssertionDriver()) {
        self.stores = stores
        self.summarizer = summarizer
        self.model = model
        self.sleepAssertionDriver = sleepAssertionDriver
    }

    // MARK: Lifecycle

    func start(config: Config) async throws {
        let startupID = UUID()
        try await withTaskCancellationHandler {
            try await startSession(config: config, startupID: startupID)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.captureEpoch == startupID else { return }
                self.cancelStartup()
            }
        }
    }

    private func startSession(config: Config, startupID: UUID) async throws {
        guard !model.captureRefinement.isProcessing else {
            throw CaptureError("Stop the local second-pass transcription before starting a new capture.")
        }
        guard !isShuttingDown else { throw CaptureError("Aitvaras is closing; no new capture can start.") }
        if screenOCRBlocked, quarantinedOCRRequest?.isFinished == true {
            screenOCRBlocked = false
            quarantinedOCRRequest = nil
        }
        guard !hardwareStopUnconfirmed else {
            throw CaptureError("A previous screen/audio input did not confirm stopping. Restart Aitvaras before another capture.")
        }
        guard !isActive, !isStarting, !isFinishing else { throw CaptureError("Eine Aufnahme läuft, startet oder wird noch gespeichert.") }
        guard pendingFinish == nil else {
            throw CaptureError("Die vorige Aufnahme konnte noch nicht gespeichert werden — bitte zuerst erneut stoppen.")
        }
        guard config.isValid else { throw CaptureError("Bildschirm oder Audio wählen und Einverständnis bestätigen.") }
        // Recheck the explicit setup selection before permissions, retained
        // audio, recognizers or capture inputs can start. UI selection changes
        // after this point never change this session's destination.
        if let targetChatID = config.targetChatID {
            _ = try stores.validateWorkspaceCaptureTarget(chatID: targetChatID)
        }
        if config.audio.usesMicrophone && model.microphoneInUseByVoice {
            throw CaptureError("Mikrofon ist durch die Sprachkonversation belegt — erst Voice beenden.")
        }
        isStarting = true
        startupCancelled = false
        defer {
            isStarting = false
            let waiters = startupWaiters
            startupWaiters = []
            for waiter in waiters { waiter.resume() }
        }
        draftRecordID = UUID()
        captureEpoch = startupID
        sessionSettings = CaptureSettings.load()
        activityID = model.activityReporter?.begin(ActivityRun(referenceID: draftRecordID?.uuidString, category: .capture,
            title: "Capture session", stage: "Starting selected inputs",
            executionLocation: "This Mac", dataAccess: "User-selected screen/audio scope",
            dataDestination: sessionSettings.audioRetention == .discard || config.audio == .none
                ? "Local transcript only" : "Local transcript and explicitly retained audio"))

        transcript = CaptureTranscript()
        self.config = config
        checkpointTask?.cancel()
        checkpointTask = nil
        lastCheckpointAttemptAt = nil
        saveWarning = nil
        inputWarning = nil
        provisional = [:]
        liveCaption = ""
        liveCaptionSource = ""
        liveCaptionIsFinal = true
        lastScreenText = ""
        microphoneLevel = 0
        systemAudioLevel = 0
        recentCaptionLines = []
        lineCount = 0

        let locale = sessionSettings.language.locale

        do {
            try checkStartupAllowed()
            try acquireSleepProtection(includingScreen: config.scope != .none)
            // Reserve the stable local association before any input opens.
            // Later hiding/archiving the selected chat must not strand a
            // running capture before its first nonempty checkpoint.
            try reserveTargetedCapture(config: config)
            if let diagnosticInputStartup {
                try await diagnosticInputStartup()
            } else {
            if sessionSettings.audioRetention != .discard, config.audio != .none, let id = draftRecordID {
                let epoch = captureEpoch
                audioRecorder = try await CaptureAudioRecorder.create(
                    store: model.captureAudioArchives, id: id, startedAt: transcript.startedAt,
                    retention: sessionSettings.audioRetention,
                    onWarning: { [weak self] warning in
                        Task { @MainActor [weak self] in self?.audioArchiveFailed(warning, epoch: epoch) }
                    })
                NotificationCenter.default.post(name: .aitvarasCaptureAudioChanged, object: nil)
            }
            try checkStartupAllowed()
            if config.audio.usesMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw CaptureError("Mikrofonzugriff fehlt. In Systemeinstellungen → Datenschutz → Mikrofon freigeben.")
                }
            }
            try checkStartupAllowed()
            if config.audio != .none, TranscriberSession.authorizationStatus() != .authorized {
                guard await TranscriberSession.requestAuthorization() else {
                    throw CaptureError("Spracherkennung fehlt. In Systemeinstellungen → Datenschutz → Spracherkennung freigeben.")
                }
            }
            try checkStartupAllowed()
            // System audio + frames via one SCStream.
            if config.audio.needsScreenStream(includingScreen: config.scope != .none) {
                try await startStream(config: config, locale: locale)
            }
            try checkStartupAllowed()
            // A separate microphone source, not an inferred speaker identity.
            if config.audio.usesMicrophone {
                try await startMic(locale: locale)
            }
            }
            try checkStartupAllowed()
        } catch {
            // A later stage can fail after ScreenCaptureKit or the first
            // transcriber already started. Never leave a hidden stream or
            // microphone running behind a failed setup sheet.
            _ = await tearDownResources()
            cancelCheckpoint()
            removeEmptyTargetReservation()
            self.config = nil
            draftRecordID = nil
            transcript = CaptureTranscript()
            lineCount = 0
            if let activityID {
                let cancelled = error is CancellationError && inputWarning == nil
                model.activityReporter?.finish(id: activityID,
                    state: hardwareStopUnconfirmed ? .outcomeUnknown : cancelled ? .cancelled : .failed,
                    outcome: hardwareStopUnconfirmed ? "Capture startup ended; input cleanup is unconfirmed and restart is required" :
                        cancelled ? "Capture startup cancelled; inputs were stopped" : "Capture could not start; inputs were stopped")
            }
            activityID = nil
            throw error
        }

        isActive = true
        startedAt = transcript.startedAt
        scopeLabel = "\(config.scope.label) · \(config.audio.rawValue)"
        if let activityID { model.activityReporter?.update(id: activityID, stage: "Recording/transcribing: \(config.audio.rawValue)") }
    }

    private func acquireSleepProtection(includingScreen: Bool) throws {
        releaseSleepProtection()
        let policy: CaptureSleepProtectionPolicy = includingScreen ? .visualEvidence : .audioOnly
        do {
            sleepProtectionLease = try CaptureSleepProtectionLease(policy: policy, driver: sleepAssertionDriver)
            sleepProtectionStatus = .protected(policy)
        } catch {
            sleepProtectionStatus = .unavailable
            throw error
        }
    }

    private func releaseSleepProtection() {
        sleepProtectionLease?.release()
        sleepProtectionLease = nil
        if sleepProtectionStatus != .unavailable { sleepProtectionStatus = .inactive }
    }

    func cancelStartup() {
        guard isStarting else { return }
        startupCancelled = true
        releaseSleepProtection()
    }

    private func checkStartupAllowed() throws {
        try Task.checkCancellation()
        guard !startupCancelled, !isShuttingDown else { throw CancellationError() }
    }

    /// NSWorkspace delivers will-sleep on the main queue. Persist synchronously
    /// before the process can be suspended; never claim a forced sleep is covered.
    func noteSystemWillSleep(at date: Date = .now) {
        if isStarting { cancelStartup(); return }
        guard isActive, let config else { return }
        inputWarning = "macOS is entering sleep. Audio/screen inputs may have a gap; idle-sleep protection cannot prevent forced sleep or lid closure."
        transcript.addWarning(inputWarning!)
        do {
            try savePendingTranscript(makePendingFinish(
                transcript: transcript.includingUnfinalized(provisional, at: date), config: config, endedAt: date))
            saveWarning = nil
        } catch { saveWarning = "The pre-sleep checkpoint could not be saved. Current text remains in memory; stop and retry saving when awake." }
        if let activityID { model.activityReporter?.update(id: activityID, stage: "System sleep requested; input continuity is not guaranteed") }
    }

    private func waitForStartupCompletion() async {
        guard isStarting else { return }
        await withCheckedContinuation { startupWaiters.append($0) }
    }

    @discardableResult
    func stop() async throws -> CaptureRecord? {
        if isStarting { cancelStartup(); return nil }
        guard canFinish, !isFinishing else { return nil }
        isFinishing = true
        defer { isFinishing = false }
        if let activityID { model.activityReporter?.update(id: activityID, stage: "Saving checkpoint before closing inputs") }

        if isActive, let config {
            isActive = false
            cancelCheckpoint()
            let stoppedAt = Date.now
            // Save current final and explicitly provisional text BEFORE any
            // framework cleanup; neither Vision nor Speech can hold it hostage.
            if !transcript.isEmpty || !provisional.isEmpty || audioRecorder != nil {
                pendingFinish = makePendingFinish(
                    transcript: transcript.includingUnfinalized(provisional, at: stoppedAt),
                    config: config, endedAt: stoppedAt)
                do { try savePendingTranscript(pendingFinish!); saveWarning = nil }
                catch { saveWarning = "Checkpoint could not be saved; text is retained in memory for retry." }
            }
            let warnings = await tearDownResources(finalizing: true)
            for warning in warnings { transcript.addWarning(warning) }
            if !warnings.isEmpty { inputWarning = warnings.joined(separator: " ") }
            if !provisional.isEmpty {
                transcript.addWarning("The last provisional speech was retained but could not be verified as final.")
            }
            let finished = transcript.includingUnfinalized(provisional, at: stoppedAt)
            self.config = nil
            scopeLabel = ""
            startedAt = nil

            guard !finished.isEmpty || (sessionSettings.audioRetention != .discard && config.audio != .none) else {
                removeEmptyTargetReservation()
                pendingFinish = nil
                draftRecordID = nil
                transcript = CaptureTranscript()
                _ = try? stores.record(ActivityEvent(
                    kind: .captureFinished, connectorID: "capture",
                    summary: "Capture ended — nothing was transcribed (no speech/text detected)"))
                NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
                if let activityID { model.activityReporter?.finish(id: activityID,
                    state: inputWarning == nil ? .succeeded : .failed,
                    outcome: inputWarning == nil ? "Inputs stopped; no speech/text was detected" : "Inputs closed with warnings; no transcript content was available") }
                activityID = nil
                return nil
            }

            pendingFinish = PendingFinish(
                recordID: draftRecordID ?? UUID(),
                transcript: finished,
                title: config.title.isEmpty ? config.scope.label : config.title,
                scope: config.scope.label,
                audio: config.audio.storageValue,
                consentConfirmed: config.consentConfirmed,
                targetChatID: config.targetChatID,
                endedAt: stoppedAt)
        }

        guard let pendingFinish else { return nil }
        let wantsSummary = sessionSettings.postprocessing == .localSummary
        let record = CaptureRecord(id: pendingFinish.recordID,
            startedAt: pendingFinish.transcript.startedAt, endedAt: pendingFinish.endedAt,
            title: pendingFinish.title, scope: pendingFinish.scope, audio: pendingFinish.audio,
            consentConfirmed: pendingFinish.consentConfirmed,
            transcript: pendingFinish.transcript.rendered(), summaryPending: wantsSummary)
        if let activityID { model.activityReporter?.update(id: activityID, stage: "Saving finalized transcript") }
        do { try stores.saveCaptureRecord(record, workspaceChatID: pendingFinish.targetChatID, recording: ActivityEvent(
            kind: .captureFinished, connectorID: "capture", summary: wantsSummary
                ? "Transcript saved; local summary requested" : "Transcript saved without summary inference",
            sourceID: record.id.uuidString)) }
        catch {
            saveWarning = "Transcript is still in memory; local saving needs a retry."
            if let activityID { model.activityReporter?.update(id: activityID, stage: "Capture stopped; save needs attention", state: .waiting) }
            throw error
        }
        self.pendingFinish = nil
        draftRecordID = nil
        transcript = CaptureTranscript()
        provisional = [:]
        saveWarning = nil
        lineCount = 0
        finishedRecord = record
        if let activityID { model.activityReporter?.finish(id: activityID,
            state: inputWarning == nil ? .succeeded : .failed,
            outcome: inputWarning == nil ? "Inputs closed; transcript saved" : "Transcript saved; input/finalization warning needs review") }
        activityID = nil
        if wantsSummary { startSummary(for: record.id) }
        NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
        return record
    }

    /// Idempotent cleanup shared by normal stop and every partially-started
    /// failure path.
    private func tearDownResources(finalizing: Bool = false) async -> [String] {
        // The lease belongs to recording, never buffered drain, saving, retries,
        // summary/refinement or history. Release even if input stop times out.
        releaseSleepProtection()
        var warnings: [String] = []
        let feeds = feedTasks
        let results = resultTasks
        let ocr = ocrTask
        feedTasks = []; resultTasks = []; ocrTask = nil
        if let request = currentOCRRequest {
            request.cancel()
            if !request.isFinished {
                quarantinedOCRRequest = request
                screenOCRBlocked = true
            }
        }
        currentOCRRequest = nil
        ocr?.cancel()
        streamOutput?.finish()
        micCapture?.stop()
        if let activityID { model.activityReporter?.update(id: activityID, stage: "Closing screen/audio inputs") }
        if let stream {
            let handle = Handoff(value: stream)
            do { try await AsyncDeadline.run(for: .seconds(3)) { try await handle.value.stopCapture() } }
            catch {
                hardwareStopUnconfirmed = true
                warnings.append("Screen/audio input did not confirm stopping. Restart Aitvaras before another capture.")
            }
        }
        // Drain already-captured buffers BEFORE ending recognizer input.
        if !finalizing {
            audioRecorder?.markIncomplete()
            for task in feeds { task.cancel() }
        }
        do { try await AsyncDeadline.run(for: .seconds(2)) { for task in feeds { await task.value } } }
        catch {
            warnings.append("Some buffered audio did not drain before the stop deadline.")
            audioRecorder?.markIncomplete()
        }
        for task in feeds { task.cancel() }
        if let recorder = audioRecorder {
            if let activityID { model.activityReporter?.update(id: activityID, stage: "Closing retained local audio") }
            let result = await recorder.finish()
            if let warning = result.warning { warnings.append(warning) }
            audioRecorder = nil
            NotificationCenter.default.post(name: .aitvarasCaptureAudioChanged, object: nil)
        }
        if let activityID { model.activityReporter?.update(id: activityID, stage: "Finalizing speech recognition") }
        async let systemStop = systemTranscriber?.stop(finalizing: finalizing)
        async let microphoneStop = micTranscriber?.stop(finalizing: finalizing)
        let (systemResult, micResult) = await (systemStop, microphoneStop)
        for result in [systemResult, micResult] {
            if let warning = result?.warning { warnings.append(warning) }
        }
        do { try await AsyncDeadline.run(for: .seconds(1)) { for task in results { await task.value } } }
        catch { warnings.append("The final recognition result could not be fully drained.") }
        for task in results { task.cancel() }
        // In-flight OCR may ignore cancellation inside Vision. Never wait for
        // it here, and reject every late result using a new epoch.
        captureEpoch = UUID()
        stream = nil
        streamOutput = nil
        micCapture = nil
        systemTranscriber = nil
        micTranscriber = nil
        microphoneLevel = 0
        systemAudioLevel = 0
        return Array(Set(warnings)).sorted()
    }

    func statusLine() -> String {
        if isFinishing { return "Capture is stopping, saving or summarizing. Inputs are not silently restarted." }
        if pendingFinish != nil {
            return "Capture stopped — transcript is waiting for a successful local save."
        }
        guard isActive, let startedAt else { return "No capture session running." }
        let minutes = Int(Date.now.timeIntervalSince(startedAt) / 60)
        let warning = durabilityWarning.map { " WARNING: \($0)" } ?? ""
        return "Capture RUNNING since \(minutes) min (\(scopeLabel)) — \(lineCount) transcript lines so far. \(sleepProtectionSummary)\(warning)"
    }

    /// Application termination must not leave capture devices running or
    /// throw away a multi-hour transcript while a local model summarizes it.
    /// Persist a summary-pending draft only; the user can retry inference on
    /// the next launch.
    func stopBeforeTermination() async throws {
        isShuttingDown = true
        checkpointTask?.cancel()
        checkpointTask = nil

        if isStarting {
            cancelStartup()
            // Do not quit while an outstanding framework start could still
            // produce inputs. On timeout, the existing quit coordinator refuses.
            do { try await AsyncDeadline.run(for: .seconds(3)) { await self.waitForStartupCompletion() } }
            catch {
                isShuttingDown = false
                throw CaptureError("Capture startup is still closing. Sleep protection has ended; please retry quitting after the pending permission/start operation returns.")
            }
        }
        releaseSleepProtection()

        if isActive, let config {
            isActive = false
            if !transcript.isEmpty || !provisional.isEmpty || audioRecorder != nil {
                pendingFinish = makePendingFinish(transcript: transcript.includingUnfinalized(provisional), config: config)
                do { try savePendingTranscript(pendingFinish!); saveWarning = nil }
                catch { saveWarning = "Checkpoint could not be saved; closing inputs before retrying." }
            }
            let warnings = await tearDownResources(finalizing: true)
            for warning in warnings { transcript.addWarning(warning) }
            cancelCheckpoint()
            if !transcript.isEmpty || !provisional.isEmpty || (sessionSettings.audioRetention != .discard && config.audio != .none) {
                pendingFinish = makePendingFinish(transcript: transcript.includingUnfinalized(provisional), config: config)
            } else {
                removeEmptyTargetReservation()
            }
            self.config = nil
            scopeLabel = ""
            startedAt = nil
        }

        for task in summaryTasks.values { task.cancel() }
        let summaries = Array(summaryTasks.values)
        _ = try? await AsyncDeadline.run(for: .seconds(2)) { for task in summaries { await task.value } }
        if let pendingFinish {
            do { try savePendingTranscript(pendingFinish) }
            catch { isShuttingDown = false; throw error }
        }
        saveWarning = nil
        if let activityID { model.activityReporter?.finish(id: activityID, state: .interrupted,
            outcome: "Stopped for quit; transcript saved and summary deferred") }
        activityID = nil
    }

    func retrySummary(for recordID: UUID) async throws -> CaptureRecord {
        guard !model.captureRefinement.isProcessing else {
            throw CaptureError("Finish or stop the local second-pass transcription before summarizing.")
        }
        guard !isRecordInProgress(recordID) else { throw CaptureError("This capture is still being recorded, saved or summarized.") }
        let id = model.activityReporter?.begin(ActivityRun(referenceID: recordID.uuidString,
            category: .capture, title: "Retry capture summary", stage: "Loading saved transcript",
            executionLocation: "This Mac", dataAccess: "Selected saved capture",
            dataDestination: "Local capture record; configured summary provider"))
        do {
            let record = try await ActivityTaskContext.$runID.withValue(id) {
                try await summarizer.retrySummaryRecord(for: recordID)
            }
            if let id { model.activityReporter?.finish(id: id, state: .succeeded, outcome: "Summary saved") }
            NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
            return record
        } catch {
            if let id { model.activityReporter?.finish(id: id,
                state: error is CancellationError ? .cancelled : .failed,
                outcome: "Transcript retained; summary not completed") }
            throw error
        }
    }

    /// Explicitly requested local postprocessing is independent of capture
    /// hardware. Its text is already durable and can be exported immediately.
    private func startSummary(for recordID: UUID) {
        guard !isShuttingDown, summaryTasks[recordID] == nil else { return }
        let id = model.activityReporter?.begin(ActivityRun(parentID: nil,
            referenceID: recordID.uuidString, category: .capture,
            title: "Summarize saved capture", stage: "Selecting local summary model",
            executionLocation: "This Mac", dataAccess: "Saved transcript and screen text",
            dataDestination: "Local summary only"))
        summaryTasks[recordID] = Task { [weak self] in
            guard let self else { return }
            defer { self.summaryTasks[recordID] = nil }
            do {
                let updated = try await ActivityTaskContext.$runID.withValue(id) {
                    try await self.summarizer.retrySummaryRecord(for: recordID)
                }
                if self.finishedRecord?.id == updated.id { self.finishedRecord = updated }
                if let id { self.model.activityReporter?.finish(id: id, state: .succeeded, outcome: "Local summary saved") }
            } catch {
                let removed = (error as? CaptureSummaryError) == .recordMissing
                if let id { self.model.activityReporter?.finish(id: id,
                    state: error is CancellationError || removed ? .cancelled : .failed,
                    outcome: removed ? "Capture was deleted; no record recreated" : "Transcript retained; summary can be retried") }
            }
            NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
        }
    }

    private struct PendingFinish {
        let recordID: UUID
        let transcript: CaptureTranscript
        let title: String
        let scope: String
        let audio: String
        let consentConfirmed: Bool
        let targetChatID: UUID?
        let endedAt: Date
    }

    private func makePendingFinish(transcript: CaptureTranscript, config: Config,
                                   endedAt: Date = .now) -> PendingFinish {
        PendingFinish(
            recordID: draftRecordID ?? UUID(),
            transcript: transcript,
            title: config.title.isEmpty ? config.scope.label : config.title,
            scope: config.scope.label,
            audio: config.audio.storageValue,
            consentConfirmed: config.consentConfirmed,
            targetChatID: config.targetChatID,
            endedAt: endedAt)
    }

    private func savePendingTranscript(_ pending: PendingFinish) throws {
        try stores.saveCaptureRecord(CaptureRecord(
            id: pending.recordID,
            startedAt: pending.transcript.startedAt,
            endedAt: pending.endedAt,
            title: pending.title,
            scope: pending.scope,
            audio: pending.audio,
            consentConfirmed: pending.consentConfirmed,
            transcript: pending.transcript.rendered(),
            summaryPending: true), workspaceChatID: pending.targetChatID)
    }

    private func reserveTargetedCapture(config: Config) throws {
        guard let targetChatID = config.targetChatID, let id = draftRecordID else { return }
        try stores.saveCaptureRecord(CaptureRecord(id: id,
            startedAt: transcript.startedAt, endedAt: transcript.startedAt,
            title: config.title.isEmpty ? config.scope.label : config.title,
            scope: config.scope.label, audio: config.audio.storageValue,
            consentConfirmed: config.consentConfirmed, transcript: "", summaryPending: false),
            workspaceChatID: targetChatID)
    }

    /// Never remove a genuine checkpoint or retained audio after a partial
    /// startup. An empty reservation left by a crash remains honest local
    /// evidence of the interrupted attempt; it does not request inference.
    private func removeEmptyTargetReservation() {
        guard let id = draftRecordID,
              !FileManager.default.fileExists(atPath: model.captureAudioArchives.directory(for: id).path) else { return }
        do {
            guard let saved = try stores.captureRecord(id: id),
                  saved.transcript.isEmpty, saved.summary.isEmpty,
                  try stores.workspaceCaptureTarget(recordID: id) != nil else { return }
            try stores.deleteCaptureRecord(id)
        } catch {
            saveWarning = "An empty local capture reservation could not be removed. Saved content was not deleted."
        }
    }

    private func scheduleCheckpoint() {
        guard checkpointTask == nil, config != nil, !transcript.isEmpty || !provisional.isEmpty else { return }
        let elapsed = lastCheckpointAttemptAt.map { Date.now.timeIntervalSince($0) }
        let delay = elapsed.map { max(0, Self.checkpointInterval - $0) } ?? 0
        checkpointTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled, let self else { return }
            self.checkpointTask = nil
            self.lastCheckpointAttemptAt = .now
            do {
                guard let config = self.config else { return }
                try self.savePendingTranscript(
                    self.makePendingFinish(transcript: self.transcript.includingUnfinalized(self.provisional), config: config))
                self.saveWarning = nil
            } catch {
                self.saveWarning = "the latest transcript checkpoint could not be saved; retrying locally"
                self.scheduleCheckpoint()
            }
        }
    }

    private func cancelCheckpoint() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    // MARK: SCK stream

    private func startStream(config: Config, locale: Locale) async throws {
        let filter: SCContentFilter
        switch config.scope {
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display(let display):
            let ownWindows = try await SCShareableContent.current.windows.filter {
                $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
            }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        case .none:
            // Audio-only still needs a filter; use the main display but
            // deliver no video output below.
            guard let display = try await SCShareableContent.current.displays.first else {
                throw CaptureError("Kein Display gefunden.")
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        try checkStartupAllowed()

        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.width = 1512
        configuration.height = 945
        configuration.showsCursor = false
        if config.audio.usesSystemAudio {
            configuration.capturesAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true   // never transcribe Aitvaras's own TTS
        }

        let (audioStream, audioContinuation) = AsyncStream<TranscriberSession.BufferHandoff>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        let (frameStream, frameContinuation) = AsyncStream<Handoff<CVPixelBuffer>>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let epoch = captureEpoch
        let recorder = audioRecorder
        let output = CaptureStreamOutput(
            wantsAudio: config.audio.usesSystemAudio,
            wantsFrames: config.scope != .none && !screenOCRBlocked,
            audioContinuation: audioContinuation,
            frameContinuation: frameContinuation,
            onUnexpectedStop: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleUnexpectedStreamStop(epoch: epoch)
                }
            }, onDroppedAudio: { [weak self] in
                recorder?.markIncomplete()
                Task { @MainActor [weak self] in
                    await self?.handleCaptureDeviceFailure("System audio could not keep up. The saved transcript or retained audio may have a gap.", epoch: epoch)
                }
            })
        streamOutput = output

        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        if config.scope != .none && !screenOCRBlocked {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: CaptureStreamOutput.queue)
        }
        if config.audio.usesSystemAudio {
            try stream.addStreamOutput(output, type: .audio,
                                       sampleHandlerQueue: CaptureStreamOutput.queue)
        }
        self.stream = stream
        try await stream.startCapture()
        try checkStartupAllowed()

        if config.audio.usesSystemAudio {
            try await startSystemTranscriber(locale: locale, buffers: audioStream)
        } else {
            audioContinuation.finish()
        }
        if config.scope != .none && !screenOCRBlocked {
            startOCRReader(frames: frameStream)
        } else {
            frameContinuation.finish()
            if config.scope != .none && screenOCRBlocked {
                inputWarning = "Screen text recognition is unavailable after a previous timeout; restart Aitvaras to retry it. Audio transcription remains available."
                transcript.addWarning(inputWarning!)
            }
        }
    }

    private func startSystemTranscriber(locale: Locale,
                                        buffers: AsyncStream<TranscriberSession.BufferHandoff>) async throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2) else {
            throw CaptureError("Audioformat nicht verfügbar.")
        }
        let transcriber = TranscriberSession()
        systemTranscriber = transcriber
        let updates = try await transcriber.start(locale: locale, micFormat: format, allowDownload: false)
        try checkStartupAllowed()

        // Detached: buffers stay off the main actor on their way into the
        // transcriber actor.
        let epoch = captureEpoch
        let recorder = audioRecorder
        feedTasks.append(Task.detached { [weak self] in
            var lastMeterAt = Date.distantPast
            for await handoff in buffers {
                if Task.isCancelled { break }
                recorder?.append(handoff: handoff, source: .systemAudio)
                if Date.now.timeIntervalSince(lastMeterAt) >= 0.2 {
                    lastMeterAt = .now
                    let level = Self.meterLevel(handoff.buffer)
                    await self?.updateMeter(level, channel: .systemAudio, epoch: epoch)
                }
                await transcriber.feed(handoff: handoff)
            }
        })
        resultTasks.append(Task { [weak self] in
            do {
                for try await update in updates {
                    self?.receive(update, channel: .systemAudio, epoch: epoch)
                }
            } catch {
                self?.recognitionFailed(epoch: epoch)
            }
        })
    }

    private func startMic(locale: Locale) async throws {
        let epoch = captureEpoch
        let recorder = audioRecorder
        let capture = MicCapture { [weak self] message in
            recorder?.markIncomplete()
            Task { @MainActor [weak self] in
                await self?.handleCaptureDeviceFailure(message, epoch: epoch)
            }
        }
        micCapture = capture
        let buffers = try capture.start(copyBuffers: true)
        guard let format = capture.format else {
            throw CaptureError("Mikrofonformat nicht verfügbar.")
        }
        let transcriber = TranscriberSession()
        micTranscriber = transcriber
        let updates = try await transcriber.start(locale: locale, micFormat: format, allowDownload: false)
        try checkStartupAllowed()

        feedTasks.append(Task.detached { [weak self] in
            var lastMeterAt = Date.distantPast
            for await buffer in buffers {
                if Task.isCancelled { break }
                recorder?.append(handoff: .init(buffer: buffer), source: .microphone)
                if Date.now.timeIntervalSince(lastMeterAt) >= 0.2 {
                    lastMeterAt = .now
                    let level = Self.meterLevel(buffer)
                    await self?.updateMeter(level, channel: .microphone, epoch: epoch)
                }
                await transcriber.feed(handoff: .init(buffer: buffer))
            }
        })
        resultTasks.append(Task { [weak self] in
            do {
                for try await update in updates {
                    self?.receive(update, channel: .microphone, epoch: epoch)
                }
            } catch {
                self?.recognitionFailed(epoch: epoch)
            }
        })
    }

    private func appendLine(channel: CaptureTranscript.Channel, text: String) {
        let oldCount = transcript.lines.count
        transcript.append(channel: channel, text: text)
        lineCount = transcript.lines.count
        if transcript.lines.count != oldCount { scheduleCheckpoint() }
    }

    private func receive(_ update: TranscriberSession.Update, channel: CaptureTranscript.Channel, epoch: UUID) {
        guard captureEpoch == epoch, config != nil else { return }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        liveCaption = String(text.suffix(600))
        liveCaptionSource = channel.rawValue
        liveCaptionIsFinal = update.isFinal
        if update.isFinal {
            provisional[channel] = nil
            appendLine(channel: channel, text: text)
            recentCaptionLines.append("[\(channel.rawValue)] \(text)")
            if recentCaptionLines.count > 30 { recentCaptionLines.removeFirst(recentCaptionLines.count - 30) }
        } else {
            provisional[channel] = String(text.suffix(16_000))
            scheduleCheckpoint()
        }
    }

    nonisolated private static func meterLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        min(1, max(0, (MicCapture.level(of: buffer) + 60) / 60))
    }

    private func updateMeter(_ level: Float, channel: CaptureTranscript.Channel, epoch: UUID) {
        guard epoch == captureEpoch, isActive else { return }
        if channel == .microphone { microphoneLevel = level }
        if channel == .systemAudio { systemAudioLevel = level }
    }

    private func recognitionFailed(epoch: UUID) {
        guard captureEpoch == epoch else { return }
        let warning = "Speech recognition reported an error; the transcript may have a gap."
        transcript.addWarning(warning)
        inputWarning = warning
        if isActive {
            Task { [weak self] in await self?.handleCaptureDeviceFailure(warning, epoch: epoch) }
        }
    }

    private func audioArchiveFailed(_ warning: String, epoch: UUID) {
        guard captureEpoch == epoch else { return }
        transcript.addWarning(warning)
        inputWarning = warning
        scheduleCheckpoint()
        NotificationRouter.requestedWorkNeedsAttention()
        NotificationCenter.default.post(name: .aitvarasCaptureAudioChanged, object: nil)
    }

    // MARK: OCR

    private func startOCRReader(frames: AsyncStream<Handoff<CVPixelBuffer>>) {
        let epoch = captureEpoch
        ocrTask = Task.detached(priority: .utility) { [weak self] in
            var lastOCR = Date.distantPast
            for await handoff in frames {
                if Task.isCancelled { break }
                guard Date.now.timeIntervalSince(lastOCR) >= Self.ocrInterval else { continue }
                lastOCR = .now
                let request = CaptureOCRRequest()
                guard await self?.setOCRRequest(request, epoch: epoch) == true else { break }
                do {
                    if let text = try await request.recognize(handoff) {
                        guard !Task.isCancelled else { break }
                        await self?.appendScreenNote(text, epoch: epoch)
                    }
                } catch {
                    if !Task.isCancelled { await self?.screenRecognitionFailed(epoch: epoch) }
                    break
                }
            }
        }
    }

    private func setOCRRequest(_ request: CaptureOCRRequest, epoch: UUID) -> Bool {
        guard epoch == captureEpoch, config != nil else { request.cancel(); return false }
        currentOCRRequest = request
        return true
    }

    private func appendScreenNote(_ text: String, epoch: UUID) {
        guard epoch == captureEpoch, config != nil else { return }
        lastScreenText = String(text.prefix(6_000))
        if transcript.appendScreenNote(text) { scheduleCheckpoint() }
    }

    private func screenRecognitionFailed(epoch: UUID) {
        guard epoch == captureEpoch, config != nil else { return }
        screenOCRBlocked = true
        if let stream, let streamOutput { try? stream.removeStreamOutput(streamOutput, type: .screen) }
        quarantinedOCRRequest = currentOCRRequest
        currentOCRRequest?.cancel()
        currentOCRRequest = nil
        let warning = "Screen text recognition stopped responding. No further screen text is being added; audio transcription continues if selected."
        inputWarning = warning
        transcript.addWarning(warning)
        scheduleCheckpoint()
        if config?.audio == AudioMode.none {
            Task { [weak self] in await self?.handleCaptureDeviceFailure(warning, epoch: epoch) }
        }
    }

    private func handleUnexpectedStreamStop(epoch: UUID) async {
        await handleCaptureDeviceFailure(
            "macOS ended the screen or audio capture. Aitvaras is saving the transcript collected so far.", epoch: epoch)
    }

    private func handleCaptureDeviceFailure(_ message: String, epoch: UUID? = nil, presentUI: Bool = true) async {
        if let epoch, epoch != captureEpoch { return }
        if isStarting {
            inputWarning = message
            cancelStartup()
            return
        }
        guard isActive, !isFinishing else { return }
        inputWarning = message
        transcript.addWarning(message)
        if presentUI { model.presentError(
            title: "Capture stopped unexpectedly",
            message: message) }
        do {
            if let record = try await stop(), presentUI {
                CaptureWindows.shared.showResult(record: record, model: model)
            }
        } catch {
            if presentUI { CaptureWindows.shared.showSaveError(error) }
        }
    }

    /// Bootstrap-free fixtures: no audio, screen, OCR or model is started.
    func prepareSyntheticPreview() {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        if !(sleepAssertionDriver is CaptureDiagnosticSleepDriver) {
            sleepAssertionDriver = CaptureDiagnosticSleepDriver()
        }
        // Fixture uses only fake assertions, including screenshots.
        do { try acquireSleepProtection(includingScreen: false) }
        catch { preconditionFailure("Synthetic sleep assertion unexpectedly failed") }
        captureEpoch = UUID()
        draftRecordID = UUID()
        sessionSettings = CaptureSettings(postprocessing: .transcriptOnly)
        config = Config(scope: .none, audio: .microphone, title: "Synthetic lecture", consentConfirmed: true)
        transcript = CaptureTranscript(startedAt: .now.addingTimeInterval(-45))
        transcript.append(channel: .microphone, text: "The example introduces a constrained optimization problem.")
        recentCaptionLines = ["[Mikrofon] The example introduces a constrained optimization problem."]
        provisional = [.microphone: "We now compare the two feasible solutions."]
        liveCaption = "We now compare the two feasible solutions."
        liveCaptionSource = "Mikrofon"
        liveCaptionIsFinal = false
        microphoneLevel = 0.45
        systemAudioLevel = 0
        lastScreenText = "Example: objective function and feasible region"
        lineCount = 1
        startedAt = transcript.startedAt
        scopeLabel = "Synthetic microphone input · no device opened"
        isActive = true
        activityID = model.activityReporter?.begin(ActivityRun(referenceID: draftRecordID?.uuidString,
            category: .capture, title: "Synthetic capture", stage: "Transcribing synthetic input",
            executionLocation: "Fixture only", dataAccess: "Synthetic text", dataDestination: "Isolated test store"))
    }

    /// Real controller stop/save paths, with simulated feeds and a deliberately
    /// non-cooperative OCR task. Safe to run without capture permissions.
    func runSyntheticStopChecks() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        let oldEpoch = captureEpoch
        config?.audio = .systemAndMic
        let blockedOCR = CaptureDiagnosticGate()
        ocrTask = Task { [weak self] in
            await blockedOCR.wait()
            self?.appendScreenNote("Late obsolete OCR text must never reach a new session", epoch: oldEpoch)
        }
        while !(await blockedOCR.started) { await Task.yield() }
        feedTasks.append(Task { [weak self] in
            self?.receive(.init(text: "Last finalized phrase from the buffered audio.", isFinal: true), channel: .microphone, epoch: oldEpoch)
        })
        feedTasks.append(Task { [weak self] in
            self?.receive(.init(text: "Final system-audio phrase from its separate source.", isFinal: true), channel: .systemAudio, epoch: oldEpoch)
        })
        let clock = ContinuousClock.now
        guard let record = try await stop(), record.transcript.contains("Last finalized phrase"),
              record.transcript.contains("[Systemaudio] Final system-audio phrase"),
              !record.summaryPending, clock.duration(to: .now) < .seconds(2),
              sleepProtectionLease == nil, sleepProtectionStatus == .inactive else {
            throw CaptureError("Synthetic stop/save did not finish independently from stalled OCR.")
        }
        prepareSyntheticPreview()
        await blockedOCR.finish()
        await handleCaptureDeviceFailure("Obsolete device callback", epoch: oldEpoch)
        for _ in 0..<10 { await Task.yield() }
        guard isActive, !lastScreenText.contains("obsolete"), transcript.screenNotes.isEmpty else {
            throw CaptureError("Late OCR contaminated a new capture.")
        }
        // Simulate disk failure. Even the early checkpoint failure must not
        // prevent cleanup, lose the in-memory snapshot, or claim success.
        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER diagnostic_capture_save_failure BEFORE INSERT ON captureRecord BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END")
        }
        let failingEpoch = captureEpoch
        var failed = false
        do { _ = try await stop() } catch { failed = true }
        try await stores.db.queue.write { db in try db.execute(sql: "DROP TRIGGER diagnostic_capture_save_failure") }
        guard failed, !isActive, !isFinishing, canFinish, captureEpoch != failingEpoch,
              sleepProtectionLease == nil, sleepProtectionStatus == .inactive else {
            throw CaptureError("A failed save did not retain retryable text after cleanup.")
        }
        guard let retried = try await stop(), retried.transcript.contains("Unfinalized speech"), !canFinish else {
            throw CaptureError("Retry did not save retained provisional text.")
        }
        try await runSyntheticWorkspaceCaptureChecks()
        try await runSyntheticSleepProtectionChecks()
    }

    private func runSyntheticSleepProtectionChecks() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        let driver = CaptureDiagnosticSleepDriver()
        sleepAssertionDriver = driver
        defer { diagnosticInputStartup = nil }
        let configuration = Config(scope: .none, audio: .microphone,
            title: "Synthetic sleep lifecycle", consentConfirmed: true)
        var inputsStarted = false
        diagnosticInputStartup = { inputsStarted = true }
        driver.failNext = true
        var failed = false
        do { try await start(config: configuration) } catch { failed = true }
        guard failed, !inputsStarted, driver.liveCount == 0, sleepProtectionStatus == .unavailable else {
            throw CaptureError("Assertion failure did not refuse capture before inputs.")
        }

        // Startup failure after assertion acquisition uses the real catch path.
        diagnosticInputStartup = {
            guard self.sleepProtectionStatus == .protected(.audioOnly), driver.liveCount == 1 else {
                throw CaptureError("Input startup preceded sleep protection.")
            }
            throw CaptureError("Synthetic input startup failure")
        }
        do { try await start(config: configuration) } catch { }
        guard !isActive, driver.liveCount == 0, sleepProtectionStatus == .inactive else {
            throw CaptureError("Failed input startup leaked sleep protection.")
        }

        // Task cancellation, explicit stop and quit each interrupt suspended
        // startup without opening any input or retaining the assertion.
        for mode in ["cancel", "stop", "quit", "device"] {
            let gate = CaptureDiagnosticGate()
            diagnosticInputStartup = { await gate.wait() }
            let starting = Task { try await self.start(config: configuration) }
            while !(await gate.started) { await Task.yield() }
            var quitting: Task<Void, Error>?
            switch mode {
            case "cancel":
                starting.cancel()
                while !startupCancelled { await Task.yield() }
            case "stop": _ = try await stop()
            case "quit":
                quitting = Task { try await self.stopBeforeTermination() }
                while !startupCancelled { await Task.yield() }
            default:
                await handleCaptureDeviceFailure("Synthetic startup device failure", epoch: captureEpoch, presentUI: false)
            }
            if driver.liveCount != 0 {
                throw CaptureError("Cancelled startup retained its sleep assertion.")
            }
            await gate.finish()
            do { try await starting.value; throw CaptureError("Cancelled startup became active.") }
            catch is CancellationError { }
            try await quitting?.value
            isShuttingDown = false
            guard !isActive, !isStarting, driver.liveCount == 0, sleepProtectionStatus == .inactive else {
                throw CaptureError("Startup cancellation leaked sleep protection.")
            }
        }

        diagnosticInputStartup = { }
        try await start(config: configuration)
        guard driver.liveCount == 1, isActive else { throw CaptureError("Active capture lost its assertion.") }
        transcript.append(channel: .microphone, text: "Synthetic phrase before forced sleep.")
        noteSystemWillSleep()
        guard let checkpointID = draftRecordID,
              let checkpoint = try stores.captureRecord(id: checkpointID),
              checkpoint.transcript.contains("Synthetic phrase before forced sleep"),
              checkpoint.transcript.contains("forced sleep"),
              inputWarning?.contains("gap") == true else {
            throw CaptureError("Forced-sleep boundary did not preserve text and an honest continuity warning.")
        }
        await handleCaptureDeviceFailure("Synthetic active device failure", epoch: captureEpoch, presentUI: false)
        guard !isActive, driver.liveCount == 0 else { throw CaptureError("Device failure retained sleep protection.") }

        prepareSyntheticPreview()
        try await stopBeforeTermination()
        guard driver.liveCount == 0, sleepProtectionLease == nil else { throw CaptureError("Quit retained sleep protection.") }
        isShuttingDown = false
        pendingFinish = nil
        draftRecordID = nil
        print("[capture-sleep-check] PASS: before-input acquisition, failed assertion/startup, cancelled startup, stop, device failure, quit and save-retry release; fake assertions only")
    }

    /// Runs inside the existing isolated lifecycle diagnostic. This exercises
    /// real checkpoint, teardown and retry paths without starting any device
    /// or provider. Same-title chats deliberately prove stable-ID routing.
    private func runSyntheticWorkspaceCaptureChecks() async throws {
        let project = try stores.createWorkspaceProject(title: "Synthetic capture destination")
        let target = try stores.createWorkspaceChat(projectID: project.id, title: "Same title", kind: .primary)
        let other = try stores.createWorkspaceChat(projectID: project.id, title: "Same title", kind: .primary)

        prepareSyntheticPreview()
        config?.targetChatID = target.id
        guard let config, let recordID = draftRecordID else { throw CaptureError("Missing targeted capture fixture.") }
        _ = try stores.validateWorkspaceCaptureTarget(chatID: target.id)
        try reserveTargetedCapture(config: config)
        guard let reservation = try stores.captureRecord(id: recordID), reservation.transcript.isEmpty,
              !reservation.summaryPending,
              try stores.workspaceCaptureTarget(recordID: recordID)?.chatID == target.id else {
            throw CaptureError("Initial capture reservation did not atomically retain its target.")
        }
        try stores.setWorkspaceChatArchived(id: target.id, archived: true)
        model.openWorkspaceChat(other.id)
        try savePendingTranscript(makePendingFinish(transcript: transcript.includingUnfinalized(provisional), config: config))
        guard try stores.workspaceCaptureTarget(recordID: recordID)?.chatID == target.id,
              try stores.workspaceCaptures(chatID: other.id).isEmpty else {
            throw CaptureError("A checkpoint followed current UI selection or lost its archived target.")
        }

        try await stores.db.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER diagnostic_capture_update_failure BEFORE UPDATE ON captureRecord BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END")
        }
        var failed = false
        do { _ = try await stop() } catch { failed = true }
        try await stores.db.queue.write { db in try db.execute(sql: "DROP TRIGGER diagnostic_capture_update_failure") }
        guard failed, canFinish, !isActive else { throw CaptureError("Targeted save failure did not retain retry state.") }
        model.openWorkspaceChat(other.id)
        guard let finished = try await stop(), finished.id == recordID,
              try stores.workspaceCaptureTarget(recordID: recordID)?.chatID == target.id else {
            throw CaptureError("A save retry changed the frozen target.")
        }
        // The summary/update and legacy save paths must retain the relation of
        // an already-saved/recovered capture rather than infer a new target.
        try stores.saveCaptureRecord(finished)
        guard try stores.workspaceCaptureTarget(recordID: recordID)?.chatID == target.id else {
            throw CaptureError("A recovered capture lost its saved association.")
        }

        prepareSyntheticPreview()
        self.config?.targetChatID = other.id
        guard let quitID = draftRecordID, let quitConfig = self.config else { throw CaptureError("Missing quit target fixture.") }
        try reserveTargetedCapture(config: quitConfig)
        try await stopBeforeTermination()
        guard try stores.workspaceCaptureTarget(recordID: quitID)?.chatID == other.id,
              try stores.captureRecord(id: quitID)?.transcript.contains("Unfinalized speech") == true else {
            throw CaptureError("Quit checkpoint lost its frozen capture target.")
        }
        isShuttingDown = false
        pendingFinish = nil
        draftRecordID = nil
        transcript = CaptureTranscript()
        provisional = [:]

        // Empty reservations are removable, while a real recovered capture
        // and its original link must survive that cleanup path.
        prepareSyntheticPreview()
        self.config?.targetChatID = other.id
        guard let emptyID = draftRecordID, let emptyConfig = self.config else { throw CaptureError("Missing empty fixture.") }
        try reserveTargetedCapture(config: emptyConfig)
        transcript = CaptureTranscript()
        provisional = [:]
        _ = try await stop()
        guard try stores.captureRecord(id: emptyID) == nil,
              try stores.workspaceCaptureTarget(recordID: emptyID) == nil,
              try stores.workspaceCaptureTarget(recordID: recordID)?.chatID == target.id else {
            throw CaptureError("Empty-reservation cleanup altered a durable capture.")
        }
        print("[workspace-capture-check] PASS: atomic reservation, archived target, same-title/UI isolation, checkpoint, save retry, recovered link, quit and empty cleanup")
    }

    /// Exercise capture -> retained sources -> saved text -> explicit deletion,
    /// without opening a microphone, screen, recognizer, or summary model.
    func runSyntheticAudioChecks() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        prepareSyntheticPreview()
        config?.audio = .systemAndMic
        sessionSettings.audioRetention = .untilDeleted
        guard let id = draftRecordID,
              let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) else {
            throw CaptureError("Synthetic audio fixture could not be created.")
        }
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData?[0][index] = 0.1 * sin(Float(index) * 0.1) }
        let recorder = try await CaptureAudioRecorder.create(store: model.captureAudioArchives,
            id: id, startedAt: transcript.startedAt, retention: .untilDeleted, onWarning: { _ in })
        audioRecorder = recorder
        feedTasks.append(Task {
            recorder.append(handoff: .init(buffer: buffer), source: .microphone)
            recorder.append(handoff: .init(buffer: buffer), source: .systemAudio)
        })
        guard let record = try await stop(), record.id == id,
              let manifest = try model.captureAudioArchives.inspect(id).manifest,
              manifest.state == .finalized, manifest.sources.count == 2,
              manifest.sources.allSatisfy({ $0.frameCount == 160 }),
              try stores.captureRecord(id: id)?.transcript == record.transcript else {
            throw CaptureError("Retained source audio did not finish independently of the saved transcript.")
        }
        try await model.deleteCaptureAndArtifacts(id)
        guard try stores.captureRecord(id: id) == nil,
              !FileManager.default.fileExists(atPath: model.captureAudioArchives.directory(for: id).path) else {
            throw CaptureError("Explicit deletion did not remove the capture and retained sources.")
        }
        prepareSyntheticPreview()
        guard let discardedID = draftRecordID else { throw CaptureError("Missing discard fixture.") }
        _ = try await stop()
        guard !FileManager.default.fileExists(atPath: model.captureAudioArchives.directory(for: discardedID).path) else {
            throw CaptureError("Discard mode created an audio archive.")
        }
        prepareSyntheticPreview()
        sessionSettings.audioRetention = .untilDeleted
        guard let interruptedID = draftRecordID else { throw CaptureError("Missing interrupted fixture.") }
        let interrupted = try await CaptureAudioRecorder.create(store: model.captureAudioArchives,
            id: interruptedID, startedAt: transcript.startedAt, retention: .untilDeleted, onWarning: { _ in })
        audioRecorder = interrupted
        interrupted.append(handoff: .init(buffer: buffer), source: .microphone)
        _ = await tearDownResources(finalizing: false)
        guard let failed = try model.captureAudioArchives.inspect(interruptedID).manifest,
              failed.state == .failed, failed.failure == .upstreamGap else {
            throw CaptureError("Interrupted startup incorrectly finalized retained audio.")
        }
        _ = try await stop()
        try await model.deleteCaptureAndArtifacts(interruptedID)
    }

}

private final class CaptureDiagnosticSleepDriver: CaptureSleepAssertionDriving {
    private struct State {
        var nextID: UInt32 = 0
        var live: Set<UInt32> = []
        var failNext = false
    }
    private let state = Mutex(State())
    var liveCount: Int { state.withLock { $0.live.count } }
    var failNext: Bool {
        get { state.withLock { $0.failNext } }
        set { state.withLock { $0.failNext = newValue } }
    }
    func acquire(preventDisplayIdleSleep: Bool) throws -> UInt32 {
        try state.withLock {
            if $0.failNext { $0.failNext = false; throw CaptureError("Synthetic assertion failure") }
            $0.nextID += 1
            $0.live.insert($0.nextID)
            return $0.nextID
        }
    }
    func release(_ assertion: UInt32) { state.withLock { _ = $0.live.remove(assertion) } }
}

private actor CaptureDiagnosticGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

/// Vision's synchronous OCR can become stuck inside the framework. Run it on
/// a utility queue, cancel its request at the deadline, and never await this
/// operation while saving/stopping. The controller disables further OCR after
/// a timeout so a stalled framework cannot accumulate work or new frame copies.
private final class CaptureOCRRequest: @unchecked Sendable {
    private let request: VNRecognizeTextRequest
    private struct State { var started = false; var finished = false; var cancelled = false }
    private let state = Mutex(State())
    var isFinished: Bool { state.withLock { $0.finished } }
    init() {
        request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.preferBackgroundProcessing = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
    }
    func cancel() {
        state.withLock { value in
            value.cancelled = true
            if !value.started { value.finished = true }
        }
        request.cancel()
    }
    func recognize(_ frame: Handoff<CVPixelBuffer>) async throws -> String? {
        let allowed = state.withLock { value in
            guard !value.cancelled else { return false }
            value.started = true
            return true
        }
        guard allowed else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            do {
                return try await AsyncDeadline.run(for: .seconds(4)) { [self] in
                    try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async { [self] in
                            defer { state.withLock { $0.finished = true } }
                            do {
                                let handler = VNImageRequestHandler(cvPixelBuffer: frame.value)
                                try handler.perform([request])
                                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                                continuation.resume(returning: text.isEmpty ? nil : text)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
            } catch { cancel(); throw error }
        } onCancel: { self.cancel() }
    }
}

struct CaptureError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Explicit ownership handoff for AV buffers: the producer yields and never
/// touches the value again, so crossing isolation is safe by construction —
/// asserted here because region analysis can't see through the stream.
private struct Handoff<T>: @unchecked Sendable {
    let value: T
}

/// SCStream delegate/output living off the main actor: converts audio
/// sample buffers to PCM and forwards the latest video frame. Buffers are
/// handed over without retaining video frames beyond the bounded OCR stream.
private final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "aitvaras.capture.stream")

    private let wantsAudio: Bool
    private let wantsFrames: Bool
    private let audioContinuation: AsyncStream<TranscriberSession.BufferHandoff>.Continuation
    private let frameContinuation: AsyncStream<Handoff<CVPixelBuffer>>.Continuation
    private let onUnexpectedStop: @Sendable () -> Void
    private let onDroppedAudio: @Sendable () -> Void

    init(wantsAudio: Bool, wantsFrames: Bool,
         audioContinuation: AsyncStream<TranscriberSession.BufferHandoff>.Continuation,
         frameContinuation: AsyncStream<Handoff<CVPixelBuffer>>.Continuation,
         onUnexpectedStop: @escaping @Sendable () -> Void,
         onDroppedAudio: @escaping @Sendable () -> Void) {
        self.wantsAudio = wantsAudio
        self.wantsFrames = wantsFrames
        self.audioContinuation = audioContinuation
        self.frameContinuation = frameContinuation
        self.onUnexpectedStop = onUnexpectedStop
        self.onDroppedAudio = onDroppedAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .audio:
            guard wantsAudio, sampleBuffer.isValid else { return }
            guard let pcm = Self.pcmBuffer(from: sampleBuffer) else {
                if CMSampleBufferGetNumSamples(sampleBuffer) > 0 { onDroppedAudio() }
                return
            }
            if case .dropped = audioContinuation.yield(TranscriberSession.BufferHandoff(buffer: pcm)) {
                onDroppedAudio()
            }
        case .screen:
            guard wantsFrames, sampleBuffer.isValid,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            frameContinuation.yield(Handoff(value: pixelBuffer))
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish()
        onUnexpectedStop()
    }

    func finish() {
        audioContinuation.finish()
        frameContinuation.finish()
    }

    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
