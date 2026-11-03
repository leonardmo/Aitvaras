import AppKit
import Foundation
import Observation
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

protocol CodexWorkspaceTransport: Sendable {
    func status() async throws -> CodexInteractiveStatus
    func login(onEvent: @escaping @Sendable (CodexInteractiveEvent) async throws -> Void) async throws
    func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String, projectRoots: [String],
             onEvent: @escaping @Sendable (CodexInteractiveEvent) async throws -> Void) async throws
    func interrupt() async
    func shutdown() async
}

extension CodexInteractiveClient: CodexWorkspaceTransport {}

/// App-owned execution is intentionally separate from imported native history.
/// Switching views never owns or cancels the provider worker.
@MainActor
@Observable
final class CodexWorkspaceModel {
    private(set) var sessions: [WorkspaceFrontierSession] = []
    private(set) var turns: [WorkspaceFrontierTurn] = []
    private(set) var models: [CodexInteractiveModel] = []
    private(set) var authenticated = false
    private(set) var accountChecked = false
    private(set) var isBusy = false
    private(set) var isStopping = false
    private(set) var status: String?
    private(set) var errorMessage: String?
    private(set) var usageSummary = "Usage has not been checked"
    private(set) var usageWindows: [CodexUsageWindow] = []
    private(set) var contextUsedTokens: Int?
    private(set) var contextLimitTokens: Int?
    private(set) var reviewedContext: String?
    private(set) var reviewRevision: Int?
    private(set) var projectIssue: String?
    var selectedSessionID: UUID? { didSet { refreshTurns() } }
    var reporter: ActivityReporter?

    @ObservationIgnored private var stores: Stores?
    @ObservationIgnored private var client: (any CodexWorkspaceTransport)?
    @ObservationIgnored private var loadedChatID: UUID?
    @ObservationIgnored private var activeTurn: WorkspaceFrontierTurn?
    /// The handover travelling with the active turn; recorded once Codex
    /// acknowledges the turn, which is what moves the thread's watermark (D30).
    @ObservationIgnored private var pendingHandover: (plan: WorkspaceHandoverPlan, chatID: UUID)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activityID: UUID?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var checkpointCharacters = 0
    @ObservationIgnored private var terminating = false

    func configure(stores: Stores, reporter: ActivityReporter?, transport: (any CodexWorkspaceTransport)? = nil) throws {
        guard self.stores == nil else { return }
        // Exactly once at startup, before any provider process can exist.
        _ = try stores.reconcileUnfinishedWorkspaceFrontierTurns()
        self.stores = stores
        self.reporter = reporter
        client = transport ?? CodexInteractiveClient(profileDirectory:
            AitvarasPaths.stateDirectory.appendingPathComponent("codex-interactive", isDirectory: true))
    }

    func load(chatID: UUID) {
        guard !isBusy, let stores else { return }
        do {
            if loadedChatID != chatID { contextUsedTokens = nil; contextLimitTokens = nil }
            let previous = loadedChatID == chatID ? selectedSessionID : nil
            sessions = try stores.workspaceFrontierSessions(chatID: chatID)
            loadedChatID = chatID
            selectedSessionID = sessions.contains(where: { $0.id == previous }) ? previous : sessions.last?.id
            reviewedContext = nil
            reviewRevision = nil
            refreshTurns()
            prepareReview(chatID: chatID, reportError: false)
        } catch { errorMessage = "Saved Codex conversations could not be loaded." }
    }

    private func refreshTurns() {
        guard let stores else { return }
        do { turns = try selectedSessionID.map { try stores.workspaceFrontierTurns(sessionID: $0) } ?? [] }
        catch { errorMessage = "Saved Codex messages could not be loaded." }
    }

    func prepareReview(chatID: UUID, reportError: Bool = true) {
        guard !isBusy, let stores else { return }
        reviewedContext = nil
        reviewRevision = nil
        do {
            let packet = try stores.workspaceContextPacket(chatID: chatID)
            guard packet.policyStatus == .reviewed,
                  try stores.workspacePolicy(projectID: packet.projectID)?.allowedProviders.contains(.codex) == true else {
                throw WorkspaceFrontierError.reviewRequired
            }
            reviewedContext = packet.promptText
            reviewRevision = packet.policyRevision
            projectIssue = nil
            errorMessage = nil
        } catch {
            projectIssue = "Enable Codex in this project's settings and save."
            if reportError { errorMessage = projectIssue }
        }
    }

