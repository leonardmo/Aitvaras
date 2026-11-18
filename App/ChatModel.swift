import Foundation
import Observation
import AppKit
import AitvarasCore
import AitvarasAgents
import AitvarasStore
import AitvarasEngines

/// Selection and presentation only. Runs belong to the application manager.
@MainActor @Observable
final class ChatModel {
    let manager: AgentSessionManager
    private let stores: Stores
    let gitActions: AgentGitActionCoordinator
    let forgeActions: AgentForgeActionCoordinator
    private(set) var pullRequestBinding: AgentPullRequest?
    private(set) var pullRequest: ForgePullRequest?
    private(set) var pullRequestChecks: [ForgeCheck] = []
    private(set) var forgeError: String?
    private(set) var forgeBusy = false
    private(set) var forgeDraft: ForgeRequestDraft?
    private(set) var forgeKind: ForgeKind?
    private(set) var forgeNeedsSignIn = false
    private var forgeRefreshID: UUID?
    let conversationActions: AgentConversationActions
    private(set) var changes: ChangesState?
    private(set) var gitBusy = false
    private(set) var branchStatus: GitBranchStatus?
    private(set) var pushDisabledReason: String? = "Refresh branch status first."
    private(set) var gitError: String?
    private(set) var canDiscardChanges = false
    private let claudeDefaultDirectory: URL
    private let profileBackends: AgentProfileBackends?
    private(set) var claudeProfiles: [AgentProviderProfile] = []
    private(set) var claudeProfile = "default"
    private(set) var inlineChoices: [AgentProviderChoice] = []
    private(set) var profileStatuses: [AgentProviderChoice: AgentStatus] = [:]
    private(set) var profileLimits: [AgentProviderChoice: [AgentRateLimitWindow]] = [:]
    private(set) var profileError: String?
    private(set) var signingInChoice: AgentProviderChoice?
    var choice: AgentProviderChoice { .init(provider: provider, profile: claudeProfile) }
    var allChoices: [AgentProviderChoice] { claudeProfiles.map(\.choice) + [.init(provider: .codex), .init(provider: .local)] }
    func title(_ choice: AgentProviderChoice) -> String {
        if choice.provider == .claude { return claudeProfiles.first { $0.nativeProfile == choice.profile }?.name ?? "Claude" }
        return choice.provider.rawValue.capitalized
    }
    func statusLabel(_ choice: AgentProviderChoice) -> String {
        guard let status = profileStatuses[choice] else { return "Unknown" }
        if !status.installed { return "Not installed" }
        switch status.authentication {
        case .subscription, .local: return "Signed in"
        case .signedOut: return "Signed out"
        case .unsupported: return "Unsupported login"
        case .unavailable: return "Unavailable"
        }
    }
    private func backend(for choice: AgentProviderChoice) -> (any AgentBackend)? {
        if let profileBackends { return try? profileBackends.backend(choice) }
        guard choice.profile == "default" else { return nil }
        return backends[choice.provider]
    }
    func reloadProfiles() {
        do { claudeProfiles = try stores.claudeProfiles() }
        catch { self.error = "Claude profiles could not be loaded." }
    }
    private func syncSelectedStatus() {
        statuses[.claude] = profileStatuses[.init(provider: .claude, profile: claudeProfile)]
        providerLimits[.claude] = profileLimits[.init(provider: .claude, profile: claudeProfile)]
    }
    private func snapshotInlineChoices() {
        let recent = (try? stores.value(forKey: "agent.recentProfiles"))
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        inlineChoices = AgentProviderChoice.inlineChoices(all: allChoices, recent: recent.compactMap(AgentProviderChoice.init(id:)), selected: choice)
    }
    func addClaudeProfile(name: String) {
        profileError = nil
        do {
            _ = try stores.createClaudeProfile(name: name, stateDirectory: AitvarasPaths.stateDirectory, defaultDirectory: claudeDefaultDirectory)
            reloadProfiles()
            Task { await refreshStatus() }
        } catch { profileError = "Claude profile could not be created." }
    }
    func updateClaudeProfile(_ profile: AgentProviderProfile) {
        profileError = nil
        do { try stores.saveClaudeProfile(profile); reloadProfiles() }
        catch { profileError = "Claude profile could not be saved." }
    }
    func deleteClaudeProfile(_ profile: AgentProviderProfile) {
        guard !isBusy, signingIn == nil else { return }
        profileError = nil
        do {
            try stores.deleteClaudeProfile(id: profile.id); reloadProfiles()
            inlineChoices.removeAll { $0 == profile.choice }
            if claudeProfile == profile.nativeProfile {
                claudeProfile = "default"; invalidateCommandCatalog(); invalidatePending(); try loadSettings()
                statuses[.claude] = profileStatuses[.init(provider: .claude)]
                providerLimits[.claude] = profileLimits[.init(provider: .claude)]
            }
        } catch { profileError = "Claude profile could not be deleted." }
    }
    func moveClaudeProfile(_ profile: AgentProviderProfile, by offset: Int) {
        guard let index = claudeProfiles.firstIndex(where: { $0.id == profile.id }), claudeProfiles.indices.contains(index + offset) else { return }
        profileError = nil
        var ids = claudeProfiles.map(\.id); ids.swapAt(index, index + offset)
        do { try stores.reorderClaudeProfiles(ids: ids); reloadProfiles() }
        catch { profileError = "Claude profiles could not be reordered." }
    }
    private let backends: [AgentProvider: any AgentBackend]
    private let agentSetup: AgentSetupCoordinator?
    private var catalogRevision = UUID()
    private(set) var agentSetupRevision = UUID()
    private(set) var conversationBusy = false
    private(set) var sideQuestionAnswer: String?
    private(set) var sideQuestionVisible = false
    private(set) var sideQuestionBusy = false
    private var sideQuestionTask: Task<Void, Never>?
    private var sideQuestionToken = UUID()
    private let signInCoordinator: ProviderSignIn
    private var selection = ChatSelectionState()
    private(set) var newChatID = UUID()
    var newProjectID: UUID? { didSet { if newProjectID != oldValue { useWorktree = false; invalidateCommandCatalog() } } }
    var useWorktree = false
    private(set) var creatingChat = false
    var didCreateChat: ((UUID) -> Void)?
    var activityChanged: (() -> Void)?
    private(set) var sidebarStates: [UUID: ChatState] = [:]
    private(set) var unseenChats: Set<UUID> = []
    private var sidebarTasks: [UUID: Task<Void, Never>] = [:]
    private var visibleChats: [UUID: UUID] = [:]
    private var localAvailable = true
    private var localModelTitle = "Checking model…"

