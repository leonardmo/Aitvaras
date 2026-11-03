import AppKit
import Foundation
import Observation
import AitvarasCore
import AitvarasStore
import AitvarasConnectors

protocol ClaudeWorkspaceTransport: Sendable {
    func status() async throws -> ClaudeInteractiveStatus
    func run(sessionID: String?, context: String, model: String, effort: String?, prompt: String, projectRoots: [String], userMessageID: UUID?,
             onEvent: @escaping @Sendable (ClaudeInteractiveEvent) async throws -> Void) async throws
    func readOwnedSession(sessionID: String, expectedProfileNamespace: String) async throws -> ClaudeOwnedHistorySnapshot
    func interrupt() async
    func shutdown() async
}

extension ClaudeInteractiveClient: ClaudeWorkspaceTransport {}

enum ClaudeConnectionPhase: Equatable {
    case idle, checking, waitingForBrowser, verifying, connected, signedOut, cancelled, failed
}

/// App-owned CLI sessions are never adopted from imported history or another
/// account namespace. Account checks and view selection send no chat message.
@MainActor @Observable
final class ClaudeWorkspaceModel {
    private(set) var sessions: [WorkspaceClaudeSession] = []
    private(set) var turns: [WorkspaceClaudeTurn] = []
    private(set) var models: [CodexInteractiveModel] = []
    private(set) var authenticated = false
    private(set) var accountChecked = false
    private(set) var accountLabel: String?
    private(set) var accountMode: ClaudeAccountMode = .shared
    private(set) var profileNamespace: String?
    private(set) var isBusy = false
    private(set) var isStopping = false
    private(set) var status: String?
    private(set) var errorMessage: String?
    private(set) var usageWindows: [CodexUsageWindow] = []
    private(set) var contextUsedTokens: Int?
    private(set) var contextLimitTokens: Int?
    private(set) var reviewedContext: String?
    private(set) var reviewRevision: Int?
    private(set) var projectIssue: String?
    private(set) var transcriptRevision = 0
    private(set) var historyRefreshStatus: String?
    private(set) var connectionPhase: ClaudeConnectionPhase = .idle
    private(set) var signInBrowserURL: URL?
    private(set) var requiresFreshSignIn = false
    var isSigningIn: Bool { connectionPhase == .waitingForBrowser || connectionPhase == .verifying }
    var selectedSessionID: UUID? { didSet { refreshTurns() } }
    var reporter: ActivityReporter?
    var canRefreshHistory: Bool {
        !isBusy && !terminating && authenticated && sessions.contains {
            $0.id == selectedSessionID && $0.externalID != nil && $0.profileNamespace == profileNamespace
        }
    }

    @ObservationIgnored private var stores: Stores?
    @ObservationIgnored private var client: (any ClaudeWorkspaceTransport)?
    @ObservationIgnored private var injectedTransport = false
    @ObservationIgnored private var signInClient: (any ClaudeSubscriptionSigningIn)?
    @ObservationIgnored private var injectedSignInGuidance: ClaudeLoginGuidance?
    @ObservationIgnored private var loadedChatID: UUID?
    @ObservationIgnored private var activeTurn: WorkspaceClaudeTurn?
    @ObservationIgnored private var pendingHandover: (plan: WorkspaceHandoverPlan, chatID: UUID)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var activityID: UUID?
    @ObservationIgnored private var lastCheckpoint = Date.distantPast
    @ObservationIgnored private var checkpointCharacters = 0
    @ObservationIgnored private var terminating = false

    static let accountModeKey = "workspace.claude.accountMode"
    static let maximumWireBytes = 65_536
    private var separateProfile: URL { AitvarasPaths.stateDirectory.appendingPathComponent("claude-interactive", isDirectory: true) }