    /// Sending is the explicit action that creates a conversation. Selection,
    /// account checks and project settings never start a provider turn.
    func sendFromComposer(prompt: String, chatID: UUID, modelID: String, effort: String?) async {
        guard !isBusy, !terminating, loadedChatID == chatID, let stores else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, prompt.count <= Stores.maximumWorkspaceFrontierPromptCharacters,
              prompt.utf8.count <= 65_536 else {
            errorMessage = "Shorten this message before sending. Nothing was sent."
            return
        }
        guard models.contains(where: { $0.id == modelID && (effort == nil || $0.efforts.contains(effort!)) }) else {
            errorMessage = "Choose an available model in AI Settings. No message was sent."
            return
        }
        prepareReview(chatID: chatID)
        guard projectIssue == nil else { return }
        // Backend threads are implementation details of one Aitvaras chat.
        // A thread is kept across Local turns and caught up on Send (D30); a
        // new one is used only when its reviewed context, model or effort no
        // longer match, or an uncertain turn blocks it. Nothing is replayed.
        let current = sessions.first { $0.id == selectedSessionID }
        if current?.policyRevision != reviewRevision || current?.reviewedContext != reviewedContext
            || current?.model != modelID || current?.effort != effort
            || turns.contains(where: { $0.state.blocksNewTurn }) {
            selectedSessionID = nil
        }
        if selectedSessionID == nil {
            guard createSession(chatID: chatID, model: modelID, effort: effort) else { return }
        }
        guard let sessionID = selectedSessionID else { return }
        let handover: WorkspaceHandoverPlan?
        do {
            let allowed = try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.codex") == "1"
            handover = allowed ? try Self.handoverPlan(stores: stores, chatID: chatID,
                threadKey: WorkspaceThreadKey.codexSession(sessionID), prompt: prompt) : nil
        } catch {
            errorMessage = "Chat history could not be prepared. Your message was not sent."
            return
        }
        await send(prompt: prompt, chatID: chatID, handover: handover)
    }

    static let maximumWireBytes = 65_536

    /// What this thread has not seen, fitted beside the message (D30).
    static func handoverPlan(stores: Stores, chatID: UUID, threadKey: String, prompt: String) throws -> WorkspaceHandoverPlan? {
        try stores.workspaceHandoverPlan(chatID: chatID, threadKey: threadKey, fittingBeside: prompt, maximumBytes: maximumWireBytes)
    }

    func connectAccount() async {
        await checkSetup()
        if !authenticated, errorMessage == nil { await signIn() }
    }

    func createSession(chatID: UUID, model: String, effort: String?) -> Bool {
        guard !isBusy, !terminating, authenticated, let stores,
              let reviewedContext, let reviewRevision,
              let available = models.first(where: { $0.id == model }),
              effort == nil || available.efforts.contains(effort!) else { return false }
        do {
            let session = try stores.createWorkspaceFrontierSession(chatID: chatID, model: model,
                effort: effort, expectedPolicyRevision: reviewRevision, reviewedContext: reviewedContext)
            loadedChatID = chatID
            sessions = try stores.workspaceFrontierSessions(chatID: chatID)
            selectedSessionID = session.id
            status = "Chat prepared. Nothing is sent until you send a message."
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not prepare this conversation. Open Project settings, enable Codex and save the current settings."
            return false
        }
    }

    func checkSetup() async {
        guard !isBusy, !terminating, let client else { return }
        guard begin(title: "Check Codex account and models", access: "Separate Codex profile account status, model catalog and quota",
            destination: "OpenAI account and model services") else { return }
        let task = Task { @MainActor in
            defer { self.end() }
            do {
                let result = try await client.status()
                self.authenticated = result.authenticated
                self.accountChecked = true
                self.models = result.models
                self.usageSummary = "Checked \(Date.now.formatted(date: .omitted, time: .shortened)) · \(result.usageSummary)"
                self.usageWindows = result.usageWindows ?? []
                self.status = result.authenticated ? "Codex account connected" : "Codex account not connected"
                self.errorMessage = nil
                self.reporter?.finish(id: self.activityID!, state: .succeeded, outcome: "Codex setup checked")
            } catch {
                self.authenticated = false
                self.accountChecked = true
                self.models = []
                self.usageSummary = "Usage unavailable"
                self.usageWindows = []
                self.status = "Codex connection setup failed. No message was sent."
                self.errorMessage = Self.safeSetupError(error) ?? "Codex setup could not be verified. No message was sent. Check the CLI installation and connection, then retry."
                self.reporter?.update(id: self.activityID!, stage: "Setup failed")
                self.reporter?.finish(id: self.activityID!, state: .failed,
                    outcome: Self.safeSetupError(error) ?? "Codex setup could not be verified")
            }
        }
        worker = task
        await task.value
    }