    func markChatOpened(_ id: UUID) {
        try? stores.markChatSeen(id)
        unseenChats.remove(id)
    }
    func showChat(_ id: UUID?, surface: UUID) {
        visibleChats[surface] = id
        if let id { markChatOpened(id) }
    }
    func sidebarStatus(_ id: UUID) -> ChatSidebarStatus {
        ChatSidebarStatus(sidebarStates[id], unseen: unseenChats.contains(id))
    }
    var needsPerson: Bool { !approvalSuggestions.isEmpty }
    func observeSidebar(_ chats: [WorkspaceChat]) {
        for chat in chats where sidebarTasks[chat.id] == nil {
            let id = chat.id
            if (try? stores.chatHasUnseenCompletion(id)) == true { unseenChats.insert(id) }
            sidebarTasks[id] = Task { [weak self, manager] in
                do {
                    for await value in try await manager.updates(chatID: id) {
                        guard !Task.isCancelled, let self else { return }
                        let previous = self.sidebarStates[id]
                        self.sidebarStates[id] = value
                        if previous?.rateLimits != value.rateLimits { self.recordProfileUsage(value) }
                        if let snapshot = value.agentSetup, previous?.agentSetup != snapshot,
                           let projectID = try? self.stores.agentProjectID(chatID: id),
                           let session = try? self.stores.agentSessions(chatID: id).first(where: { $0.id == value.entries.last?.sessionID && $0.provider == snapshot.provider }) {
                            await self.agentSetup?.report(snapshot, projectID: projectID, directory: URL(fileURLWithPath: session.cwd), revision: value.mcpSetup?.revision, profile: session.providerProfile)
                            self.agentSetupRevision = UUID()
                        }
                        if self.visibleChats.values.contains(id) { try? self.stores.markChatSeen(id) }
                        if (try? self.stores.chatHasUnseenCompletion(id)) == true { self.unseenChats.insert(id) }
                        else { self.unseenChats.remove(id) }
                        if let previous, previous.isRunning != value.isRunning || previous.outcome != value.outcome {
                            self.activityChanged?()
                        }
                    }
                } catch { /* A row keeps its saved history if observation fails. */ }
            }
        }
    }
    func prepareNew(projectID: UUID?) {
        select(nil)
        for provider in [AgentProvider.local, .claude, .codex] { composerSelections[newChatID, provider] = .init() }
        newChatID = UUID(); newProjectID = projectID; useWorktree = false
        selection.draft = ""
        reloadProfiles()
        let savedChoice = (try? stores.value(forKey: "agent.lastProfile")).flatMap(AgentProviderChoice.init(id:))
        let saved = savedChoice?.provider ?? (try? stores.value(forKey: "agent.lastProvider")).flatMap(AgentProvider.init(rawValue:))
        if let savedChoice, savedChoice.provider == .claude, allChoices.contains(savedChoice) { claudeProfile = savedChoice.profile }
        else { claudeProfile = "default" }
        selection.select(nil, provider: ChatSettings.newProvider(lastUsed: saved, localAvailable: localAvailable, statuses: statuses))
        snapshotInlineChoices(); syncSelectedStatus()
        error = nil; authProvider = nil
        try? loadSettings()
    }
    #if DEBUG
    // Set only by the isolated self-driver, never persisted as a preference.
    var selfDriveCodexModel: String? {
        didSet { settings = settings.filter { $0.value.provider != .codex }; try? loadSettings() }
    }
    var selfDriveLocalModel: String? {
        didSet { settings = settings.filter { $0.value.provider != .local }; try? loadSettings() }
    }
    #endif
    private var newSessionModel: String {
        #if DEBUG
        if provider == .codex, let selfDriveCodexModel { return selfDriveCodexModel }
        if provider == .local, let selfDriveLocalModel { return selfDriveLocalModel }
        #endif
        return provider == .local ? "local" : provider == .claude ? (claudeProfiles.first { $0.nativeProfile == claudeProfile }?.defaultModel ?? "opus") : "default"
    }
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
    private var submittedText: Set<UUID> = []
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
        guard let id = chatID, state?.isRunning != true, sending[id] == nil else { return }
        guard refreshingHistory.insert(id).inserted else { return }
        defer { refreshingHistory.remove(id) }
        do {
            try await manager.refreshNativeHistory(chatID: id)
            guard !Task.isCancelled, chatID == id else { return }
        } catch AgentSessionManagerError.chatBusy { return }
        catch {
            guard !Task.isCancelled, chatID == id else { return }
            // Native refresh is supplemental. Keep the canonical transcript
            // and leave normal chatting quiet when the native store lags.
            return
        }
    }
    func discoverNativeSessions() async {
        guard !terminating, !discoveringNativeSessions else { return }
        discoveringNativeSessions = true; nativeDiscoveryError = nil
        defer { discoveringNativeSessions = false }
        for choice in allChoices where choice.provider != .local && backend(for: choice) != nil {
            do { _ = try await manager.discoverNativeSessions(provider: choice.provider, profile: choice.profile) }
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
    var selectedSignInProvider: AgentProvider? {
        ChatSettings.signInProvider(for: choice, statuses: profileStatuses)
    }
    var composerAuthProvider: AgentProvider? { selectedSignInProvider ?? authProvider }
    private(set) var signingIn: AgentProvider?
    private(set) var statuses: [AgentProvider: AgentStatus] = [:]
    private(set) var catalogs: [AgentProviderChoice: [AgentModel]] = [:]
    private(set) var providerLimits: [AgentProvider: [AgentRateLimitWindow]] = [:]
    private var modelLoads: [AgentProviderChoice: (token: UUID, task: Task<[AgentModel], Error>)] = [:]

    init(manager: AgentSessionManager, stores: Stores, backends: [AgentProvider: any AgentBackend], profileBackends: AgentProfileBackends? = nil, claudeDefaultDirectory: URL? = nil, agentSetup: AgentSetupCoordinator? = nil, forgeEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.claudeDefaultDirectory = claudeDefaultDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        self.profileBackends = profileBackends
        self.manager = manager; self.stores = stores; self.backends = backends
        self.agentSetup = agentSetup
        signInCoordinator = ProviderSignIn(persistence: stores)
        gitActions = AgentGitActionCoordinator(persistence: stores, audit: { _ = try stores.record($0) })
        forgeActions = AgentForgeActionCoordinator(persistence: stores, registry: ForgeRegistry(environment: forgeEnvironment), audit: { _ = try stores.record($0) })
        let scopedFactory: AgentSessionManager.ProfileBackendFactory? = profileBackends.map { pool in
            { @Sendable choice in try pool.backend(choice) }
        }
        conversationActions = AgentConversationActions(persistence: stores, git: gitActions,
            worktreeStorage: AitvarasPaths.stateDirectory.appendingPathComponent("AgentWorktrees", isDirectory: true), backend: { provider in
                guard let backend = backends[provider] else { throw AgentFailure.notInstalled }; return backend
            }, profileBackend: scopedFactory, audit: { _ = try stores.record($0) })
        reloadProfiles()
        approvalSubscription = Task { [weak self, manager] in
            for await suggestions in await manager.approvalUpdates() {
                guard !Task.isCancelled, let self else { return }
                if self.approvalSuggestions != suggestions { self.approvalSuggestions = suggestions }
            }
        }
    }
    var chatID: UUID? { selection.chatID }
    var provider: AgentProvider { selection.provider }
    private(set) var composerInsertionRevision = UUID()
    func editDraft(_ value: String) {
        if value != selection.draft { invalidatePending() }
        selection.draft = value
    }
    var draft: String {
        get { selection.draft }
        set {
            if newValue != selection.draft { invalidatePending() }
            selection.draft = newValue
            composerInsertionRevision = UUID()
        }
    }
    var composerOwnerID: UUID { chatID ?? newChatID }
    var currentProjectID: UUID? {
        if let chatID { return try? stores.agentProjectID(chatID: chatID) }
        return newProjectID
    }
    var canAskSideQuestion: Bool {
        guard provider == .claude, !isBusy, let chatID,
              let session = try? stores.agentSession(chatID: chatID, provider: .claude) else { return false }
        return session.sessionID != nil && session.forkOrigin?.pending != true
    }
    func prepareSideQuestion() {
        guard canAskSideQuestion else { error = AgentConversationText.sideQuestionUnavailable; return }
        if AgentConversationText.sideQuestion(in: draft) == nil { draft = "/btw " + draft }
    }
    func askSideQuestion(_ question: String) {
        guard canAskSideQuestion, let owner = chatID else { error = AgentConversationText.sideQuestionUnavailable; return }
        guard !question.isEmpty else { error = "Write a question after /btw."; return }
        dismissSideQuestion()
        let token = UUID(); sideQuestionToken = token
        sideQuestionVisible = true; sideQuestionBusy = true; sideQuestionAnswer = nil
        if AgentConversationText.sideQuestion(in: draft) == question { draft = "" }
        sideQuestionTask = Task {
            defer { if sideQuestionToken == token { sideQuestionBusy = false; sideQuestionTask = nil } }
            do {
                let answer = try await conversationActions.sideQuestion(chatID: owner, question: question)
                guard !Task.isCancelled, sideQuestionToken == token, chatID == owner else { return }
                sideQuestionAnswer = answer
            } catch {
                guard !Task.isCancelled, sideQuestionToken == token, chatID == owner else { return }
                sideQuestionAnswer = "The side question could not be answered. Try again."
                if draft.isEmpty { draft = "/btw " + question }
            }
        }
    }
    func dismissSideQuestion() {
        sideQuestionToken = UUID(); sideQuestionTask?.cancel(); sideQuestionTask = nil
        sideQuestionVisible = false; sideQuestionAnswer = nil; sideQuestionBusy = false
    }
    func replyWithQuote(_ entry: AgentTranscriptEntry, selection: String?) {
        guard chatID == entry.chatID else { return }
        draft = AgentConversationText.appending(AgentConversationText.quote(entry.text, selection: selection), to: draft)
    }
    func addDiffContext(_ context: String, owner: UUID) {
        guard chatID == owner else { return }
        draft = AgentConversationText.appending(context, to: draft)
    }
    @discardableResult func fork(_ entry: AgentTranscriptEntry, editedText: String? = nil) async -> Bool {
        guard chatID == entry.chatID, !isBusy, !gitBusy, !conversationBusy else { return false }
        let owner = entry.chatID
        conversationBusy = true
        do {
            let result = try await conversationActions.fork(chatID: owner, messageID: entry.id, editedText: editedText)
            guard chatID == owner, !terminating, !Task.isCancelled else { conversationBusy = false; activityChanged?(); return false }
            select(result.chatID); didCreateChat?(result.chatID)
            conversationBusy = false
            if let input = result.input {
                draft = input.text
                composerSelection = .init()
                composerSelection.attachments = input.attachments; composerSelection.mentions = input.mentions; composerSelection.command = input.command
                await send()
            }
            return true
        } catch {
            conversationBusy = false
            guard chatID == owner, !terminating, !Task.isCancelled else { return false }
            if case AgentConversationError.worktreeUnavailable(let child) = error {
                select(child); didCreateChat?(child)
                if let editedText { draft = editedText }
                self.error = "The fork's worktree could not be prepared. Its isolation intent has been retained."
                return true
            } else if error as? AgentConversationError == .dirtyWorktree {
                self.error = AgentConversationError.dirtyWorktreeReason; return false
            } else { self.error = "This message could not be forked. Choose a completed Claude assistant message."; return false }
        }
    }
    var commandCatalogContext: AgentCommandCatalogContext {
        .init(ownerID: composerOwnerID, projectID: currentProjectID, directory: projectDirectory, provider: provider, revision: catalogRevision)
    }
    func invalidateCommandCatalog() {
        catalogRevision = UUID()
        agentSetupRevision = UUID()
        composerSelections[composerOwnerID, provider].command = nil
    }
    var composerSelection: AgentComposerSelection {
        get { composerSelections[composerOwnerID, provider] }
        set {
            invalidatePending(); composerSelections[composerOwnerID, provider] = newValue
        }
    }
    var hasInput: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerSelection.attachments.isEmpty }
    var projectDirectory: URL? {
        if chatID == nil {
            guard let newProjectID, let folder = try? stores.workspaceFolders(projectID: newProjectID).first else { return nil }
            return URL(fileURLWithPath: folder.path, isDirectory: true)
        }
        return settings[settingsKey].map { URL(fileURLWithPath: $0.cwd, isDirectory: true) }
    }

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
        if self.composerOwnerID == chatID, self.provider == provider { invalidatePending(); error = nil }
    }
    private func attachmentFailed(_ failure: Error, chatID: UUID, provider: AgentProvider) {
        guard self.composerOwnerID == chatID, self.provider == provider, !(failure is CancellationError) else { return }
        switch failure as? AgentAttachmentError {
        case .tooLarge: error = "Attachments must total 512 KB or less."
        case .tooMany: error = "Attach up to 8 files."
        case .missingFile: error = "That file could not be read. Choose it again."
        default: error = "Use a text file or PNG, JPEG, GIF or WebP image\(provider == .claude ? ", or PDF." : ".")"
        }
    }
    func commands() async throws -> [AgentCommand] {
        guard let directory = projectDirectory, let backend = backend(for: choice) else { throw AgentFailure.unsupported }
        let owner = composerOwnerID, chosenProvider = provider
        let context = commandCatalogContext
        let projectID = try chatID.map { try stores.agentProjectID(chatID: $0) } ?? newProjectID
        let commands: [AgentCommand]
        let setupNotice: String?
        if let claude = backend as? ClaudeBackend {
            do {
                let catalog = try await claude.commandCatalog(directory: directory, projectID: projectID)
                commands = catalog.commands; setupNotice = catalog.setup?.notice
            } catch AgentFailure.unsupported { commands = []; setupNotice = nil }
        } else {
            commands = try await backend.commands(directory: directory, projectID: projectID); setupNotice = nil
        }
        if let notice = setupNotice {
            let currentProject = try chatID.map { try stores.agentProjectID(chatID: $0) } ?? newProjectID
            if composerOwnerID == owner, provider == chosenProvider, projectDirectory == directory,
               currentProject == projectID { error = notice }
        }
        try Task.checkCancellation()
        guard context == commandCatalogContext else { throw CancellationError() }
        return provider == .claude ? AgentCommandCatalog.withConversationCommands(commands) : commands
    }
    func files(query: String) async throws -> [AgentFileMention] {
        guard let directory = projectDirectory, let backend = backend(for: choice) else { throw AgentFailure.unsupported }
        return try await backend.files(query: query, directory: directory)
    }
    private func clearComposer(chatID: UUID, provider: AgentProvider, sent: AgentInput) {
        var value = composerSelections[chatID, provider]
        value.attachments.removeAll { file in sent.attachments.contains { $0.id == file.id } }
        value.mentions.removeAll { sent.mentions.contains($0) }
        if value.command == sent.command { value.command = nil }
        composerSelections[chatID, provider] = value
    }
    var isBusy: Bool { state?.isRunning == true || chatID.map { sending[$0] != nil } == true }
    var canSubmit: Bool {
        guard selectedSignInProvider == nil else { return false }
        guard let id = chatID else { return !terminating && !creatingChat && newProjectID != nil && signingIn == nil }
        return !terminating && !gitBusy && !stopping.contains(id) && sending[id] == nil && !submittedText.contains(id) && signingIn == nil
            && (!isBusy || statuses[provider]?.capabilities.contains(.followups) == true)
    }
    private var settingsKey: String { "\(composerOwnerID.uuidString).\(choice.id)" }
    var localProviderDetail: String {
        if backends[.local] is LocalBackend { return "Install opencode for tools. opencode is not installed; Local uses text-only inference." }
        if statuses[.local]?.authentication == .unavailable { return "Ollama is not running or has no installed local models." }
        return "opencode · sandboxed on this Mac. Web search is off."
    }
    var currentContextFraction: Double? {
        guard let sessionID = settings[settingsKey]?.id, state?.entries.last?.sessionID == sessionID else { return nil }
        return ChatSettings.contextFraction(state?.usage)
    }
    var models: [AgentModel] { catalogs[choice] ?? [] }
    var selectedModel: AgentModel? { models.first { $0.id == model } }
    var modelTitle: String {
        if let selectedModel { return modelTitle(selectedModel) }
        return model == "default" ? "Default" : model == "local" ? localModelTitle : model
    }
    func modelTitle(_ value: AgentModel) -> String {
        // The AgentLoop adapter has one routing entry, not a model named Local.
        if provider == .local, value.id == "local", backends[.local] is LocalBackend { return localModelTitle }
        return value.name.caseInsensitiveCompare(provider.rawValue) == .orderedSame ? value.id : value.name
    }
    var model: String {
        get { settings[settingsKey]?.model ?? newSessionModel }
        set {
            guard let value = models.first(where: { $0.id == newValue }), let session = settings[settingsKey], !isBusy else { return }
            saveSettings(ChatSettings.selecting(model: value, in: session))
        }
    }
    var effort: String {
        get { settings[settingsKey]?.effort ?? (provider == .claude ? "medium" : "") }
        set {
            guard !isBusy, newValue.isEmpty || selectedModel?.efforts.contains(newValue) == true,
                  var session = settings[settingsKey] else { return }
            session.effort = newValue.isEmpty ? nil : newValue; saveSettings(session)
        }
    }
    var mode: AgentMode {
        get { settings[settingsKey]?.mode ?? .ask }
        set {
            guard !isBusy, provider != .local || statuses[provider]?.capabilities.contains(.approvals) == true,
                  var session = settings[settingsKey] else { return }
            session.mode = newValue; saveSettings(session)
        }
    }
    private func saveSettings(_ session: AgentChatSession) {
        do {
            var value = session
            // The manager may have bound a native identity since the last Send.
            value.sessionID = try stores.agentSession(chatID: value.chatID, choice: value.choice)?.sessionID
            value.forkOrigin = try stores.agentSession(chatID: value.chatID, choice: value.choice)?.forkOrigin
            if chatID != nil { try stores.saveAgentSession(value) }
            settings[settingsKey] = value; invalidatePending()
        } catch { self.error = "Chat settings could not be saved." }
    }

    func select(_ id: UUID?) {
        guard id != chatID else { return }
        dismissSideQuestion()
        subscription?.cancel()
        previewTask?.cancel()
        // View changes cancel a browser flow and invalidate its automatic send.
        if loginToken != nil { cancelSignIn() }
        if let pending = try? stores.pendingSend(), pending.session.chatID != id { invalidatePending() }
        state = id.flatMap { sidebarStates[$0] }; error = nil; authProvider = nil; changes = nil; canDiscardChanges = false; branchStatus = nil; pushDisabledReason = "Refresh branch status first."; gitError = nil
        pullRequest = nil; pullRequestBinding = id.flatMap { try? stores.agentPullRequest(chatID: $0) }; pullRequestChecks = []; forgeError = nil; forgeDraft = nil; forgeKind = nil; forgeNeedsSignIn = false; forgeRefreshID = nil
        do {
            let saved = try stores.value(forKey: id.map { "agent.provider.\($0.uuidString)" } ?? "agent.lastProvider")
            selection.select(id, provider: saved.flatMap(AgentProvider.init(rawValue:)) ?? .local)
            claudeProfile = try id.map { try stores.selectedClaudeProfile(chatID: $0) } ?? "default"
            snapshotInlineChoices(); syncSelectedStatus()
            try loadSettings()
            if let id, state == nil { state = ChatState(chatID: id, entries: try stores.agentEntries(chatID: id)) }
            if let pending = try stores.pendingSend(), pending.session.chatID == id {
                if pending.expiresAt > .now, pending.session.choice == choice {
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
        setChoice(.init(provider: value, profile: value == .claude ? claudeProfile : "default"))
    }
    func setChoice(_ value: AgentProviderChoice) {
        guard !isBusy, !creatingChat, signingIn == nil, value != choice, allChoices.contains(value) else { return }
        do {
            try stores.selectAgentChoice(value, chatID: chatID)
            selection.select(chatID, provider: value.provider)
            if value.provider == .claude { claudeProfile = value.profile }
            invalidatePending(); invalidateCommandCatalog(); dismissSideQuestion()
            try loadSettings(); error = nil; authProvider = nil
            statuses[value.provider] = profileStatuses[value]
            providerLimits[value.provider] = profileLimits[value]
        } catch { self.error = "Provider selection could not be saved." }
    }

    private func loadSettings() throws {
        guard let id = chatID, let chat = try stores.workspaceChat(id: id) else {
            if settings[settingsKey] == nil {
                settings[settingsKey] = AgentChatSession(chatID: newChatID, provider: provider, cwd: "/tmp",
                                                       model: newSessionModel, effort: provider == .claude ? claudeProfiles.first { $0.nativeProfile == claudeProfile }?.defaultEffort ?? "medium" : nil, providerProfile: choice.profile)
            }
            restoreModelSelection()
            return
        }
        let folders = try stores.workspaceFolders(projectID: chat.projectID).map { URL(fileURLWithPath: $0.path) }
        let owned = try stores.agentWorktree(chatID: id)
        if try stores.requiresAgentWorktree(chatID: id), owned == nil { throw AgentGitError.creationFailed }
        let cwd = owned?.cwdPath ?? folders.first?.path ?? fallbackDirectory(id).path
        // Refresh identities while retaining unsent choices (which are saved immediately).
        settings[settingsKey] = try stores.agentSession(chatID: id, choice: choice)
            ?? AgentChatSession(chatID: id, provider: provider, cwd: cwd,
                                model: newSessionModel, effort: provider == .claude ? claudeProfiles.first { $0.nativeProfile == claudeProfile }?.defaultEffort ?? "medium" : nil, providerProfile: choice.profile)
        if settings[settingsKey]?.sessionID == nil { settings[settingsKey]?.cwd = cwd }
        let primary = URL(fileURLWithPath: settings[settingsKey]?.cwd ?? cwd).resolvingSymlinksInPath().standardizedFileURL.path
        settings[settingsKey]?.additionalRootsJSON = try owned?.additionalRootsJSON
            ?? String(decoding: JSONEncoder().encode(folders.filter {
                $0.resolvingSymlinksInPath().standardizedFileURL.path != primary
            }.map(\.path)), as: UTF8.self)
        restoreModelSelection()
    }
    private func restoreModelSelection() {
        guard let session = settings[settingsKey] else { return }
        var automaticallySelect = true
        #if DEBUG
        // A cost-limited run must fail rather than fall back to another model.
        if provider == .codex, selfDriveCodexModel == session.model { automaticallySelect = false }
        if provider == .local, selfDriveLocalModel == session.model { automaticallySelect = false }
        #endif
        let restored = ChatSettings.restoring(session, models: models, automaticallySelect: automaticallySelect)
        if restored != session { saveSettings(restored) }
    }
    private func fallbackDirectory(_ id: UUID) -> URL {
        AitvarasPaths.stateDirectory.appendingPathComponent("AgentChats/\(id.uuidString)", isDirectory: true)
    }

    func refreshChanges(allowWhileBusy: Bool = false) async {
        guard let owner = chatID, let directory = projectDirectory, !gitBusy || allowWhileBusy else { return }
        do {
            let value = try await gitActions.changes(in: directory)
            let branch = try await gitActions.branchStatus(at: value.directory)
            guard chatID == owner, projectDirectory == directory, !gitBusy || allowWhileBusy else { return }
            changes = value; branchStatus = branch
            do {
                let owned = try await gitActions.mapping(chatID: owner)
                guard chatID == owner, projectDirectory == directory, !gitBusy || allowWhileBusy else { return }
                canDiscardChanges = owned?.worktreePath == value.directory.path
                pushDisabledReason = branch.pushRefusal(ownedBranch: owned.map { _ in "aitvaras/chat-\(owner.uuidString.lowercased())" })?.message
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard chatID == owner, projectDirectory == directory, !gitBusy || allowWhileBusy else { return }
                canDiscardChanges = false
                pushDisabledReason = (branch.detached ? AgentGitError.detachedHEAD : (error as? AgentGitError) ?? .ownershipConflict).message
            }
            if gitError == "Changes could not be refreshed." { gitError = nil }
        } catch is CancellationError { return }
        catch {
            guard chatID == owner else { return }
            // Keep the last review visible on a failed refresh; never mistake
            // an unavailable git command for a clean checkout.
            if changes != nil, gitError == nil { gitError = "Changes could not be refreshed." }
            branchStatus = nil; pushDisabledReason = "Refresh branch status first."
            canDiscardChanges = false
        }
    }
    func applyGitChanges(_ expected: ChangesState, owner: UUID, message: String?, pushAfterCommit: Bool = false, expectedBranch: String? = nil) async {
        guard chatID == owner, !isBusy, !gitBusy else { return }
        gitBusy = true
        var committed = false
        do {
            if let message {
                try await gitActions.commit(chatID: owner, expected: expected, message: message, confirmed: true)
                committed = true
                if chatID == owner { await refreshChanges(allowWhileBusy: true) }
                if pushAfterCommit {
                    try await gitActions.push(chatID: owner, confirmed: true, expectedDirectory: expected.directory, expectedBranch: expectedBranch)
                }
            } else {
                try await gitActions.discard(chatID: owner, expected: expected, confirmed: true)
            }
            if chatID == owner { gitError = nil }
        } catch {
            if chatID == owner {
                let reason = (error as? AgentGitError)?.message ?? "Git operation failed. Refresh and try again."
                gitError = committed ? "Committed locally. " + reason : reason
            }
        }
        gitBusy = false
        if chatID == owner { await refreshChanges(); if pushAfterCommit { await refreshPullRequest() } }
    }

    func pushGitBranch(owner: UUID, directory: URL, branch: String) async {
        guard chatID == owner, !isBusy, !gitBusy else { return }
        gitBusy = true
        do {
            try await gitActions.push(chatID: owner, confirmed: true, expectedDirectory: directory, expectedBranch: branch)
            if chatID == owner { gitError = nil }
        } catch {
            if chatID == owner { gitError = (error as? AgentGitError)?.message ?? "Push failed. Refresh and try again." }
        }
        gitBusy = false
        if chatID == owner { await refreshChanges(); await refreshPullRequest() }
    }

    private var forgeEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS"] != "1" && env["AITVARAS_UI_TEST_MODE"] != "1"
    }
    var canCreatePullRequest: Bool {
        guard let branch = branchStatus else { return false }
        return forgeEnabled && pullRequest == nil && !branch.detached && !branch.isDefaultBranch
            && branch.upstream == "origin/" + branch.branch && branch.ahead == 0 && branch.behind == 0
    }
    func refreshPullRequest() async {
        guard forgeEnabled, let owner = chatID, let directory = changes?.directory else { return }
        let token = UUID(); forgeRefreshID = token
        do {
            let snapshot = try await forgeActions.refresh(chatID: owner, directory: directory)
            guard chatID == owner, forgeRefreshID == token else { return }
            pullRequest = snapshot.request; pullRequestChecks = snapshot.checks; forgeError = snapshot.checkError?.message; forgeNeedsSignIn = false
            forgeKind = snapshot.forge
            pullRequestBinding = try? stores.agentPullRequest(chatID: owner)
        } catch {
            guard chatID == owner, forgeRefreshID == token else { return }
            let host = branchStatus?.remoteHost
            let kind = try? await forgeActions.kind(host: host)
            guard chatID == owner, forgeRefreshID == token else { return }
            forgeKind = kind; forgeNeedsSignIn = error as? ForgeError == .signedOut
            if error as? ForgeError == .notInstalled, let kind {
                forgeError = "Install \(kind.title) CLI (\(kind.executableName)) to see \(kind.requestName)s"
            } else { forgeError = (error as? ForgeError)?.message ?? "Could not refresh pull request." }
        }
    }
    func preparePullRequest() async {
        guard canCreatePullRequest, let owner = chatID, let directory = changes?.directory, !forgeBusy else { return }
        forgeBusy = true; defer { forgeBusy = false }
        do {
            let draft = try await forgeActions.draft(chatID: owner, directory: directory)
            guard chatID == owner else { return }
            forgeKind = draft.kind
            await refreshPullRequest()
            if chatID == owner, pullRequest == nil { forgeDraft = draft }
        } catch {
            guard chatID == owner else { return }
            let kind = try? await forgeActions.kind(host: branchStatus?.remoteHost)
            guard chatID == owner else { return }
            forgeKind = kind
            forgeNeedsSignIn = error as? ForgeError == .signedOut
            if error as? ForgeError == .notInstalled, let kind = forgeKind {
                forgeError = "Install \(kind.title) CLI (\(kind.executableName)) to see \(kind.requestName)s"
            } else { forgeError = (error as? ForgeError)?.message ?? (error as? AgentGitError)?.message ?? "Could not prepare pull request." }
        }
    }
    func dismissForgeDraft() { forgeDraft = nil }
    func createPullRequest(_ draft: ForgeRequestDraft, isDraft: Bool, owner: UUID) async -> Bool {
        guard chatID == owner, !forgeBusy, !gitBusy, !isBusy else { return false }
        forgeBusy = true; defer { forgeBusy = false }
        do {
            let request = try await forgeActions.createPullRequest(chatID: owner, draft: draft, isDraft: isDraft, confirmed: true)
            guard chatID == owner else { return true }
            pullRequest = request; pullRequestBinding = try? stores.agentPullRequest(chatID: owner); forgeDraft = nil; forgeError = nil
            await refreshPullRequest()
            return true
        } catch {
            if chatID == owner { forgeError = (error as? ForgeError)?.message ?? (error as? AgentGitError)?.message ?? "Could not create pull request." }
            return false
        }
    }

    /// No browser or user message is initiated by opening Chat or Settings.
    func refreshStatus() async {
        reloadProfiles()
        for entry in allChoices {
            let backend = backend(for: entry)
            profileStatuses[entry] = try? await backend?.status()
            if entry == choice || entry.provider != .claude { statuses[entry.provider] = profileStatuses[entry] }
            if let codex = backend as? CodexBackend {
                profileLimits[entry] = try? await codex.rateLimits()
                providerLimits[entry.provider] = profileLimits[entry]
            }
        }
        if backends[.local] is LocalBackend {
            let assigned = MLXEngine.assignedModel(for: .chat)
            localAvailable = MLXEngine.installedModels().contains(assigned)
            if localAvailable { localModelTitle = assigned }
            else {
                let ollama = OllamaEngine()
                localAvailable = await ollama.isAvailable(for: .chat)
                localModelTitle = localAvailable ? await ollama.configuredModelName : "Model unavailable"
            }
        } else {
            localAvailable = (try? await backends[.local]?.models().isEmpty) == false
        }
        if chatID == nil, (try? stores.value(forKey: "agent.lastProvider")) == nil {
            let value = ChatSettings.newProvider(lastUsed: nil, localAvailable: localAvailable, statuses: statuses)
            selection.select(nil, provider: value); try? loadSettings()
        }
    }
    func loadModels() async {
        let selected = choice
        if catalogs[selected] != nil { restoreModelSelection(); return }
        guard let backend = backend(for: selected) else { return }
        let load: (token: UUID, task: Task<[AgentModel], Error>)
        if let existing = modelLoads[selected] { load = existing }
        else {
            load = (UUID(), Task {
                let status = try await backend.status()
                guard status.authentication == .subscription || status.authentication == .local else { return [] }
                return try await backend.models()
            })
            modelLoads[selected] = load
        }
        defer { if modelLoads[selected]?.token == load.token { modelLoads.removeValue(forKey: selected) } }
        do {
            let values = try await load.task.value
            guard modelLoads[selected]?.token == load.token, !values.isEmpty else { return }
            catalogs[selected] = selected.provider == .claude ? ChatSettings.claudeModels(values) : values
            guard choice == selected, !isBusy, signingIn == nil else { return }
            restoreModelSelection()
        } catch { /* A real Send supplies the actionable failure. */ }
    }

    /// Compatibility entry point for typed actions outside the main composer.
    /// The draft stays owned by its chat if navigation wins the scheduling race.
    func submitText(_ text: String, chatID id: UUID) -> Bool {
        guard chatID == id, canSubmit,
              let chat = try? stores.workspaceChat(id: id), chat.archivedAt == nil,
              let project = try? stores.workspaceProject(id: chat.projectID), project.isVisible else { return false }
        draft = text
        submittedText.insert(id)
        Task { [weak self] in
            guard let self else { return }
            self.submittedText.remove(id)
            guard self.chatID == id, self.draft == text else { return }
            await self.send()
        }
        return true
    }

    func submitNewText(_ text: String) -> Bool {
        guard chatID == nil, canSubmit else { return false }
        let owner = newChatID
        draft = text
        Task { [weak self] in
            guard let self, self.chatID == nil, self.newChatID == owner, self.draft == text else { return }
            await self.send()
        }
        return true
    }

    func send() async {
        guard hasInput else { return }
        if let question = AgentConversationText.sideQuestion(in: draft) {
            askSideQuestion(question)
            return
        }
        #if DEBUG
        if provider == .codex, let selfDriveCodexModel {
            await loadModels()
            guard models.contains(where: { $0.id == selfDriveCodexModel }) else {
                error = "The self-drive Codex model is unavailable."; return
            }
        }
        if provider == .local, let selfDriveLocalModel {
            await loadModels()
            guard models.contains(where: { $0.id == selfDriveLocalModel }) else {
                error = "The self-drive Local model is unavailable."; return
            }
        }
        #endif
        if chatID == nil {
            guard canSubmit, hasInput, let projectID = newProjectID else { return }
            creatingChat = true
            defer { creatingChat = false }
            let text = draft, chosenProvider = provider, chosenChoice = choice, chosenSettings = settings[settingsKey]
            let composition = composerSelection
            var createdChat: WorkspaceChat?
            do {
                guard let created = try stores.createChatOnFirstSend(projectID: projectID, text: text, hasAttachments: !composition.attachments.isEmpty, requiresWorktree: useWorktree) else { return }
                createdChat = created
                try stores.selectAgentChoice(chosenChoice, chatID: created.id)
                if useWorktree {
                    let folders = try stores.workspaceFolders(projectID: projectID).map { URL(fileURLWithPath: $0.path) }
                    _ = try await gitActions.create(chatID: created.id, projectID: projectID, folders: folders,
                        storage: AitvarasPaths.stateDirectory.appendingPathComponent("AgentWorktrees", isDirectory: true))
                }
                select(created.id)
                if var session = settings[settingsKey], let chosenSettings {
                    session.model = chosenSettings.model; session.effort = chosenSettings.effort; session.mode = chosenSettings.mode
                    saveSettings(session)
                }
                selection.draft = text
                composerSelections[created.id, chosenProvider] = composition
                didCreateChat?(created.id)
            } catch {
                if let created = createdChat {
                    // First Send owns this record even if git preparation failed.
                    // Keep its failed ownership evidence and never use the checkout.
                    select(created.id)
                    selection.draft = text
                    composerSelections[created.id, chosenProvider] = composition
                    didCreateChat?(created.id)
                }
                self.error = useWorktree ? "Worktree could not be prepared. Use New Chat to retry." : "Chat could not be created. Try again."
                return
            }
        }
        restoreModelSelection()
        guard let id = chatID, canSubmit, var session = settings[settingsKey],
              hasInput else { return }
        if provider == .local, backends[provider] is OpencodeBackend, selectedModel == nil {
            error = "Choose an installed local model."; return
        }
        let text = draft, provider = provider, sentChoice = choice, key = settingsKey
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
                try await manager.send(chatID: id, provider: provider, input: input, onAccepted: { [weak self] in
                    await self?.accepted(input, chatID: id, provider: provider)
                })
                attempts.removeValue(forKey: input.id)
                return
            }
            // A post-turn preview must finish before settings/context are read.
            // Send stays available and owns this input while it waits.
            do { try await manager.waitForNativeHistory(chatID: id) }
            catch where AgentSessionManager.historyUnavailable(error) { /* Send uses retained history. */ }
            guard !stoppedSends.contains(input.id) else { return }
            // Verification also rejects failed/incomplete creation after restart.
            _ = try await gitActions.mapping(chatID: id)
            session.instructions = try stores.workspaceContextPacket(chatID: id).promptText
            session.sessionID = try stores.agentSession(chatID: id, choice: sentChoice)?.sessionID
            session.forkOrigin = try stores.agentSession(chatID: id, choice: sentChoice)?.forkOrigin
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
            try stores.selectAgentChoice(sentChoice, chatID: id, rememberRecent: true)
            // Starting the manager first guarantees auth failures have a journal.
            try await manager.send(chatID: id, provider: provider, input: input, onAccepted: { [weak self] in
                await self?.accepted(input, chatID: id, provider: provider)
            })
        } catch {
            if !stoppedSends.contains(input.id) {
                if (error as? AgentSessionManagerError) == .runningChatLimit {
                    attempts.removeValue(forKey: input.id)
                    if chatID == id {
                        authProvider = nil
                        self.error = AgentFailure.sendMessage(for: error, provider: provider)
                    }
                    return
                }
                let failure = (error as? AgentFailure) ?? .unknown
                try? await manager.reportSendFailure(chatID: id, failure: failure)
                if chatID == id { failed(inputID: input.id, failure: failure) }
                if chatID == id { self.error = AgentFailure.sendMessage(for: error, provider: provider) }
            }
        }
    }
    private func accepted(_ input: AgentInput, chatID: UUID, provider: AgentProvider) {
        // Clear before provider startup, including auth failure. The durable
        // user entry owns the accepted text; a later draft is independent.
        let visibleDraft = selection.draft
        selection.clearDraft(chatID: chatID, ifUnchanged: input.text)
        if selection.draft != visibleDraft { composerInsertionRevision = UUID() }
        clearComposer(chatID: chatID, provider: provider, sent: input)
    }
    private func observe(_ state: ChatState) {
        if let mode = state.acknowledgedMode, let sessionID = state.entries.last?.sessionID,
           let session = try? stores.agentSessions(chatID: state.chatID).first(where: { $0.id == sessionID }),
           observedModes[state.chatID]?.input != state.inputID || observedModes[state.chatID]?.mode != mode {
            observedModes[state.chatID] = (state.inputID, mode)
            if state.isRunning || session.mode == mode {
                settings["\(state.chatID.uuidString).\(session.choice.id)"]?.mode = mode
            }
        }
        recordProfileUsage(state)
        if case .failed(let failure) = state.outcome, let input = state.inputID { failed(inputID: input, failure: failure) }
        if !state.isRunning, let input = state.inputID, state.outcome == .completed { attempts.removeValue(forKey: input) }
        if !state.isRunning, state.outcome == .completed || state.outcome == .interrupted,
           let input = state.inputID, refreshedInputs[state.chatID] != input {
            refreshedInputs[state.chatID] = input
            previewTask = Task { [weak self] in await self?.refreshNativePreview() }
        }
    }
    private func recordProfileUsage(_ state: ChatState) {
        if !state.rateLimits.isEmpty, let sessionID = state.entries.last?.sessionID,
           let session = try? stores.agentSessions(chatID: state.chatID).first(where: { $0.id == sessionID }) {
            profileLimits[session.choice] = state.rateLimits
            if choice == session.choice { providerLimits[session.provider] = state.rateLimits }
        }
    }
    private func failed(inputID: UUID, failure: AgentFailure) {
        guard !handledFailures.contains(inputID), let attempt = attempts.removeValue(forKey: inputID) else { return }
        handledFailures.insert(inputID)
        authProvider = failure == .authRequired ? attempt.provider : nil
        error = AgentFailure.sendMessage(for: failure, provider: attempt.provider)
        guard failure == .authRequired, let id = chatID, attempt.provider == provider else { return }
        do {
            guard let turn = try stores.agentTurn(id: inputID), turn.chatID == id, turn.delivery == .prepared, turn.resendCount == 0,
                  let session = try stores.agentSession(chatID: id, choice: choice) else { return }
            let pending = try PendingSend(inputID: inputID, text: attempt.input.text, session: session, accountID: attempt.accountID,
                                          hasAttachments: !attempt.input.attachments.isEmpty)
            try stores.savePendingSend(pending)
            armPendingExpiry(pending)
        } catch { self.error = "Sign in to \(provider.rawValue.capitalized)" }
    }
    private func armPendingExpiry(_ pending: PendingSend) {
        pendingExpiry?.cancel()
        pendingExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, pending.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            guard let self, let current = try? self.stores.pendingSend(), current.inputID == pending.inputID else { return }
            self.cancelSignIn()
            if self.chatID == pending.session.chatID {
                self.error = "Sign-in timed out. The message remains in this chat."
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
        signIn(.init(provider: provider, profile: provider == .claude ? claudeProfile : "default"))
    }
    func signIn(_ selected: AgentProviderChoice) {
        let provider = selected.provider
        guard provider != .local, signingIn == nil, let backend = backend(for: selected) else { return }
        signingInChoice = selected; profileError = nil
        let token = UUID(), selectedChat = chatID
        loginToken = token; signingIn = provider
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.loginToken == token { self.loginToken = nil; self.signingIn = nil; self.signingInChoice = nil } }
            var retriedInput: UUID?
            do {
                if provider == .claude { try self.stores.authorizeClaudeProfileSignIn(profile: selected.profile) }
                try await self.signInCoordinator.signIn(backend: backend) { [weak self] url in
                    await self?.openSignInURL(url, token: token)
                }
                try Task.checkCancellation()
                guard self.loginToken == token else { return }
                let status = try await backend.status()
                try Task.checkCancellation()
                guard self.loginToken == token else { return }
                self.profileStatuses[selected] = status
                if self.choice == selected || provider != .claude { self.statuses[provider] = status }
                guard status.authentication == .subscription else { throw AgentFailure.authRequired }
                self.catalogs[selected] = nil
                self.modelLoads.removeValue(forKey: selected)?.task.cancel()
                if let pending = try self.stores.pendingSend(), pending.session.choice == selected, self.choice == selected,
                   self.chatID == selectedChat, self.chatID == pending.session.chatID, self.provider == provider,
                   let turn = try self.stores.agentTurn(id: pending.inputID),
                   let session = try self.stores.agentSession(chatID: pending.session.chatID, provider: provider),
                   let chat = try self.stores.workspaceChat(id: pending.session.chatID), chat.archivedAt == nil,
                   try self.stores.workspaceProject(id: chat.projectID)?.isVisible == true {
                    _ = try await self.signInCoordinator.consume(inputID: pending.inputID, turn: turn, session: session, accountID: self.statuses[provider]?.accountID)
                    try Task.checkCancellation()
                    guard self.loginToken == token, self.chatID == selectedChat, self.provider == provider else { return }
                    self.pendingExpiry?.cancel(); self.pendingExpiry = nil
                    self.handledFailures.remove(pending.inputID)
                    guard let entry = try self.stores.agentEntries(chatID: pending.session.chatID).first(where: { $0.id == pending.inputID }) else {
                        throw ProviderSignInError.staleIntent
                    }
                    let retryInput = try AgentInput.restoring(id: pending.inputID, text: pending.text, payload: entry.payloadJSON)
                    self.attempts[pending.inputID] = (retryInput, provider, self.statuses[provider]?.accountID)
                    retriedInput = pending.inputID
                    self.error = nil; self.authProvider = nil; self.signingIn = nil; self.signingInChoice = nil
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
                    if self.handledFailures.contains(pending.inputID) { return }
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
                    self.error = error is CancellationError ? nil : "Sign-in did not complete. The message remains in this chat."
                    self.authProvider = self.choice == selected ? provider : nil
                    self.profileError = error is CancellationError ? nil : "Sign-in did not complete for \(self.title(selected)). Try again."
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
        loginToken = nil; loginTask?.cancel(); loginTask = nil; signingIn = nil; signingInChoice = nil
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
        dismissSideQuestion()
        await conversationActions.shutdown()
        await agentSetup?.shutdown()
        previewTask?.cancel()
        cancelSignIn(); stoppedSends.formUnion(sending.values)
        modelLoads.values.forEach { $0.task.cancel() }; modelLoads.removeAll()
        // Local cleanup must run even when journaling fails, and before a
        // different backend's shutdown can throw. Await the process-group kill.
        do { try await manager.shutdown() }
        catch {
            for case let opencode as OpencodeBackend in backends.values { await opencode.shutdown() }
            throw error
        }
        sidebarTasks.values.forEach { $0.cancel() }; sidebarTasks.removeAll()
        for case let opencode as OpencodeBackend in backends.values { await opencode.shutdown() }
        for case let codex as CodexBackend in backends.values { try await codex.shutdown() }
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
    func canAlwaysAllow(chatID: UUID, request: AgentRequest) -> Bool {
        guard AgentToolPolicy.canAlwaysAllow(request), case .permission(let tool) = request.kind,
              let provider = request.scope.session?.provider else { return false }
        guard tool.name.hasPrefix("mcp__") else { return true }
        guard provider != .codex, let owner = try? stores.workspaceChat(id: chatID),
              let session = try? stores.agentSession(chatID: chatID, provider: provider),
              let context = try? stores.agentMCPLaunchContext(directory: URL(fileURLWithPath: session.cwd), projectID: owner.projectID),
              let resolution = try? AgentMCPResolver.prepare(directory: URL(fileURLWithPath: session.cwd), setup: context.setup, globalServers: context.globalServers) else { return false }
        var fingerprints = (try? resolution.effectiveServers.mapValues { try $0.fingerprint() }) ?? [:]
        for (name, fingerprint) in resolution.repositoryFingerprints where resolution.effectiveServers[name] != nil { fingerprints[name] = fingerprint }
        return AgentToolPolicy.fingerprint(tool: tool.name, servers: fingerprints) != nil
    }
    func alwaysAllow(chatID: UUID, request: AgentRequest) async -> Bool {
        guard respondingRequests.insert(request.identity).inserted else { return false }
        defer { respondingRequests.remove(request.identity) }
        do { try await manager.alwaysAllow(chatID: chatID, request: request); return true }
        catch { return false }
    }
}
