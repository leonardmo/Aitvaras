import Foundation
import SwiftUI
import AppKit
import Observation
import AitvarasCore
import AitvarasStore
import AitvarasEngines
import AitvarasAgent
import AitvarasAgents
import AitvarasConnectors
import AitvarasVoice

/// One chat bubble in the UI.
struct DisplayMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id: UUID
    var role: Role
    var text: String = ""
    var reasoning: String = ""
    var toolNotes: [String] = []
    var isStreaming = false

    init(id: UUID = UUID(), role: Role, text: String = "", reasoning: String = "",
         toolNotes: [String] = [], isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.toolNotes = toolNotes
        self.isStreaming = isStreaming
    }
}

extension DisplayMessage.Role {
    init?(storedRole: String) {
        switch storedRole {
        case "user": self = .user
        case "assistant": self = .assistant
        default: return nil
        }
    }
}

/// Global app state and wiring (see ARCHITECTURE.md). Everything UI
/// observes lives here; heavy work stays in the actors it delegates to.
@MainActor
@Observable
final class AppModel {
    private static let newsArchived = true
    struct PresentedError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    struct RoutineExecutionBanner: Equatable {
        var title: String
        var steps: [String]
        var success: Bool
        var scheduled: Bool
    }

    static let shared = AppModel()

    // Core services — created in bootstrap.
    private(set) var stores: Stores?
    let keychain = KeychainStore()
    private(set) var router: EngineRouter?
    private(set) var captureOllamaModelName: String?
    private(set) var hub: ConnectorHub?
    private(set) var agentLoop: AgentLoop?
    private(set) var agentSessionManager: AgentSessionManager?
    private(set) var chatModel: ChatModel?
    private var localAgentReplyActive = false
    private(set) var voice: ConversationController?
    private(set) var neuralTTS: NeuralTTS?
    private(set) var integrations: IntegrationCoordinator?
    private(set) var archiver: ConversationArchiver?
    private(set) var consolidator: Consolidator?
    private(set) var routineExecutor: CommandRoutineExecutor?
    private(set) var routineReviewer: RoutineCloudReviewer?
    private(set) var capture: CaptureController?
    var activityReporter: ActivityReporter?
    var currentActivityRuns: [ActivityRun] = []
    var recentActivityRuns: [ActivityRun] = []
    var monitoredServices: [ServiceStatus] = []
    var backgroundPolicy = BackgroundWorkPolicy()
    var monitoringError: String?
    var monitoringReady = false
    var monitoringObserver: NSObjectProtocol?
    var automaticTasks: [String: Task<Void, Never>] = [:]
    var automaticResumeHandled: Set<BackgroundFeature> = []
    var policyApplyTask: Task<Void, Never>?
    var voiceActivityID: UUID?
    var voiceObservationTask: Task<Void, Never>?
    var monitoringFailureHandled = false
    var backgroundProblemRuns: [String: UUID] = [:]
    var failedOperationIDs: Set<UUID> = []
    let modelDownloads = ModelDownloadManager()
    let captureAudioArchives = CaptureAudioArchiveStore(profileDirectory: AitvarasPaths.stateDirectory)
    let captureRefinement = CaptureRefinementManager()
    let neuralVoiceInstaller = NeuralVoiceInstallManager()

    // UI state
    var messages: [DisplayMessage] = []
    var suggestions: [Suggestion] = []
    var activity: [ActivityEvent] = []
    var todaySnapshot: TodaySnapshot?
    var voiceSnapshot = VoiceSnapshot()
    var engineName = "…"
    var presentedError: PresentedError?
    var isResponding = false
    var voiceEnabled = false
    // Workspace identity is separate from native provider session identity.
    // Existing conversations remain unassigned until the user chooses otherwise.
    var workspaceProjects: [WorkspaceProject] = []
    var workspaceChats: [WorkspaceChat] = []
    var workspaceSidebarChats: [WorkspaceChat] = []
    var unassignedChatConversations: [Conversation] = []
    var selectedWorkspaceProjectID: UUID?
    var selectedWorkspaceChatID: UUID?
    var workspaceMessage: String?
    // Recent chats across every visible project, for the rail's shared view.
    var recentWorkspaceChats: [RecentWorkspaceChat] = []
    // Read-only native history discovery and saved snapshots.
    let nativeWorkspace = NativeWorkspaceModel()
    let codexWorkspace = CodexWorkspaceModel()
    let claudeWorkspace = ClaudeWorkspaceModel()
    let codexNativeWorkspace = CodexNativeWorkspaceModel()
    var microphoneInUseByVoice: Bool { voiceEnabled || voiceTransitioning }
    var companionPresentation = CompanionPresentation.load() {
        didSet {
            guard companionPresentation != oldValue else { return }
            companionPresentation.save()
            NotificationCenter.default.post(name: .aitvarasCompanionPresentationChanged, object: nil)
        }
    }
    var newsTopics: [NewsTopic] = []
    var newsArticles: [NewsArticle] = []
    var selectedNewsTopicID: UUID?
    var newsIsRefreshing = false
    var newsRefreshMessage: String?
    var newsMorningPreferences = NewsMorningPreferences()
    var newsMorningPromptPresented = false
    var newsNarrationArticleID: UUID?
    var newsIsNarrating = false
    var commandRoutines: [CommandRoutine] = []
    var routineExecutionBanner: RoutineExecutionBanner?
    var nightlyScheduleDecision = NightlyScheduleDecision(
        state: .waiting, reason: "Nightly memory schedule is starting.")
    var nightlyLastSuccessfulRun: Date?
    var nightlyConsolidationRunning = false
    private var isRoutingTypedTurn = false

    /// Drives the companion avatar.
    var characterState: CharacterState {
        if voiceEnabled {
            switch voiceSnapshot.phase {
            case .idle: return .idle
            case .listening: return .listening
            case .routing: return .idle
            case .thinking: return .thinking
            case .speaking: return .speaking
            }
        }
        if isRoutingTypedTurn { return .idle }
        return isResponding ? .thinking : .idle
    }
    var mouthLevel: Float { voiceSnapshot.mouthLevel }