    func signIn() async {
        guard !isBusy, !terminating, let client else { return }
        guard begin(title: "Sign in to Codex", access: "Separate official ChatGPT authentication",
            destination: "Official ChatGPT sign-in; credentials in macOS Keychain") else { return }
        let task = Task { @MainActor in
            defer { self.end() }
            do {
                try await client.login { [weak self] event in
                    try await self?.receiveLogin(event)
                }
                guard !self.isStopping else { throw CancellationError() }
                let result = try await client.status()
                guard result.authenticated else { throw CodexInteractiveError.signInRequired }
                self.authenticated = true
                self.accountChecked = true
                self.models = result.models
                self.usageSummary = "Checked \(Date.now.formatted(date: .omitted, time: .shortened)) · \(result.usageSummary)"
                self.usageWindows = result.usageWindows ?? []
                self.status = "Codex account connected"
                self.errorMessage = nil
                self.reporter?.finish(id: self.activityID!, state: .succeeded, outcome: "Codex sign-in finished")
            } catch {
                self.authenticated = false
                self.models = []
                self.status = "Sign-in was not verified. Retry in AI Settings."
                self.errorMessage = Self.safeSetupError(error) ?? "Codex sign-in did not finish. No conversation was sent."
                self.reporter?.update(id: self.activityID!, stage: "Sign-in failed")
                self.reporter?.finish(id: self.activityID!, state: .failed,
                    outcome: Self.safeSetupError(error) ?? "Codex sign-in did not finish")
            }
        }
        worker = task
        await task.value
    }

    private func receiveLogin(_ event: CodexInteractiveEvent) throws {
        switch event {
        case .loginURL(let raw):
            guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
                  ["auth.openai.com", "auth0.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? "") else {
                throw WorkspaceFrontierError.invalidValue
            }
            guard NSWorkspace.shared.open(url) else { throw CodexInteractiveError.unavailable }
            status = "Complete the official sign-in in your browser."
            if let activityID { reporter?.update(id: activityID, stage: "Waiting for browser sign-in", state: .waiting) }
        case .loginCompleted(let success):
            guard success else { throw WorkspaceFrontierError.reviewRequired }
            status = "Verifying the saved account and loading available models"
            if let activityID { reporter?.update(id: activityID, stage: "Verifying saved sign-in", state: .running) }
        default: throw WorkspaceFrontierError.invalidTransition
        }
    }

