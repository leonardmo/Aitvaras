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
    let gitActions: AgentGitActionCoordinator
    private(set) var changes: ChangesState?
    private(set) var gitBusy = false
    private(set) var canDiscardChanges = false
    private let backends: [AgentProvider: any AgentBackend]
    private let signInCoordinator: ProviderSignIn
    private var selection = ChatSelectionState()
    private var settings: [String: AgentChatSession] = [:]
    private var approvalSubscription: Task<Void, Never>?
    private var respondingRequests: Set<String> = []
    private var observedModes: [UUID: (input: UUID?, mode: AgentMode)] = [:]
    private(set) var approvalSuggestions: [AgentApprovalSuggestion] = []
    private var subscription: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var loginToken: UUID?
    private var pendingExpiry: Task<Void, Never>?
    private var sending: [UUID: UUID] = [:]
    private var stopping: Set<UUID> = []
    private var stoppedSends: Set<UUID> = []
    private var attempts: [UUID: (input: AgentInput, provider: AgentProvider, accountID: String?)] = [:]
    private var composerSelections = AgentComposerSelections()
    private var handledFailures: Set<UUID> = []
    private(set) var state: ChatState?
    private var previewTask: Task<Void, Never>?
    private var refreshingHistory = Set<UUID>()
    private var refreshedInputs: [UUID: UUID] = [:]
    private(set) var discoveringNativeSessions = false
    private(set) var nativeDiscoveryError: String?
    var nativeDiscoveryFailed: Bool { nativeDiscoveryError != nil }
    var displayEntries: [AgentTranscriptEntry] { state?.entries ?? [] }
    func refreshNativePreview() async {
        guard let id = chatID, state?.isRunning != true else { return }
        guard refreshingHistory.insert(id).inserted else { return }
        defer { refreshingHistory.remove(id) }
        do {
            try await manager.refreshNativeHistory(chatID: id)
            guard !Task.isCancelled, chatID == id else { return }
            if error == "Native history could not be read." { error = nil }
        } catch AgentSessionManagerError.chatBusy { return }
        catch {
            guard !Task.isCancelled, chatID == id else { return }
            self.error = "Native history could not be read."
        }
    }
    var nativePreviewFailed: Bool { error == "Native history could not be read." }
    func discoverNativeSessions() async {
        guard !terminating, !discoveringNativeSessions else { return }
        discoveringNativeSessions = true; nativeDiscoveryError = nil
        defer { discoveringNativeSessions = false }
        for provider in [AgentProvider.claude, .codex] where backends[provider] != nil {
            do { _ = try await manager.discoverNativeSessions(provider: provider) }
            catch is CancellationError { return }
            catch AgentFailure.notInstalled { continue }
            catch AgentNativeHistoryError.identityConflict {
                nativeDiscoveryError = "Native chat ownership conflicts with project folders or worktrees. Check project folders, then refresh."
            }
            catch { nativeDiscoveryError = "Native history could not be refreshed. Retry." }
        }
    }
    private var terminating = false
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
        gitActions = AgentGitActionCoordinator(persistence: stores, audit: { _ = try stores.record($0) })
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
    var composerSelection: AgentComposerSelection {
        get { chatID.map { composerSelections[$0, provider] } ?? .init() }
        set {
            guard let id = chatID else { return }
            invalidatePending(); composerSelections[id, provider] = newValue
        }
    }
    var hasInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerSelection.attachments.isEmpty }
    var projectDirectory: URL? { settings[settingsKey].map { URL(fileURLWithPath: $0.cwd, isDirectory: true) } }

    func attach(_ url: URL, chatID: UUID, provider: AgentProvider) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let task = Task.detached { try AgentAttachment.read(url) }
        do {
            let file = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try addAttachment(file, chatID: chatID, provider: provider)
        } catch { attachmentFailed(error, chatID: chatID, provider: provider) }
    }
    func attach(data: Data, name: String, chatID: UUID, provider: AgentProvider) {
        do { try addAttachment(AgentAttachment(name: name, data: data), chatID: chatID, provider: provider) }
        catch { attachmentFailed(error, chatID: chatID, provider: provider) }
    }
    func attachmentLoadFailed(chatID: UUID, provider: AgentProvider) {
        attachmentFailed(AgentAttachmentError.missingFile, chatID: chatID, provider: provider)
    }
    private func addAttachment(_ file: AgentAttachment, chatID: UUID, provider: AgentProvider) throws {
        guard provider != .local else { throw AgentFailure.unsupported }
        if provider == .codex, file.kind == .pdf { throw AgentAttachmentError.unsupportedType }
        var value = composerSelections[chatID, provider]
        try value.add(file)
        composerSelections[chatID, provider] = value
        if self.chatID == chatID, self.provider == provider { invalidatePending(); error = nil }
    }
    private func attachmentFailed(_ failure: Error, chatID: UUID, provider: AgentProvider) {
        guard self.chatID == chatID, self.provider == provider, !(failure is CancellationError) else { return }
        switch failure as? AgentAttachmentError {
        case .tooLarge: error = "Attachments must total 512 KB or less."
        case .tooMany: error = "Attach up to 8 files."
        case .missingFile: error = "That file could not be read. Choose it again."
        default: error = "Use a text file or PNG, JPEG, GIF or WebP image\(provider == .claude ? ", or PDF." : ".")"
        }
    }
    func commands() async throws -> [AgentCommand] {
        guard let directory = projectDirectory, let backend = backends[provider] else { throw AgentFailure.unsupported }
        return try await backend.commands(directory: directory)
    }
    func files(query: String) async throws -> [AgentFileMention] {
        guard let directory = projectDirectory, let backend = backends[provider] else { throw AgentFailure.unsupported }
        return try await backend.files(query: query, directory: directory)
    }
    private func clearComposer(chatID: UUID, provider: AgentProvider, sent: AgentInput) {
        var value = composerSelections[chatID, provider]
        value.attachments.removeAll { file in sent.attachments.contains { $0.id == file.id } }
        value.mentions.removeAll { sent.mentions.contains($0) }
        if value.command == sent.command { value.command = nil }
        composerSelections[chatID, provider] = value
    }
    var isBusy: Bool { state?.isRunning == true || chatID.map { sending[$0] != nil || refreshingHistory.contains($0) } == true }
    var canSubmit: Bool {
        guard let id = chatID else { return false }
        return !terminating && !gitBusy && !refreshingHistory.contains(id) && !stopping.contains(id) && sending[id] == nil && signingIn == nil
            && (!isBusy || provider != .local)
    }
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
        previewTask?.cancel()
        // View changes cancel a browser flow and invalidate its automatic send.
        if loginToken != nil { cancelSignIn() }
        if let pending = try? stores.pendingSend(), pending.session.chatID != id { invalidatePending() }
        state = nil; error = nil; authProvider = nil; changes = nil; canDiscardChanges = false
        do {
            let saved = try id.flatMap { try stores.value(forKey: "agent.provider.\($0.uuidString)") }
            selection.select(id, provider: saved.flatMap(AgentProvider.init(rawValue:)) ?? .local)
            try loadSettings()
            if let pending = try stores.pendingSend(), pending.session.chatID == id {
                if selection.draft.isEmpty { selection.draft = pending.text }
                if pending.session.provider == provider,
                   let entry = try stores.agentEntries(chatID: pending.session.chatID).first(where: { $0.id == pending.inputID }) {
                    let input = try AgentInput.restoring(id: pending.inputID, text: pending.text, payload: entry.payloadJSON)
                    var value = composerSelection
                    value.attachments = input.attachments; value.mentions = input.mentions; value.command = input.command
                    composerSelections[pending.session.chatID, provider] = value
                }
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
        let folders = try stores.workspaceFolders(projectID: chat.projectID).map { URL(fileURLWithPath: $0.path) }
        let owned = try stores.agentWorktree(chatID: id)
        if try stores.requiresAgentWorktree(chatID: id), owned == nil { throw AgentGitError.creationFailed }
        let cwd = owned?.cwdPath ?? folders.first?.path ?? fallbackDirectory(id).path
        // Refresh identities while retaining unsent choices (which are saved immediately).
        settings[settingsKey] = try stores.agentSession(chatID: id, provider: provider)
            ?? AgentChatSession(chatID: id, provider: provider, cwd: cwd,
                                model: provider == .local ? "local" : "default")
        if settings[settingsKey]?.sessionID == nil { settings[settingsKey]?.cwd = cwd }
        let primary = URL(fileURLWithPath: settings[settingsKey]?.cwd ?? cwd).resolvingSymlinksInPath().standardizedFileURL.path
        settings[settingsKey]?.additionalRootsJSON = try owned?.additionalRootsJSON
            ?? String(decoding: JSONEncoder().encode(folders.filter {
                $0.resolvingSymlinksInPath().standardizedFileURL.path != primary
            }.map(\.path)), as: UTF8.self)
    }
    private func fallbackDirectory(_ id: UUID) -> URL {
        AitvarasPaths.stateDirectory.appendingPathComponent("AgentChats/\(id.uuidString)", isDirectory: true)
    }

    func refreshChanges() async {
        guard let owner = chatID, let directory = projectDirectory, !gitBusy else { return }
        do {
            let owned = try await gitActions.mapping(chatID: owner)
            let value = try await gitActions.changes(in: directory)
            guard chatID == owner, projectDirectory == directory else { return }
            changes = value; canDiscardChanges = owned?.worktreePath == value.directory.path
            if error == "Changes could not be refreshed." { error = nil }
        } catch is CancellationError { return }
        catch {
            guard chatID == owner else { return }
            // Keep the last review visible on a failed refresh; never mistake
            // an unavailable git command for a clean checkout.
            if changes != nil, self.error == nil { self.error = "Changes could not be refreshed." }
            canDiscardChanges = false
        }
    }
    func applyGitChanges(_ expected: ChangesState, owner: UUID, message: String?) async {
        guard chatID == owner, !isBusy, !gitBusy else { return }
        gitBusy = true
        do {
            if let message {
                try await gitActions.commit(chatID: owner, expected: expected, message: message, confirmed: true)
            } else {
                try await gitActions.discard(chatID: owner, expected: expected, confirmed: true)
            }
            if chatID == owner { error = nil }
        } catch {
            if chatID == owner {
                self.error = error as? AgentGitError == .staleChanges
                    ? "Files changed. Review the refreshed diff and try again."
                    : "Git operation failed. Review the files and try again."
            }
        }
        gitBusy = false
        await refreshChanges()
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
        guard let id = chatID, canSubmit, var session = settings[settingsKey],
              hasInput else { return }
        let text = draft, provider = provider, key = settingsKey
        let followup = state?.isRunning == true
        let composition = composerSelection
        let input = AgentInput(text: text, attachments: composition.attachments, mentions: composition.mentions, command: composition.command)
        invalidatePending(); sending[id] = input.id; error = nil; authProvider = nil
        attempts[input.id] = (input, provider, statuses[provider]?.accountID)
        if handledFailures.count > 128 { handledFailures.removeAll() }
        defer { if sending[id] == input.id { sending.removeValue(forKey: id) }; stoppedSends.remove(input.id) }
        do {
            guard let chat = try stores.workspaceChat(id: id), chat.archivedAt == nil,
                  let project = try stores.workspaceProject(id: chat.projectID), project.isVisible else { throw AgentFailure.invalidRequest }
            if followup {
                try await manager.send(chatID: id, provider: provider, input: input)
                attempts.removeValue(forKey: input.id)
                selection.clearDraft(chatID: id, ifUnchanged: text)
                clearComposer(chatID: id, provider: provider, sent: input)
                return
            }
            // Verification also rejects failed/incomplete creation after restart.
            _ = try await gitActions.mapping(chatID: id)
            session.instructions = try stores.workspaceContextPacket(chatID: id).promptText
            session.sessionID = try stores.agentSession(chatID: id, provider: provider)?.sessionID
            guard !stoppedSends.contains(input.id) else { return }
            if session.cwd == fallbackDirectory(id).path {
                try FileManager.default.createDirectory(atPath: session.cwd, withIntermediateDirectories: true)
            } else {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &directory), directory.boolValue else { throw AgentFailure.invalidRequest }
            }
            try await manager.configure(session)
            settings[key] = session
            guard !stoppedSends.contains(input.id) else { return }
            // Starting the manager first guarantees auth failures have a journal.
            try await manager.send(chatID: id, provider: provider, input: input)
            if !handledFailures.contains(input.id) {
                self.selection.clearDraft(chatID: id, ifUnchanged: text)
                clearComposer(chatID: id, provider: provider, sent: input)
            }
        } catch {
            if chatID == id, !stoppedSends.contains(input.id) {
                failed(inputID: input.id, failure: (error as? AgentFailure) ?? .unknown)
            }
        }
    }
    private func observe(_ state: ChatState) {
        if let mode = state.acknowledgedMode, let provider = state.entries.last?.provider,
           let chatID = self.chatID,
           observedModes[chatID]?.input != state.inputID || observedModes[chatID]?.mode != mode {
            observedModes[chatID] = (state.inputID, mode)
            if state.isRunning || (try? stores.agentSession(chatID: chatID, provider: provider))?.mode == mode {
                settings["\(chatID.uuidString).\(provider.rawValue)"]?.mode = mode
            }
        }
        if let provider = state.entries.last?.provider, !state.rateLimits.isEmpty { providerLimits[provider] = state.rateLimits }
        if case .failed(let failure) = state.outcome, let input = state.inputID { failed(inputID: input, failure: failure) }
        if !state.isRunning, let input = state.inputID, state.outcome == .completed { attempts.removeValue(forKey: input) }
        if !state.isRunning, state.outcome == .completed || state.outcome == .interrupted,
           let input = state.inputID, refreshedInputs[state.chatID] != input {
            refreshedInputs[state.chatID] = input
            previewTask = Task { [weak self] in await self?.refreshNativePreview() }
        }
    }
    private func failed(inputID: UUID, failure: AgentFailure) {
        guard !handledFailures.contains(inputID), let attempt = attempts.removeValue(forKey: inputID) else { return }
        handledFailures.insert(inputID)
        if selection.draft.isEmpty { selection.draft = attempt.input.text }
        if let id = chatID, provider == attempt.provider {
            var value = composerSelections[id, provider]
            if value.attachments.isEmpty { value.attachments = attempt.input.attachments }
            if value.mentions.isEmpty { value.mentions = attempt.input.mentions }
            if value.command == nil { value.command = attempt.input.command }
            composerSelections[id, provider] = value
        }
        authProvider = failure == .authRequired ? attempt.provider : nil
        error = failureMessage(failure, provider: attempt.provider)
        guard failure == .authRequired, let id = chatID, attempt.provider == provider else { return }
        do {
            guard let turn = try stores.agentTurn(id: inputID), turn.chatID == id, turn.delivery == .prepared, turn.resendCount == 0,
                  let session = try stores.agentSession(chatID: id, provider: provider) else { return }
            let pending = try PendingSend(inputID: inputID, text: attempt.input.text, session: session, accountID: attempt.accountID,
                                          hasAttachments: !attempt.input.attachments.isEmpty)
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
                    let value = self.composerSelection
                    let retryInput = AgentInput(id: pending.inputID, text: pending.text, attachments: value.attachments,
                                               mentions: value.mentions, command: value.command)
                    self.attempts[pending.inputID] = (retryInput, provider, self.statuses[provider]?.accountID)
                    retriedInput = pending.inputID
                    self.error = nil; self.authProvider = nil; self.signingIn = nil
                    // Login has finished. View changes and draft edits must no
                    // longer cancel the manager's now-owned delivery task.
                    self.loginToken = nil; self.loginTask = nil
                    self.sending[pending.session.chatID] = pending.inputID
                    defer {
                        if self.sending[pending.session.chatID] == pending.inputID {
                            self.sending.removeValue(forKey: pending.session.chatID)
                        }
                    }
                    // Retry shares the original ID; manager atomically claims it once.
                    try await self.manager.resendPrepared(turnID: pending.inputID)
                    if !self.handledFailures.contains(pending.inputID) {
                        self.selection.clearDraft(chatID: pending.session.chatID, ifUnchanged: pending.text)
                        self.clearComposer(chatID: pending.session.chatID, provider: provider, sent: retryInput)
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
        guard let id = chatID, stopping.insert(id).inserted else { return }
        defer { stopping.remove(id) }
        let pending = sending[id]
        if let pending { stoppedSends.insert(pending) }
        do { try await manager.stop(chatID: id) }
        catch { self.error = "The response could not be stopped." }
        if sending[id] == pending { sending.removeValue(forKey: id) }
    }
    func shutdown() async throws {
        terminating = true
        previewTask?.cancel()
        cancelSignIn(); stoppedSends.formUnion(sending.values)
        modelLoads.values.forEach { $0.task.cancel() }; modelLoads.removeAll()
        try await manager.shutdown()
        if let codex = backends[.codex] as? CodexBackend { try await codex.shutdown() }
    }
    func resumeAfterCancelledTermination() { terminating = false }
    func approvalContext(_ suggestion: AgentApprovalSuggestion) -> String {
        let title = (try? stores.workspaceChat(id: suggestion.chatID))?.title ?? "Chat"
        return "\(title) · \(suggestion.request.scope.session?.provider.rawValue.capitalized ?? "Agent")"
    }
    func respond(chatID: UUID, to request: AgentRequest, with response: AgentResponse) async -> Bool {
        guard respondingRequests.insert(request.identity).inserted else { return false }
        defer { respondingRequests.remove(request.identity) }
        do { try await manager.respond(chatID: chatID, to: request, with: response); return true }
        catch { return false }
    }
}