    func configure(stores: Stores, reporter: ActivityReporter?, transport: (any ClaudeWorkspaceTransport)? = nil,
                   signInTransport: (any ClaudeSubscriptionSigningIn)? = nil,
                   signInGuidance: ClaudeLoginGuidance? = nil) throws {
        guard self.stores == nil else { return }
        _ = try stores.reconcileUnfinishedWorkspaceClaudeTurns()
        self.stores = stores
        self.reporter = reporter
        accountMode = (try stores.value(forKey: Self.accountModeKey)).flatMap(ClaudeAccountMode.init(rawValue:)) ?? .shared
        injectedTransport = transport != nil
        client = transport ?? ClaudeInteractiveClient(accountMode: accountMode, profileDirectory: separateProfile)
        signInClient = signInTransport ?? (transport == nil ? ClaudeSubscriptionSignIn(profileDirectory: separateProfile) : nil)
        injectedSignInGuidance = signInGuidance
    }

    func chooseAccountMode(_ next: ClaudeAccountMode) async {
        guard !isBusy, !terminating, next != accountMode, let stores else { return }
        do { try stores.setValue(next.rawValue, forKey: Self.accountModeKey) }
        catch { errorMessage = "The profile choice could not be saved. Nothing changed."; return }
        // Keep Send/Refresh out of the await between old-helper shutdown and
        // client replacement. Otherwise a turn could start on the old client.
        isBusy = true
        defer { isBusy = false; isStopping = false }
        await client?.shutdown()
        accountMode = next
        if !injectedTransport { client = ClaudeInteractiveClient(accountMode: next, profileDirectory: separateProfile) }
        clearAccount()
        requiresFreshSignIn = false
        connectionPhase = .idle; signInBrowserURL = nil
        status = "Profile changed. Check the account before sending."
    }

    /// One action: reuse an existing official login, or launch the official
    /// subscription browser flow and verify the selected profile on completion.
    func connectClaude() async {
        guard !isBusy, !terminating else { return }
        if !requiresFreshSignIn { await checkSetup() }
        guard !authenticated, requiresFreshSignIn || errorMessage == nil, !terminating, !isBusy else { return }
        guard let signInClient, let client,
              let guidance = injectedSignInGuidance ?? ClaudeInteractiveClient.loginGuidance(accountMode: accountMode, profileDirectory: separateProfile),
              begin(title: "Sign in to Claude", access: "Official subscription authentication; no files or chat messages",
                    destination: "Official Claude sign-in; credentials managed by Claude Code") else {
            errorMessage = errorMessage ?? "Claude Code sign-in is unavailable. Check the installation."
            connectionPhase = .failed
            return
        }
        signInBrowserURL = nil; connectionPhase = .waitingForBrowser
        status = "Finish sign-in in your browser"
        let task = Task { @MainActor in
            defer { self.end() }
            do {
                try await signInClient.signIn(guidance: guidance) { [weak self] url in
                    await MainActor.run {
                        guard let self, self.connectionPhase == .waitingForBrowser, !self.isStopping else { return }
                        self.signInBrowserURL = url
                    }
                }
                guard !self.isStopping, !self.terminating, !Task.isCancelled else { throw CancellationError() }
                self.connectionPhase = .verifying; self.status = "Verifying sign-in"
                self.reporter?.update(id: self.activityID!, stage: "Verifying account")
                let result = try await client.status()
                guard !self.isStopping, !self.terminating, !Task.isCancelled else { throw CancellationError() }
                guard result.authenticated else { throw ClaudeSubscriptionSignInError.verificationFailed }
                self.requiresFreshSignIn = false
                self.applyCheckedAccount(result)
                self.reporter?.finish(id: self.activityID!, state: .succeeded, outcome: "Claude subscription sign-in verified")
            } catch {
                let unconfirmed = (error as? ClaudeSubscriptionSignInError) == .stopUnconfirmed
                let cancelled = !unconfirmed && (self.isStopping || self.terminating || Task.isCancelled || error is CancellationError)
                self.connectionPhase = cancelled ? .cancelled : .failed
                self.status = cancelled ? "Sign-in cancelled" : "Sign-in did not finish"
                self.errorMessage = cancelled ? nil : (error as? ClaudeSubscriptionSignInError)?.errorDescription ?? Self.safeError(error) ?? "Sign-in did not finish. Try again or use Terminal under Advanced."
                self.reporter?.finish(id: self.activityID!, state: unconfirmed ? .outcomeUnknown : cancelled ? .cancelled : .failed,
                    outcome: unconfirmed ? "Official sign-in stop could not be confirmed" : cancelled ? "Official sign-in stopped" : "Official sign-in did not complete")
            }
            self.signInBrowserURL = nil
        }
        worker = task; await task.value
        if let loadedChatID, !terminating { load(chatID: loadedChatID) }
    }

