import Foundation
import SwiftUI
import Observation
import AitvarasCore
import AitvarasStore
import AitvarasEngines
import AitvarasAgent
import AitvarasVoice

/// One chat bubble in the UI.
struct DisplayMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String = ""
    var reasoning: String = ""
    var toolNotes: [String] = []
    var isStreaming = false
}

/// Global app state and wiring (see ARCHITECTURE.md). Everything UI
/// observes lives here; heavy work stays in the actors it delegates to.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Core services — created in bootstrap.
    private(set) var stores: Stores?
    let keychain = KeychainStore()
    private(set) var router: EngineRouter?
    private(set) var hub: ConnectorHub?
    private(set) var agentLoop: AgentLoop?
    private(set) var voice: ConversationController?
    private(set) var neuralTTS: NeuralTTS?
    private(set) var integrations: IntegrationCoordinator?
    private(set) var archiver: ConversationArchiver?
    private(set) var consolidator: Consolidator?
    private(set) var capture: CaptureController?

    // UI state
    var messages: [DisplayMessage] = []
    var suggestions: [Suggestion] = []
    var activity: [ActivityEvent] = []
    var voiceSnapshot = VoiceSnapshot()
    var engineName = "…"
    var bootError: String?
    var isResponding = false
    var voiceEnabled = false

    /// Drives the companion avatar.
    var characterState: CharacterState {
        if voiceEnabled {
            switch voiceSnapshot.phase {
            case .idle: return .idle
            case .listening: return .listening
            case .thinking: return .thinking
            case .speaking: return .speaking
            }
        }
        return isResponding ? .thinking : .idle
    }
    var mouthLevel: Float { voiceSnapshot.mouthLevel }

    private var bootstrapped = false
    private var currentTurn: Task<Void, Never>?

    func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            let db = try AitvarasDatabase()
            let stores = Stores(db: db)
            self.stores = stores

            // Testing seam (TESTING.md): `--seed-demo-state` fills an EMPTY
            // profile with the fictional demo persona. Combine with
            // AITVARAS_STATE_DIR for a throwaway profile; a database that
            // already has facts is never touched.
            if CommandLine.arguments.contains("--seed-demo-state") {
                _ = try? StateFixtures.seedDemoProfile(into: stores)
            }

            let mlx = MLXEngine()
            let ollama = OllamaEngine()
            let router = EngineRouter(ranked: [mlx, ollama])
            self.router = router
            Task.detached {
                // Small model serves voice turns and triage — have it hot.
                await mlx.prewarm(tier: .voice)
            }

            let hub = ConnectorHub(stores: stores, policy: loadPolicy())
            self.hub = hub

            // Capture mode (F12) — created before connector registration so
            // the capture tools can attach to it.
            self.capture = CaptureController(
                stores: stores,
                summarizer: CaptureSummarizer(router: router, stores: stores),
                model: self)

            let integrations = IntegrationCoordinator(
                stores: stores, keychain: keychain, hub: hub, router: router)
            self.integrations = integrations
            await integrations.registerAll()

            let agentLoop = AgentLoop(
                router: router, hub: hub, stores: stores,
                retriever: integrations.retriever)
            self.agentLoop = agentLoop
            integrations.attach(agentLoop: agentLoop)
            self.archiver = ConversationArchiver(router: router, stores: stores)

            // The sleeping brain (K2): first opportunity after 04:00 local —
            // checked half-hourly because a closed MacBook runs nothing at
            // literal 4am. Failures land loudly in the activity log.
            let consolidator = Consolidator(router: router, stores: stores)
            self.consolidator = consolidator
            Task.detached(priority: .background) {
                while !Task.isCancelled {
                    let outcome = await consolidator.runIfDue()
                    if outcome.ran {
                        await MainActor.run { AppModel.shared.refreshSidebandData() }
                    }
                    try? await Task.sleep(for: .seconds(1800))
                }
            }

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
            let voice = ConversationController(
                locale: { Locale(identifier: UserDefaults.standard.string(forKey: "voice.locale") ?? "en-US") },
                tts: neuralTTS,
                respond: { [stores] history, text in
                    Self.voiceRespond(agentLoop: agentLoop, stores: stores, history: history, text: text)
                })
            self.voice = voice
            if NeuralTTS.isInstalled() {
                Task.detached { _ = await neuralTTS.ensureServer() }   // warm the model
            }

            engineName = await router.engineDescription(for: .chat)
            refreshSidebandData()
            observeVoice()
            await integrations.startEventPump()
        } catch {
            bootError = "Startup failed: \(error.localizedDescription)"
        }
    }

    // MARK: Chat

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let agentLoop else { return }
        let history = chatHistory()
        messages.append(DisplayMessage(role: .user, text: trimmed))
        var assistant = DisplayMessage(role: .assistant, isStreaming: true)
        let assistantID = assistant.id
        messages.append(assistant)
        isResponding = true

        currentTurn = Task { [weak self] in
            guard let self else { return }
            let stream = await agentLoop.run(history: history, userMessage: trimmed)
            for await update in stream {
                self.apply(update, to: assistantID)
            }
            self.finishStreaming(assistantID)
            self.isResponding = false
            self.refreshSidebandData()
        }
        _ = assistant
    }

    func cancelTurn() {
        currentTurn?.cancel()
        currentTurn = nil
        isResponding = false
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
        cancelTurn()
        archiveCurrentChat()
        messages = []
    }

    /// Flush the ending conversation into memory (episode + durable facts)
    /// before it disappears — fire-and-forget, never blocks the UI.
    func archiveCurrentChat() {
        guard let archiver else { return }
        let transcript = messages.compactMap { m -> ChatMessage? in
            guard !m.text.isEmpty else { return nil }
            return ChatMessage(role: m.role == .user ? .user : .assistant, content: m.text)
        }
        guard ConversationArchiver.isSubstantial(transcript) else { return }
        Task.detached(priority: .background) {
            let outcome = await archiver.archive(transcript: transcript)
            if outcome.archived {
                await MainActor.run { AppModel.shared.refreshSidebandData() }
            }
        }
    }

    // MARK: Voice

    func toggleVoice() {
        guard let voice else { return }
        Task {
            if voiceEnabled {
                await voice.stop()
                voiceEnabled = false
            } else {
                voiceEnabled = true
                await voice.start()
            }
        }
    }

    private func observeVoice() {
        guard let voice else { return }
        Task { [weak self] in
            for await snapshot in await voice.states() {
                self?.voiceSnapshot = snapshot
                // The controller can end the session itself (30s silence
                // timeout) — keep the mic button in sync.
                self?.voiceEnabled = snapshot.phase != .idle
            }
        }
    }

    // MARK: Capture mode (F12)

    var captureActive: Bool { capture?.isActive ?? false }

    func openCaptureSetup() {
        CaptureWindows.shared.showSetup(model: self)
    }

    /// Companion button: setup when idle, stop + show result when running.
    func toggleCapture() {
        guard let capture else { return }
        if capture.isActive {
            Task {
                if let record = await capture.stop() {
                    CaptureWindows.shared.showResult(record: record, model: self)
                }
            }
        } else {
            openCaptureSetup()
        }
    }

    /// The `capture.stop_capture` tool: stop, show the result, tell the model.
    func stopCaptureFromTool() async -> String {
        guard let capture, capture.isActive else {
            return "No capture session is running."
        }
        guard let record = await capture.stop() else {
            return "Capture ended — nothing was transcribed."
        }
        CaptureWindows.shared.showResult(record: record, model: self)
        return record.summaryPending
            ? "Capture ended. The transcript is saved; the summary is pending (no engine was available)."
            : "Capture ended. Summary:\n\(record.summary.prefix(1500))"
    }

    /// Hotkey hold: ensure the session is running (never toggles off).
    func startVoiceViaHotkey() {
        guard !voiceEnabled, let voice else { return }
        voiceEnabled = true
        Task { await voice.start() }
    }

    nonisolated private static func voiceRespond(
        agentLoop: AgentLoop, stores: Stores, history: [ChatMessage], text: String
    ) -> AsyncStream<VoiceReply> {
        AsyncStream { continuation in
            let task = Task {
                var reply = ""
                var toolNotes: [String] = []
                let stream = await agentLoop.run(
                    history: history, userMessage: text, voiceMode: true,
                    tier: .voice)
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
                    case .finished, .failed: continuation.yield(.done)
                    default: break
                    }
                }
                // Every spoken exchange is persisted into the dedicated
                // voice conversation (own tab — the activity log stays
                // for tool calls and events).
                Self.recordVoiceTurn(stores: stores, user: text, assistant: reply, toolNotes: toolNotes)
                await MainActor.run {
                    AppModel.shared.refreshSidebandData()
                    NotificationCenter.default.post(name: .aitvarasActivityChanged, object: nil)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The single long-lived conversation all voice turns append to.
    nonisolated static func voiceConversationID(stores: Stores) -> UUID {
        if let raw = try? stores.value(forKey: "voice.conversationID"),
           let id = UUID(uuidString: raw ?? "") {
            return id
        }
        let conversation = Conversation(title: "Voice")
        try? stores.saveConversation(conversation)
        try? stores.setValue(conversation.id.uuidString, forKey: "voice.conversationID")
        return conversation.id
    }

    nonisolated private static func recordVoiceTurn(
        stores: Stores, user: String, assistant: String, toolNotes: [String] = []
    ) {
        let conversationID = voiceConversationID(stores: stores)
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAssistant = assistant.trimmingCharacters(in: .whitespacesAndNewlines)
        try? stores.appendMessage(StoredMessage(
            conversationID: conversationID, role: "user", content: cleanUser))
        if !toolNotes.isEmpty {
            try? stores.appendMessage(StoredMessage(
                conversationID: conversationID, role: "tool", content: toolNotes.joined(separator: "\n")))
        }
        if !cleanAssistant.isEmpty {
            try? stores.appendMessage(StoredMessage(
                conversationID: conversationID, role: "assistant", content: cleanAssistant))
        }
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

    func setVoiceLanguage(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: "voice.locale")
        guard let voice, voiceEnabled else { return }
        Task {
            await voice.stop()
            await voice.start()
        }
    }

    // MARK: Suggestions & activity

    func refreshSidebandData() {
        guard let stores else { return }
        suggestions = (try? stores.pendingSuggestions()) ?? []
        activity = (try? stores.recentActivity(limit: 300)) ?? []
        // A voice/chat tool may have started or ended a focus session by
        // writing the flag — bring the coach tasks in line.
        integrations?.focusCoach?.reconcile()
        focusSessionActive = integrations?.focusCoach?.isSessionActive ?? false
    }

    /// Mirrors the focus session for the companion overlay badge.
    var focusSessionActive = false

    func toggleFocusSession() {
        guard let coach = integrations?.focusCoach else { return }
        if coach.isSessionActive { coach.endSession() } else { coach.startSession() }
        focusSessionActive = coach.isSessionActive
    }

    func accept(_ suggestion: Suggestion) {
        guard let hub else { return }
        Task {
            _ = await hub.executeSuggestion(suggestion)
            refreshSidebandData()
        }
    }

    func reject(_ suggestion: Suggestion) {
        guard let hub else { return }
        Task {
            await hub.rejectSuggestion(suggestion)
            refreshSidebandData()
        }
    }

    // MARK: Autonomy whitelist

    private func loadPolicy() -> AutonomyPolicy {
        let raw = UserDefaults.standard.stringArray(forKey: "autonomy.whitelist") ?? []
        return AutonomyPolicy(whitelist: Set(raw))
    }

    func updateWhitelist(_ entries: Set<String>) {
        UserDefaults.standard.set(Array(entries).sorted(), forKey: "autonomy.whitelist")
        Task { await hub?.updatePolicy(AutonomyPolicy(whitelist: entries)) }
    }
}