    func send(prompt: String, chatID: UUID, handover: WorkspaceHandoverPlan? = nil) async {
        guard prompt.utf8.count <= 65_536 else {
            errorMessage = "This message exceeds the native text byte limit. Shorten it before sending; nothing was sent."
            return
        }
        guard !isBusy, !terminating, let stores, let client, let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }), authenticated,
              reporter?.failureMessage == nil else { return }
        guard loadedChatID == chatID, session.chatID == chatID else {
            errorMessage = "The visible chat changed. Select it again before sending."
            return
        }
        guard models.contains(where: { $0.id == session.model && (session.effort == nil || $0.efforts.contains(session.effort!)) }) else {
            errorMessage = "This model or reasoning level is unavailable. Choose another in AI Settings; no fallback was used."
            return
        }
        do {
            let projectRoots = try stores.workspaceCodexReadRoots(chatID: chatID, expectedPolicyRevision: session.policyRevision)
            var turn = try stores.beginWorkspaceFrontierTurn(sessionID: id, prompt: prompt)
            guard begin(title: "Codex reply", access: handover == nil
                ? "Project instructions, message, native runtime metadata\(projectRoots.isEmpty ? "" : ", approved read-only project files on request")"
                : "Project instructions, recent shared messages, current message, native runtime metadata\(projectRoots.isEmpty ? "" : ", approved read-only project files on request")",
                destination: "OpenAI via Codex") else {
                turn.state = .failed
                turn.endedAt = .now
                try stores.saveWorkspaceFrontierTurn(turn)
                refreshTurns()
                return
            }
            // The turn stays prepared (saved, not sent) until the helper asks to
            // release the prompt; only then does it become running. A failure
            // before that point provably sent nothing and is safe to retry.
            activeTurn = turn
            pendingHandover = handover.map { ($0, chatID) }
            contextUsedTokens = nil
            contextLimitTokens = nil
            lastCheckpoint = .now
            checkpointCharacters = 0
            refreshTurns()
            let task = Task { @MainActor in
                defer { self.activeTurn = nil; self.pendingHandover = nil; self.refreshTurns(); self.end() }
                do {
                    try await client.run(sessionID: session.externalID, context: session.reviewedContext,
                        model: session.model, effort: session.effort, prompt: WorkspaceHandoverText.wire(handover: handover?.text, message: prompt), projectRoots: projectRoots) { [weak self] event in
                            guard let self else { throw CancellationError() }
                            try await self.receive(event, sessionID: id)
                        }
                    guard self.activeTurn?.state.isTerminal == true else { throw WorkspaceFrontierError.invalidTransition }
                } catch {
                    if self.activeTurn?.state.isTerminal == true {
                        // A provider acknowledgement already saved successfully
                        // is not undone by a later pipe/cleanup/telemetry error.
                        self.errorMessage = "The provider outcome is saved, but connection cleanup did not finish normally. No message will be retried."
                        return
                    }
                    let reason = Self.safeError(error)
                    if var pending = self.activeTurn, pending.state == .prepared {
                        // Never released to the provider: nothing was sent.
                        let stopped = self.isStopping
                        pending.state = stopped ? .cancelled : .failed
                        pending.endedAt = .now
                        do {
                            try stores.saveWorkspaceFrontierTurn(pending); self.activeTurn = pending
                            if !stopped { try stores.recordWorkspaceFrontierTurnFailure(id: pending.id, reason: reason ?? "Codex could not start.") }
                        } catch { /* Leave unfinished durable state for startup reconciliation. */ }
                        self.errorMessage = stopped ? "Stopped before sending. Nothing was sent."
                            : ["Nothing was sent.", reason, "Your message is still in the box; press Send to try again."].compactMap { $0 }.joined(separator: " ")
                        self.reporter?.finish(id: self.activityID!, state: stopped ? .cancelled : .failed,
                            outcome: stopped ? "Stopped before delivery; nothing was sent" : "Could not start; nothing was sent")
                        return
                    }
                    if var pending = self.activeTurn, !pending.state.isTerminal {
                        pending.state = .outcomeUnknown
                        pending.endedAt = .now
                        do {
                            try stores.saveWorkspaceFrontierTurn(pending); self.activeTurn = pending
                            try stores.recordWorkspaceFrontierTurnFailure(id: pending.id, reason: reason ?? "Connection ended without a confirmed outcome.")
                        } catch { /* Leave unfinished durable state for startup reconciliation. */ }
                    }
                    self.errorMessage = [reason, "Codex stopped without a verified outcome. Partial text is saved where possible. This message will not be replayed. A new message can use a fresh connection."].compactMap { $0 }.joined(separator: " ")
                    self.reporter?.finish(id: self.activityID!, state: .outcomeUnknown, outcome: "Provider outcome could not be verified; no automatic retry")
                }
            }
            worker = task
            await task.value
        } catch {
            errorMessage = "Message not sent. Check Project settings and local storage, then try a new message. Earlier uncertain messages will not be retried."
            if isBusy { reporter?.finish(id: activityID!, state: .failed, outcome: "Message not sent because preparation failed"); end() }
            refreshTurns()
        }
    }

    private func receive(_ event: CodexInteractiveEvent, sessionID: UUID) throws {
        guard let stores, var turn = activeTurn, !turn.state.isTerminal else { throw WorkspaceFrontierError.invalidTransition }
        switch event {
        case .threadCreated(let externalID):
            _ = try stores.bindWorkspaceFrontierSession(id: sessionID, externalID: externalID)
            if let chatID = loadedChatID { sessions = try stores.workspaceFrontierSessions(chatID: chatID) }
        case .deliveryAttempt:
            // Recorded before the helper may write the prompt. Refusing here
            // (a stop, a second attempt) keeps the prompt undelivered.
            guard turn.state == .prepared, !isStopping else { throw CancellationError() }
            turn.state = .running
            try stores.saveWorkspaceFrontierTurn(turn)
        case .turnStarted(let externalID):
            if turn.state == .prepared { turn.state = .running }
            turn.providerTurnID = externalID
            try stores.saveWorkspaceFrontierTurn(turn)
            if let (plan, chatID) = pendingHandover {
                pendingHandover = nil
                // Failing to record only means the next Send repeats these
                // messages; it never ends a delivered turn.
                _ = try? stores.recordWorkspaceHandover(plan, chatID: chatID, turnID: turn.id,
                                                        anchor: turn.startedAt.addingTimeInterval(-0.001))
            }
            status = isStopping ? "Stop requested · awaiting Codex" : "Codex is responding"
            reporter?.update(id: activityID!, stage: status)
        case .textDelta(let text):
            guard turn.outputText.count + text.count <= 200_000 else { throw WorkspaceFrontierError.invalidValue }
            turn.outputText += text
            if Date.now.timeIntervalSince(lastCheckpoint) >= 0.5 || turn.outputText.count - checkpointCharacters >= 4096 {
                try stores.saveWorkspaceFrontierTurn(turn)
                lastCheckpoint = .now
                checkpointCharacters = turn.outputText.count
            }
        case .contextUsage(let used, let limit):
            contextUsedTokens = used
            contextLimitTokens = limit
        case .projectFileAccess(let tool, let path, let bytes):
            reporter?.update(id: activityID!, stage: "Reading approved project files")
            let detail = try JSONSerialization.data(withJSONObject: ["tool": tool, "path": path, "bytes": bytes])
            _ = try stores.record(ActivityEvent(kind: .toolExecuted, connectorID: "codex",
                summary: "Read-only project file request", detailJSON: String(decoding: detail, as: UTF8.self),
                runID: activityID))
        case .completed(let state, let inputTokens, let outputTokens):
            switch state {
            case "completed": turn.state = .completed
            case "interrupted": turn.state = .cancelled
            case "failed": turn.state = .failed
            default: throw WorkspaceFrontierError.invalidTransition
            }
            turn.inputTokens = inputTokens
            turn.outputTokens = outputTokens
            turn.endedAt = .now
            try stores.saveWorkspaceFrontierTurn(turn, allowCompletedAfterCancellation: true)
            let result: ActivityRunState = turn.state == .completed ? .succeeded : turn.state == .cancelled ? .cancelled : .failed
            reporter?.finish(id: activityID!, state: result, outcome: "Codex turn \(turn.state.rawValue)")
            status = turn.state == .completed ? "Reply saved" : turn.state == .cancelled ? "Codex confirmed the stop" : "Codex reported a failed turn"
        default: throw WorkspaceFrontierError.invalidTransition
        }
        activeTurn = turn
        if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
    }

    func stop() async {
        guard isBusy, !isStopping, let client else { return }
        guard activeTurn?.state.isTerminal != true else { return }
        isStopping = true
        status = "Stop requested · awaiting Codex"
        if activeTurn?.state == .prepared {
            // Not released yet: the barrier will refuse, so nothing is sent.
            status = "Stopping before sending"
        } else if var turn = activeTurn, !turn.state.isTerminal {
            turn.state = .cancellationRequested
            do { try stores?.saveWorkspaceFrontierTurn(turn); activeTurn = turn }
            catch { errorMessage = "Could not save the stop request. Waiting for the provider's actual outcome." }
        }
        if let activityID { reporter?.update(id: activityID, stage: "Stop requested", state: .cancellationRequested) }
        await client.interrupt()
    }

    func stopBeforeTermination() async {
        terminating = true
        let pending = worker
        await stop()
        await client?.shutdown()
        await pending?.value
    }

    func resumeAfterCancelledTermination() { terminating = false }

    private func begin(title: String, access: String, destination: String) -> Bool {
        guard let reporter, reporter.failureMessage == nil else {
            errorMessage = "Activity monitoring is unavailable. No Codex operation was started."
            return false
        }
        let id = reporter.begin(ActivityRun(category: .cloud, trigger: .manual,
            title: title, stage: "Starting", provider: "Codex", executionLocation: "This Mac → OpenAI",
            dataAccess: access, dataDestination: destination))
        guard reporter.failureMessage == nil else {
            errorMessage = "Activity monitoring could not save this operation. Nothing was sent to Codex."
            return false
        }
        isBusy = true
        isStopping = false
        errorMessage = nil
        status = "Starting"
        activityID = id
        return true
    }

    private func end() {
        isBusy = false
        isStopping = false
        worker = nil
        activityID = nil
    }

    private static func safeError(_ error: Error) -> String? {
        // Only our fixed vocabulary is suitable for UI. Native diagnostics may
        // contain private paths, provider text or authentication material.
        (error as? CodexInteractiveError)?.errorDescription
    }

    private static func safeSetupError(_ error: Error) -> String? {
        guard let known = error as? CodexInteractiveError else { return nil }
        switch known {
        case .unavailable, .interruptedUnknown:
            return "Codex stopped while preparing the isolated connection. No conversation message was sent."
        default: return known.errorDescription
        }
    }
}
