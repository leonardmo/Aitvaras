import Foundation
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

/// No CLI, account, network, model, real profile or device access.
@MainActor
enum CodexWorkspaceCheck {
    enum Failure: Error { case assertion(line: Int), simulatedDisconnect }

    static func prepareUI(_ app: AppModel) async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try app.prepareMonitoringFixture("idle")
        guard let stores = app.stores else { throw Failure.assertion(line: #line) }
        try require(app.createWorkspaceProject(title: "Example studies", instructions: "Explain concepts clearly and cite sources.", folderURLs: []))
        try require(app.createWorkspaceChat(title: "Example course", kind: .primary, purpose: "A permanent course discussion."))
        guard let projectID = app.selectedWorkspaceProjectID, let chatID = app.selectedWorkspaceChatID else { throw Failure.assertion(line: #line) }
        let review = try stores.workspacePolicyReview(projectID: projectID)
        _ = try stores.reviewWorkspacePolicy(projectID: projectID, allowedProviders: [.local, .codex], expectedRevision: review.revision)
        try app.codexWorkspace.configure(stores: stores, reporter: app.activityReporter, transport: SyntheticCodexTransport())
        app.codexWorkspace.load(chatID: chatID)
        await app.codexWorkspace.checkSetup()
        app.codexWorkspace.prepareReview(chatID: chatID)
        try require(app.codexWorkspace.createSession(chatID: chatID, model: "synthetic-model", effort: "medium"))
        // A Local exchange first, then Codex with history sharing on, so the
        // snapshot shows the handover line between them (D30).
        guard let conversationID = try stores.workspaceChat(id: chatID)?.localConversationID else { throw Failure.assertion(line: #line) }
        try stores.appendMessage(StoredMessage(conversationID: conversationID, role: "user",
            content: "What is a gradient, in one sentence?", createdAt: .now.addingTimeInterval(-60)))
        try stores.appendMessage(StoredMessage(conversationID: conversationID, role: "assistant",
            content: "It points in the direction in which a function increases fastest.", createdAt: .now.addingTimeInterval(-50)))
        try stores.setValues([WorkspaceChatBackend.key(chatID, "shareHistory.codex"): "1",
                              WorkspaceChatBackend.key(chatID, "backend"): "codex"])
        await app.codexWorkspace.sendFromComposer(prompt: "Explain the key idea in this synthetic example.", chatID: chatID,
                                                  modelID: "synthetic-model", effort: "medium")
        try require(try stores.workspaceHandovers(chatID: chatID).count == 1)
    }

    static func run() async throws {
        precondition(AitvarasPaths.isIsolated && ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1")
        try require(WorkspaceChatBackend.requiresHistoryConfirmation(from: .local, to: .codex))
        try require(WorkspaceChatBackend.requiresHistoryConfirmation(from: .claude, to: .codex))
        try require(!WorkspaceChatBackend.requiresHistoryConfirmation(from: .codex, to: .local))
        let stores = Stores(db: try AitvarasDatabase(url: nil))
        let reporter = ActivityReporter(stores: stores)
        let project = try stores.createWorkspaceProject(title: "Synthetic frontier project", instructions: "SYNTHETIC_REVIEWED_CONTEXT")
        let review = try stores.workspacePolicyReview(projectID: project.id)
        _ = try stores.reviewWorkspacePolicy(projectID: project.id, allowedProviders: [.local, .codex], expectedRevision: review.revision)
        let fake = SyntheticCodexTransport()
        let model = CodexWorkspaceModel()
        try model.configure(stores: stores, reporter: reporter, transport: fake)
        let chat = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic course", kind: .primary)
        model.load(chatID: chat.id)
        try require(await fake.callCount == 0)
        await model.signIn()
        try require(model.authenticated && model.models.count == 1)
        await model.checkSetup()
        try require(model.authenticated && model.models.count == 1)
        model.prepareReview(chatID: chat.id)
        try require(model.reviewedContext?.contains("SYNTHETIC_REVIEWED_CONTEXT") == true)
        try require(model.createSession(chatID: chat.id, model: "synthetic-model", effort: "medium"))
        try require(await fake.runCount == 0)
        await model.send(prompt: "Synthetic first message", chatID: chat.id)
        try require(model.turns.count == 1 && model.turns[0].state == .completed
            && model.turns[0].outputText == "Synthetic reply" && model.turns[0].inputTokens == 12)
        let ownID = model.sessions.first?.externalID
        try require(ownID != nil)
        let beforeMismatch = await fake.runCount
        await model.send(prompt: "Must not cross chat boundaries", chatID: UUID())
        await model.send(prompt: String(repeating: "🐉", count: 17_000), chatID: chat.id)
        try require(await fake.runCount == beforeMismatch)
        await model.send(prompt: "Synthetic follow-up", chatID: chat.id)
        try require(model.turns.count == 2 && model.turns.allSatisfy { $0.state == .completed })
        try require(await fake.resumedID == ownID)
        try require(try stores.messages(in: chat.localConversationID).isEmpty)

        await fake.setMode(.completeThenDisconnect)
        await model.send(prompt: "Synthetic completion followed by cleanup failure", chatID: chat.id)
        try require(model.turns.last?.state == .completed)
        try require(model.errorMessage?.contains("outcome is saved") == true)

        // Stop remains pending until the worker reports an interrupted turn.
        await fake.setMode(.waitForStop)
        let stopping = Task { @MainActor in await model.send(prompt: "Synthetic stop", chatID: chat.id) }
        await fake.waitUntilStarted()
        try require(model.isBusy && model.turns.last?.state == .running)
        await model.stop()
        await stopping.value
        try require(!model.isBusy && model.turns.last?.state == .cancelled)

        // A failure before the prompt is released sent nothing: the turn is
        // failed, not unknown, keeps its reason, and the same thread carries on.
        await fake.setMode(.failBeforeDelivery)
        let threadBefore = model.selectedSessionID
        await model.send(prompt: "Synthetic start failure", chatID: chat.id)
        let undelivered = model.turns.last
        try require(undelivered?.state == .failed && undelivered?.providerTurnID == nil)
        try require(try stores.workspaceFrontierTurnFailureReason(id: undelivered!.id) == "The dedicated Codex connection stopped.")
        try require(model.errorMessage?.hasPrefix("Nothing was sent.") == true
            && model.errorMessage?.contains("unknown") == false)
        try require(try stores.workspaceChatTimeline(chatID: chat.id).contains { $0.text == "Synthetic start failure" && $0.notDelivered })
        await fake.setMode(.complete)
        await model.send(prompt: "Synthetic retry after start failure", chatID: chat.id)
        try require(model.turns.last?.state == .completed && model.selectedSessionID == threadBefore)

        // Stopping before release sends nothing and is recorded as stopped.
        await fake.setMode(.holdBeforeDelivery)
        let early = Task { @MainActor in await model.send(prompt: "Synthetic early stop", chatID: chat.id) }
        await fake.waitUntilStarted()
        try require(model.isBusy && model.turns.last?.state == .prepared)
        await model.stop()
        await early.value
        try require(model.turns.last?.state == .cancelled && model.turns.last?.providerTurnID == nil)
        try require(model.errorMessage == "Stopped before sending. Nothing was sent.")
        try require(model.selectedSessionID == threadBefore)

        // Unknown delivery is saved as unknown and is never retried.
        await fake.setMode(.disconnect)
        await model.send(prompt: "Synthetic disconnect", chatID: chat.id)
        try require(model.turns.last?.state == .outcomeUnknown)
        let calls = await fake.runCount
        await model.send(prompt: "Must not replay unresolved conversation", chatID: chat.id)
        try require(await fake.runCount == calls)
        try require(!model.isBusy)

        // A stale reviewed project is refused before a provider call.
        let other = try stores.createWorkspaceChat(projectID: project.id, title: "Synthetic other course", kind: .primary)
        model.load(chatID: other.id)
        model.prepareReview(chatID: other.id)
        try require(model.createSession(chatID: other.id, model: "synthetic-model", effort: nil))
        var edited = try stores.workspaceProject(id: project.id)!
        edited.instructions = "SYNTHETIC_CHANGED_CONTEXT"
        try stores.saveWorkspaceProject(edited)
        await model.send(prompt: "Must not send stale context", chatID: other.id)
        try require(await fake.runCount == calls)

        let runs = try stores.activityRuns(limit: 100)
        try require(runs.allSatisfy { !$0.title.contains("Synthetic first message") && !($0.outcome ?? "").contains("Synthetic reply") })
        await model.stopBeforeTermination()
        // The simplified composer creates a session only on explicit Send.
        let simpleStores = Stores(db: try AitvarasDatabase(url: nil))
        let simpleReporter = ActivityReporter(stores: simpleStores)
        let simpleProject = try simpleStores.createWorkspaceProject(title: "Synthetic simple project")
        let simpleChat = try simpleStores.createWorkspaceChat(projectID: simpleProject.id, title: "Synthetic chat")
        let simpleFake = SyntheticCodexTransport()
        let simple = CodexWorkspaceModel()
        try simple.configure(stores: simpleStores, reporter: simpleReporter, transport: simpleFake)
        simple.load(chatID: simpleChat.id)
        try require(await simpleFake.callCount == 0)
        try require(simple.sessions.isEmpty && simple.projectIssue != nil)
        await simple.checkSetup()
        await simple.sendFromComposer(prompt: "Refused before project Save", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(await simpleFake.runCount == 0)
        try require(simple.sessions.isEmpty)
        let settings = try simpleStores.workspacePolicyReview(projectID: simpleProject.id)
        _ = try simpleStores.saveWorkspaceProjectSettings(projectID: simpleProject.id, title: simpleProject.title,
            instructions: "Synthetic instructions", folders: [], allowedProviders: [.local, .codex],
            expectedContextRevision: settings.revision, expectedPolicyRevision: nil, expectedProjectTitle: simpleProject.title)
        simple.prepareReview(chatID: simpleChat.id, reportError: false)
        await simple.sendFromComposer(prompt: "Explicit first Send", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(simple.sessions.count == 1 && simple.turns.count == 1 && simple.turns[0].state == .completed)
        try require(await simpleFake.runCount == 1)
        await simple.sendFromComposer(prompt: "Explicit follow-up", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(simple.sessions.count == 1 && simple.turns.count == 2)
        simple.selectedSessionID = nil
        await simple.sendFromComposer(prompt: "Invalid model refused", chatID: simpleChat.id, modelID: "missing-model", effort: nil)
        try require(simple.sessions.count == 1)
        let runsBefore = await simpleFake.runCount
        await simple.sendFromComposer(prompt: " ", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(await simpleFake.runCount == runsBefore)
        try simpleStores.appendMessage(.init(conversationID: simpleChat.localConversationID, role: "user", content: "LOCAL_PRIVATE_CANARY"))
        await simple.sendFromComposer(prompt: "No history permission yet", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(await simpleFake.lastPrompt == "No history permission yet")
        let unsharedSession = simple.selectedSessionID
        try simpleStores.setValue("1", forKey: "workspace.chat.\(simpleChat.id).shareHistory.codex")
        try simpleStores.appendMessage(.init(conversationID: simpleChat.localConversationID, role: "assistant", content: "LOCAL_SHARED_CANARY"))
        await simple.sendFromComposer(prompt: "Continue this shared chat", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        // D30: the same thread is kept and caught up on what it missed.
        try require(simple.selectedSessionID == unsharedSession)
        let sentPrompt = await simpleFake.lastPrompt
        try require(sentPrompt.hasPrefix(WorkspaceHandoverText.header) && sentPrompt.contains("LOCAL_PRIVATE_CANARY")
            && sentPrompt.contains("LOCAL_SHARED_CANARY") && sentPrompt.hasSuffix("\nContinue this shared chat"))
        // Its own earlier turns are not sent back to it.
        try require(!sentPrompt.contains("No history permission yet"))
        try require(simple.turns.last?.promptText == "Continue this shared chat")
        let handovers = try simpleStores.workspaceHandovers(chatID: simpleChat.id)
        // This chat already moved to a second Codex thread above, so the
        // handover also carries the first thread's turns it never saw.
        try require(handovers.count == 1 && handovers[0].entryCount == 6 && handovers[0].turnID == simple.turns.last?.id)
        try require(sentPrompt.contains("[user · Codex] Explicit first Send") && sentPrompt.contains("from Local, Codex"))
        let handoverEntry = try simpleStores.workspaceChatTimeline(chatID: simpleChat.id).first { $0.role == "handover" }
        try require(handoverEntry.map(WorkspaceChatTranscriptView.handoverTitle) == "Caught Codex up on 6 messages from Local, Codex")
        // Nothing new since: the next message goes alone.
        await simple.sendFromComposer(prompt: "Nothing missed", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(await simpleFake.lastPrompt == "Nothing missed")
        // A Local exchange in between is the only thing handed over next time.
        try simpleStores.appendMessage(.init(conversationID: simpleChat.localConversationID, role: "user", content: "LOCAL_BETWEEN_CANARY",
                                             createdAt: Date.now.addingTimeInterval(1)))
        await simple.sendFromComposer(prompt: "Back to Codex", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        let delta = await simpleFake.lastPrompt
        try require(simple.selectedSessionID == unsharedSession && delta.contains("LOCAL_BETWEEN_CANARY")
            && !delta.contains("LOCAL_SHARED_CANARY") && delta.contains("· 1 message from Local"))
        let readReview = try simpleStores.workspacePolicyReview(projectID: simpleProject.id)
        let readPolicy = try simpleStores.workspacePolicy(projectID: simpleProject.id)
        _ = try simpleStores.saveWorkspaceProjectSettings(projectID: simpleProject.id, title: simpleProject.title,
            instructions: readReview.instructions, folders: [.init(path: "/synthetic/approved")], allowedProviders: [.codex],
            expectedContextRevision: readReview.revision, expectedPolicyRevision: readPolicy?.revision,
            expectedProjectTitle: simpleProject.title, allowCodexFileRead: true)
        await simple.sendFromComposer(prompt: "Read approved files", chatID: simpleChat.id, modelID: "synthetic-model", effort: nil)
        try require(await simpleFake.lastRoots == ["/synthetic/approved"])
        try require(simple.contextUsedTokens == 120 && simple.contextLimitTokens == 1000)
        try require(simple.usageWindows.first?.usedPercent == 25)
        // A handover shrinks to fit the native byte limit beside a large message.
        try simpleStores.appendMessage(.init(conversationID: simpleChat.localConversationID, role: "assistant",
            content: String(repeating: "🔥", count: 16_000), createdAt: Date.now.addingTimeInterval(2)))
        let large = String(repeating: "🐉", count: 9_000)
        if let plan = try CodexWorkspaceModel.handoverPlan(stores: simpleStores, chatID: simpleChat.id,
                threadKey: WorkspaceThreadKey.codexSession(unsharedSession!), prompt: large) {
            try require(WorkspaceHandoverText.wire(handover: plan.text, message: large).utf8.count <= CodexWorkspaceModel.maximumWireBytes)
        }
        await simple.stopBeforeTermination()
        print("[codex-workspace-check] PASS: local-only opening, exact review, owned binding, streaming, follow-up, stop acknowledgement, undelivered start failures and early stops, kept threads caught up by handover, unknown-outcome blocking, stale context and metadata-only activity")
    }

    private static func require(_ value: Bool, line: Int = #line) throws {
        guard value else { throw Failure.assertion(line: line) }
    }
}

private actor SyntheticCodexTransport: CodexWorkspaceTransport {
    enum Mode { case complete, completeThenDisconnect, waitForStop, disconnect, failBeforeDelivery, holdBeforeDelivery }
    var callCount = 0
    var runCount = 0
    var resumedID: String?
    var lastPrompt = ""
    var lastRoots: [String] = []
    private var mode = Mode.complete
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func setMode(_ value: Mode) { mode = value; started = false }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func status() async throws -> CodexInteractiveStatus {
        callCount += 1
        return CodexInteractiveStatus(authenticated: true,
            models: [CodexInteractiveModel(id: "synthetic-model", displayName: "Synthetic model", efforts: ["medium"])],
            usageSummary: "Synthetic quota fixture",
            usageWindows: [.init(usedPercent: 25, durationMinutes: 300)])
    }
    func login(onEvent: @escaping @Sendable (CodexInteractiveEvent) async throws -> Void) async throws {
        callCount += 1
        try await onEvent(.loginCompleted(true))
    }
    func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String, projectRoots: [String],
             onEvent: @escaping @Sendable (CodexInteractiveEvent) async throws -> Void) async throws {
        callCount += 1
        runCount += 1
        resumedID = sessionID
        lastPrompt = prompt
        lastRoots = projectRoots
        if sessionID == nil { try await onEvent(.threadCreated("synthetic-owned-\(runCount)")) }
        // Like the real helper: the prompt is released only after the app
        // has recorded the delivery attempt.
        switch mode {
        case .failBeforeDelivery: throw CodexInteractiveError.unavailable
        case .holdBeforeDelivery:
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
                started = true
                startedContinuation?.resume()
                startedContinuation = nil
            }
        default: break
        }
        try await onEvent(.deliveryAttempt)
        try await onEvent(.turnStarted("synthetic-turn-\(runCount)"))
        try await onEvent(.contextUsage(usedTokens: 120, limitTokens: 1000))
        if !projectRoots.isEmpty { try await onEvent(.projectFileAccess(tool: "aitvaras_project_read", path: "project[0]/example.txt", bytes: 8)) }
        try await onEvent(.textDelta("Synthetic "))
        switch mode {
        case .disconnect: throw CodexWorkspaceCheck.Failure.simulatedDisconnect
        case .waitForStop:
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
                started = true
                startedContinuation?.resume()
                startedContinuation = nil
            }
            try await onEvent(.completed(state: "interrupted", inputTokens: nil, outputTokens: nil))
        // A held prompt that is wrongly released completes, so the check sees it.
        case .complete, .completeThenDisconnect, .failBeforeDelivery, .holdBeforeDelivery:
            try await onEvent(.textDelta("reply"))
            try await onEvent(.completed(state: "completed", inputTokens: 12, outputTokens: 3))
            if case .completeThenDisconnect = mode { throw CodexWorkspaceCheck.Failure.simulatedDisconnect }
        }
    }
    func interrupt() async { stopContinuation?.resume(); stopContinuation = nil }
    func shutdown() async { await interrupt() }
}
