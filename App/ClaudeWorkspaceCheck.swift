import Foundation
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

/// Offline app lifecycle checks. No CLI, sign-in, account, network or device use.
@MainActor enum ClaudeWorkspaceCheck {
    enum Failure: Error { case assertion(line: Int), simulatedDisconnect, fixtureTimeout }

    static func run() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try await checkGuidedSignIn()
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let reporter = ActivityReporter(stores: stores)
        let project = try stores.createWorkspaceProject(title: "Synthetic Claude course", instructions: "SYNTHETIC_CLAUDE_CONTEXT")
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic discussion")
        let fake = SyntheticClaudeTransport()
        let signIn = SyntheticClaudeSignIn {}
        let model = ClaudeWorkspaceModel()
        try model.configure(stores: stores, reporter: reporter, transport: fake, signInTransport: signIn,
            signInGuidance: .init(executable: "/synthetic/never-executed-claude", configDirectory: "/synthetic/profile",
                                 arguments: ["auth", "login", "--claudeai"], environment: [:]))
        model.load(chatID: chat.id)
        try require(model.sessions.isEmpty && model.projectIssue != nil)
        try require(await fake.statusCount == 0)
        try require(await fake.runCount == 0)
        await model.checkSetup()
        try require(model.authenticated && model.models.count == 1)
        let initialNamespace = model.profileNamespace!
        try require(try model.historyDecision(chatID: chat.id, profileNamespace: initialNamespace) == nil)
        try require(model.saveHistoryDecision(false, chatID: chat.id, profileNamespace: initialNamespace))
        try require(try model.historyDecision(chatID: chat.id, profileNamespace: initialNamespace) == false)
        let intent = ClaudeComposerSendIntent(chatID: chat.id, profileNamespace: initialNamespace,
            prompt: "Synthetic consent intent", modelID: "synthetic-claude", effort: nil)
        try require(intent.isCurrent(chatID: chat.id, profileNamespace: initialNamespace, backend: .claude))
        try require(!intent.isCurrent(chatID: UUID(), profileNamespace: initialNamespace, backend: .claude))
        try require(!intent.isCurrent(chatID: chat.id, profileNamespace: "other-account", backend: .claude))
        try require(!intent.isCurrent(chatID: chat.id, profileNamespace: initialNamespace, backend: .local))
        await model.sendFromComposer(prompt: "Refused without project approval", chatID: chat.id, modelID: "synthetic-claude", effort: nil)
        try require(await fake.runCount == 0)
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local, .claude], expectedRevision: review.revision)
        await model.sendFromComposer(prompt: "Synthetic first message", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.turns.count == 1 && model.turns[0].state == .completed && model.turns[0].outputText == "Synthetic Claude reply")
        try require(await fake.readCount == 1)
        try require(model.transcriptRevision == 1)
        let initialProjection = try stores.workspaceClaudeProjection(sessionID: model.selectedSessionID!)
        try require(initialProjection?.messages.count == 2)
        let firstTimeline = try stores.workspaceChatTimeline(chatID: chat.id)
        try require(firstTimeline.filter { $0.role == "user" && $0.text == "Synthetic first message" }.count == 1)
        try require(firstTimeline.filter { $0.role == "assistant" && $0.text == "Synthetic Claude reply" }.count == 1)
        try require(model.contextUsedTokens == 120 && model.contextLimitTokens == 1000 && model.usageWindows.first?.usedPercent == 25)
        let original = model.selectedSessionID
        let externalID = model.sessions.first?.externalID
        await model.sendFromComposer(prompt: "Synthetic follow-up", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.selectedSessionID == original && model.turns.count == 2 && model.turns.allSatisfy { $0.state == .completed })
        try require(await fake.resumedID == externalID)
        try require(try stores.messages(in: chat.localConversationID).isEmpty)

        await fake.setMode(.failBeforeDelivery)
        await model.sendFromComposer(prompt: "Synthetic failed start", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.turns.last?.state == .failed && model.turns.last?.providerTurnID == nil)
        try require(model.errorMessage?.hasPrefix("Nothing was sent.") == true)
        try require(try stores.workspaceChatTimeline(chatID: chat.id).contains { $0.text == "Synthetic failed start" && $0.notDelivered })

        await fake.setMode(.holdBeforeDelivery)
        let early = Task { @MainActor in
            await model.sendFromComposer(prompt: "Synthetic early stop", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        }
        try await fake.waitUntilStarted()
        try require(model.isBusy && model.turns.last?.state == .prepared)
        await model.stop(); await early.value
        try require(model.turns.last?.state == .cancelled && model.turns.last?.providerTurnID == nil)
        try require(model.errorMessage == "Stopped before sending. Nothing was sent.")

        await fake.setMode(.waitForStop)
        let stopping = Task { @MainActor in
            await model.sendFromComposer(prompt: "Synthetic acknowledged stop", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        }
        try await fake.waitUntilStarted()
        try require(model.isBusy && model.turns.last?.state == .running)
        await model.stop()
        try require(model.isBusy && model.isStopping && model.turns.last?.state == .cancellationRequested)
        await fake.acknowledgeStop()
        await stopping.value
        try require(!model.isBusy && model.turns.last?.state == .cancelled)

        await fake.setMode(.completeThenDisconnect)
        await model.sendFromComposer(prompt: "Synthetic saved completion", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.turns.last?.state == .completed && model.errorMessage?.contains("outcome is saved") == true)
        await fake.setMode(.disconnect)
        await model.sendFromComposer(prompt: "Synthetic uncertain outcome", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        let uncertainID = model.selectedSessionID
        try require(model.turns.last?.state == .outcomeUnknown && model.turns.last?.outputText == "Synthetic ")
        let beforeRefreshRuns = await fake.runCount
        await model.refreshHistory(chatID: chat.id)
        try require(await fake.runCount == beforeRefreshRuns)
        try require(model.turns.last?.state == .outcomeUnknown && model.turns.last?.outputText == "Synthetic ")
        try require(try stores.workspaceClaudeTurn(id: model.turns.last!.id)?.state == .outcomeUnknown)
        try require(try stores.workspaceChatTimeline(chatID: chat.id).contains {
            $0.text == "Observed uncertain provider text" && $0.state == .outcomeUnknown
        })
        let observedProjection = try stores.workspaceClaudeProjection(sessionID: uncertainID!)
        let revisionBeforeReadFailure = model.transcriptRevision
        await fake.setReadFailure(true)
        await model.refreshHistory(chatID: chat.id)
        try require(model.transcriptRevision == revisionBeforeReadFailure)
        try require(try stores.workspaceClaudeProjection(sessionID: uncertainID!) == observedProjection)
        try require(model.turns.last?.state == .outcomeUnknown)
        await fake.setReadFailure(false)
        await fake.setMode(.complete)
        await model.sendFromComposer(prompt: "New message, never a replay", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.selectedSessionID != uncertainID && model.turns.last?.state == .completed)
        try require(await fake.lastPrompt == "New message, never a replay")

        let calls = await fake.runCount
        await model.sendFromComposer(prompt: "Wrong chat", chatID: UUID(), modelID: "synthetic-claude", effort: nil)
        await model.sendFromComposer(prompt: "No silent model fallback", chatID: chat.id, modelID: "missing-model", effort: nil)
        await model.sendFromComposer(prompt: String(repeating: "🐉", count: 17_000), chatID: chat.id, modelID: "synthetic-claude", effort: nil)
        try require(await fake.runCount == calls)

        // Sharing is a separate explicit grant tied to the verified account.
        try stores.appendMessage(.init(conversationID: chat.localConversationID, role: "user", content: "LOCAL_CLAUDE_PRIVATE_CANARY"))
        await model.sendFromComposer(prompt: "History stays private", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(await fake.lastPrompt == "History stays private")
        let namespace = model.profileNamespace!
        try stores.setValues([WorkspaceChatBackend.key(chat.id, "shareHistory.claude"): "1",
                              WorkspaceChatBackend.key(chat.id, "shareHistory.claude.profile"): namespace])
        await model.sendFromComposer(prompt: "Explicit history grant", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(await fake.lastPrompt.contains("LOCAL_CLAUDE_PRIVATE_CANARY"))
        try require(try stores.workspaceHandovers(chatID: chat.id).count == 1)
        let beforeAccountChange = await fake.runCount
        await fake.setNamespace("synthetic-account-b")
        await model.sendFromComposer(prompt: "Account changed during Send", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(await fake.runCount == beforeAccountChange)
        try require(model.sessions.isEmpty && model.errorMessage?.contains("account changed") == true)
        try require(try model.historyDecision(chatID: chat.id, profileNamespace: model.profileNamespace!) == nil)
        try require(!model.saveHistoryDecision(true, chatID: chat.id, profileNamespace: initialNamespace))
        await model.sendFromComposer(prompt: "Must not transfer history consent", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(await fake.runCount == beforeAccountChange)
        try require(model.errorMessage?.contains("has not been allowed") == true)
        try require(model.saveHistoryDecision(false, chatID: chat.id, profileNamespace: model.profileNamespace!))
        await model.sendFromComposer(prompt: "New account without private history", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(await fake.resumedID == nil)
        try require(await fake.lastPrompt == "New account without private history")
        await fake.setMode(.authenticationFailure)
        await model.sendFromComposer(prompt: "Synthetic revoked login", chatID: chat.id, modelID: "synthetic-claude", effort: "medium")
        try require(model.turns.last?.state == .failed && model.turns.last?.outputText == "")
        try require(model.requiresFreshSignIn && !model.authenticated && model.connectionPhase == .failed)
        let attemptsAfterRejection = await fake.runCount
        await model.checkSetup() // Cached account metadata is not proof of a fresh login.
        try require(model.requiresFreshSignIn && !model.authenticated)
        try require(await fake.runCount == attemptsAfterRejection)
        await model.connectClaude()
        try require(!model.requiresFreshSignIn && model.authenticated)
        try require(await signIn.attempts == 1)
        try require(await fake.runCount == attemptsAfterRejection) // Login never resends the failed prompt.
        await model.chooseAccountMode(.separate)
        try require(!model.authenticated && model.sessions.isEmpty && model.turns.isEmpty)
        try require(try stores.value(forKey: ClaudeWorkspaceModel.accountModeKey) == "separate")

        let activity = try stores.activityRuns(limit: 100)
        try require(activity.allSatisfy { !$0.title.contains("PRIVATE_CANARY") && !($0.outcome ?? "").contains("Synthetic Claude reply") })
        try require(WorkspaceChatBackend.requiresHistoryConfirmation(from: .local, to: .claude))
        try require(WorkspaceChatBackend.requiresHistoryConfirmation(from: .codex, to: .claude))
        await model.stopBeforeTermination()
        print("[claude-workspace-check] PASS: metadata-only opening, project approval, owned sessions, durable delivery barrier, streaming, stop acknowledgements, unknown no-replay, account isolation and account-bound history consent")
    }

    private static func checkGuidedSignIn() async throws {
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let reporter = ActivityReporter(stores: stores)
        let transport = SyntheticClaudeTransport()
        await transport.setAuthenticated(false)
        let signIn = SyntheticClaudeSignIn { await transport.setAuthenticated(true) }
        let model = ClaudeWorkspaceModel()
        try model.configure(stores: stores, reporter: reporter, transport: transport, signInTransport: signIn,
            signInGuidance: .init(executable: "/synthetic/never-executed-claude", configDirectory: "/synthetic/profile",
                                 arguments: ["auth", "login", "--claudeai"], environment: [:]))
        await model.connectClaude()
        try require(model.authenticated && model.connectionPhase == .connected && !model.isBusy)
        try require(await signIn.attempts == 1)
        let checks = await transport.statusCount, runs = await transport.runCount
        try require(checks == 2 && runs == 0)
        await model.connectClaude()
        try require(await signIn.attempts == 1)
        await transport.setAuthenticated(false)
        await signIn.setHolding(true)
        let pending = Task { @MainActor in await model.connectClaude() }
        for _ in 0..<500 {
            if model.connectionPhase == .waitingForBrowser, model.signInBrowserURL != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(model.connectionPhase == .waitingForBrowser && model.isBusy)
        await model.stop(); await pending.value
        try require(model.connectionPhase == .cancelled && !model.isBusy && !model.authenticated)
        try require(model.signInBrowserURL == nil && model.errorMessage == nil)
        let signedOut = SyntheticClaudeTransport()
        await signedOut.setAuthenticated(false)
        let unverified = ClaudeWorkspaceModel()
        try unverified.configure(stores: stores, reporter: reporter, transport: signedOut,
            signInTransport: SyntheticClaudeSignIn {},
            signInGuidance: .init(executable: "/synthetic/never-executed-claude", configDirectory: "/synthetic/profile",
                                 arguments: ["auth", "login", "--claudeai"], environment: [:]))
        await unverified.connectClaude()
        try require(unverified.connectionPhase == .failed && !unverified.authenticated && !unverified.isBusy)
        try require(unverified.errorMessage?.contains("still signed out") == true)
    }

    static func prepareUI(_ app: AppModel) async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try app.prepareMonitoringFixture("idle")
        guard let stores = app.stores else { throw Failure.assertion(line: #line) }
        try require(app.createWorkspaceProject(title: "Example studies", instructions: "Explain concepts clearly." , folderURLs: []))
        try require(app.createWorkspaceChat(title: "Example discussion", kind: .primary, purpose: "A course discussion."))
        guard let projectID = app.selectedWorkspaceProjectID, let chatID = app.selectedWorkspaceChatID else { throw Failure.assertion(line: #line) }
        let review = try stores.workspacePolicyReview(projectID: projectID)
        _ = try stores.reviewWorkspacePolicy(projectID: projectID, allowedProviders: [.local, .claude], expectedRevision: review.revision)
        try app.claudeWorkspace.configure(stores: stores, reporter: app.activityReporter, transport: SyntheticClaudeTransport())
        app.claudeWorkspace.load(chatID: chatID)
        await app.claudeWorkspace.checkSetup()
        try stores.setValues([WorkspaceChatBackend.key(chatID, "backend"): "claude",
                              WorkspaceChatBackend.key(chatID, "shareHistory.claude"): "0"])
        await app.claudeWorkspace.sendFromComposer(prompt: "Explain the key idea in this synthetic example.", chatID: chatID,
            modelID: "synthetic-claude", effort: "medium")
    }

    private static func require(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw Failure.assertion(line: line) }
    }
}

private actor SyntheticClaudeSignIn: ClaudeSubscriptionSigningIn {
    private let complete: @Sendable () async -> Void
    private var holding = false
    private(set) var attempts = 0
    init(complete: @escaping @Sendable () async -> Void) { self.complete = complete }
    func setHolding(_ value: Bool) { holding = value }
    func signIn(guidance: ClaudeLoginGuidance, onBrowserURL: @escaping @Sendable (URL) async -> Void) async throws {
        attempts += 1
        await onBrowserURL(URL(string: "https://claude.ai/oauth/authorize?client_id=synthetic")!)
        for _ in 0..<500 {
            if !holding { await complete(); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeWorkspaceCheck.Failure.fixtureTimeout
    }
    func cancel() async { }
}

private actor SyntheticClaudeTransport: ClaudeWorkspaceTransport {
    enum Mode { case complete, completeThenDisconnect, failBeforeDelivery, holdBeforeDelivery, waitForStop, disconnect, authenticationFailure }
    var statusCount = 0
    var runCount = 0
    var readCount = 0
    var resumedID: String?
    var lastPrompt = ""
    private var namespace = "synthetic-account-a"
    private var authenticated = true
    private var ownership: [String: String] = [:]
    private var history: [String: [ClaudeOwnedHistoryMessage]] = [:]
    private var readFailure = false
    private var mode = Mode.complete
    private var started = false
    private var stopRequested = false
    private var stopAcknowledged = false
    func setMode(_ value: Mode) { mode = value; started = false; stopRequested = false; stopAcknowledged = false }
    func acknowledgeStop() { stopAcknowledged = true }
    func setNamespace(_ value: String) { namespace = value }
    func setAuthenticated(_ value: Bool) { authenticated = value }
    func setReadFailure(_ value: Bool) { readFailure = value }
    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if started { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeWorkspaceCheck.Failure.fixtureTimeout
    }
    func status() async throws -> ClaudeInteractiveStatus {
        statusCount += 1
        return .init(authenticated: authenticated,
            models: [.init(id: "synthetic-claude", displayName: "Synthetic Claude", efforts: ["medium"])],
            usageWindows: [.init(usedPercent: 25, durationMinutes: 300)], accountLabel: "Synthetic subscription", profileNamespace: namespace)
    }
    func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String, projectRoots: [String], userMessageID: UUID?,
             onEvent: @escaping @Sendable (ClaudeInteractiveEvent) async throws -> Void) async throws {
        runCount += 1; resumedID = sessionID; lastPrompt = prompt
        let externalID = sessionID ?? UUID().uuidString
        if sessionID == nil {
            ownership[externalID] = namespace; history[externalID] = []
            try await onEvent(.sessionCreated(externalID))
        }
        guard ownership[externalID] == namespace, let userMessageID else { throw ClaudeInteractiveError.ownership }
        if case .failBeforeDelivery = mode { throw ClaudeInteractiveError.unavailable }
        if case .holdBeforeDelivery = mode { try await holdUntilStop() }
        try await onEvent(.deliveryAttempt)
        history[externalID, default: []].append(.init(id: userMessageID.uuidString, role: "user", text: prompt))
        try await onEvent(.turnStarted(userMessageID.uuidString))
        if case .authenticationFailure = mode {
            let errorID = UUID().uuidString
            history[externalID, default: []].append(.init(id: errorID, role: "assistant", text: "SYNTHETIC_AUTH_ERROR"))
            try await onEvent(.providerFailure(code: "authenticationRequired", messageID: errorID))
            try await onEvent(.completed(state: "failed", inputTokens: nil, outputTokens: nil))
            return
        }
        try await onEvent(.contextUsage(usedTokens: 120, limitTokens: 1000))
        try await onEvent(.textDelta("Synthetic "))
        switch mode {
        case .disconnect:
            history[externalID, default: []].append(.init(id: UUID().uuidString, role: "assistant", text: "Observed uncertain provider text"))
            throw ClaudeWorkspaceCheck.Failure.simulatedDisconnect
        case .waitForStop:
            try await holdUntilStop()
            for _ in 0..<500 {
                if stopAcknowledged { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard stopAcknowledged else { throw ClaudeWorkspaceCheck.Failure.fixtureTimeout }
            try await onEvent(.completed(state: "interrupted", inputTokens: nil, outputTokens: nil))
        default:
            try await onEvent(.textDelta("Claude reply"))
            let assistantID = UUID().uuidString
            history[externalID, default: []].append(.init(id: assistantID, role: "assistant", text: "Synthetic Claude reply"))
            try await onEvent(.assistantMessage(id: assistantID, text: "Synthetic Claude reply"))
            try await onEvent(.completed(state: "completed", inputTokens: 12, outputTokens: 3))
            if case .completeThenDisconnect = mode { throw ClaudeWorkspaceCheck.Failure.simulatedDisconnect }
        }
    }
    func readOwnedSession(sessionID: String, expectedProfileNamespace: String) async throws -> ClaudeOwnedHistorySnapshot {
        readCount += 1
        if readFailure { throw ClaudeInteractiveError.unavailable }
        guard expectedProfileNamespace == namespace, ownership[sessionID] == namespace else { throw ClaudeInteractiveError.ownership }
        return .init(sessionID: sessionID, profileNamespace: namespace, messages: history[sessionID] ?? [], complete: true, observedAt: .now)
    }
    private func holdUntilStop() async throws {
        started = true
        for _ in 0..<500 {
            if stopRequested { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeWorkspaceCheck.Failure.fixtureTimeout
    }
    func interrupt() async { stopRequested = true }
    func shutdown() async { await interrupt() }
}