    private var bootstrapped = false
    private var bootstrapping = false
    var currentTurn: Task<Void, Never>?
    private var currentTurnID: UUID?
    private var currentAssistantID: UUID?
    var chatConversationID: UUID?
    nonisolated static let visibleChatMessageLimit = 200
    var earlierChatMessagesAreHidden = false
    private var voiceTransitioning = false
    private var voiceMicSessionActive = false
    private var wakeBriefingRunning = false
    private var newsSchedulerTask: Task<Void, Never>?
    var routineSchedulerTask: Task<Void, Never>?
    private var routineBannerTask: Task<Void, Never>?
    private var nightlySchedulerTask: Task<Void, Never>?
    private var nightlyOpportunityAt = Date()
    private var nightlyRetryNotBefore: Date?
    private var newsMorningAnswerExpiresAt: Date?
    private let newsImageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Synthetic UI states never initialize engines, connectors, microphones or
    /// a user's database. Only the isolated screenshot harness may call this.
    func prepareMonitoringFixture(_ scenario: String) throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        self.stores = stores
        let reporter = ActivityReporter(stores: stores)
        activityReporter = reporter
        nativeWorkspace.reporter = reporter
        let policy = BackgroundWorkPolicy(reviewed: scenario != "review", paused: scenario == "paused",
                                          allowed: scenario == "review" ? [] : [.indexing, .memory])
        try stores.saveBackgroundWorkPolicy(policy)
        reporter.service(ServiceStatus(id: "indexing", name: "Folder indexing", configured: true,
            enabled: policy.allowed.contains(.indexing), paused: policy.paused,
            stage: policy.paused ? "Paused" : "Waiting for file changes", lastSuccess: .now.addingTimeInterval(-600)))
        reporter.service(ServiceStatus(id: "memory", name: "Memory maintenance", configured: true,
            enabled: policy.allowed.contains(.memory), paused: policy.paused,
            stage: policy.paused ? "Paused" : "Scheduled opportunity", nextOpportunity: .now.addingTimeInterval(3600)))
        if scenario == "active" || scenario == "waiting" {
            let id = reporter.begin(ActivityRun(category: .knowledge, title: "Index study notes",
                stage: "Scanning registered sources", executionLocation: "This Mac",
                dataAccess: "Selected notes folder", dataDestination: "Local search index"))
            reporter.update(id: id, stage: "Embedding changed notes", progressCompleted: 18, progressTotal: 42)
            reporter.begin(ActivityRun(category: .capture, title: "Save lecture capture", stage: "Saving transcript",
                executionLocation: "This Mac", dataDestination: "Local capture record"))
            reporter.begin(ActivityRun(category: .connection, state: .awaitingApproval,
                title: "Calendar action", stage: "Awaiting your approval", executionLocation: "Not started",
                dataAccess: "Proposed calendar event", dataDestination: "Local calendar"))
        }
        let finished = reporter.begin(ActivityRun(category: .capture, title: "Summarize saved capture",
            stage: "Reading saved transcript", startedAt: .now.addingTimeInterval(-1800),
            executionLocation: "This Mac", dataAccess: "Selected capture", dataDestination: "Local summary"))
        reporter.update(id: finished, stage: "Preparing summary")
        reporter.finish(id: finished, state: .succeeded, outcome: "Transcript and summary saved")
        if scenario == "failure" {
            let id = reporter.begin(ActivityRun(category: .connection, title: "Check enabled connection", stage: "Connecting"))
            reporter.finish(id: id, state: .failed, outcome: "Connection unavailable. No external changes were made.")
        }
        todaySnapshot = try stores.todaySnapshot()
        refreshMonitoring()
        if scenario == "startup" { monitoringReady = false }
        if scenario == "unavailable" { monitoringError = "Activity monitoring is unavailable. Automatic work is suspended." }
        bootstrapped = true
    }

    func prepareSyntheticCapturePreview() throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        guard let stores else { throw CocoaError(.fileNoSuchFile) }
        let router = EngineRouter(ranked: [], stores: stores, reporter: activityReporter)
        let controller = CaptureController(stores: stores,
            summarizer: CaptureSummarizer(router: router, stores: stores, reporter: activityReporter), model: self)
        capture = controller
        controller.prepareSyntheticPreview()
        refreshMonitoring()
    }

    func bootstrapIfNeeded() async {
        guard !bootstrapped, !bootstrapping else { return }
        bootstrapping = true
        defer { bootstrapping = false }
        var startupID: UUID?
        // Remove the short diagnostic WAV written by older builds before any
        // normal bootstrap path can return early.
        VoiceLog.removeLegacySensitiveArtifacts()
        do {
            let db = try AitvarasDatabase()
            let stores = Stores(db: db)
            self.stores = stores
            let reporter = ActivityReporter(stores: stores)
            activityReporter = reporter
            monitoringFailureHandled = false
            reporter.recoverInterruptedRuns()
            try codexWorkspace.configure(stores: stores, reporter: reporter)
            try claudeWorkspace.configure(stores: stores, reporter: reporter)
            try codexNativeWorkspace.configure(stores: stores, reporter: reporter)
            backgroundPolicy = try stores.backgroundWorkPolicy()
            startupID = reporter.begin(ActivityRun(
                category: .startup, trigger: .startup, title: "Starting Aitvaras",
                stage: "Restoring saved conversations", executionLocation: "This Mac",
                dataAccess: "Local app settings and saved history", dataDestination: "This Mac only"))
            installMonitoringObserver()
            refreshMonitoring()
            await ActivityTaskContext.$runID.withValue(startupID) { await prepareCaptureAudioArchives() }

            let chatConversationID = try Self.chatConversationID(stores: stores)
            self.chatConversationID = chatConversationID
            let chatMessageCount = try stores.messageCount(in: chatConversationID)
            messages = try stores.messages(
                in: chatConversationID, limit: Self.visibleChatMessageLimit).compactMap { stored in
                guard let role = DisplayMessage.Role(storedRole: stored.role) else { return nil }
                return DisplayMessage(id: stored.id, role: role, text: stored.content)
            }
            earlierChatMessagesAreHidden = chatMessageCount > Self.visibleChatMessageLimit
            restoreWorkspaceSelection()

            // Testing seam (TESTING.md): `--seed-demo-state` fills an EMPTY
            // profile with the fictional demo persona. Combine with
            // AITVARAS_STATE_DIR for a throwaway profile; a database that
            // already has facts is never touched.
            if CommandLine.arguments.contains("--seed-demo-state") {
                _ = try? StateFixtures.seedDemoProfile(into: stores)
            }

            let mlx = MLXEngine(reportLoad: { event in
                switch event {
                case .started(let id, let model):
                    reporter.begin(ActivityRun(id: id, referenceID: model, category: .model,
                        title: "Prepare local model", stage: "Loading weights into memory",
                        executionLocation: "This Mac", dataAccess: "Installed model files", dataDestination: "This Mac only"))
                case .finished(let id, let succeeded):
                    reporter.finish(id: id, state: succeeded ? .succeeded : .failed,
                        outcome: succeeded ? "Local model is ready" : "Model preparation stopped or failed")
                }
            })
            let ollama = OllamaEngine()
            self.captureOllamaModelName = await ollama.configuredModelName
            let router = EngineRouter(ranked: [mlx, ollama], stores: stores, reporter: reporter)
            self.router = router
            let hub = ConnectorHub(stores: stores, policy: loadPolicy(), reporter: reporter)
            self.hub = hub

            // Capture mode (F12) — created before connector registration so
            // the capture tools can attach to it.
            self.capture = CaptureController(
                stores: stores,
                summarizer: CaptureSummarizer(router: router, stores: stores, reporter: reporter),
                model: self)

            let integrations = IntegrationCoordinator(
                stores: stores, keychain: keychain, hub: hub, router: router, reporter: reporter)
            self.integrations = integrations
            await integrations.registerAll()

            // Both wrappers resolve their feature setting at call time. Keep
            // them wired permanently so provider changes apply immediately.
            let routineReviewer = RoutineCloudReviewer(stores: stores, reporter: reporter)
            self.routineReviewer = routineReviewer

            let agentLoop = AgentLoop(
                router: router, hub: hub, stores: stores,
                retriever: integrations.retriever,
                routineReviewer: routineReviewer, reporter: reporter)
            self.agentLoop = agentLoop
            try await bootstrapAgentChats(stores: stores, agentLoop: agentLoop)
            integrations.attach(agentLoop: agentLoop)
            let routineExecutor = CommandRoutineExecutor(hub: hub, stores: stores, reporter: reporter)
            self.routineExecutor = routineExecutor
            let archiver = ConversationArchiver(router: router, stores: stores, reporter: reporter)
            self.archiver = archiver

            // The sleeping brain (K2): 04:00 is a logical daily boundary, not
            // a wake alarm. The scheduler catches up after launch/wake, waits
            // for the machine to settle, and uses a half-hour poll as backup.
            let cliEngine = CLIBackgroundEngine(stores: stores, reporter: reporter)
            let consolidator = Consolidator(
                router: router, stores: stores, preferredEngine: cliEngine,
                routineReviewer: routineReviewer, reporter: reporter)
            self.consolidator = consolidator
            startNightlyConsolidationScheduler()
            NotificationCenter.default.addObserver(
                forName: .aitvarasActivityChanged, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AppModel.shared.refreshSidebandData() }
            }
            NotificationCenter.default.addObserver(
                forName: .aitvarasFocusChanged, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in
                    AppModel.shared.focusSessionActive =
                        AppModel.shared.integrations?.focusCoach?.isSessionActive ?? false
                }
            }

            let neuralTTS = NeuralTTS(
                serverScriptURL: Bundle.main.url(forResource: "tts_server", withExtension: "py"))
            self.neuralTTS = neuralTTS
            let cleanupID = reporter.begin(ActivityRun(parentID: startupID, category: .startup,
                trigger: .startup, title: "Check local voice helper", stage: "Cleaning up an unused helper",
                executionLocation: "This Mac", dataAccess: "App-owned helper state", dataDestination: "This Mac only"))
            automaticTasks["voiceHelperCleanup"] = Task { [weak self] in
                defer { self?.automaticTasks["voiceHelperCleanup"] = nil }
                await neuralTTS.cleanupUnownedServer()
                reporter.finish(id: cleanupID, state: Task.isCancelled ? .cancelled : .succeeded,
                    outcome: "Local helper cleanup ended; no model was prewarmed")
            }
            let voice = ConversationController(
                locale: { Locale(identifier: AitvarasPreferences.current.string(forKey: "voice.locale") ?? "en-US") },
                tts: neuralTTS,
                respond: { [stores] history, text in
                    Self.voiceRespond(
                        agentLoop: agentLoop, routineExecutor: routineExecutor,
                        stores: stores, history: history, text: text)
                })
            self.voice = voice
            engineName = MLXEngine.installedModels().isEmpty ? "Not checked" : "Local models available"
            refreshSidebandData()
            observeVoice()
            await integrations.startEventPump()
            startCommandRoutineScheduler(using: routineExecutor)
            bootstrapped = true
            reporter.finish(id: startupID!, state: .succeeded, outcome: "Ready. Optional automatic work follows your reviewed settings.")
            await applyAutomaticWorkPolicy()
            refreshMonitoring()
        } catch {
            if let startupID { activityReporter?.finish(id: startupID, state: .failed, outcome: "Startup did not finish. Retry is available.") }
            monitoringError = "Startup did not finish. Retry startup from Home."
            await integrations?.stopAutomaticWork()
            presentError(title: "Aitvaras could not start", error: error)
        }
    }

    func presentError(title: String, message: String) {
        presentedError = PresentedError(title: title, message: message)
        NotificationRouter.requestedWorkNeedsAttention()
    }

    func presentError(title: String, error: Error) {
        presentError(title: title, message: error.localizedDescription)
    }

    // MARK: Chat

    @discardableResult
    private func bootstrapAgentChats(stores: Stores, agentLoop: AgentLoop) async throws {
        let inherited = ProcessInfo.processInfo.environment
        let environment = try await Task.detached {
            try await ProviderEnvironment.resolve(inherited: inherited)
        }.value
        let isolated = AitvarasPaths.isIsolated
        let claude = ClaudeBackend(executable: AgentProviderLaunchPolicy.executable(.claude,
            environment: inherited, isolated: isolated), environment: environment,
            overrides: isolated && inherited["AITVARAS_FAKE_CLAUDE"] != nil
                ? ["CLAUDE_CONFIG_DIR": AitvarasPaths.stateDirectory.appendingPathComponent("FakeProviders/claude").path] : [:])
        let codex = CodexBackend(executable: AgentProviderLaunchPolicy.executable(.codex,
            environment: inherited, isolated: isolated), environment: environment)
        let localSelection = inherited["AITVARAS_LOCAL_CHAT_BACKEND"]
        if localSelection == "codex-oss",
           !AgentProviderLaunchPolicy.allows(.codex, environment: inherited, isolated: isolated) {
            throw AgentFailure.offline
        }
        let local = try LocalChatBackendFactory.make(selection: localSelection,
            executable: AgentProviderLaunchPolicy.executable(.codex, environment: inherited, isolated: isolated),
            environment: environment) { [weak self] configuration, input in
            guard let self else { throw AgentFailure.offline }
            return try await self.localAgentReply(agentLoop: agentLoop, configuration: configuration, input: input)
        }
        let backends: [AgentProvider: any AgentBackend] = [.claude: claude, .codex: codex, .local: local]
        let available = backends.filter { AgentProviderLaunchPolicy.allows($0.key, environment: inherited, isolated: isolated) }
        let manager = try AgentSessionManager(persistence: stores, backend: { provider in
            guard let backend = available[provider] else { throw AgentFailure.offline }
            return backend
        }, audit: { _ = try stores.record($0) })
        nativeWorkspace.readerFactory = { provider in
            NativeBackendSessionReader(provider: provider, backend: available[provider == .claude ? .claude : .codex])
        }
        agentSessionManager = manager
        chatModel = ChatModel(manager: manager, stores: stores, backends: available)
    }

    private func localAgentReply(agentLoop: AgentLoop, configuration: AgentSessionConfiguration,
                                 input: AgentInput) throws -> AsyncThrowingStream<String, Error> {
        guard !localAgentReplyActive, !isResponding, !microphoneInUseByVoice, !captureRefinement.isProcessing else {
            throw AgentFailure.invalidTransition
        }
        localAgentReplyActive = true
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                defer { self?.localAgentReplyActive = false }
                // A nonnil project context preserves the existing tool-free,
                // no-shared-memory project path. Catch-up is already in input.
                let stream = await agentLoop.run(history: [], userMessage: input.text,
                    referenceID: input.id.uuidString, projectTextContext: configuration.instructions)
                for await update in stream {
                    if Task.isCancelled { break }
                    switch update {
                    case .textDelta(let text): continuation.yield(text)
                    case .failed: continuation.finish(throwing: AgentFailure.offline); return
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdownAgentChats() async throws {
        try await chatModel?.shutdown()
    }

    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !selectedUnassignedVoiceHistory else {
            workspaceMessage = "Saved voice history is read-only here. Start a new chat to continue."
            return false
        }
        guard !captureRefinement.isProcessing else {
            presentError(title: "Local transcription is running", message: "Finish or stop the second pass before starting another AI conversation. Your draft is kept.")
            return false
        }
        guard trimmed.count <= AgentLoop.maximumUserMessageCharacters else {
            presentError(
                title: "Message is too long",
                message: "Keep chat messages under \(AgentLoop.maximumUserMessageCharacters.formatted()) characters. Add long documents or code folders in Knowledge so Aitvaras can retrieve only the relevant parts.")
            return false
        }
        guard !isResponding, let agentLoop,
              let stores, let conversationID = chatConversationID else { return false }
        let projectContext: String?
        do {
            // Resolve from durable identity, not a possibly stale UI snapshot.
            if let chat = try stores.workspaceChat(forConversationID: conversationID) {
                guard chat.archivedAt == nil,
                      chat.id == selectedWorkspaceChatID,
                      chat.projectID == selectedWorkspaceProjectID,
                      let project = try stores.workspaceProject(id: chat.projectID), project.isVisible else {
                    workspaceMessage = "Restore this chat or select an available project chat before sending."
                    return false
                }
                projectContext = try stores.workspaceContextPacket(chatID: chat.id).promptText
            } else {
                guard selectedWorkspaceProjectID == nil, selectedWorkspaceChatID == nil else {
                    workspaceMessage = "Choose a chat before sending."
                    return false
                }
                projectContext = nil
            }
        } catch {
            workspaceMessage = "Chat permissions could not be checked. Nothing was sent."
            return false
        }
        let history: [ChatMessage]
        do {
            if let chatID = selectedWorkspaceChatID {
                history = try stores.workspaceChatTimeline(chatID: chatID, limit: 40)
                    .filter { $0.state == nil || $0.state == .completed }
                    .suffix(20).compactMap { entry in
                        guard !entry.text.isEmpty, let role = ChatMessage.Role(rawValue: entry.role) else { return nil }
                        return ChatMessage(role: role, content: entry.text)
                    }
            } else { history = chatHistory() }
        } catch {
            workspaceMessage = "Chat history could not be loaded. Your message was not sent."
            return false
        }
        let user = StoredMessage(conversationID: conversationID, role: "user", content: trimmed)
        do {
            try stores.appendMessage(user)
        } catch {
            presentError(title: "Message was not sent", error: error)
            return false
        }
        messages.append(DisplayMessage(id: user.id, role: .user, text: trimmed))
        refreshWorkspaces()
        let assistant = DisplayMessage(role: .assistant, isStreaming: true)
        let assistantID = assistant.id
        let turnID = UUID()
        messages.append(assistant)
        trimVisibleChat()
        isResponding = true
        isRoutingTypedTurn = true
        currentTurnID = turnID
        currentAssistantID = assistantID

        currentTurn = Task { [weak self] in
            guard let self else { return }
            if projectContext == nil, let routineExecutor,
               let result = await routineExecutor.executeShortcut(
                matching: trimmed, channel: .typed) {
                guard !Task.isCancelled, self.currentTurnID == turnID else { return }
                if let index = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[index].toolNotes = [
                        "⚡ exact shortcut · no AI model",
                        result.stepNames.joined(separator: " → ")
                    ].filter { !$0.isEmpty }
                    self.messages[index].text = result.spokenText
                }
                self.showRoutineResult(result)
                self.finishStreaming(assistantID)
                self.persistAssistant(
                    assistantID, conversationID: conversationID, stores: stores)
                self.isResponding = false
                self.isRoutingTypedTurn = false
                self.currentTurn = nil
                self.currentTurnID = nil
                self.currentAssistantID = nil
                self.refreshSidebandData()
                return
            }
            self.isRoutingTypedTurn = false
            let stream = await agentLoop.run(history: history, userMessage: trimmed,
                referenceID: selectedWorkspaceChatID?.uuidString ?? conversationID.uuidString,
                projectTextContext: projectContext)
            for await update in stream {
                guard !Task.isCancelled, self.currentTurnID == turnID else { break }
                self.apply(update, to: assistantID)
            }
            guard !Task.isCancelled, self.currentTurnID == turnID else { return }
            self.finishStreaming(assistantID)
            self.persistAssistant(assistantID, conversationID: conversationID, stores: stores)
            self.isResponding = false
            self.currentTurn = nil
            self.currentTurnID = nil
            self.currentAssistantID = nil
            self.refreshSidebandData()
        }
        return true
    }

    func cancelTurn() {
        currentTurn?.cancel()
        isRoutingTypedTurn = false
        if let assistantID = currentAssistantID {
            finishStreaming(assistantID)
            if let stores, let conversationID = chatConversationID {
                persistAssistant(assistantID, conversationID: conversationID, stores: stores)
            }
        }
        currentTurn = nil
        currentTurnID = nil
        currentAssistantID = nil
        isResponding = false
    }

    private func persistAssistant(_ id: UUID, conversationID: UUID, stores: Stores) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            try stores.appendMessage(StoredMessage(
                id: id, conversationID: conversationID, role: "assistant", content: content))
            refreshWorkspaces()
        } catch {
            presentError(title: "Reply was not saved", error: error)
        }
    }

    private func apply(_ update: AgentUpdate, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        switch update {
        case .textDelta(let d): messages[idx].text += d
        case .reasoningDelta(let d): messages[idx].reasoning += d
        case .toolStarted(let name): messages[idx].toolNotes.append("→ \(name)")
        case .toolFinished(let name, _): messages[idx].toolNotes.append("✓ \(name)")
        case .confirmationRequested(let s):
            messages[idx].toolNotes.append("⏸ waiting for your approval: \(s.toolName)")
            refreshSidebandData()
        case .finished: break
        case .failed(let message):
            messages[idx].text += messages[idx].text.isEmpty
                ? "Something went wrong: \(message)" : "\n\n(\(message))"
        }
    }

    private func finishStreaming(_ id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].isStreaming = false
    }

    private func chatHistory() -> [ChatMessage] {
        messages.suffix(20).compactMap { m in
            guard !m.text.isEmpty else { return nil }
            return ChatMessage(role: m.role == .user ? .user : .assistant, content: m.text)
        }
    }

    func newChat() {
        guard !isWorkspaceSelectionBusy else {
            workspaceMessage = "Finish or stop the current conversation before creating another chat."
            return
        }
        if selectedWorkspaceProjectID != nil {
            createWorkspaceChat(title: "New chat", kind: .temporary, purpose: "")
            return
        }
        guard let stores, let previousID = chatConversationID else { return }
        do {
            chatConversationID = try stores.rotatePersistentConversation(
                forKey: Self.chatConversationKey, title: "Chat")
            messages.removeAll()
            earlierChatMessagesAreHidden = false
            archiveStoredConversation(previousID)
            refreshWorkspaces()
        } catch {
            presentError(title: "New chat could not be created", error: error)
        }
    }

    /// Flush the ending conversation into memory (episode + durable facts)
    /// before it disappears — fire-and-forget, never blocks the UI.
    func archiveCurrentChat() {
        guard let chatConversationID else { return }
        archiveStoredConversation(chatConversationID)
    }

    private func trimVisibleChat() {
        let overflow = messages.count - Self.visibleChatMessageLimit
        guard overflow > 0 else { return }
        messages.removeFirst(overflow)
        earlierChatMessagesAreHidden = true
    }

    private func archiveStoredConversation(_ id: UUID) {
        guard let archiver, automaticWorkAllowed(.archiving) else { return }
        guard automaticTasks["archive-\(id)"] == nil else { return }
        automaticTasks["archive-\(id)"] = Task {
            defer { automaticTasks["archive-\(id)"] = nil }
            do {
                let outcome = try await ActivityTaskContext.$trigger.withValue(.automatic) {
                    try await archiver.archiveStoredConversation(id: id)
                }
                if outcome.archived {
                    await MainActor.run { AppModel.shared.refreshSidebandData() }
                }
            } catch {
                await MainActor.run {
                    AppModel.shared.reportBackgroundError(
                        title: "Chat could not be archived", error: error)
                }
            }
        }
    }

    nonisolated private static let chatConversationKey = "chat.conversationID"

    nonisolated private static func chatConversationID(stores: Stores) throws -> UUID {
        try stores.persistentConversationID(forKey: chatConversationKey, title: "Chat")
    }

    // MARK: Voice

    func toggleVoice() {
        guard selectedWorkspaceProjectID == nil || voiceEnabled else {
            workspaceMessage = "Project voice conversations are not connected yet. Use text here, or switch to Unassigned for the existing voice mode."
            return
        }
        guard voiceEnabled || !captureRefinement.isProcessing else {
            presentError(title: "Local transcription is running", message: "Finish or stop the second pass before starting a voice conversation.")
            return
        }
        guard !voiceTransitioning, let voice else { return }
        voiceTransitioning = true
        Task {
            defer { voiceTransitioning = false }
            if voiceEnabled {
                let endedMicSession = voiceMicSessionActive
                voiceMicSessionActive = false
                await voice.stop()
                voiceEnabled = false
                if endedMicSession {
                    archiveCurrentVoiceConversation(delay: .milliseconds(500))
                }
            } else {
                await startVoiceSession(using: voice)
            }
        }
    }

    /// Give each mic activation its own durable History conversation. If a
    /// previous session contains turns, rotate first so it can be learned in
    /// the background without new speech changing its fingerprint.
    private func startVoiceSession(using voice: ConversationController) async {
        // Every entry point (including hold-to-talk and companion actions) must
        // respect the current scope before opening the microphone or rotating
        // legacy voice history. Project-scoped voice arrives in a later step.
        guard selectedWorkspaceProjectID == nil else {
            workspaceMessage = "Project voice conversations are not connected yet. Use text here, or switch to Unassigned for the existing voice mode."
            return
        }
        guard capture?.microphoneInUse != true else {
            presentError(title: "Microphone is in use", message: "Stop the microphone capture before starting a voice conversation.")
            return
        }
        guard let stores else { return }
        do {
            let previousID = try Self.voiceConversationID(stores: stores)
            if try !stores.messages(in: previousID).isEmpty {
                _ = try stores.rotatePersistentConversation(
                    forKey: Self.voiceConversationKey, title: "Voice")
                archiveVoiceConversation(previousID)
            }
            voiceEnabled = true
            voiceMicSessionActive = true
            voiceActivityID = activityReporter?.begin(ActivityRun(category: .voice,
                title: "Voice conversation", stage: "Starting microphone",
                executionLocation: "This Mac", dataAccess: "Microphone while explicitly enabled", dataDestination: "On-device speech recognition and local conversation"))
            await ActivityTaskContext.$runID.withValue(voiceActivityID) { await voice.start() }
            if !(await voice.isRunning) {
                voiceEnabled = false
                voiceMicSessionActive = false
                if let voiceActivityID { activityReporter?.finish(id: voiceActivityID, state: .failed, outcome: "Voice input could not start") }
                voiceActivityID = nil
            }
        } catch {
            voiceEnabled = false
            voiceMicSessionActive = false
            presentError(title: "Voice session could not be started", error: error)
        }
    }

    private func observeVoice() {
        guard let voice else { return }
        voiceObservationTask?.cancel()
        voiceObservationTask = Task { [weak self] in
            var previousPhase = VoicePhase.idle
            for await snapshot in await voice.states() {
                let sessionEnded = previousPhase != .idle && snapshot.phase == .idle
                let phaseChanged = previousPhase != snapshot.phase
                previousPhase = snapshot.phase
                self?.voiceSnapshot = snapshot
                if let self, let id = voiceActivityID {
                    if phaseChanged { activityReporter?.update(id: id, stage: "Voice: \(snapshot.phase)") }
                    if sessionEnded {
                        let stopped = (try? stores?.activityRun(id: id))?.state == .cancellationRequested
                        activityReporter?.finish(id: id, state: stopped ? .cancelled : .succeeded,
                            outcome: stopped ? "Microphone session stopped" : "Microphone session ended")
                        voiceActivityID = nil
                    }
                }
                // The controller can end the session itself (30s silence
                // timeout) — keep the mic button in sync.
                self?.voiceEnabled = snapshot.phase != .idle
                if sessionEnded, self?.voiceMicSessionActive == true {
                    self?.voiceMicSessionActive = false
                    // A cancelled reply may still be committing its atomic
                    // History turn, so let that short write settle first.
                    self?.archiveCurrentVoiceConversation(delay: .milliseconds(500))
                }
            }
        }
    }

    // MARK: Capture mode (F12)

    var captureActive: Bool { (capture?.canFinish ?? false) || (capture?.isFinishing ?? false) }

    func openCaptureSetup() {
        CaptureWindows.shared.showSetup(model: self)
    }

    /// Companion button: setup when idle, stop + show result when running.
    func toggleCapture() {
        guard let capture else { return }
        if capture.canFinish {
            Task {
                do {
                    if let record = try await capture.stop() {
                        CaptureWindows.shared.showResult(record: record, model: self)
                    }
                } catch {
                    CaptureWindows.shared.showSaveError(error)
                }
            }
        } else {
            openCaptureSetup()
        }
    }

    /// The `capture.stop_capture` tool: stop, show the result, tell the model.
    func stopCaptureFromTool() async -> String {
        guard let capture, capture.canFinish else {
            return "No capture session is running."
        }
        let record: CaptureRecord
        do {
            guard let saved = try await capture.stop() else {
                return "Capture ended — nothing was transcribed."
            }
            record = saved
        } catch {
            return "Capture ended, but its transcript could not be saved locally. Retry the stop action before starting another capture. Error: \(error.localizedDescription)"
        }
        CaptureWindows.shared.showResult(record: record, model: self)
        return record.summaryPending
            ? "Capture ended. The transcript is saved; the summary is pending."
            : record.summary.isEmpty ? "Capture ended. The transcript is saved without summary inference."
            : "Capture ended. Summary:\n\(record.summary.prefix(1500))"
    }

    /// Hotkey hold: ensure the session is running (never toggles off).
    func startVoiceViaHotkey() {
        guard selectedWorkspaceProjectID == nil else {
            workspaceMessage = "Project voice conversations are not connected yet. Use text here, or switch to Unassigned for the existing voice mode."
            return
        }
        guard !voiceEnabled, !voiceTransitioning, let voice else { return }
        voiceTransitioning = true
        Task {
            defer { voiceTransitioning = false }
            await startVoiceSession(using: voice)
        }
    }

    nonisolated private static func voiceRespond(
        agentLoop: AgentLoop, routineExecutor: CommandRoutineExecutor,
        stores: Stores, history: [ChatMessage], text: String
    ) -> AsyncStream<VoiceReply> {
        AsyncStream { continuation in
            let task = Task {
                var reply = ""
                var toolNotes: [String] = []
                if let morningReply = await MainActor.run(body: {
                    AppModel.shared.newsMorningVoiceReplyIfPending(for: text)
                }) {
                    continuation.yield(.delta(morningReply))
                    continuation.yield(.done)
                    do {
                        try Self.recordVoiceTurn(
                            stores: stores, user: text, assistant: morningReply)
                    } catch {
                        await MainActor.run {
                            AppModel.shared.presentError(
                                title: "Voice history was not saved", error: error)
                        }
                    }
                    await MainActor.run { AppModel.shared.refreshSidebandData() }
                    continuation.finish()
                    return
                }
                if let result = await routineExecutor.executeShortcut(
                    matching: text, channel: .voice) {
                    reply = result.spokenText
                    toolNotes = ["⚡ exact shortcut · no AI model"]
                        + result.stepNames.map { "✓ \($0)" }
                    continuation.yield(.delta(reply))
                    continuation.yield(.done)
                    do {
                        try Self.recordVoiceTurn(
                            stores: stores, user: text, assistant: reply,
                            toolNotes: toolNotes)
                    } catch {
                        await MainActor.run {
                            AppModel.shared.presentError(
                                title: "Voice history was not saved", error: error)
                        }
                    }
                    await MainActor.run {
                        AppModel.shared.showRoutineResult(result)
                        AppModel.shared.refreshSidebandData()
                    }
                    continuation.finish()
                    return
                }
                let responseTier = VoiceModelRouting.tier(for: text)
                continuation.yield(.modelThinking)
                let stream = await agentLoop.run(
                    history: history, userMessage: text, voiceMode: true,
                    tier: responseTier, referenceID: try? stores.value(forKey: Self.voiceConversationKey))
                for await update in stream {
                    switch update {
                    case .textDelta(let d):
                        reply += d
                        continuation.yield(.delta(d))
                    case .toolStarted(let name):
                        toolNotes.append("→ \(name)")
                    case .toolFinished(let name, _):
                        toolNotes.append("✓ \(name)")
                    case .confirmationRequested(let s):
                        toolNotes.append("⏸ awaiting approval: \(s.toolName)")
                    case .finished:
                        continuation.yield(.done)
                    case .failed(let message):
                        let failure = "I couldn't complete that. \(String(message.prefix(300)))"
                        reply += failure
                        continuation.yield(.delta(failure))
                        continuation.yield(.done)
                    default: break
                    }
                }
                // Every spoken exchange is persisted into the dedicated
                // voice conversation (own tab — the activity log stays
                // for tool calls and events).
                do {
                    try Self.recordVoiceTurn(
                        stores: stores, user: text, assistant: reply, toolNotes: toolNotes)
                } catch {
                    await MainActor.run {
                        AppModel.shared.presentError(
                            title: "Voice history was not saved", error: error)
                    }
                }
                await MainActor.run {
                    AppModel.shared.refreshSidebandData()
                    NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private static let voiceConversationKey = "voice.conversationID"

    /// The durable conversation for the current voice session.
    nonisolated static func voiceConversationID(stores: Stores) throws -> UUID {
        try stores.persistentConversationID(
            forKey: voiceConversationKey, title: "Voice")
    }

    /// Best-effort shutdown flush for completed turns in the current session.
    func archiveCurrentVoiceConversation(delay: Duration? = nil) {
        guard let stores,
              let raw = try? stores.value(forKey: Self.voiceConversationKey),
              let id = UUID(uuidString: raw) else { return }
        archiveVoiceConversation(id, delay: delay)
    }

    private func archiveVoiceConversation(_ id: UUID, delay: Duration? = nil) {
        guard let archiver, automaticWorkAllowed(.archiving) else { return }
        guard automaticTasks["voiceArchive-\(id)"] == nil else { return }
        automaticTasks["voiceArchive-\(id)"] = Task {
            defer { automaticTasks["voiceArchive-\(id)"] = nil }
            do {
                if let delay { try await Task.sleep(for: delay) }
                guard automaticWorkAllowed(.archiving) else { return }
                let outcome = try await ActivityTaskContext.$trigger.withValue(.automatic) {
                    try await archiver.archiveStoredConversation(id: id)
                }
                if outcome.archived {
                    await MainActor.run { AppModel.shared.refreshSidebandData() }
                }
            } catch is CancellationError {
                // App is shutting down.
            } catch {
                await MainActor.run {
                    AppModel.shared.reportBackgroundError(
                        title: "Voice conversation could not be archived", error: error)
                }
            }
        }
    }

    nonisolated private static func recordVoiceTurn(
        stores: Stores, user: String, assistant: String, toolNotes: [String] = []
    ) throws {
        let conversationID = try voiceConversationID(stores: stores)
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages = [StoredMessage(
            conversationID: conversationID, role: "user", content: cleanUser)]
        if !toolNotes.isEmpty {
            messages.append(StoredMessage(
                conversationID: conversationID, role: "tool",
                content: toolNotes.joined(separator: "\n")))
        }
        if !cleanAssistant.isEmpty {
            messages.append(StoredMessage(
                conversationID: conversationID, role: "assistant", content: cleanAssistant))
        }
        try stores.appendMessages(messages)
    }

    /// Bumped to move keyboard focus into the companion's text field
    /// (⌥Space double-tap).
    var companionFocusRequest = 0

    /// Typed prompt from the companion — answered with her voice.
    func askCompanion(_ text: String) {
        guard let voice else { return }
        Task { await voice.submitTyped(text) }
    }

    /// Proactive: bring Aitvaras on screen and have her speak (break/drift
    /// nudge, urgent message). No system notification.
    func announce(_ text: String) {
        NotificationCenter.default.post(name: .aitvarasShowCompanion, object: nil)
        guard let voice else { return }
        Task { await voice.announce(text) }
    }

    // MARK: News

    func refreshNewsState(topicID: UUID? = nil) {
        guard let stores else { return }
        do {
            newsTopics = try stores.newsTopics()
            let effectiveTopic = topicID ?? selectedNewsTopicID
            newsArticles = try stores.newsArticles(topicID: effectiveTopic, limit: 200)
            newsMorningPreferences = try stores.newsMorningPreferences()
        } catch {
            presentError(title: "News could not be loaded", error: error)
        }
    }

    func saveNewsTopic(_ topic: NewsTopic) {
        guard let stores else { return }
        do {
            let saved = try stores.saveNewsTopic(topic)
            selectedNewsTopicID = saved.id
            refreshNewsState(topicID: saved.id)
            refreshNews(topicID: saved.id)
        } catch {
            presentError(title: "News topic could not be saved", error: error)
        }
    }

    func deleteNewsTopic(_ id: UUID) {
        guard let stores else { return }
        do {
            try stores.deleteNewsTopic(id)
            if selectedNewsTopicID == id { selectedNewsTopicID = nil }
            refreshNewsState()
        } catch {
            presentError(title: "News topic could not be deleted", error: error)
        }
    }

    func setNewsMorningPreferences(_ preferences: NewsMorningPreferences) {
        guard let stores else { return }
        do {
            try stores.setNewsMorningPreferences(preferences)
            newsMorningPreferences = preferences
        } catch {
            presentError(title: "Morning news setting could not be saved", error: error)
        }
    }

    func refreshNews(topicID: UUID? = nil) {
        guard !Self.newsArchived else {
            newsRefreshMessage = "News is archived. Saved data is preserved; automatic refresh and narration are disabled."
            return
        }
        guard !newsIsRefreshing, let service = integrations?.news else {
            if integrations?.externalIntegrationsDisabled == true {
                newsRefreshMessage = "External integrations are disabled for this profile."
            }
            return
        }
        newsIsRefreshing = true
        newsRefreshMessage = nil
        Task {
            defer { newsIsRefreshing = false }
            do {
                let topics: [NewsTopic]
                if let topicID {
                    topics = newsTopics.filter { $0.id == topicID && $0.isEnabled }
                } else {
                    topics = newsTopics.filter(\.isEnabled)
                }
                guard !topics.isEmpty else {
                    newsRefreshMessage = "Add and enable a topic first."
                    return
                }
                var accepted = 0
                var unavailable: Set<String> = []
                var failedTopics: [String] = []
                for topic in topics {
                    do {
                        let result = try await service.refresh(topic: topic)
                        accepted += result.acceptedArticles
                        unavailable.formUnion(result.sourceFailures)
                    } catch {
                        failedTopics.append(topic.name)
                    }
                }
                refreshNewsState(topicID: topicID ?? selectedNewsTopicID)
                if failedTopics.count == topics.count {
                    throw NSError(
                        domain: "AitvarasNews", code: 1,
                        userInfo: [NSLocalizedDescriptionKey:
                            "No topic could be refreshed. Check the internet connection and try again."])
                }
                newsRefreshMessage = if !failedTopics.isEmpty {
                    "Updated with \(accepted) stories. Could not refresh: \(failedTopics.joined(separator: ", "))."
                } else if !unavailable.isEmpty {
                    "Updated with \(accepted) stories. Some sources were temporarily unavailable."
                } else {
                    "Updated with \(accepted) curated stories."
                }
            } catch {
                newsRefreshMessage = error.localizedDescription
                presentError(title: "News could not be refreshed", error: error)
            }
        }
    }

    func selectNewsTopic(_ id: UUID?) {
        selectedNewsTopicID = id
        refreshNewsState(topicID: id)
    }

    func markNewsArticleRead(_ id: UUID) {
        guard let stores else { return }
        do {
            try stores.markNewsArticleRead(id)
            if let index = newsArticles.firstIndex(where: { $0.id == id }) {
                newsArticles[index].isRead = true
            }
        } catch {
            presentError(title: "Article state could not be saved", error: error)
        }
    }

    func openNewsReader(topicID: UUID? = nil) {
        if let topicID { selectedNewsTopicID = topicID }
        refreshNewsState(topicID: selectedNewsTopicID)
        NotificationCenter.default.post(name: .aitvarasOpenNews, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeKey })?.makeKeyAndOrderFront(nil)
    }

    func newsImage(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let cached = newsImageCache.object(forKey: key) { return cached }
        guard let service = integrations?.news,
              let data = try? await service.imageData(for: url),
              let image = NSImage(data: data) else { return nil }
        newsImageCache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func readNewsBriefing(topicID: UUID? = nil) {
        dismissNewsMorningOffer()
        openNewsReader(topicID: topicID)
    }

    private func newsBriefingNarration() -> String? {
        let stories = newsArticles.prefix(5)
        guard !stories.isEmpty else { return nil }
        let topicByID = Dictionary(uniqueKeysWithValues: newsTopics.map { ($0.id, $0.name) })
        var sections: [String] = ["Here is your current news briefing."]
        for article in stories {
            let topic = topicByID[article.topicID].map { "For \($0). " } ?? ""
            sections.append(topic + article.narrationText)
        }
        return sections.joined(separator: " ")
    }

    func readNewsArticle(_ article: NewsArticle) {
        openNewsReader(topicID: article.topicID)
    }

    private func speakNews(_ text: String, articleID: UUID?) {
        guard let voice else { return }
        newsNarrationArticleID = articleID
        newsIsNarrating = true
        Task {
            await voice.announce(text)
            if newsNarrationArticleID == articleID {
                newsNarrationArticleID = nil
                newsIsNarrating = false
            }
        }
    }

    func stopNewsNarration() {
        newsNarrationArticleID = nil
        newsIsNarrating = false
        guard let voice else { return }
        Task { await voice.stopAnnouncement() }
    }

    private func startNewsScheduler() {
        guard !Self.newsArchived else { return }
        guard newsSchedulerTask == nil, integrations?.news != nil else { return }
        newsSchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let service = self.integrations?.news {
                    let refreshed = await service.refreshDue()
                    if !refreshed.isEmpty { self.refreshNewsState(topicID: self.selectedNewsTopicID) }
                }
                self.offerMorningNewsIfDue()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
    }

    private func offerMorningNewsIfDue(at date: Date = .now) {
        guard !Self.newsArchived else { return }
        guard let stores else { return }
        do {
            // Do not announce that a briefing is ready when every source is
            // unavailable and the isolated cache is still empty.
            guard try !stores.newsArticles(limit: 1).isEmpty else { return }
            guard try stores.claimMorningNewsOffer(at: date) else { return }
            newsMorningPromptPresented = true
            newsMorningAnswerExpiresAt = date.addingTimeInterval(4 * 60 * 60)
            announce("Good morning. Your news briefing is ready. Would you like to open and hear it?")
        } catch {
            // This is an optional prompt; a transient settings failure must
            // not become a second interruption of its own.
        }
    }

    func stopNewsScheduler() {
        newsSchedulerTask?.cancel()
        newsSchedulerTask = nil
    }

    func dismissNewsMorningOffer() {
        newsMorningPromptPresented = false
        newsMorningAnswerExpiresAt = nil
    }

    /// Resolve only an unambiguous yes/no to the one spoken morning question.
    /// Anything else continues through the normal voice agent unchanged.
    private func newsMorningVoiceReplyIfPending(for text: String, at date: Date = .now) -> String? {
        guard !Self.newsArchived else { return nil }
        guard let expires = newsMorningAnswerExpiresAt else { return nil }
        guard date <= expires else {
            dismissNewsMorningOffer()
            return nil
        }
        switch NewsMorningReplyIntent.classify(text) {
        case .decline:
            dismissNewsMorningOffer()
            return "No problem. Your news feed will stay ready whenever you want it."
        case .accept:
            dismissNewsMorningOffer()
            openNewsReader(topicID: selectedNewsTopicID)
            return newsBriefingNarration()
                ?? "There are no stories in your news feed yet. You can refresh it in the News reader."
        case .unrelated:
            return nil
        }
    }

    // MARK: Nightly memory schedule

    func updateNightlySchedule(_ settings: NightlyScheduleSettings) {
        settings.save()
        restartNightlyConsolidationScheduler()
    }

    /// A wake is an opportunity rather than a demand to run immediately.
    /// The configured settling delay starts here; a poll remains the fallback.
    func noteNightlySchedulingOpportunity(at date: Date = .now) {
        nightlyOpportunityAt = date
        guard consolidator != nil else { return }
        restartNightlyConsolidationScheduler()
    }

    func runNightlyConsolidationNow() async {
        guard let consolidator, !nightlyConsolidationRunning else { return }
        nightlySchedulerTask?.cancel()
        nightlySchedulerTask = nil
        nightlyConsolidationRunning = true
        nightlyScheduleDecision = NightlyScheduleDecision(
            state: .ready, reason: "Updating memory now…")
        let outcome = await consolidator.run()
        nightlyConsolidationRunning = false
        if outcome.failed {
            nightlyRetryNotBefore = Date().addingTimeInterval(30 * 60)
            nightlyScheduleDecision = NightlyScheduleDecision(
                state: .waiting,
                reason: outcome.failureMessage
                    ?? "The memory update failed and will retry automatically.",
                nextEligibleAt: nightlyRetryNotBefore)
            presentError(
                title: "Nightly memory update could not finish",
                message: outcome.failureMessage
                    ?? "The update will retry automatically.")
        } else {
            nightlyRetryNotBefore = nil
            refreshSidebandData()
            await refreshNightlyScheduleStatus()
        }
        restartNightlyConsolidationScheduler()
    }

    @discardableResult
    func stopNightlyConsolidationScheduler() -> Task<Void, Never>? {
        let task = nightlySchedulerTask
        task?.cancel()
        nightlySchedulerTask = nil
        return task
    }

    func startNightlyConsolidationScheduler() {
        restartNightlyConsolidationScheduler()
    }

    private func restartNightlyConsolidationScheduler() {
        guard automaticWorkAllowed(.memory) else { return }
        guard !nightlyConsolidationRunning else { return }
        nightlySchedulerTask?.cancel()
        nightlySchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let nextCheck = await self.evaluateNightlyConsolidationSchedule()
                let seconds = min(
                    max(nextCheck.timeIntervalSinceNow, 1),
                    30 * 60)
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    return
                }
            }
        }
    }

    private func evaluateNightlyConsolidationSchedule(
        now: Date = .now
    ) async -> Date {
        guard automaticWorkAllowed(.memory), !Task.isCancelled else {
            return now.addingTimeInterval(30 * 60)
        }
        guard let consolidator else {
            return now.addingTimeInterval(30 * 60)
        }
        let lastRun: Date?
        do {
            lastRun = try await consolidator.lastSuccessfulRun()
            nightlyLastSuccessfulRun = lastRun
        } catch {
            nightlyScheduleDecision = NightlyScheduleDecision(
                state: .waiting,
                reason: "Schedule state is unavailable; Aitvaras will retry.",
                nextEligibleAt: now.addingTimeInterval(30 * 60))
            return now.addingTimeInterval(30 * 60)
        }

        if let retryAt = nightlyRetryNotBefore, now < retryAt {
            nightlyScheduleDecision = NightlyScheduleDecision(
                state: .waiting,
                reason: "The previous attempt failed; Aitvaras will retry.",
                nextEligibleAt: retryAt)
            return retryAt
        }

        let decision = NightlyConsolidationSchedule.decision(
            settings: .load(),
            lastSuccessfulRun: lastRun,
            opportunityAt: nightlyOpportunityAt,
            power: SystemPowerState.current(),
            now: now)
        nightlyScheduleDecision = decision

        guard decision.state == .ready, !nightlyConsolidationRunning else {
            return decision.nextEligibleAt ?? now.addingTimeInterval(30 * 60)
        }

        nightlyConsolidationRunning = true
        nightlyScheduleDecision = NightlyScheduleDecision(
            state: .ready,
            reason: "Updating memory now…",
            dailyBoundary: decision.dailyBoundary)
        let outcome = await ActivityTaskContext.$trigger.withValue(.automatic) {
            await consolidator.run(now: now)
        }
        nightlyConsolidationRunning = false

        if outcome.failed {
            // Automatic work never demands immediate attention. The failure
            // remains visible in Activity and Schedule, and the watermark is
            // retained for a later retry.
            let retryAt = Date().addingTimeInterval(30 * 60)
            nightlyRetryNotBefore = retryAt
            nightlyScheduleDecision = NightlyScheduleDecision(
                state: .waiting,
                reason: outcome.failureMessage
                    ?? "The memory update failed and will retry automatically.",
                nextEligibleAt: retryAt,
                dailyBoundary: decision.dailyBoundary)
            refreshSidebandData()
            return retryAt
        }

        nightlyRetryNotBefore = nil
        refreshSidebandData()
        await refreshNightlyScheduleStatus()
        return nightlyScheduleDecision.nextEligibleAt
            ?? Date().addingTimeInterval(30 * 60)
    }

    private func refreshNightlyScheduleStatus() async {
        guard let consolidator else { return }
        let now = Date()
        let lastRun = try? await consolidator.lastSuccessfulRun()
        nightlyLastSuccessfulRun = lastRun
        nightlyScheduleDecision = NightlyConsolidationSchedule.decision(
            settings: .load(),
            lastSuccessfulRun: lastRun,
            opportunityAt: nightlyOpportunityAt,
            power: SystemPowerState.current(),
            now: now)
    }

    // MARK: Wake briefing

    /// Persist the boundary before macOS suspends the process. This is kept in
    /// SQLite rather than memory so an app restart during sleep cannot erase
    /// the period that needs catching up.
    func noteSystemWillSleep(at date: Date = .now) {
        capture?.noteSystemWillSleep(at: date)
        guard let stores else {
            // Normal app bootstrap finishes long before a sleep notification,
            // but preserve the boundary during an unusually early sleep too.
            Task {
                await bootstrapIfNeeded()
                do { try self.stores?.noteSystemSleep(at: date) }
                catch { self.presentError(title: "Sleep time could not be saved", error: error) }
            }
            return
        }
        do {
            try stores.noteSystemSleep(at: date)
        } catch {
            presentError(title: "Sleep time could not be saved", error: error)
        }
    }

    /// Catch up replayable connectors, build a text-only count recap, consume
    /// its durable sleep boundary, and then present it through the companion.
    /// A duplicate macOS wake notification is harmless because completion and
    /// boundary consumption are one SQLite transaction.
    func handleSystemWake(at wokeAt: Date = .now) async {
        guard !wakeBriefingRunning else { return }
        wakeBriefingRunning = true
        defer { wakeBriefingRunning = false }

        await bootstrapIfNeeded()
        guard let stores, let integrations,
              BackgroundFeature.allCases.contains(where: { automaticWorkAllowed($0) }) else { return }
        do {
            guard let window = try stores.pendingWakeBriefingWindow(wokeAt: wokeAt) else {
                return
            }
            let refresh = await integrations.catchUpAfterWake(
                since: window.catchUpStartedAt)
            let briefing = try stores.wakeBriefing(
                since: window.catchUpStartedAt,
                sleepStartedAt: window.sleepStartedAt,
                preparedAt: .now,
                unavailableSources: refresh.unavailable,
                limitedSources: refresh.limited)
            try stores.completeWakeBriefing(briefing)
            refreshSidebandData()
            // Wake recaps are available in History, never unsolicited speech.
        } catch {
            // Keep the durable sleep boundary intact so the next activation
            // can retry; connector intake itself is replay-safe and deduped.
            reportBackgroundError(title: "Wake briefing could not be prepared", error: error)
        }
    }

    func setVoiceLanguage(_ identifier: String) {
        AitvarasPreferences.current.set(identifier, forKey: "voice.locale")
        guard let voice, voiceMicSessionActive, !voiceTransitioning else { return }
        voiceTransitioning = true
        Task {
            defer { voiceTransitioning = false }
            voiceMicSessionActive = false
            await voice.stop()
            voiceEnabled = false
            archiveCurrentVoiceConversation(delay: .milliseconds(500))
            await startVoiceSession(using: voice)
        }
    }

    // MARK: Suggestions & activity

    func setCloudAgentSelection(
        _ selection: CloudModelSelection,
        for feature: CloudAgentFeature
    ) {
        CloudAgentSettings.setSelection(selection, for: feature)
        guard feature == .routineReview,
              selection != .local,
              let routineReviewer, automaticWorkAllowed(.routineReview) else { return }
        // Enabling review should also pick up candidates learned while the
        // feature was local-only; no restart or new observation is required.
        Task {
            try? await ActivityTaskContext.$trigger.withValue(.automatic) {
                try await routineReviewer.reviewPending()
            }
            refreshSidebandData()
        }
    }

    func refreshSidebandData() {
        guard let stores else { return }
        do {
            let refreshedSuggestions = try stores.pendingSuggestions()
            let refreshedActivity = try stores.recentActivity(limit: 300)
            let refreshedToday = try stores.todaySnapshot()
            let refreshedRoutines = try stores.commandRoutines(includeDismissed: true)
            suggestions = refreshedSuggestions
            activity = refreshedActivity
            todaySnapshot = refreshedToday
            commandRoutines = refreshedRoutines
        } catch {
            // Preserve the last known UI instead of pretending durable state
            // became empty when the database is temporarily unavailable.
            presentError(title: "Activity could not be refreshed", error: error)
            return
        }
        // A voice/chat tool may have started or ended a focus session by
        // writing the flag — bring the coach tasks in line.
        integrations?.focusCoach?.reconcile()
        focusSessionActive = integrations?.focusCoach?.isSessionActive ?? false
        refreshMonitoring()
    }

    /// Mirrors the focus session for the companion overlay badge.
    var focusSessionActive = false

    func toggleFocusSession() {
        guard let coach = integrations?.focusCoach else { return }
        do {
            if coach.isSessionActive { try coach.endSession() } else { try coach.startSession() }
            focusSessionActive = coach.isSessionActive
        } catch {
            presentError(title: "Focus session could not be changed", error: error)
        }
    }

    func accept(_ suggestion: Suggestion) {
        guard let hub else { return }
        Task {
            do {
                _ = try await hub.executeSuggestion(suggestion)
            } catch {
                presentError(title: "Action could not be completed", error: error)
            }
            refreshSidebandData()
        }
    }

    func reject(_ suggestion: Suggestion) {
        guard let hub else { return }
        Task {
            do {
                try await hub.rejectSuggestion(suggestion)
            } catch {
                presentError(title: "Suggestion could not be dismissed", error: error)
            }
            refreshSidebandData()
        }
    }

    // MARK: Learned shortcuts & scheduled routines

    func saveCommandRoutine(_ routine: CommandRoutine) {
        guard let stores else { return }
        do {
            _ = try stores.saveCommandRoutine(routine)
            refreshSidebandData()
        } catch {
            presentError(title: "Routine could not be saved", error: error)
        }
    }

    func setCommandRoutineStatus(_ routine: CommandRoutine, to status: CommandRoutine.Status) {
        guard let stores else { return }
        do {
            try stores.setCommandRoutineStatus(routine.id, to: status)
            refreshSidebandData()
        } catch {
            presentError(title: "Routine could not be changed", error: error)
        }
    }

    func deleteCommandRoutine(_ routine: CommandRoutine) {
        guard let stores else { return }
        do {
            try stores.deleteCommandRoutine(routine.id)
            refreshSidebandData()
        } catch {
            presentError(title: "Routine could not be deleted", error: error)
        }
    }

    func startCommandRoutineScheduler(using executor: CommandRoutineExecutor) {
        guard automaticWorkAllowed(.routines) else { return }
        routineSchedulerTask?.cancel()
        routineSchedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.automaticWorkAllowed(.routines) == true else { return }
                let results = await executor.runDueSchedules()
                guard let self else { return }
                for result in results {
                    showRoutineResult(result)
                    if !result.success {
                        reportBackgroundError(
                            title: "Scheduled routine failed",
                            message: result.spokenText)
                    }
                }
                if !results.isEmpty { refreshSidebandData() }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func showRoutineResult(_ result: CommandRoutineExecutor.Result) {
        routineBannerTask?.cancel()
        routineExecutionBanner = RoutineExecutionBanner(
            title: result.title, steps: result.stepNames,
            success: result.success, scheduled: result.wasScheduled)
        if !result.wasScheduled { NotificationCenter.default.post(name: .aitvarasShowCompanion, object: nil) }
        routineBannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.routineExecutionBanner = nil
        }
    }

    // MARK: Autonomy whitelist

    private func loadPolicy() -> AutonomyPolicy {
        let raw = AitvarasPreferences.current.stringArray(forKey: "autonomy.whitelist") ?? []
        return AutonomyPolicy(whitelist: Set(raw))
    }

    func updateWhitelist(_ entries: Set<String>) {
        AitvarasPreferences.current.set(Array(entries).sorted(), forKey: "autonomy.whitelist")
        Task { await hub?.updatePolicy(AutonomyPolicy(whitelist: entries)) }
    }
}
