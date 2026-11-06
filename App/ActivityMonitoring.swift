import AppKit
import Foundation
import SwiftUI
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

extension BackgroundFeature {
    var monitoringTitle: String {
        switch self {
        case .mail: "Mail checks"
        case .notifications: "System notification checks"
        case .connectors: "Connected-service checks"
        case .indexing: "Folder indexing"
        case .archiving: "Conversation archiving"
        case .memory: "Memory maintenance"
        case .routineReview: "Cloud routine review"
        case .routines: "Scheduled routines"
        case .delivery: "External notification delivery"
        case .focus: "Focus observations"
        }
    }
}

struct ActivityMenuControls: View {
    @Environment(\.openWindow) private var openWindow

    private func open(_ notification: Notification.Name? = nil) {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let notification {
            DispatchQueue.main.async { NotificationCenter.default.post(name: notification, object: nil) }
        }
    }

    var body: some View {
        HStack {
            Button("Open Aitvaras") { open() }
            Button("History") { open(.aitvarasOpenActivity) }
            Button("Automatic work") { open(.aitvarasOpenBackgroundReview) }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }.controlSize(.small).padding(12).frame(width: 420)
    }
}

extension AppModel {
    var topLevelCurrentActivity: [ActivityRun] {
        let activeIDs = Set(currentActivityRuns.map(\.id))
        return currentActivityRuns.filter { $0.parentID == nil || !activeIDs.contains($0.parentID!) }
    }

