import Foundation
import Observation
import AppKit
import AitvarasCore
import AitvarasAgents
import AitvarasStore

/// Selection and presentation only. Runs belong to the application manager.
@MainActor @Observable
final class ChatModel {
    let manager: AgentSessionManager
    private let stores: Stores
    private let backends: [AgentProvider: any AgentBackend]
    private let signInCoordinator: ProviderSignIn
    private var selection = ChatSelectionState()
    private var settings: [String: AgentChatSession] = [:]
    private var approvalSubscription: Task<Void, Never>?
    private var respondingRequests: Set<String> = []
    private(set) var approvalSuggestions: [AgentApprovalSuggestion] = []
    private var subscription: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginToken: UUID?
    private var pendingExpiry: Task<Void, Never>?
    private var sending: Set<UUID> = []
    private var stoppedSends: Set<UUID> = []
    private var attempts: [UUID: (text: String, provider: AgentProvider, accountID: String?)] = [:]
    private var handledFailures: Set<UUID> = []
    private(set) var state: ChatState?
    private(set) var error: String?
    private(set) var authProvider: AgentProvider?
    private(set) var signingIn: AgentProvider?
    private(set) var statuses: [AgentProvider: AgentStatus] = [:]
    private(set) var catalogs: [AgentProvider: [AgentModel]] = [:]
    private(set) var providerLimits: [AgentProvider: [AgentRateLimitWindow]] = [:]
    private var modelLoads: [AgentProvider: (token: UUID, task: Task<[AgentModel], Error>)] = [:]

    init(manager: AgentSessionManager, stores: Stores, backends: [AgentProvider: any AgentBackend]) {
        self.manager = manager; self.stores = stores; self.backends = backends
        signInCoordinator = ProviderSignIn(persistence: stores)
        approvalSubscription = Task { [weak self, manager] in
            for await suggestions in await manager.approvalUpdates() {
                guard !Task.isCancelled, let self else { return }
                if self.approvalSuggestions != suggestions { self.approvalSuggestions = suggestions }
            }
        }
    }
    var chatID: UUID? { selection.chatID }
    var provider: AgentProvider { selection.provider }
    var draft: String {
        get { selection.draft }
        set {
            if newValue != selection.draft { invalidatePending() }
            selection.draft = newValue
        }
    }
    var isBusy: Bool { state?.isRunning == true || chatID.map { sending.contains($0) } == true }
    private var settingsKey: String { "\(chatID?.uuidString ?? "").\(provider.rawValue)" }
    var models: [AgentModel] { catalogs[provider] ?? [] }
    var selectedModel: AgentModel? { models.first { $0.id == model } }
    var model: String {
        get { settings[settingsKey]?.model ?? (provider == .local ? "local" : "default") }
        set {
            guard let value = models.first(where: { $0.id == newValue }), let session = settings[settingsKey], !isBusy else { return }
            saveSettings(ChatSettings.selecting(model: value, in: session))
        }
    }
    var effort: String {
        get { settings[settingsKey]?.effort ?? "" }
        set {
            guard !isBusy, newValue.isEmpty || selectedModel?.efforts.contains(newValue) == true,
                  var session = settings[settingsKey] else { return }
            session.effort = newValue.isEmpty ? nil : newValue; saveSettings(session)
        }
    }
    var mode: AgentMode {
        get { settings[settingsKey]?.mode ?? .ask }
        set {
            guard !isBusy, provider != .local, var session = settings[settingsKey] else { return }
            session.mode = newValue; saveSettings(session)
        }
    }
    private func saveSettings(_ session: AgentChatSession) {
        do {
            var value = session
            // The manager may have bound a native identity since the last Send.
            value.sessionID = try stores.agentSession(chatID: value.chatID, provider: value.provider)?.sessionID
            try stores.saveAgentSession(value)
            settings[settingsKey] = value; invalidatePending()
        } catch { self.error = "Chat settings could not be saved." }
    }