    func reopenSignInBrowser() {
        guard connectionPhase == .waitingForBrowser, let url = signInBrowserURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func clearAccount() {
        authenticated = false; accountChecked = false; accountLabel = nil; profileNamespace = nil
        models = []; usageWindows = []; sessions = []; selectedSessionID = nil; turns = []
        contextUsedTokens = nil; contextLimitTokens = nil
        historyRefreshStatus = nil
        errorMessage = nil
    }

    /// Only this explicit button opens the official CLI's sign-in command.
    /// Check/Refresh never calls it, especially for the shared default profile.
    func openOfficialSignIn() {
        guard !injectedTransport, !AitvarasPaths.externalIntegrationsDisabled else {
            errorMessage = "External integrations are disabled for this Aitvaras profile."; return
        }
        guard !isBusy, !terminating,
              let guidance = ClaudeInteractiveClient.loginGuidance(accountMode: accountMode, profileDirectory: separateProfile) else {
            errorMessage = "Install the supported official Claude Code CLI before opening sign-in."; return
        }
        do {
            let directory = AitvarasPaths.stateDirectory.appendingPathComponent("claude-sign-in", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let script = directory.appendingPathComponent("official-sign-in.command")
            let env = ProcessInfo.processInfo.environment
            var clean = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                         "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "TERM": "xterm-256color"]
            for key in ["USER", "LOGNAME", "LANG"] { if let value = env[key] { clean[key] = value } }
            for (key, value) in guidance.environment { clean[key] = value }
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let assignments = clean.sorted { $0.key < $1.key }.map { quote("\($0.key)=\($0.value)") }
            let command = (["/usr/bin/env", "-i"] + assignments + [quote(guidance.executable)] + guidance.arguments.map(quote)).joined(separator: " ")
            try Data(("#!/bin/sh\nexec " + command + "\n").utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            clearAccount()
            connectionPhase = .signedOut
            status = "Finish in Terminal, then use Sign in to Claude to verify."
            NSWorkspace.shared.open([script], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if error != nil { Task { @MainActor [weak self] in self?.errorMessage = "Terminal could not open. Sign in using the official Claude Code CLI, then check again." } }
                }
        } catch { errorMessage = "The official sign-in command could not be prepared. Nothing was launched." }
    }

    func load(chatID: UUID) {
        guard !isBusy, let stores else { return }
        do {
            if loadedChatID != chatID { contextUsedTokens = nil; contextLimitTokens = nil; historyRefreshStatus = nil }
            let previous = loadedChatID == chatID ? selectedSessionID : nil
            loadedChatID = chatID
            sessions = try profileNamespace.map { try stores.workspaceClaudeSessions(chatID: chatID, profileNamespace: $0) } ?? []
            selectedSessionID = sessions.contains(where: { $0.id == previous }) ? previous : sessions.last?.id
            prepareReview(chatID: chatID, reportError: false)
        } catch { errorMessage = "Saved Claude conversations could not be loaded." }
    }

    private func refreshTurns() {
        do { turns = try selectedSessionID.map { try stores?.workspaceClaudeTurns(sessionID: $0) ?? [] } ?? [] }
        catch { errorMessage = "Saved Claude messages could not be loaded." }
    }

    func prepareReview(chatID: UUID, reportError: Bool = true) {
        guard !isBusy, let stores else { return }
        reviewedContext = nil; reviewRevision = nil
        do {
            let packet = try stores.workspaceContextPacket(chatID: chatID)
            guard packet.policyStatus == .reviewed,
                  try stores.workspacePolicy(projectID: packet.projectID)?.allowedProviders.contains(.claude) == true else {
                throw WorkspaceClaudeError.reviewRequired
            }
            reviewedContext = packet.promptText; reviewRevision = packet.policyRevision
            projectIssue = nil
        } catch {
            projectIssue = "Enable Claude in this project's settings and save."
            if reportError { errorMessage = projectIssue }
        }
    }

    /// Read-only metadata. This never signs in, switches an account or sends a prompt.
    func checkSetup() async {
        guard !isBusy, !terminating, let client,
              begin(title: "Check Claude account and models", access: "Selected Claude Code profile account metadata, model catalog and available quota",
                    destination: "Official Claude Code account services") else { return }
        connectionPhase = connectionPhase == .verifying ? .verifying : .checking
        let task = Task { @MainActor in
            defer { self.end() }
            do {
                let result = try await client.status()
                guard !self.isStopping, !self.terminating else { throw CancellationError() }
                self.applyCheckedAccount(result)
                self.reporter?.finish(id: self.activityID!, state: .succeeded, outcome: "Claude account metadata checked")
            } catch {
                self.clearAccount(); self.accountChecked = true
                self.connectionPhase = .failed
                self.status = "Claude setup could not be verified. Nothing was sent."
                self.errorMessage = Self.safeError(error) ?? "Check the official Claude Code installation and selected subscription profile, then refresh."
                self.reporter?.finish(id: self.activityID!, state: .failed, outcome: "Claude account metadata unavailable")
            }
            // Reload only after leaving the busy section; no old namespace can
            // survive an account change or a failed status check.
        }
        worker = task
        await task.value
        if let loadedChatID { load(chatID: loadedChatID) }
    }

    private func applyCheckedAccount(_ result: ClaudeInteractiveStatus) {
        if requiresFreshSignIn {
            clearAccount(); accountChecked = true; connectionPhase = .failed
            errorMessage = "Claude rejected the saved login. Reconnect to sign in again; the failed message will not be resent."
            return
        }
        let namespace = result.authenticated ? result.profileNamespace : nil
        if profileNamespace != namespace {
            sessions = []; selectedSessionID = nil
            contextUsedTokens = nil; contextLimitTokens = nil; historyRefreshStatus = nil
        }
        authenticated = result.authenticated; accountChecked = true
        accountLabel = result.accountLabel; profileNamespace = namespace
        models = result.authenticated ? result.models : []; usageWindows = result.usageWindows ?? []
        status = result.authenticated ? "Claude Code account connected" : "Claude Code sign-in required"
        connectionPhase = result.authenticated ? .connected : .signedOut; errorMessage = nil
    }

    func sendFromComposer(prompt: String, chatID: UUID, modelID: String, effort: String?) async {
        guard !isBusy, !terminating, loadedChatID == chatID, let stores else { return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= Stores.maximumWorkspaceClaudePromptCharacters, prompt.utf8.count <= Self.maximumWireBytes else {
            errorMessage = "Shorten this message before sending. Nothing was sent."; return
        }
        // Refresh every Send so a changed account can never resume a session
        // from a stale namespace. The helper independently verifies it again.
        let previousNamespace = profileNamespace
        await checkSetup()
        guard !terminating, loadedChatID == chatID, authenticated, let namespace = profileNamespace else { return }
        if let previousNamespace, previousNamespace != namespace {
            errorMessage = "The Claude account changed. Check the selected profile and send again; nothing was sent."; return
        }
        guard models.contains(where: { $0.id == modelID && (effort == nil || $0.efforts.contains(effort!)) }) else {
            errorMessage = "Choose an available Claude model and reasoning level. No fallback was used."; return
        }
        prepareReview(chatID: chatID)
        guard projectIssue == nil else { return }
        let current = sessions.first { $0.id == selectedSessionID }
        if current?.profileNamespace != namespace || current?.policyRevision != reviewRevision || current?.reviewedContext != reviewedContext
            || current?.model != modelID || current?.effort != effort || turns.contains(where: { $0.state.blocksNewTurn }) {
            selectedSessionID = nil
        }
        do {
            let allowed = try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.claude") == "1"
            if allowed, try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.claude.profile") != namespace {
                errorMessage = "This Claude profile has not been allowed to receive chat history. Confirm history sharing in AI Settings, or turn it off. Nothing was sent."
                return
            }
            if selectedSessionID == nil {
                guard let reviewedContext, let reviewRevision else { return }
                let session = try stores.createWorkspaceClaudeSession(chatID: chatID, profileNamespace: namespace,
                    model: modelID, effort: effort, expectedPolicyRevision: reviewRevision, reviewedContext: reviewedContext)
                sessions = try stores.workspaceClaudeSessions(chatID: chatID, profileNamespace: namespace)
                selectedSessionID = session.id
            }
            guard let sessionID = selectedSessionID else { return }
            let handover = allowed ? try stores.workspaceHandoverPlan(chatID: chatID,
                threadKey: WorkspaceThreadKey.claudeSession(sessionID), fittingBeside: prompt, maximumBytes: Self.maximumWireBytes) : nil
            await send(prompt: prompt, chatID: chatID, handover: handover)
        } catch { errorMessage = "Claude could not prepare this message. Check Project settings and local storage. Nothing was sent." }
    }

    /// A remembered choice belongs to one verified account namespace and chat.
    /// A new profile must never inherit a previous profile's positive grant.
    func historyDecision(chatID: UUID, profileNamespace namespace: String) throws -> Bool? {
        guard authenticated, profileNamespace == namespace, loadedChatID == chatID, let stores else { return nil }
        guard try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.claude.profile") == namespace,
              let choice = try stores.value(forKey: "workspace.chat.\(chatID).shareHistory.claude"),
              ["0", "1"].contains(choice) else { return nil }
        return choice == "1"
    }

    @discardableResult
    func saveHistoryDecision(_ share: Bool, chatID: UUID, profileNamespace namespace: String) -> Bool {
        guard !isBusy, !terminating, authenticated, profileNamespace == namespace, loadedChatID == chatID, let stores else {
            errorMessage = "The chat or Claude profile changed. Nothing was sent; press Send to review again."; return false
        }
        do {
            try stores.setValues(["workspace.chat.\(chatID).shareHistory.claude": share ? "1" : "0",
                                 "workspace.chat.\(chatID).shareHistory.claude.profile": namespace])
            return true
        } catch { errorMessage = "The history choice could not be saved. Nothing was sent."; return false }
    }

    private func send(prompt: String, chatID: UUID, handover: WorkspaceHandoverPlan?) async {
        guard !isBusy, !terminating, let stores, let client, let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }), authenticated,
              session.profileNamespace == profileNamespace, session.chatID == chatID, loadedChatID == chatID else { return }
        do {
            let roots = try stores.workspaceClaudeReadRoots(chatID: chatID, expectedPolicyRevision: session.policyRevision)
            var turn = try stores.beginWorkspaceClaudeTurn(sessionID: id, prompt: prompt)
            // Persist the UUID supplied to the SDK before the delivery barrier.
            // Projection dedup never relies on equal text or a made-up turn ID.
            do { try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: turn.id.uuidString, role: "user") }
            catch {
                turn.state = .failed; turn.endedAt = .now
                try? stores.saveWorkspaceClaudeTurn(turn)
                throw error
            }
            guard begin(title: "Claude reply", access: handover == nil
                ? "Reviewed project instructions and current message\(roots.isEmpty ? "" : "; approved read-only project files on request")"
                : "Reviewed project instructions, explicitly shared chat history and current message\(roots.isEmpty ? "" : "; approved read-only project files on request")",
                destination: "Anthropic via official Claude Code subscription") else {
                turn.state = .failed; turn.endedAt = .now; try stores.saveWorkspaceClaudeTurn(turn); refreshTurns(); return
            }
            activeTurn = turn; pendingHandover = handover.map { ($0, chatID) }
            contextUsedTokens = nil; contextLimitTokens = nil; lastCheckpoint = .now; checkpointCharacters = 0
            refreshTurns()
            let task = Task { @MainActor in
                defer { self.activeTurn = nil; self.pendingHandover = nil; self.refreshTurns(); self.end() }
                do {
                    try await client.run(sessionID: session.externalID, context: session.reviewedContext, model: session.model,
                        effort: session.effort, prompt: WorkspaceHandoverText.wire(handover: handover?.text, message: prompt), projectRoots: roots, userMessageID: turn.id) { [weak self] event in
                            guard let self else { throw CancellationError() }
                            try await self.receive(event, sessionID: id)
                        }
                    guard self.activeTurn?.state.isTerminal == true else { throw WorkspaceClaudeError.invalidTransition }
                } catch {
                    if self.activeTurn?.state.isTerminal == true {
                        self.errorMessage = "The Claude outcome is saved, but connection cleanup did not finish normally. Nothing will be replayed."
                        return
                    }
                    if var pending = self.activeTurn {
                        let undelivered = pending.state == .prepared
                        pending.state = undelivered ? (self.isStopping ? .cancelled : .failed) : .outcomeUnknown
                        pending.endedAt = .now
                        do {
                            try stores.saveWorkspaceClaudeTurn(pending); self.activeTurn = pending
                            if !undelivered || !self.isStopping {
                                try stores.recordWorkspaceClaudeTurnFailure(id: pending.id,
                                    reason: Self.safeError(error) ?? "Connection ended without a verified outcome.")
                            }
                        } catch { /* Startup reconciliation preserves uncertain delivery. */ }
                        self.errorMessage = undelivered
                            ? (self.isStopping ? "Stopped before sending. Nothing was sent." : "Nothing was sent. Check the connection, then press Send to try again.")
                            : "Claude stopped without a verified outcome. Partial text is saved where possible. This message will not be replayed."
                        self.reporter?.finish(id: self.activityID!, state: undelivered ? (self.isStopping ? .cancelled : .failed) : .outcomeUnknown,
                            outcome: undelivered ? "Stopped before delivery; nothing sent" : "Unverified provider outcome; no automatic retry")
                    }
                }
            }
            worker = task; await task.value
            if let saved = try? stores.workspaceClaudeTurn(id: turn.id), saved.providerTurnID != nil,
               [.completed, .cancelled, .failed].contains(saved.state) {
                // Finishing the explicitly requested Send is not a new automatic job.
                await refreshHistory(chatID: chatID, sessionID: id, trigger: .manual)
            }
        } catch {
            if (error as? WorkspaceClaudeError) == .staleContext {
                selectedSessionID = nil
                errorMessage = "The reviewed project context changed. Press Send to prepare a fresh connection; nothing was sent."
            } else { errorMessage = "Message not sent. Check Project settings and local storage." }
            refreshTurns()
        }
    }