    func installMonitoringObserver() {
        modelDownloads.reporter = activityReporter
        captureRefinement.reporter = activityReporter
        neuralVoiceInstaller.reporter = activityReporter
        nativeWorkspace.reporter = activityReporter
        guard monitoringObserver == nil else { return }
        monitoringObserver = NotificationCenter.default.addObserver(
            forName: .aitvarasMonitoringChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMonitoring() }
        }
    }

    func refreshMonitoring() {
        guard let stores else { return }
        do {
            currentActivityRuns = try stores.currentActivityRuns()
            let latest = try stores.activityRuns(limit: 40)
            let attention = try stores.activityAttentionRuns()
            recentActivityRuns = Array(Dictionary((latest + attention).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
                .sorted { $0.startedAt > $1.startedAt }
            monitoredServices = try stores.serviceStatuses()
            backgroundPolicy = try stores.backgroundWorkPolicy()
            monitoringReady = true
            monitoringError = activityReporter?.failureMessage
            if monitoringError != nil, !monitoringFailureHandled {
                monitoringFailureHandled = true
                policyApplyTask = Task { [weak self] in await self?.applyAutomaticWorkPolicy() }
            }
        } catch {
            monitoringError = "Activity monitoring is unavailable. Automatic work is suspended."
            if !monitoringFailureHandled {
                monitoringFailureHandled = true
                policyApplyTask = Task { [weak self] in await self?.applyAutomaticWorkPolicy() }
            }
        }
    }

    func automaticWorkAllowed(_ feature: BackgroundFeature) -> Bool {
        guard !captureRefinement.isProcessing else { return false }
        guard activityReporter?.failureMessage == nil, monitoringError == nil,
              let policy = try? stores?.backgroundWorkPolicy() else { return false }
        return policy.permits(feature, trigger: .automatic)
    }

    func saveBackgroundPolicy(_ policy: BackgroundWorkPolicy) {
        guard let stores else { return }
        do {
            var reviewed = policy
            reviewed.reviewed = true
            try stores.saveBackgroundWorkPolicy(reviewed)
            backgroundPolicy = reviewed
            let id = activityReporter?.begin(ActivityRun(category: .system,
                title: "Automatic work settings changed", stage: "Settings saved",
                executionLocation: "This Mac", dataDestination: "Local settings only"))
            if let id { activityReporter?.finish(id: id, state: .succeeded,
                outcome: reviewed.paused ? "Automatic work paused" : "Only selected features may run automatically") }
            let previous = policyApplyTask
            policyApplyTask = Task { [weak self] in
                await previous?.value
                await self?.applyAutomaticWorkPolicy()
            }
        } catch {
            monitoringError = "Automatic work settings could not be saved. Nothing new was enabled."
        }
    }

    func toggleAutomaticWorkPause() {
        guard backgroundPolicy.reviewed else { return }
        var policy = backgroundPolicy
        policy.paused.toggle()
        saveBackgroundPolicy(policy)
    }

    func acknowledgeActivityRun(_ id: UUID) {
        do {
            try stores?.acknowledgeActivityRun(id: id)
            refreshMonitoring()
        } catch { monitoringError = "The review could not be saved. The original problem is retained." }
    }

    func applyAutomaticWorkPolicy() async {
        if !automaticWorkAllowed(.memory) { stopNightlyConsolidationScheduler() }
        else { startNightlyConsolidationScheduler() }
        if !automaticWorkAllowed(.routines) {
            routineSchedulerTask?.cancel()
            routineSchedulerTask = nil
        } else if let routineExecutor, routineSchedulerTask == nil {
            startCommandRoutineScheduler(using: routineExecutor)
        }
        for (key, feature) in [("archiveRecovery", BackgroundFeature.archiving),
                               ("routineReview", .routineReview)] where !automaticWorkAllowed(feature) {
            automaticTasks[key]?.cancel()
            automaticResumeHandled.remove(feature)
        }
        if !automaticWorkAllowed(.archiving) {
            for (key, task) in automaticTasks where key.hasPrefix("archive-") || key.hasPrefix("voiceArchive-") {
                task.cancel()
            }
        }
        await integrations?.applyBackgroundPolicy()
        scheduleApprovedBackgroundRecovery()
        refreshServiceConfiguration()
        refreshMonitoring()
    }

    private func scheduleApprovedBackgroundRecovery() {
        if automaticWorkAllowed(.archiving), let archiver, let stores,
           automaticTasks["archiveRecovery"] == nil,
           automaticResumeHandled.insert(.archiving).inserted {
            automaticTasks["archiveRecovery"] = Task { [weak self] in
                guard let self else { return }
                defer { automaticTasks["archiveRecovery"] = nil }
                do {
                    try await Task.sleep(for: .seconds(15))
                    guard automaticWorkAllowed(.archiving) else { return }
                    // Re-read the active IDs after the delay; never archive a
                    // conversation that became active while awaiting review.
                    var excluded: Set<UUID> = []
                    for key in ["chat.conversationID", "voice.conversationID"] {
                        if let raw = try stores.value(forKey: key), let id = UUID(uuidString: raw) { excluded.insert(id) }
                    }
                    _ = try await ActivityTaskContext.$trigger.withValue(.automatic) {
                        try await archiver.retryStoredConversations(excluding: excluded)
                    }
                    refreshSidebandData()
                } catch is CancellationError { }
                catch { reportBackgroundError(title: "Stored conversations could not be recovered", error: error) }
            }
        }
        if automaticWorkAllowed(.routineReview), let routineReviewer,
           automaticTasks["routineReview"] == nil,
           automaticResumeHandled.insert(.routineReview).inserted {
            automaticTasks["routineReview"] = Task { [weak self] in
                guard let self else { return }
                defer { automaticTasks["routineReview"] = nil }
                do {
                    try await ActivityTaskContext.$trigger.withValue(.automatic) {
                        try await routineReviewer.reviewPending()
                    }
                    refreshSidebandData()
                } catch is CancellationError { }
                catch { reportBackgroundError(title: "Routine review could not finish", error: error) }
            }
        }
    }

    func refreshServiceConfiguration() {
        guard let reporter = activityReporter, let stores else { return }
        let previous = (try? stores.serviceStatuses()) ?? []
        for feature in BackgroundFeature.allCases {
            let configured: Bool
            switch feature {
            case .notifications: configured = (try? stores.value(forKey: "notifications.enabled")) == "1"
            case .focus: configured = (try? stores.value(forKey: FocusCoach.enabledKey)) == "1"
            case .indexing: configured = !(integrations?.ragSourceConfigs.isEmpty ?? true)
            case .delivery: configured = (try? stores.value(forKey: "telegram.chatID"))?.isEmpty == false
            case .connectors: configured = integrations?.hasConfiguredAutomaticConnections == true
            case .routines: configured = ((try? stores.commandRoutines(includeDismissed: false)) ?? [])
                .contains { $0.status == "active" && $0.scheduleMinuteOfDay != nil }
            default: configured = true
            }
            let enabled = automaticWorkAllowed(feature)
            var status = previous.first { $0.id == feature.rawValue }
                ?? ServiceStatus(id: feature.rawValue, name: feature.monitoringTitle)
            status.configured = configured
            status.enabled = enabled && configured
            status.paused = !enabled
            if !enabled || !configured {
                status.stage = !backgroundPolicy.reviewed ? "Waiting for your review"
                    : !configured ? "Not configured"
                    : backgroundPolicy.paused ? "Automatic work paused" : "Off by your choice"
                status.nextOpportunity = nil
            } else if feature == .focus {
                status.stage = focusSessionActive ? "Observing this focus session" : "Ready; start a focus session explicitly"
            } else if feature == .memory {
                status.stage = nightlyScheduleDecision.reason
                status.nextOpportunity = nightlyScheduleDecision.nextEligibleAt
            } else {
                status.stage = "Enabled; runs only when due"
            }
            reporter.service(status)
        }
    }

    func reportBackgroundError(title: String, error: Error) {
        reportBackgroundError(title: title, message: "The operation could not finish. Review this feature's status before retrying.")
    }

    func reportBackgroundError(title: String, message: String) {
        if let parent = ActivityTaskContext.runID { failedOperationIDs.insert(parent) }
        if let id = activityReporter?.problem(title: title, outcome: message) { backgroundProblemRuns[title] = id }
    }

    func shutdownMonitoring() async {
        let runningTurn = currentTurn
        cancelTurn()
        await runningTurn?.value
        if let voiceActivityID { activityReporter?.update(id: voiceActivityID, stage: "Stopping voice for quit", state: .cancellationRequested) }
        await voice?.stop()
        let observation = voiceObservationTask
        observation?.cancel()
        await observation?.value
        voiceObservationTask = nil
        if let voiceActivityID { activityReporter?.finish(id: voiceActivityID, state: .cancelled, outcome: "Voice stopped for quit") }
        voiceActivityID = nil
        let nightlyTask = stopNightlyConsolidationScheduler()
        let routineTask = routineSchedulerTask
        routineTask?.cancel()
        routineSchedulerTask = nil
        let backgroundTasks = Array(automaticTasks.values)
        for task in backgroundTasks { task.cancel() }
        await integrations?.stopAutomaticWork()
        await nightlyTask?.value
        await routineTask?.value
        for task in backgroundTasks { await task.value }
        automaticTasks.removeAll()
    }

    func canStopActivityRun(_ run: ActivityRun) -> Bool {
        guard !run.state.isTerminal, run.state != .cancellationRequested else { return false }
        if run.id == nativeWorkspace.activeRunID { return true }
        if run.category == .capture, captureRefinement.isProcessing,
           run.referenceID == captureRefinement.activeArchiveID?.uuidString { return true }
        if run.category == .chat {
            if let turn = try? stores?.agentTurn(id: run.id) {
                return turn.state == .running && run.referenceID == turn.chatID.uuidString
            }
            return run.parentID == nil && isResponding && run.referenceID == localChatActivityReference
        }
        if run.id == voiceActivityID { return true }
        if run.category == .capture { return capture?.isActive == true }
        if run.category == .knowledge { return integrations?.isIndexing == true }
        if run.category == .model {
            return (run.referenceID != nil && run.referenceID == modelDownloads.activeModelID)
                || (run.title == "Install optional voice" && neuralVoiceInstaller.isInstalling)
        }
        return false
    }

    func cancelActivityRun(_ id: UUID) {
        guard let run = currentActivityRuns.first(where: { $0.id == id }), canStopActivityRun(run) else { return }
        if id == nativeWorkspace.activeRunID {
            nativeWorkspace.operations.cancelActive()
            return
        }
        activityReporter?.update(id: id, stage: "Stop requested; waiting for acknowledgement", state: .cancellationRequested)
        switch run.category {
        case .chat:
            if (try? stores?.agentTurn(id: id)) != nil, let manager = agentSessionManager {
                Task {
                    do { try await manager.stop(activityRunID: id) }
                    catch { monitoringError = "The response could not be stopped. Try Stop in its chat." }
                }
            } else { cancelTurn() }
        case .voice: if voiceEnabled { toggleVoice() }
        case .capture:
            if captureRefinement.isProcessing, run.referenceID == captureRefinement.activeArchiveID?.uuidString {
                captureRefinement.cancelActive()
            } else { toggleCapture() }
        case .knowledge: integrations?.cancelIndexing()
        case .model:
            if modelDownloads.activeModelID != nil { modelDownloads.cancelActive() }
            else { neuralVoiceInstaller.cancelActive() }
        default: break
        }
    }
}