    func select(_ id: UUID?) {
        guard id != chatID else { return }
        subscription?.cancel()
        // View changes cancel a browser flow and invalidate its automatic send.
        if loginToken != nil { cancelSignIn() }
        if let pending = try? stores.pendingSend(), pending.session.chatID != id { invalidatePending() }
        state = nil; error = nil; authProvider = nil
        do {
            let saved = try id.flatMap { try stores.value(forKey: "agent.provider.\($0.uuidString)") }
            selection.select(id, provider: saved.flatMap(AgentProvider.init(rawValue:)) ?? .local)
            try loadSettings()
            if let pending = try stores.pendingSend(), pending.session.chatID == id {
                if selection.draft.isEmpty { selection.draft = pending.text }
                if pending.expiresAt > .now, pending.session.provider == provider {
                    authProvider = provider; error = "Sign in to \(provider.rawValue.capitalized)"
                    armPendingExpiry(pending)
                } else { try stores.savePendingSend(nil) }
            }
            guard let id else { return }
            subscription = Task { [weak self, manager] in
                do {
                    for await state in try await manager.updates(chatID: id) {
                        guard !Task.isCancelled, let self, self.chatID == id else { return }
                        self.state = state
                        self.observe(state)
                    }
                } catch { if self?.chatID == id { self?.error = "Chat history could not be loaded." } }
            }
        } catch { self.error = "Chat settings could not be loaded." }
    }

    func setProvider(_ value: AgentProvider) {
        guard let id = chatID, !isBusy, value != provider else { return }
        do {
            try selection.select(id, provider: value) {
                try stores.setValues(["agent.provider.\(id.uuidString)": value.rawValue])
            }
            invalidatePending(); try loadSettings(); error = nil; authProvider = nil
        } catch { self.error = "Provider selection could not be saved." }
    }

    private func loadSettings() throws {
        guard let id = chatID, let chat = try stores.workspaceChat(id: id) else { return }
        let cwd = try stores.workspaceFolders(projectID: chat.projectID).first?.path ?? fallbackDirectory(id).path
        // Refresh identities while retaining unsent choices (which are saved immediately).
        settings[settingsKey] = try stores.agentSession(chatID: id, provider: provider)
            ?? AgentChatSession(chatID: id, provider: provider, cwd: cwd,
                                model: provider == .local ? "local" : "default")
    }
    private func fallbackDirectory(_ id: UUID) -> URL {
        AitvarasPaths.stateDirectory.appendingPathComponent("AgentChats/\(id.uuidString)", isDirectory: true)
    }

    /// No browser or user message is initiated by opening Chat or Settings.
    func refreshStatus() async {
        for provider in [AgentProvider.claude, .codex, .local] {
            statuses[provider] = try? await backends[provider]?.status()
            if let codex = backends[provider] as? CodexBackend {
                providerLimits[provider] = try? await codex.rateLimits()
            }
        }
    }
    func loadModels() async {
        let provider = provider
        guard catalogs[provider] == nil, let backend = backends[provider] else { return }
        let load: (token: UUID, task: Task<[AgentModel], Error>)
        if let existing = modelLoads[provider] { load = existing }
        else {
            // View task cancellation must not strand the next chat's menu.
            load = (UUID(), Task {
                let status = try await backend.status()
                guard status.authentication == .subscription || status.authentication == .local else { return [] }
                return try await backend.models()
            })
            modelLoads[provider] = load
        }
        defer { if modelLoads[provider]?.token == load.token { modelLoads.removeValue(forKey: provider) } }
        do {
            let values = try await load.task.value
            guard modelLoads[provider]?.token == load.token, !values.isEmpty else { return }
            catalogs[provider] = values
            guard self.provider == provider, !isBusy, signingIn == nil, let first = values.first,
                  let session = settings[settingsKey], !values.contains(where: { $0.id == session.model }) else { return }
            saveSettings(ChatSettings.selecting(model: first, in: session))
        } catch { /* A real Send supplies the actionable failure. */ }
    }