    private func receive(_ event: ClaudeInteractiveEvent, sessionID: UUID) throws {
        guard let stores, var turn = activeTurn, !turn.state.isTerminal else { throw WorkspaceClaudeError.invalidTransition }
        switch event {
        case .sessionCreated(let externalID):
            _ = try stores.bindWorkspaceClaudeSession(id: sessionID, externalID: externalID)
            if let chatID = loadedChatID, let profileNamespace { sessions = try stores.workspaceClaudeSessions(chatID: chatID, profileNamespace: profileNamespace) }
        case .deliveryAttempt:
            guard turn.state == .prepared, !isStopping else { throw CancellationError() }
            turn.state = .running; try stores.saveWorkspaceClaudeTurn(turn)
        case .turnStarted(let externalID):
            guard turn.state == .running || turn.state == .cancellationRequested else { throw WorkspaceClaudeError.invalidTransition }
            turn.providerTurnID = externalID; try stores.saveWorkspaceClaudeTurn(turn)
            if let (plan, chatID) = pendingHandover {
                pendingHandover = nil
                _ = try? stores.recordWorkspaceHandover(plan, chatID: chatID, turnID: turn.id, anchor: turn.startedAt.addingTimeInterval(-0.001))
            }
            status = isStopping ? "Stop requested · awaiting Claude" : "Claude is responding"
            reporter?.update(id: activityID!, stage: status)
        case .textDelta(let text):
            guard turn.state != .prepared, turn.outputText.count + text.count <= 200_000 else { throw WorkspaceClaudeError.invalidTransition }
            turn.outputText += text
            if Date.now.timeIntervalSince(lastCheckpoint) >= 0.5 || turn.outputText.count - checkpointCharacters >= 4096 {
                try stores.saveWorkspaceClaudeTurn(turn); lastCheckpoint = .now; checkpointCharacters = turn.outputText.count
            }
        case .assistantMessage(let externalID, _):
            guard turn.state != .prepared else { throw WorkspaceClaudeError.invalidTransition }
            try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: externalID, role: "assistant")
        case .providerFailure(let code, let messageID):
            if let messageID {
                // Remember the SDK-generated error identity so a later native
                // history refresh cannot resurrect its prose as an answer.
                try stores.recordWorkspaceClaudeMessageIdentity(turnID: turn.id, externalID: messageID, role: "assistant")
            }
            turn.failureReason = code
            if code == "authenticationRequired" {
                requiresFreshSignIn = true
                authenticated = false; accountChecked = true; models = []; usageWindows = []
                connectionPhase = .failed
                errorMessage = "Claude rejected the saved login. Reconnect to sign in again; the failed message will not be resent."
            } else {
                errorMessage = code == "usageLimit" ? "Claude's usage limit was reached. This message was not retried."
                    : "Claude rejected this request. The failed message was not retried."
            }
        case .contextUsage(let used, let limit): contextUsedTokens = used; contextLimitTokens = limit
        case .projectFileAccess(let tool, let path, let bytes):
            let detail = try JSONSerialization.data(withJSONObject: ["tool": tool, "path": path, "bytes": bytes])
            _ = try stores.record(ActivityEvent(kind: .toolExecuted, connectorID: "claude", summary: "Read-only project file request",
                detailJSON: String(decoding: detail, as: UTF8.self), runID: activityID))
        case .completed(let state, let inputTokens, let outputTokens):
            guard turn.state != .prepared else { throw WorkspaceClaudeError.invalidTransition }
            switch state { case "completed": turn.state = .completed; case "interrupted": turn.state = .cancelled
            case "failed": turn.state = .failed; default: throw WorkspaceClaudeError.invalidTransition }
            turn.inputTokens = inputTokens; turn.outputTokens = outputTokens; turn.endedAt = .now
            try stores.saveWorkspaceClaudeTurn(turn, allowCompletedAfterCancellation: true)
            reporter?.finish(id: activityID!, state: turn.state == .completed ? .succeeded : turn.state == .cancelled ? .cancelled : .failed,
                outcome: "Claude turn \(turn.state.rawValue)")
            status = turn.state == .completed ? "Reply saved" : turn.state == .cancelled ? "Claude confirmed the stop" : "Claude reported a failed turn"
        }
        activeTurn = turn
        if let index = turns.firstIndex(where: { $0.id == turn.id }) { turns[index] = turn }
    }

    /// Read-only refresh of an already-bound, app-owned session. This neither
    /// sends a prompt nor treats observed text as proof of a turn's outcome.
    func refreshHistory(chatID: UUID, sessionID requestedID: UUID? = nil, trigger: ActivityTrigger = .manual) async {
        guard !isBusy, !terminating, authenticated, loadedChatID == chatID,
              let stores, let client, let namespace = profileNamespace,
              let id = requestedID ?? selectedSessionID,
              let session = sessions.first(where: { $0.id == id && $0.chatID == chatID && $0.profileNamespace == namespace }),
              let externalID = session.externalID else { return }
        let previousStatus = status, previousError = errorMessage
        guard begin(title: "Refresh Claude conversation", access: "Text from this app-owned Claude Code session and account metadata; no model request",
                    destination: "Local read-only Claude Code history projection", trigger: trigger) else { return }
        let task = Task { @MainActor in
            defer { self.end(); self.status = previousStatus; self.errorMessage = previousError }
            do {
                let snapshot = try await client.readOwnedSession(sessionID: externalID, expectedProfileNamespace: namespace)
                guard !self.isStopping, !self.terminating, self.loadedChatID == chatID,
                      self.profileNamespace == namespace else { throw CancellationError() }
                try stores.replaceWorkspaceClaudeProjection(sessionID: id, expectedProfileNamespace: namespace, snapshot: snapshot)
                self.transcriptRevision += 1
                self.historyRefreshStatus = "Claude Code text refreshed \(Date.now.formatted(date: .omitted, time: .shortened))"
                self.reporter?.finish(id: self.activityID!, state: .succeeded, outcome: "Owned Claude session text refreshed; turn outcomes unchanged")
            } catch {
                self.historyRefreshStatus = "Saved text kept; Claude Code history could not be refreshed."
                self.reporter?.finish(id: self.activityID!, state: self.isStopping ? .cancelled : .failed,
                    outcome: "Claude history refresh did not replace saved text")
            }
        }
        worker = task; await task.value
    }

    func stop() async {
        if isSigningIn, isBusy, !isStopping {
            isStopping = true
            status = "Cancelling sign-in"
            if let activityID { reporter?.update(id: activityID, stage: "Cancelling sign-in", state: .cancellationRequested) }
            worker?.cancel()
            await signInClient?.cancel()
            await client?.interrupt()
            return
        }
        guard isBusy, !isStopping, activeTurn?.state.isTerminal != true, let client else { return }
        isStopping = true; status = "Stop requested · awaiting Claude"
        if activeTurn?.state == .prepared { status = "Stopping before sending" }
        else if var turn = activeTurn {
            turn.state = .cancellationRequested
            do { try stores?.saveWorkspaceClaudeTurn(turn); activeTurn = turn; refreshTurns() }
            catch { errorMessage = "The stop request could not be saved. Waiting for Claude's actual outcome." }
        }
        if let activityID { reporter?.update(id: activityID, stage: "Stop requested", state: .cancellationRequested) }
        await client.interrupt()
    }

    func stopBeforeTermination() async {
        terminating = true; let pending = worker
        await stop(); await client?.shutdown(); await pending?.value
    }
    func resumeAfterCancelledTermination() { terminating = false }

    private func begin(title: String, access: String, destination: String, trigger: ActivityTrigger = .manual) -> Bool {
        guard let reporter, reporter.failureMessage == nil else { errorMessage = "Activity monitoring is unavailable. No Claude operation started."; return false }
        let id = reporter.begin(ActivityRun(category: .cloud, trigger: trigger, title: title, stage: "Starting", provider: "Claude",
            executionLocation: "This Mac → Anthropic", dataAccess: access, dataDestination: destination))
        guard reporter.failureMessage == nil else { errorMessage = "Activity monitoring could not save this operation. Nothing was sent."; return false }
        activityID = id; isBusy = true; isStopping = false; errorMessage = nil; status = "Starting"
        return true
    }
    private func end() { isBusy = false; isStopping = false; worker = nil; activityID = nil }
    private static func safeError(_ error: Error) -> String? { (error as? ClaudeInteractiveError)?.errorDescription }
}