    func send() async {
        guard let id = chatID, !isBusy, signingIn == nil, var session = settings[settingsKey],
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft, provider = provider, key = settingsKey
        let input = AgentInput(text: text)
        invalidatePending(); sending.insert(id); error = nil; authProvider = nil
        attempts[input.id] = (text, provider, statuses[provider]?.accountID)
        if handledFailures.count > 128 { handledFailures.removeAll() }
        defer { sending.remove(id); stoppedSends.remove(id) }
        do {
            guard let chat = try stores.workspaceChat(id: id), chat.archivedAt == nil,
                  let project = try stores.workspaceProject(id: chat.projectID), project.isVisible else { throw AgentFailure.invalidRequest }
            session.instructions = try stores.workspaceContextPacket(chatID: id).promptText
            session.sessionID = try stores.agentSession(chatID: id, provider: provider)?.sessionID
            guard !stoppedSends.contains(id) else { return }
            if session.cwd == fallbackDirectory(id).path {
                try FileManager.default.createDirectory(atPath: session.cwd, withIntermediateDirectories: true)
            } else {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directory), directory.boolValue else { throw AgentFailure.invalidRequest }
            }
            try await manager.configure(session)
            settings[key] = session
            guard !stoppedSends.contains(id) else { return }
            // Starting the manager first guarantees auth failures have a journal.
            try await manager.send(chatID: id, provider: provider, input: input)
            if !handledFailures.contains(input.id) { selection.clearDraft(chatID: id, ifUnchanged: text) }
        } catch {
            if chatID == id, !stoppedSends.contains(id) {
                failed(inputID: input.id, failure: (error as? AgentFailure) ?? .unknown)
            }
        }
    }
    private func observe(_ state: ChatState) {
        if let provider = state.entries.last?.provider, !state.rateLimits.isEmpty { providerLimits[provider] = state.rateLimits }
        if case .failed(let failure) = state.outcome, let input = state.inputID { failed(inputID: input, failure: failure) }
        if !state.isRunning, let input = state.inputID, state.outcome == .completed { attempts.removeValue(forKey: input) }
    }
    private func failed(inputID: UUID, failure: AgentFailure) {
        guard !handledFailures.contains(inputID), let attempt = attempts.removeValue(forKey: inputID) else { return }
        handledFailures.insert(inputID)
        if selection.draft.isEmpty { selection.draft = attempt.text }
        authProvider = failure == .authRequired ? attempt.provider : nil
        error = failureMessage(failure, provider: attempt.provider)
        guard failure == .authRequired, let id = chatID, attempt.provider == provider else { return }
        do {
            guard let turn = try stores.agentTurn(id: inputID), turn.chatID == id, turn.delivery == .prepared, turn.resendCount == 0,
                  let session = try stores.agentSession(chatID: id, provider: provider) else { return }
            let pending = try PendingSend(inputID: inputID, text: attempt.text, session: session, accountID: attempt.accountID)
            try stores.savePendingSend(pending)
            armPendingExpiry(pending)
        } catch { self.error = "Sign in to \(provider.rawValue.capitalized)" }
    }
    private func failureMessage(_ failure: AgentFailure, provider: AgentProvider) -> String {
        switch failure {
        case .authRequired: "Sign in to \(provider.rawValue.capitalized)"
        case .offline: "You’re offline. Your draft is kept."
        case .quota: "Usage limit reached. Try again later."
        case .notInstalled: "\(provider.rawValue.capitalized) is not installed."
        case .unsupported: "This provider configuration is unavailable."
        default: "Message could not be sent. Your draft is kept."
        }
    }
    private func armPendingExpiry(_ pending: PendingSend) {
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, pending.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard let self, let current = try? self.stores.pendingSend(), current.inputID == pending.inputID else { return }
            self.cancelSignIn()
            if self.chatID == pending.session.chatID {
                self.error = "Sign-in timed out. Your draft is kept."
                self.authProvider = pending.session.provider
            }
        }
    }
    private func invalidatePending() {
        pendingExpiry?.cancel(); pendingExpiry = nil
        if loginToken != nil { cancelSignIn() }
        do { try stores.savePendingSend(nil) }
        catch { self.error = "The waiting message could not be cleared." }
    }
    func signIn(_ provider: AgentProvider) {
        guard provider != .local, signingIn == nil, let backend = backends[provider] else { return }
        let token = UUID(), selectedChat = chatID
        loginToken = token; signingIn = provider
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.loginToken == token { self.loginToken = nil; self.signingIn = nil } }
            var retriedInput: UUID?
            do {
                try await self.signInCoordinator.signIn(backend: backend) { [weak self] url in
                    await self?.openSignInURL(url, token: token)
                }
                try Task.checkCancellation()
                guard self.loginToken == token else { return }
                let status = try await backend.status()
                try Task.checkCancellation()
                guard self.loginToken == token else { return }
                self.statuses[provider] = status
                guard status.authentication == .subscription else { throw AgentFailure.authRequired }
                self.catalogs[provider] = nil
                self.modelLoads.removeValue(forKey: provider)?.task.cancel()
                if let pending = try self.stores.pendingSend(), pending.session.provider == provider,
                   self.chatID == selectedChat, self.chatID == pending.session.chatID, self.provider == provider,
                   self.draft == pending.text, let turn = try self.stores.agentTurn(id: pending.inputID),
                   let session = try self.stores.agentSession(chatID: pending.session.chatID, provider: provider),
                   let chat = try self.stores.workspaceChat(id: pending.session.chatID), chat.archivedAt == nil,
                   try self.stores.workspaceProject(id: chat.projectID)?.isVisible == true {
                    _ = try await self.signInCoordinator.consume(inputID: pending.inputID, turn: turn, session: session, accountID: self.statuses[provider]?.accountID)
                    try Task.checkCancellation()
                    guard self.loginToken == token, self.chatID == selectedChat, self.provider == provider else { return }
                    self.pendingExpiry?.cancel(); self.pendingExpiry = nil
                    self.handledFailures.remove(pending.inputID)
                    self.attempts[pending.inputID] = (pending.text, provider, self.statuses[provider]?.accountID)
                    retriedInput = pending.inputID
                    self.error = nil; self.authProvider = nil; self.signingIn = nil
                    // Login has finished. View changes and draft edits must no
                    // longer cancel the manager's now-owned delivery task.
                    self.loginToken = nil; self.loginTask = nil
                    self.sending.insert(pending.session.chatID)
                    defer { self.sending.remove(pending.session.chatID) }
                    // Retry shares the original ID; manager atomically claims it once.
                    try await self.manager.resendPrepared(turnID: pending.inputID)
                    if !self.handledFailures.contains(pending.inputID) {
                        self.selection.clearDraft(chatID: pending.session.chatID, ifUnchanged: pending.text)
                    } else { return }
                } else { try self.stores.savePendingSend(nil) }
                guard self.chatID == selectedChat else { return }
                self.error = nil; self.authProvider = nil
            } catch {
                if retriedInput != nil {
                    guard self.chatID == selectedChat, self.provider == provider else { return }
                } else {
                    guard self.loginToken == token else { return }
                }
                try? self.stores.savePendingSend(nil)
                if (error as? ProviderSignInError) == .staleIntent {
                    self.error = nil; self.authProvider = nil
                } else if let retriedInput {
                    self.failed(inputID: retriedInput, failure: (error as? AgentFailure) ?? .unknown)
                } else {
                    self.error = error is CancellationError ? nil : "Sign-in did not complete. Your draft is kept."
                    self.authProvider = provider
                }
            }
        }
    }
    private func openSignInURL(_ url: URL, token: UUID) {
        guard loginToken == token else { return }
        NSWorkspace.shared.open(url)
    }
    func cancelSignIn() {
        pendingExpiry?.cancel(); pendingExpiry = nil
        loginToken = nil; loginTask?.cancel(); loginTask = nil; signingIn = nil
        do { try stores.savePendingSend(nil); error = nil; authProvider = nil }
        catch { self.error = "The waiting message could not be cleared." }
    }
    func stop() async {
        guard let id = chatID else { return }
        if sending.contains(id) { stoppedSends.insert(id) }
        do { try await manager.stop(chatID: id) }
        catch { self.error = "The response could not be stopped." }
    }
    func shutdown() async throws {
        cancelSignIn(); stoppedSends.formUnion(sending)
        modelLoads.values.forEach { $0.task.cancel() }; modelLoads.removeAll()
        try await manager.shutdown()
        if let codex = backends[.codex] as? CodexBackend { try await codex.shutdown() }
    }
    func approvalContext(_ suggestion: AgentApprovalSuggestion) -> String {
        let title = (try? stores.workspaceChat(id: suggestion.chatID))?.title ?? "Chat"
        return "\(title) · \(suggestion.request.scope.session?.provider.rawValue.capitalized ?? "Agent")"
    }
    func respond(chatID: UUID, to request: AgentRequest, with response: AgentResponse) async -> Bool {
        guard respondingRequests.insert(request.identity).inserted else { return false }
        defer { respondingRequests.remove(request.identity) }
        do { try await manager.respond(chatID: chatID, to: request, with: response); return true }
        catch {
            if case .questions = request.kind, self.chatID == chatID { self.error = "This request is no longer available." }
            return false
        }
    }
}
